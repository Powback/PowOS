# PowOS compute mesh — sharing resources and moving containers between hosts

Status: **design, for later implementation** (2026-10-20). Nothing here is built. §3 lists kernel facts read
back from the phone (USB adb, read-only `zcat /proc/config.gz`), from the built containers kernel
(`targets/android/kernel/out/config`), from the OnePlus kernel source in the `powos-gki-cache` volume (read-only
mount) and from the Colima VM (`colima ssh`, read-only). Nothing on any device was changed.

Problem, in the user's words: "we will now have about 5 devices running powos connected over vpn, some mobile some
desktops some servers. the container system can allow us to do resource sharing so that we can seamlessly transfer
one container from one system to another for cross device compute capabilities".

This doc designs that on top of `docs/REMOTE-POWOS.md` (hosts, realm identity, WireGuard, STDB-to-STDB sync, the
migration steps M0–M8) and the app model in `docs/POWOS-APPS-FEASIBILITY.md` (tiers, manifest, runtime switch,
per-table sync). It adds no new transport and no new identity: workloads, devices and moves are rows in a
SpacetimeDB module, executed by each host's own daemon (REMOTE-POWOS §2.1 rule 2: "rows cross hosts, never shell
commands").

Related: `docs/PHONE-KERNEL-CONTAINERS.md` (the phone's container kernel, podman results §11, the hybrid-cgroup plan
§9 step 3), `docs/AGENTS-VIEW-DESIGN.md` (the work board, §1.3 screen, §8 module), `~/Projects/CLAUDE.md`
(PowStation, Pi-hole/dns-sync, WireGuard `10.13.13.0/24`, NAS PowCache).

Terms (in addition to REMOTE-POWOS's *host*, *hub*, *realm*):

| term | meaning |
|---|---|
| workload | one thing the mesh can place: a container (Tier 2 app, a dev box, a service) or a job (build, transcode, inference). Has a spec, an owner, a current runner |
| runner | the host a workload is running on right now |
| owner | the host that is authoritative for a workload's row and its placement (§5.1). Default: the host it was created on |
| move | stop-or-freeze on one runner, start on another, with state carried by one of the three modes in §2 |
| lease | the single-writer right to run a workload and write its volumes; an epoch number fences stale runners (§6.3) |

---

## 1. The fleet

### 1.1 Device classes

| host id | device | arch / CPU | RAM | runtime | power | network | trust tier (§8.3) |
|---|---|---|---|---|---|---|---|
| `phone` | OnePlus Open CPH2551, SM8550 | arm64: 1×X3 (0xd4e), 2×A715 (0xd4d), 2×A710 (0xd47), 3×A510 (0xd46). HWCAPs include `paca pacg bti sm3 sm4`, **no `sve`** | 15.5 GB | podman 6.1.4 + crun in the Arch Linux ARM PowOS root; rootless as `powos` day to day, rootful in PowOS's own mount ns for tests (§11.1); vfs storage (f2fs); `netns=host`, `ipcns=host` | battery, AC sometimes | Wi-Fi `192.168.50.239`, WireGuard `10.13.13.7` (`tun0`, the WireGuard app), mobile data (metered) | personal |
| `razr` | Motorola razr fold (2026) | arm64, Snapdragon 8 Elite (Gen 5) per the web: **Qualcomm Oryon cores**, not Arm-designed. Check `getprop ro.soc.model` and `/proc/cpuinfo` on day 1 | up to 16 GB | the same PowOS-on-Android stack once ported (memory: `powos-razr-fold`) | battery | Wi-Fi, WireGuard, mobile | personal |
| `hub` | Mac Studio M4 Max, the **Colima VM** `192.168.50.100` (bridged) | arm64 (Apple cores under Virtualization.framework). Guest HWCAPs include `paca pacg bti afp`, no `sm3/sm4`, no `sve` | VM 58 GB of 64 | Docker (no podman, no criu in the VM today), kernel Ubuntu `6.8.0-100-generic` | AC, always on | LAN, holds the WireGuard server; Traefik, Pi-hole | infra |
| `mac` | the Mac itself `192.168.50.99` | arm64 (macOS) | — | none for containers (all containers run in the VM); runs Claude sessions, the agentsd reporter | AC | LAN; not a WireGuard peer (REMOTE-POWOS C7, open question 3) | personal (agents only, not a runner) |
| `desk…` | x86 desktops with NVIDIA (one or more) | x86_64, NVIDIA (RTX 50-series path: `bazzite-nvidia-open`) | 32–64 GB typical | PowOS/Bazzite: podman rootless + rootful, cgroup v2, btrfs, Fedora kernel (`CHECKPOINT_RESTORE=y` in Fedora's config, to confirm per host) | AC, but sleeps; may be in a game | LAN + WireGuard | personal |
| `srv…` | servers (headless PowOS or Bazzite installs, x86 or arm64) | as installed | as installed | podman | AC, always on | LAN + WireGuard | infra |
| `nas` | Synology PowCache `192.168.50.231` | — | — | **storage only** (NFS/SMB/S3), not a runner | AC | LAN | infra |
| `web` | PowOS Web (qemu-wasm) | wasm | — | never a runner (REMOTE-POWOS: a host for viewing) | — | — | personal |

Rows are per host, not per class; the fleet table is what `powos mesh devices` prints (§9.1), from §4's inventory.

### 1.2 The architecture split

There are two pools, and a third distinction inside the arm64 one:

| pool | hosts | what crosses freely | what doesn't |
|---|---|---|---|
| **arm64** | phone, razr, hub (Colima VM), arm64 servers | arm64 images; volumes; STDB state | live processes between **different CPU vendors** (§3.4: pointer-authentication algorithm, HWCAP sets) |
| **x86_64** | desktops, x86 servers | amd64 images; volumes; live processes (CRIU, CPU features masked to a common baseline) | — |
| across pools | any ↔ any | multi-arch images (an OCI index with `linux/arm64` + `linux/amd64`), volumes, STDB state | live processes, ever. Emulation (qemu-user / Rosetta in the hub's VM, FEX on the phone) runs a foreign image **slowly**, never restores a foreign checkpoint |

Consequence for everything below: **a move between pools is always a restart (§2.2) or a "run it there" (§2.3).**
Live migration (§2.1) is a same-pool optimisation, realistically within x86 and within one phone SoC family.

---

## 2. Three move modes

| | (a) live: CRIU checkpoint/restore | (b) restart elsewhere | (c) state in STDB: "run it there" |
|---|---|---|---|
| carries | process memory, open files, threads, timers, (optionally) established TCP | the container's volumes (and its writable layer if asked) | nothing: state is already on every host |
| arch | same arch **and** compatible CPU (§3.4) | any: needs an image for the target arch | any: needs an image (or no image: Tier 0) |
| downtime | freeze → transfer → restore: ~1–3 s + transfer of RSS (a 200 MB process over Wi-Fi ≈ 4–8 s) | stop → final volume delta → start: cold start (270–460 ms on the phone) + delta transfer + the app's own startup | stop → start: cold start only |
| what the app sees | nothing (same pid, same memory); clocks continue (`TIME_NS`) | a restart: like a reboot of that container | a restart; its data is the same rows |
| privileges | **root on both ends** (podman checkpoint is rootful only; CRIU needs `CAP_CHECKPOINT_RESTORE`/`CAP_SYS_ADMIN`) | rootless is fine | rootless is fine |
| failure | restore fails → source resumes from its frozen state (it was never killed) | target fails health check → source restarts with its own volume (lease not committed) | target fails → start again on the old host |
| kernel needs | §3 | none beyond running containers | none |

### 2.1 (a) Live checkpoint/restore

Mechanism: `podman container checkpoint --export=<file>.tar.zst --compress=zstd [--tcp-established]
[--keep]` on the source, transfer, `podman container restore --import=<file> [--name] [--tcp-established]` on the
target. The export holds the CRIU image, the container's config and its writable layer's diff; named volumes are
not in it and go through §6. With `--pre-checkpoint` / `--with-previous` (x86 only: needs soft-dirty, §3.3) the
bulk of memory is copied while the container runs and only the last dirty pages during the freeze. arm64 has no
soft-dirty tracking; the arm64 alternative for big processes is CRIU's lazy pages (`--lazy-pages`, userfaultfd on
the target pulls pages on fault from the source's page server), which the phone and hub kernels have
(`USERFAULTFD=y`).

**Applies when all hold:**
1. Source and target are in the same pool and CPU-compatible (§3.4): target HWCAPs ⊇ source HWCAPs, and the same
   pointer-authentication algorithm (same CPU vendor family) for any PAC-built binary.
2. Both run podman with CRIU ≥ 4.0 and a kernel with §3.1's options; both are rootful-capable through the local
   privileged helper (§8.2).
3. The workload is in the same image digest on both (the restore needs the same rootfs lower layers).
4. The container has no devices CRIU can't dump: no GPU (unless §5.5's CUDA path), no `/dev/kgsl-3d0`, no
   `/dev/fuse` mounts held open, no Binder.
5. Its network is its own netns (pasta/netavark), not `netns=host` (today's phone default): a host-netns
   container's sockets belong to the host and can't be carried. With `--tcp-established`, the target must own the
   same IP: the workload's mesh VIP (§7.2).

**Realistic pairs:** desk ↔ desk / x86 server (the strongest case: heavy, long-lived dev boxes and builds);
phone ↔ phone of the same SoC (only one today). **Not**: phone ↔ hub (Arm cores vs Apple cores, §3.4), phone ↔
razr (Arm cores vs Oryon) until measured.

### 2.2 (b) Restart elsewhere

Mechanism: the target pulls the workload's image by **index digest** (it picks its own arch's manifest), the
volume is pre-synced while the source still runs, the source stops (`podman stop`, SIGTERM then the spec's
timeout), a final delta goes over, the lease moves (§6.3), the target starts and passes its health check, the source
deletes its container instance (volumes kept for the grace period, §6.4).

**Applies:** every cross-arch move; every move of a container that uses `netns=host`, devices or anything else (a)
refuses; every move where seconds of downtime are fine (most services, dev boxes between sessions, anything moved by
policy rather than by the user mid-task). **This is the default mode.**

Requirements on the workload: a multi-arch image (or one arch, which limits placement to that pool); state only in
declared volumes (no state in the writable layer unless `--with-rootfs-diff`, same arch only); tolerating SIGTERM.

### 2.3 (c) State in STDB

A workload whose state lives in SpacetimeDB synced tables (REMOTE-POWOS §2.5 option B, M7) has nothing to carry:
every host already has the rows. A move is "stop there, start here", and **so is placement**: the mesh can run the
same workload on whichever host is best right now with no transfer at all.

This is the design target for PowOS apps, and the reason to prefer it:
- **Tier 0** (module-only) apps don't move: every host runs its own module and syncs (FEASIBILITY §5.2).
- **Tier 1** workers (the shared runtime) and **Tier 2** backends should keep durable state in their app's synced
  tables and use volumes only for caches (re-creatable) — then they are mode (c).
- Agents: a Claude session's state is its transcript (`~/.claude/projects/…`) plus the comms spool. With the
  transcript in a synced volume (§6) or, later, a synced table, "move this agent to the desk" is (b)/(c): stop,
  start `claude --resume` there; mail follows `role@host` (REMOTE-POWOS §2.7).

**Applies** whenever the manifest's `sync.tables` covers all durable state and `volumes` are all `cache`. The
scheduler prefers (c) > (b) > (a) for automatic moves; the user can ask for (a) explicitly (`--mode live`).

### 2.4 Which mode, decided

```
user asked --mode X                      → X, or refuse with the reason (never silently downgrade a "live")
all state in STDB, volumes cache-only    → (c)
same pool, CPU-compatible, (a)'s list ok,
  and the workload is marked live-capable → (a), fall back to (b) only if --mode auto
otherwise                                → (b)
no image for the target's arch           → not placeable there (filtered in §5.2)
```

Jobs (`kind: job`) never move mid-run except by (a); otherwise they are cancelled and re-run from their inputs
(they must be idempotent: §5.4).

---

## 3. Kernel requirements

### 3.1 What CRIU needs

From CRIU's kernel requirements and `criu check --all`:

| option | why | required? |
|---|---|---|
| `CHECKPOINT_RESTORE` | `prctl(PR_SET_MM_MAP)`, `/proc/sys/kernel/ns_last_pid`, `/proc/<pid>/task/<tid>/children` (selects `PROC_CHILDREN`), seccomp filter dump, timerfd/inotify/fcntl extras; on arm64 also the `NT_ARM_PACA_KEYS`/`NT_ARM_PACG_KEYS` ptrace regsets (pointer-auth keys; guarded in `arch/arm64/kernel/ptrace.c`) | **yes** |
| `NAMESPACES`, `PID_NS`, `NET_NS`, `UTS_NS`, `USER_NS`, `IPC_NS` | container namespaces | yes (`IPC_NS` only if the container has its own IPC ns) |
| `TIME_NS` | restores `CLOCK_MONOTONIC`/`BOOTTIME` offsets so timers don't jump between hosts | yes for cross-host |
| `KCMP` | sharing detection of files/mm/fs between tasks | yes |
| `MEMFD_CREATE`, `SHMEM`, `TMPFS` | memfd and shared memory | yes |
| `FHANDLE`, `EVENTFD`, `EPOLL`, `INOTIFY_USER` | dump/restore of those fds | yes |
| `FANOTIFY` | only if the workload uses fanotify | optional |
| `UNIX_DIAG` | dump of **any** unix socket (almost every process has one) | **yes** |
| `INET_DIAG`, `INET_TCP_DIAG`, `INET_UDP_DIAG` (+ `INET_RAW_DIAG`) | TCP/UDP socket dump | yes (raw: optional) |
| `PACKET_DIAG`, `NETLINK_DIAG` | packet and netlink sockets (netlink is common: anything that talks to rtnetlink) | **yes** |
| `TUN` | pasta, tun fds | yes for pasta-networked containers |
| `USERFAULTFD` | lazy pages / post-copy migration | optional, needed for big arm64 moves |
| `MEM_SOFT_DIRTY` | iterative pre-copy (`--pre-checkpoint`) | optional; **x86, ppc64 and s390 only** (`HAVE_ARCH_SOFT_DIRTY` is not selected by arm64 in 5.15) |
| `NETFILTER_XT_MARK` / nftables | CRIU's network lock during dump (`--network-lock iptables|nftables`) | yes (either) |

### 3.2 The phone, as it runs today (read 2026-10-20)

Read with `ANDROID_SERIAL=8e5d600d adb shell 'zcat /proc/config.gz'` (no root). Running kernel
`5.15.180-o-g298ff0fe2773-dirty #4 SMP PREEMPT Tue Oct 20 00:05:31 UTC 2026` = the flashed containers kernel
(PHONE-KERNEL-CONTAINERS §9 step 1; `pids` in `/proc/cgroups`). Identical to `targets/android/kernel/out/config` for
every option below.

| option | phone | effect for CRIU |
|---|---|---|
| `CHECKPOINT_RESTORE` | **not set** | **blocks CRIU.** Confirmed at runtime: `/proc/sys/kernel/ns_last_pid` does not exist |
| `PROC_CHILDREN` | **not set** (selected by the above) | blocks CRIU's task tree walk |
| `UNIX_DIAG` | **not set** | blocks (any unix socket) |
| `PACKET_DIAG` | **not set** | blocks for packet sockets; `criu check` fails |
| `NETLINK_DIAG` | **not set** | blocks for netlink sockets |
| `INET_RAW_DIAG` | not set | optional |
| `FANOTIFY` | not set | optional |
| `IPC_NS`, `SYSVIPC`, `POSIX_MQUEUE` | not set | containers run `ipcns=host` (known; KMI-unsafe, PHONE-KERNEL §2); CRIU treats the IPC ns as external, fine because there is no SysV IPC at all |
| `MEM_SOFT_DIRTY` | absent (arm64) | no iterative pre-copy |
| `INET_DIAG`, `INET_TCP_DIAG`, `INET_UDP_DIAG`, `INET_DIAG_DESTROY` | y | ok |
| `KCMP` | y | ok |
| `MEMFD_CREATE`, `SHMEM`, `TMPFS` | y | ok (`TMPFS_XATTR` not set: irrelevant to CRIU) |
| `USERFAULTFD` | y (`HAVE_ARCH_USERFAULTFD_MINOR=y`) | lazy pages possible |
| `TIME_NS` | y | ok |
| `NAMESPACES`, `PID_NS`, `NET_NS`, `UTS_NS`, `USER_NS` | y | ok |
| `FHANDLE`, `EVENTFD`, `EPOLL`, `INOTIFY_USER`, `TUN`, `SECCOMP_FILTER`, `BPF_SYSCALL`, `CGROUP_FREEZER` | y | ok |
| `NETFILTER_XT_MARK`, `IP_NF_IPTABLES`; `NF_TABLES` (=m, PHONE-KERNEL patch 0003) | y / m | network lock either way |
| `CGROUP_PIDS`, `CFS_BANDWIDTH` | y (patches 0001/0002) | limits for restored containers |
| `/proc/<pid>/map_files` | present | ok (ungated since 4.3) |

Also missing in userspace: `criu` is not in the PowOS root's package set (only mention in the tree:
`targets/android/phone-rules.conf`), and podman checkpoint needs rootful podman with cgroups handled (today
`cgroups=disabled` outside the `-v2test` RAM boot, §3.5).

**Verdict: the phone cannot checkpoint today.** Mode (b) and (c) work on it as soon as containers do.

### 3.3 What adding CRIU to the phone kernel costs (estimate, not built)

Same route as PHONE-KERNEL-CONTAINERS §4 (route (a), extended; `build-containers-kernel.sh` with one more fragment):

| option | type | KMI outlook | evidence |
|---|---|---|---|
| `CHECKPOINT_RESTORE=y` (+ `PROC_CHILDREN`) | bool → **Image** | **Probably layout-neutral.** In the OnePlus tree (`common-containers`, read-only), its guards are in `.c` files only (`kernel/sys.c`, `kernel/pid_namespace.c`, `kernel/ptrace.c`, `kernel/seccomp.c`, `fs/proc/base.c`, `fs/fcntl.c`, `fs/timerfd.c`, `fs/notify/inotify/inotify_user.c`, `fs/autofs/inode.c`, `ipc/*`, `arch/arm64/kernel/ptrace.c`) plus two headers: `include/linux/ipc_namespace.h:23` (inside `SYSVIPC`, which is off) and a function declaration in `seccomp.h`. No struct field appears. Must still pass `kmi-check.py` (CRCs) and `layout-diff.py` (pahole) against the 836 vendor modules, exactly as for patches 0001–0003 | grep of the tree, 2026-10-20 |
| `UNIX_DIAG`, `PACKET_DIAG`, `NETLINK_DIAG`, `INET_RAW_DIAG` | tristate → **`.ko`** | modules only, like the 22 nftables modules: Image untouched by them, loaded by the system module's `post-fs-data.sh` | Kconfig |
| `FANOTIFY` | bool → Image | adds `fsnotify` group fields (`struct fsnotify_group` union) — **likely a layout change**; leave it out | — |

Cost: one more full-LTO build (~1.5–2.5 h link, PHONE-KERNEL §6), `fastboot boot` test with the go/no-go list
(§7.5 there) plus `criu check --all` in the PowOS root, then a flash decision by the user. A separate decision from
this doc; phase 5 (§10) depends on it.

### 3.4 Same arch is not enough: CPU compatibility

Read 2026-10-20 (`/proc/cpuinfo` Features):

| HWCAP | phone (SM8550) | hub VM (M4) |
|---|---|---|
| `sm3`, `sm4` | yes | **no** |
| `afp` | no | **yes** |
| `paca`, `pacg`, `bti` | yes | yes |
| `sve`, `sve2`, `sme` | no | no |
| page size | 4 KiB | 4 KiB |

Two problems for live moves between them:
1. **HWCAP sets are not ordered.** glibc, OpenSSL and others pick code paths (ifuncs, `getauxval(AT_HWCAP)`) once at
   startup. A process restored on a CPU without a feature it selected dies with SIGILL the first time it uses it
   (phone → hub: SM3/SM4 code in OpenSSL; hub → phone: anything keyed on `afp`). CRIU's `--cpu-cap` checks this on
   x86; on arm64 PowOS must check it itself: restore only if `target ⊇ source`.
2. **Pointer authentication.** Both expose `paca`, but Arm-designed cores implement QARMA and Apple's cores an
   implementation-defined algorithm. A PAC-signed return address on a restored stack, even with the keys carried
   over (`NT_ARM_PACA_KEYS`, needs `CHECKPOINT_RESTORE`), authenticates only on the same algorithm. Distro
   userlands built with `-mbranch-protection=standard` (Ubuntu, Debian, Fedora on arm64; Arch Linux ARM: to check)
   will crash. **To verify** in phase 0 (expected: fail), not assumed.

So the mesh records a **CPU compatibility class** per host (§4: `cpu_class` = vendor + PAC algorithm family +
HWCAP bitmap) and allows (a) only when the classes match or the target's HWCAPs are a superset with the same PAC
family. On x86, CRIU's `--cpu-cap=cpu` plus a common baseline (e.g. x86-64-v3) for live-capable workloads is the
known recipe.

### 3.5 Other kernels

| host | kernel | CRIU options | notes |
|---|---|---|---|
| hub (Colima VM) | Ubuntu `6.8.0-100-generic` aarch64 | `CHECKPOINT_RESTORE=y`, `USERFAULTFD=y`, `TIME_NS=y`, `UNIX_DIAG=m`, `PACKET_DIAG=m`, `NETLINK_DIAG=m` (read 2026-10-20) | Kernel-ready. No podman, no criu installed; Docker's `checkpoint` is experimental and Docker-only. Installing podman + criu in the VM is a change to PowStation's VM (needs the user's OK). Only useful for hub ↔ another Apple-core host — there is none — so **(a) on the hub is not worth doing**; the hub uses (b)/(c) |
| desk / x86 servers | Fedora/Bazzite kernel | Fedora ships `CHECKPOINT_RESTORE=y` and the DIAG options; `criu` is a Fedora package | To confirm per host on enrollment (`criu check --all` in `powos mesh devices --probe`). Rootful podman via the privileged helper |
| razr | unknown until day 1 | — | Same exercise as §3.2 |

Cgroups, for any restored or restarted container on the phone: podman 6 wants v2 controllers, which Android keeps
in v1 (PHONE-KERNEL §7.4/§9 step 3). Until that's decided, the phone runs containers with `--cgroups=disabled` and
the supervisor puts conmon into the v1 `memcg`/`cpuctl` and v2 `pids` groups (the hybrid plan, §9 step 3 there).
Whether `podman container checkpoint` works with `cgroups=disabled` (CRIU then freezes by ptrace, not the freezer
cgroup) is an **open question** (§11).

---

## 4. Resource inventory

### 4.1 What each host publishes

One row per host in the `powos-mesh` module (§5.1), table `device`:

| field | example (phone) | source |
|---|---|---|
| `host` | `phone` | REMOTE-POWOS host id (directory row, M5) |
| `arch`, `cpu_class` | `arm64`, `arm-qarma/0x…` (HWCAP bitmap) | `uname -m`, `/proc/cpuinfo`, `getauxval` |
| `cpus`, `cpu_free` | 8, 5.1 | `/proc/stat` over the interval, minus PowOS's reserve (phone: 2 cores for Android/UI) |
| `mem_total`, `mem_free` | 15.5 GB, 4.2 GB | `MemAvailable` minus a reserve (phone: 4 GB for Android; lmkd must never kill the UI for a guest) |
| `gpus` | `[]` / `[{vendor:"nvidia", model:"RTX 5080", mem:16G, free:14G, busy:false}]` | `nvidia-smi --query-gpu`, CDI spec present; the phone's Adreno is never offered |
| `power` | `{ac:false, battery:63, charging:false, saver:false}` | `/sys/class/power_supply`, Android `BatteryManager` via the shell bridge |
| `thermal` | `normal` \| `warm` \| `throttling` \| `critical` | Android thermal status / `/sys/class/thermal`; desktops: CPU package temp vs Tj max |
| `user_active` | `foreground-game` \| `interactive` \| `idle 12m` \| `locked` | logind idle hint, gamescope/Steam game running, phone screen state |
| `net` | `{via:"wifi", metered:false, wg_rtt_ms:{hub:4}, up_mbps:80}` | Android `ConnectivityManager` (metered flag), WireGuard handshake + a 1-ping RTT to peers, measured throughput of the last transfer |
| `storage_free` | `{containers: 21G}` | `statfs` on the container storage |
| `runtimes` | `{podman:"6.1.4", criu:null, rootful:true, cgroups:"hybrid", live:false}` | probes at start and on change |
| `images` | digests present locally (top 50) | `podman images --digests` |
| `trust` | `personal` | from the directory (enrollment), **not** self-declared: the hub ignores this field from the host itself |
| `accepting` | `true` | user switch (`powos mesh accept off`), drain state, policy |
| `seen`, `seq` | timestamp, counter | — |

Rows carry no secrets and no file paths beyond names (REMOTE-POWOS §2.9).

### 4.2 How it stays fresh

Inventory is the one place this design **pushes** instead of subscribing: a remote subscription to a phone keeps a
WebSocket and its radio awake, and the phone is exactly the host that must not pay for being observable.

- Each host's `powos-meshd` writes its own row to its **local** `powos-mesh` module (always cheap) and calls the
  hub's `report_device(row)` reducer as `host:<id>` (REMOTE-POWOS §2.3 tokens; until M4, the interim per-device
  identity of M2).
- **When:** on change past a threshold (CPU free ±1 core, memory ±10 %, battery crossing 50/20/10 %, AC plug,
  thermal state, user activity state, network type or metered flag), otherwise every 30 s on AC / 5 min on battery
  (coalesced with other WireGuard traffic when possible).
- **Staleness:** a row older than 3 intervals is shown `stale` and is not a placement target for new work; older
  than 10 min (battery hosts: 15 min) it is `offline`. Workloads on an offline runner follow §5.4.
- Always-on hosts (hub, servers) may also be subscribed to directly by viewers; the hub's aggregated `device` table
  is what the phone's board (§9.3) subscribes to, so the phone opens one subscription, not five.
- The hub down: hosts on one LAN still see each other's rows through their local modules over mDNS + direct
  WireGuard (REMOTE-POWOS §2.8); placement degrades to "local or named host" (§5.4).

---

## 5. Placement and the scheduler

### 5.1 Where decisions are made

Following REMOTE-POWOS §2.1 ("one server per host, authoritative for its own data"):

- A workload's row lives in its **owner's** `powos-mesh` module: `workload { id: uuidv7, name, owner, spec, runner,
  lease_epoch, state, pinned_to, policy, updated }`. The owner decides placement; the runner executes.
- Default owner: the host where it was created. Long-running services that should keep moving while the phone is
  away can be given to the hub (`powos mesh own <name> hub`): the hub is always on, so it can reschedule them.
- The scheduler is a library in `powos-meshd`, so every host can place its own workloads; the hub runs the same code
  for the ones it owns. No central controller that the phone depends on (AGENTS-VIEW §8: "the phone never depends on
  a hub").

### 5.2 Filter, then score

**Hard filters** (a host failing any is not a candidate):

| filter | rule |
|---|---|
| online | `device` row fresh, `accepting` |
| arch | the image index has the host's arch (or the spec allows emulation, explicitly) |
| resources | `cpu_free ≥ spec.cpus`, `mem_free ≥ spec.mem + margin`, GPU match (`spec.gpu: {vendor, mem}`), storage for image + volumes |
| trust | host tier allowed by the workload's `trust` (§8.3) |
| mode | if the move must be live, §2.1's list incl. CPU class |
| power | battery host below `spec.min_battery` (default 30 %) and not charging: no new work |
| user | `pinned_to` set → only that host; `avoid` list respected |
| activity | a host in `foreground-game` takes no new work except jobs marked `background-ok` |

**Score** (weights in the policy, defaults shown):

```
score = 3·fit(cpu,mem) + 2·power(ac=1, charging=0.6, battery>50=0.3, else 0)
      + 2·data_locality(volume already there = 1, NAS-backed = 0.7, needs copy = 1 − size/1GB…)
      + 1·thermal(normal 1, warm 0.5) + 1·latency_to_user(rtt to the device the user holds)
      − 3·network_cost(metered link on either end and transfer > 50 MB)
      − 1·disruption(would evict or slow a user-active host)
```

**Hysteresis:** a running workload moves automatically only if the best score beats its current runner's by a margin
(default 25 %), it has run at least 10 min where it is, and the estimated transfer amortises (`transfer_s <
expected_remaining_s / 10` for jobs). User-requested moves skip hysteresis.

### 5.3 Default policies

| policy | trigger | action | mode |
|---|---|---|---|
| **heavy builds go to servers/desks** | a `job` with `class: build` (Rust/Kotlin/kernel), or `cpus ≥ 4` | place on the best AC host of the job's arch, prefer x86 desks for amd64 images and the hub for arm64 | job: run there |
| **battery < 20 % → offload** | phone/razr not charging, battery crosses 20 % | move movable non-interactive workloads off; stop accepting | (c) > (b) |
| **thermal throttling → offload** | `thermal ≥ throttling` for 2 min | same as battery | (c) > (b) |
| **GPU jobs to NVIDIA hosts** | `spec.gpu.vendor = nvidia` | only NVIDIA hosts with free VRAM and not `foreground-game` | job |
| **interactive stays local** | `spec.interactive` (terminal attached, UI, low-latency) | never auto-moved; only the user moves it | — |
| **desk is gaming** | `foreground-game` on a desk | no new work; running `background-ok` jobs get `nice 19` + CPU cap; others move off | (b) |
| **desk sleeps / laptop lid** | host announces suspend (logind `PrepareForSleep`) | drain: move services off, checkpoint-or-cancel jobs before suspend (bounded: 20 s) | (a) if possible else (b) |
| **metered network** | phone on mobile data | no volume transfers > 50 MB to or from it; placements that need one wait for Wi-Fi | — |
| **back home** | the user's device reconnects to the LAN | nothing automatic: moves back only by policy `prefer: phone` | — |

Policies are data in the owner's module (`policy` table), shown and edited by `powos mesh policy` (§9.1). The
scheduler explains every decision (`powos mesh place <name> --explain`: candidates, filter that removed each, scores).

### 5.4 Failure handling

| failure | detection | behaviour |
|---|---|---|
| target fails to pull/start/health-check during a move | move state machine (§5.6) timeout per step | abort: source resumes (a: it is still frozen, `restore` locally; b: restart with its own volume); lease unchanged |
| source dies mid-move | source `device` row offline | if the final delta/checkpoint arrived: commit on the target; else abort, workload `lost` until the source returns |
| runner goes offline | `device` row offline | **jobs:** re-queued elsewhere after 2 min (at-least-once; jobs must be idempotent and write outputs atomically). **services with `cache` volumes or STDB state:** restarted elsewhere after 5 min (bump the lease epoch first). **services with local `data` volumes:** marked `stranded`, not restarted (the only copy is there); the user decides (`powos containers move --from-backup` uses the last synced copy and accepts data loss since then) |
| old runner comes back after its workload was restarted elsewhere | its meshd reads the workload row: `lease_epoch` > its own | stops its copy at once, keeps the volume as `orphan-<epoch>` for 7 days, notifies; never syncs it back automatically |
| owner offline | — | the runner keeps running (runner autonomy); no moves until the owner returns, unless ownership was given to the hub |
| hub down | — | LAN peers still place among themselves; DNS/Traefik follow (§7) stops updating: names keep pointing at the last runner |
| flapping | > 3 automatic moves of one workload in an hour | auto-placement held for that workload, user notified |

### 5.5 GPU workloads

- NVIDIA hosts expose GPUs through CDI (`nvidia-ctk cdi generate` → `--device nvidia.com/gpu=all`); a workload asks
  `spec.gpu` and gets only the CDI device, never `/dev` wholesale.
- GPU jobs are (b)/job placements. Live moves of a CUDA process are possible only with NVIDIA's `cuda-checkpoint`
  (driver ≥ 550) and CRIU's CUDA plugin, same GPU model on both ends: a late, optional phase (§10 phase 6).
- The desk's dGPU can also be in a Windows VM (`powos gpu to-vm`): `powos-meshd` reports `gpus[].busy=true` then.

### 5.6 The move state machine

A move is a row `move { id: uuidv7, workload, from, to, mode, state, epoch, by, created, steps[] }` in the owner's
module; each host's meshd executes the steps that concern it (REMOTE-POWOS §2.6: action rows with expiry and audit).

```
requested ─► planned ─► preparing ─────────► freezing ─► transferring ─► starting ─► verifying ─► committed
 (by, why)   (mode,     target: pull image,  source:      final delta /   target:     health check  source: delete
             estimate)  pre-sync volumes     stop or      checkpoint      start with  passes        instance after
                                             checkpoint;  over the WG     epoch n+1                 grace (§6.4)
                                             lease → n+1  transfer path
                         any step fails or times out ─────────────────────────────────────► aborted (source resumes
                                                                                            unless lease committed)
```

- The lease epoch is bumped at `freezing`, before the target starts, so at no point can two runners hold the same
  epoch.
- A `requested` move older than 60 s that never reached `planned` expires (REMOTE-POWOS §2.6's rule).
- Every step writes progress (bytes, ETA) to the row, which is what the board and the CLI show.

---

## 6. Storage

### 6.1 Volume classes (declared in the workload spec)

| class | example | moved how | conflicts |
|---|---|---|---|
| `cache` | build caches, package caches, model weights fetched from a URL | not moved; re-created or re-fetched on the target (optional warm copy if cheap) | none |
| `data` (local) | a service's database files, a dev box's home | **pre-sync while running, final delta while stopped** (§6.2) | single writer by lease (§6.3) |
| `nas` | media libraries, shared datasets, large artefacts | not moved: mounted from PowCache on whichever runner (NFS over WireGuard; SMB for hosts without NFS) | single writer by lease, or read-only for `ro` mounts |
| `stdb` | app state | not a volume: synced tables (REMOTE-POWOS §2.5) | per-row LWW / CRDT, already designed |
| `scratch` | `/tmp`-like | dropped | none |

The phone mounts `nas` volumes only on Wi-Fi + AC, or read-only; a workload with a `nas` volume is not placed on a
metered phone.

### 6.2 Transfer

| source ↔ target | method |
|---|---|
| btrfs ↔ btrfs (Bazzite desks, servers) | `btrfs subvolume snapshot -r` + `btrfs send -p <last common snapshot>` / `receive`: incremental, exact, cheap to repeat. Each `data` volume is its own subvolume |
| anything else (phone f2fs/ext4 image, hub ext4) | `rsync -aHAX --numeric-ids --delete` in two passes: live pre-sync, then the final pass while stopped. Over a pull endpoint on the source's WireGuard address, authenticated by a one-time token from the move row (§8.2); not over ssh |
| CRIU export | one `tar.zst` (CRIU images + rootfs diff), streamed, sha256 + source-host signature checked before `restore` |

There is no ZFS anywhere in this fleet (f2fs on the phone, btrfs on Bazzite, ext4 in the VM), so `zfs send` is not
an option; btrfs send is its equivalent where both ends are btrfs. Later, a content-addressed chunk store (casync /
restic style) on the NAS can deduplicate repeated moves of large volumes across all filesystems.

Volume pre-sync can run continuously for workloads marked `standby: <host>`: the volume is mirrored to a second host
every N minutes, so a move (or a recovery after the runner dies) needs only the last delta. This is the only
"replication" in the design, and it is one-way, from the lease holder.

### 6.3 Consistency: one writer

- A `data` or `nas` read-write volume has exactly one writer: the runner holding the workload's current
  `lease_epoch`. The epoch is written into the volume (`.powos-lease`) at start; meshd refuses to start a container
  whose volume carries a higher epoch than the row it was given (a stale copy) and refuses to sync from a source whose
  epoch is lower than the target's.
- No multi-writer filesystem sync, ever. Two hosts that need the same data at the same time use STDB tables (merge
  rules exist there) or a `nas` volume with an app that does its own locking.
- Final-delta consistency: (b) stops the container before the last pass, so the copy is crash-consistent at worst
  (as after a power cut); apps that need more declare a `pre_stop` hook (e.g. `sqlite3 .backup`, `pg_dump`).

### 6.4 After a move

The source keeps the old volume for a grace period (default 24 h, `nas`/`stdb`: nothing to keep) as
`<vol>@moved-<epoch>`, so an aborted or regretted move can go back with a delta, not a full copy. `powos mesh gc`
lists and removes them.

---

## 7. Networking

### 7.1 Names: the service follows

Three layers, cheapest first:

| client kind | address it uses | how it follows a move |
|---|---|---|
| HTTP(S) services | `<name>.pow` (LAN/VPN) and optionally `<name>.powback.com` (public, Authelia) | the name resolves to the hub (`.100`) as today (dns-sync); **Traefik on the hub forwards to the current runner's WireGuard address**: the hub's meshd writes a Traefik file-provider entry (`http.services.<name>.loadBalancer.servers = [http://<runner wg ip>:<port>]`) on every commit. Clients never see the move; open connections break (b) or survive through the hub's proxy reconnect for HTTP/1 keep-alive only |
| other TCP/UDP services | `<name>.svc.pow` | a Pi-hole local A record → the runner's WireGuard IP, written by the hub's meshd at commit (the same path dns-sync uses), short local TTL (10 s) |
| long-lived clients, and (a) with `--tcp-established` | the workload's **mesh VIP** (§7.2) | the VIP moves with the workload; established TCP can survive a live move |

### 7.2 The mesh VIP

- Each workload that asks for one gets a stable `/32` from a mesh range outside the host range, e.g.
  `10.13.14.0/24` (hosts stay in `10.13.13.0/24`). Recorded in the workload row.
- **Routing.** In the hub-and-spoke WireGuard today, every peer routes `10.13.0.0/16` via the hub (on the phone: the
  WireGuard app's profile `AllowedIPs` gains `10.13.14.0/24`, one profile change). The hub routes the VIP to the
  runner by listing it in **that peer's** `AllowedIPs` (`wg set wg0 peer <runner> allowed-ips <wg ip>/32,<vip>/32`)
  and removing it from the old one, at commit. Only the hub's config changes per move.
- With direct LAN peer-to-peer WireGuard (REMOTE-POWOS §2.4), VIP traffic still goes through the hub (one extra
  hop on the LAN, ~1 ms); direct paths use the runner's own address via `<name>.svc.pow`.
- **On the runner.** The VIP is added as a local address on the WireGuard interface (`ip addr add <vip>/32 dev
  wg0|tun0`) and DNAT'd to the container: netavark/pasta port mapping on desks; on the phone, an `inet powos_mesh`
  nftables table (the modules exist since PHONE-KERNEL patch 0003; loaded at boot by the system module) with
  `ip daddr <vip> tcp dport <p> dnat to 127.0.0.1:<host port>`.
- **The phone's caveats:** `tun0` belongs to the WireGuard app's `VpnService`; adding an address to it needs root
  (meshd runs the local privileged helper, §8.2), and Android's per-UID policy routing (`ip rule` fwmarks from netd)
  must route the replies back into `tun0`: a `powos-mesh` rule for the VIP source (`ip rule add from <vip> lookup
  <tun0 table>`), applied and removed with the address. Android's netd uses iptables (legacy); the nftables table
  stays in its own family/table and only touches VIP traffic. To be tested in phase 2 before relying on it
  (REMOTE-POWOS open question 2: who owns the phone's tunnel).

### 7.3 Ports and egress

- A workload declares its ports (`spec.ports: [{name, port, proto, expose: lan|vpn|public|none}]`). Nothing is
  published on a runner's LAN address unless `lan`; VIP and WireGuard exposure are filtered on the WireGuard
  interface to enrolled peers (REMOTE-POWOS §2.4's defence in depth).
- Egress: a guest workload's network follows its manifest's `net` list (the same vocabulary as `host.net`:
  `"lan"`, exact hosts). Enforced by the runner: a per-workload nftables set on desks/servers (netavark), the
  `powos_mesh` table's `meta skuid`/cgroup match on the phone.

---

## 8. Security

### 8.1 Identity and authentication

Nothing new: REMOTE-POWOS §2.3.
- Hosts authenticate as `host:<id>` (ES256 tokens signed by the host key, verified against the realm JWKS); users as
  `user:<u>`, agents as `agent:<role>@<host>`.
- `powos-mesh` reducers check `ctx.sender`'s kind and host exactly like `powos-agents`' reporter rule: a host writes
  only its own `device` row, executes only the move steps addressed to it, and only the owner (or a `user:`) can
  create moves for a workload.
- Until M4 lands, the mesh runs between the phone and the hub only, with M2's interim per-device identity, and
  nothing in it is reachable outside WireGuard.

### 8.2 No root channel across hosts

- **No host runs a command on another.** A move is a row; each host's `powos-meshd` reads rows addressed to it and
  acts locally. adb, ssh and `powos-vadb` play no part (REMOTE-POWOS §2.9).
- `powos-meshd` runs as the PowOS user. The steps that need root locally (rootful podman checkpoint/restore, the VIP
  address, nftables) go through a **local privileged helper** with a fixed verb list, like
  `powos-container-ctl` (`start|stop|restart|delete` today): `checkpoint <name> <file>`, `restore <file>`,
  `vip add|del <vip> <port map>`. Arguments are validated (names by regex, files only under the mesh spool, VIPs only
  from the mesh range). The helper never takes a command line from the network.
- **Artifacts, not commands, cross hosts.** Image layers come from the registry by digest; volume deltas and
  checkpoint exports are pulled by the target from the source's transfer endpoint (WireGuard address only, one-time
  token from the move row, sha256 in the row, signed by the source host key).
- **A CRIU image is code.** Restoring one executes the source's memory with root-assisted restore on the target.
  Rule: **live restore only from a host of equal or higher trust tier**, and never into a `personal` host from a
  `guest` one. (b) is safer by construction: the target runs its own copy of a signed image; only data crosses.

### 8.3 Trust tiers

The tier is set at enrollment by the user (directory row), never by the host about itself.

| tier | hosts | may run | may receive |
|---|---|---|---|
| `personal` | phone, razr, the user's desks | anything the user owns, interactive included | (a), (b), (c) from any personal/infra host |
| `infra` | hub, servers | services and jobs; no interactive sessions holding user tokens unless the user moves one there | (a), (b), (c) from personal/infra |
| `guest` | a friend's PC, a rented cloud VM, a shared lab box (future) | only workloads marked `trust: guest-ok`: no secrets, no `data`/`nas` volumes except their own scratch/cache, no STDB tokens beyond an app-scoped one | (b), (c) only; never sends checkpoints anywhere |

### 8.4 Signed images

- Workload specs pin images by **index digest** (`ghcr.io/powback/<img>@sha256:…` or `registry.pow/<img>@sha256:…`).
- Images are signed with cosign/sigstore by the realm's build key; every host's `/etc/containers/policy.json`
  requires `sigstoreSigned` for the PowOS registries (podman verifies at pull). Unsigned images run only locally,
  never through the mesh (`powos containers move` refuses: "image not signed").
- This is REMOTE-POWOS M8's "signed software" applied to container images; the signing key is the same one that
  signs pacman packages and bundles once M8 lands.

### 8.5 What a guest workload may access (on any runner)

| resource | allowed |
|---|---|
| filesystem | its image, its declared volumes; never `/home`, `/var/lib/powos`, the host's podman socket, `~/.claude`, `~/.android` |
| devices | only CDI devices its spec names (GPU); no `/dev/kgsl*`, `/dev/binder*`, `/dev/fuse`, `/dev/kvm` unless declared and the host allows it |
| network | its own netns; ports per §7.3; egress per its `net` list; never the host's loopback (so never `127.0.0.1:3410`, the phone's uid-locked STDB, REMOTE-POWOS C16) |
| STDB | only through an app-scoped token for its own database, minted by the owner (FEASIBILITY §3), passed at start |
| secrets | only those scoped to the workload, sealed to the runner's host key at placement (the owner encrypts for the target), mounted as a tmpfs file; never in the spec row, never in a checkpoint export (export excludes the secrets mount; restore re-mounts it from the target's own sealed copy) |
| `claude-auth.pow` | only if the spec asks for `ai`, and then with a tenant secret scoped to the workload (claude-rate-limiter tenants); never the host's default |
| privileges | rootless user namespace, no `--privileged`, seccomp default, `no-new-privileges`, cgroup limits from the spec (phone: hybrid limits, §3.5) |

---

## 9. UX, CLI and agents

### 9.1 CLI

The contract is `--help` (PowOS rule: agents read help; an undocumented verb doesn't exist). Proposed verbs:

```
powos mesh devices [--json] [--probe]        # §4 rows: arch, free cpu/mem, gpu, power, thermal, net, trust, live-capable
powos mesh status [<workload>] [--json]      # every workload: owner, runner, mode it would move with, state, VIP/name
powos mesh place <workload|image> [--explain] [--needs cpus=4,mem=8G,gpu=nvidia]   # dry-run placement, no action
powos mesh run <image@digest> [--on <host>|auto] [--job] [--volume …] [--name …]   # create + place
powos mesh policy [list|set <key> <value>|reset]
powos mesh pin <workload> <host> | unpin <workload>
powos mesh own <workload> <host>             # hand placement authority to another host (e.g. the hub)
powos mesh drain <host> | undrain <host>     # move everything movable off (before a trip, a game, a shutdown)
powos mesh accept on|off                     # this host takes new work or not
powos mesh moves [--all]                     # in-flight and recent moves, with progress
powos mesh gc                                # old moved-volume copies, orphans

powos containers move <name> <host> [--mode auto|live|restart] [--dry-run] [--keep-source] [--from-backup]
powos containers where <name>                # runner, owner, VIP/name
```

`powos containers move` is the `powos containers` front door (the existing `list/start/stop/logs/…` dispatcher in
`bin/powos`); it writes a `move` row and follows its progress. `--dry-run` prints the plan: mode and why, bytes to
transfer, estimated downtime, the name/VIP change, what happens on failure. `powos containers list --json` gains
`runner` and `owner` columns so the existing containers widget shows where things run.

Host names come from the directory (`--host phone`, REMOTE-POWOS M5); IPs are never typed.

### 9.2 Agents

- **An agent asks for compute elsewhere** through an MCP tool beside comms: `mesh_run({image | command + base image,
  needs: {cpus, mem, gpu, arch}, inputs: [paths|urls], outputs: [paths], timeout})` → a `job` placed by §5, with
  inputs uploaded as a `data` volume and outputs synced back on completion; `mesh_status(job)`, `mesh_cancel(job)`.
  The existing `powos app builder user@host` (Rust module builds over ssh into `powos-app-builder` on the Mac) is the
  first thing this replaces: the same build as a mesh job, without an ssh key.
- **Permissions.** An `agent:` identity may create jobs it owns on `personal`/`infra` hosts within the policy's
  budget (default: ≤ 8 cpus, ≤ 16 GB, ≤ 2 h, no GPU). Anything beyond — GPU, `guest` hosts, moving a workload it
  doesn't own, moving anything interactive — becomes an **ask** (AGENTS-VIEW §6) the user approves on the phone,
  with REMOTE-POWOS §2.9's step-up rule for approvals from another host.
- **Work board.** Each agent-created job adds a `work` row ("build kernel on desk-1", owner = agent, status from
  the job), so the PowOS AI page's Work list (AGENTS-VIEW, "The work board") shows remote compute next to tasks.
- **Agent sessions as workloads.** A Claude session in a dev container is a workload like any other; moving it is
  (b): stop, sync the transcript + worktree volume, `claude --resume` on the target. `role@host` mail follows its
  runner (REMOTE-POWOS §2.7: the comms bridge delivers to wherever `coder` runs, the directory knows).
- The system agents' context (`config/ai/context/capabilities.md`) gets one line pointing here; `powos mesh help`
  goes into the devops agent's prompt via `!powos mesh help` once the verbs exist.

### 9.3 The phone: a board of where things run

A page in the PowOS AI area ("Compute"), and a 4×2 home widget (count line at 4×1), built as a PowOS app on the hub's
aggregated `powos-mesh` tables (one subscription, closed while hidden — AGENTS-VIEW §5's budget rules):

```
┌ Compute ─────────────────────────────── ● live  4 hosts ┐
│ phone  bat 63% · 5.1/8 cpu · 4.2G │ hub  AC · 9/14 · 31G │
│  ▸ notes-sync    (c)   ● running  │  ▸ shopping-api ● 2d │
│                                   │  ▸ builder      ● 3 jobs│
├───────────────────────────────────┼──────────────────────┤
│ desk-1  AC · gaming · RTX 5080    │ razr  offline 2h     │
│  ▸ whisper-gpu  ⏸ nice19          │                      │
│  ▸ coder-box    ⇢ moving to hub 62% (restart, ~40 s)    │
└─────────────────────────────────────────────────────────┘
```

- One column per host: power, free CPU/RAM, GPU, thermal, gaming/idle state, trust badge; stale/offline greyed with
  "last seen".
- Workload chips: name, mode it would move with ((a)/(b)/(c)), state, runtime. Tap: details (owner, runner, VIP/name,
  volumes, last moves, logs via `powos containers logs` on the runner's module).
- **Drag a chip to another column = move**: a confirm sheet with the `--dry-run` plan (mode, size, downtime,
  failure behaviour). In-flight moves show progress from the `move` row; an abort button while not committed.
- Asks from agents ("coder wants 8 cpus on desk-1 for a kernel build") appear here and in the Agents view.
- Desktop: the same page in a window/plasmoid (AGENTS-VIEW §1.3's pattern: one UI codebase).

---

## 10. Phased plan

| phase | scope | depends on (REMOTE-POWOS) | effort |
|---|---|---|---|
| **0 — prototype: phone ↔ hub** | (1) **Restart move (b) by hand, scripted:** one small multi-arch service image (e.g. a tiny HTTP + SQLite app, `linux/arm64` + `linux/amd64`), a `data` volume; phone (podman, vfs) → hub (Docker in the Colima VM) and back; rsync two-pass over WireGuard; Traefik file-provider entry flip on the hub so `<name>.pow` follows. Measure downtime and bytes. (2) **Mode (c) demo:** `apps/counter` (or `~/Projects/shopping`) with its synced table once M7 exists; until then, document only. (3) **CRIU feasibility, no kernel change:** none on the phone (§3.2 blocks it); on an x86 desk if one is enrolled, `podman container checkpoint --export` → `restore --import` round trip on the same host, then desk ↔ desk. The phone CRIU kernel (§3.3) is a separate user decision | none. Without M1/M2 the prototype is driven from a developer keyboard (a dev channel, REMOTE-POWOS §2.10) and is not left running | 3–5 days |
| **1 — inventory** | `powos-mesh` module (`device`, `workload`, `move`, `policy`), `powos-meshd` on phone + hub publishing §4 rows, `powos mesh devices/status`, the board read-only | M1 (hub STDB), M2 (phone ↔ hub subscription, interim identity) | 1–2 weeks |
| **2 — restart moves** | §5.6 state machine for (b), volume classes and transfer (§6), lease epochs, Traefik/Pi-hole follow, `powos containers move/where`, `--dry-run`, the privileged helper's verbs; the VIP on desks/servers, then the phone (§7.2 caveats) | M4 (host tokens: moves between more than phone+hub), M5 (directory: host names, WG IPs) | 2–3 weeks |
| **3 — state-in-STDB moves** | (c) as a mode: manifest `volumes` all `cache` + `sync.tables` → "run it there"; Tier 1/2 app backends follow; agents' transcripts in a synced volume | M7 (per-table sync) | ~1 week |
| **4 — scheduler + agents** | §5.2 filter/score, §5.3 policies (battery/thermal offload, builds to servers, GPU to NVIDIA, gaming), hysteresis, failure handling (§5.4), `mesh_run` MCP tool + asks + work-board rows, drag-to-move on the board, `powos app builder` replaced by a mesh job | M3 (asks/answers as reducers), M6 (comms `role@host`) | 2–3 weeks |
| **5 — live moves (a)** | CRIU in the x86 pool (rootful helper, `--tcp-established` with VIPs, pre-copy); CPU-class check (§3.4); on the phone only after the user approves the CRIU kernel (§3.3: build, `fastboot boot`, go/no-go, flash) + `criu` in the PowOS root + the cgroup question (§3.5); arm64 lazy pages | M8 (signed images/artifacts; no dev channels) | 2–4 weeks (+ the kernel cycle, ~1 day of build/test) |
| **6 — later** | GPU live moves (`cuda-checkpoint`), `guest` tier with sealed secrets, standby replicas (§6.2), chunked dedup store on the NAS, razr as a peer (its own §3.2 exercise) | — | open |

Phase 0's exit criteria: a service moves phone → hub → phone with its data intact, its `.pow` name working
throughout except for the measured downtime, and a written result (downtime, bytes, what broke) appended here.

---

## 11. Open questions and risks

1. **Arm64 live moves across CPU vendors** (§3.4): is PAC the hard stop we expect (QARMA vs Apple's algorithm), and
   does Arch Linux ARM's userland use `-mbranch-protection`? If so, arm64 (a) exists only between identical SoC
   families. Measure in phase 0/5, don't assume.
2. **Podman checkpoint on the phone with `cgroups=disabled`**: does crun/CRIU accept it, or does (a) on the phone
   wait for Android's controllers on v2 (PHONE-KERNEL §9 step 3)?
3. **Rootful vs rootless.** Podman checkpoint/restore is rootful only; the phone's day-to-day containers are rootless
   as `powos`. Live-capable workloads must be created rootful (through the helper), a second container store on the
   phone. Acceptable, or (a) stays desk-only?
4. **`netns=host` on the phone** (FEASIBILITY: `netns=host` in `50-powos-phone.conf`) rules out (a) and VIPs for
   those containers. Moving the phone to pasta per container is a precondition for phase 5 there.
5. **The phone's tunnel** (REMOTE-POWOS open question 2): the VIP needs addresses and ip rules on a `tun0` that the
   WireGuard app owns. If PowOS brings its own `VpnService`, that becomes clean; if not, root edits to another app's
   interface are fragile across reconnects.
6. **Battery and radio cost** of inventory pushes and transfers on the phone: budget to measure in phase 1 (target: no
   measurable drain when idle, as for the agents view).
7. **Split brain** if a host is partitioned (not dead) and its workload is restarted elsewhere: the epoch fences
   volumes and the returning host stops its copy, but a partitioned runner keeps serving its stale copy to clients
   on its side of the partition until it reconnects. For `data` services, auto-restart-elsewhere is therefore off by
   default (§5.4).
8. **Hub as a single point**: Traefik/Pi-hole follow and VIP routing live on the hub. Hub down = names freeze at the
   last runner, VIPs stop routing; LAN-direct still works by host address. Acceptable for a home fleet; revisit if a
   second always-on server appears.
9. **CRIU image confidentiality**: a checkpoint holds the process's memory, including any secrets it loaded. Exports
   are encrypted to the target's host key in transit and at rest in the spool, deleted after restore; still, (a) for
   workloads holding tokens should be opt-in per workload.
10. **Docker on the hub vs podman everywhere else**: two runtimes to drive. Either the hub's meshd speaks the Docker
    API (restart moves only), or podman goes into the Colima VM (a PowStation change: the user's call). Phase 0 uses
    Docker as it is.
11. **Kernel decision for the phone**: `CHECKPOINT_RESTORE` looks KMI-safe by source inspection (§3.3), but that is a
    grep, not the kmi-check + layout-diff the flash rule requires. Another build/test/flash cycle, and the OTA rule
    (PHONE-KERNEL §10) applies to it as to the current kernel.
12. **Licensing/ToS for `guest` hosts** (cloud VMs) and `claude-auth.pow` use from workloads running off the user's
    own devices: out of scope until the guest tier is wanted.
