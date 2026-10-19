# PowOS Apps — feasibility study

Date: 2026-10-19. Read-only research. Nothing on the phone was changed. On-device container numbers are the
manager's (user-approved, measured 2026-10-19 19:00, cleaned up afterwards). Every other number was measured on the
Mac (Apple Silicon, arm64 Linux containers under Colima, same Arch Linux ARM userland as the phone's rootfs) or read
from the phone over adb.

**Goal, in the user's words:** "native, real-time, updatable, hot-reloadable apps and widgets, usable
cross-platform, with native integration in both the PowOS launcher and the desktop". The user expects to run many
apps and widgets at once, on the phone too.

**These decisions are fixed:**
- UI is Astro with Preact islands, shipped as a static bundle.
- State and logic live in SpacetimeDB: one server per device, and each app is a database/module on that server.
- An app is the UI, plus a module, plus a manifest.

## TL;DR

| # | Question | Answer |
|---|---|---|
| 1 | SpacetimeDB on the phone | **Yes, with the official binary.** `spacetime-aarch64-unknown-linux-gnu.tar.gz` is a release asset of every release (v2.1.0 … v2.12.0). It is glibc-linked and runs as-is on Arch Linux ARM: 178 MB on disk, 137 MB RSS idle, 130-150 ms to `/v1/ping`. No source build is needed. **The cost is per loaded database:** a TypeScript module costs about 15-17 MB, so 50 TS modules come to about 870 MB (Rust/WASM: ~5.5 MB each, after a one-off 59 MB for the WASM engine). It should run as a boot-lifetime service outside the desktop session. |
| 2 | Containers on the phone | **They work rootless, but no app can be confined yet.** Podman 6.1.4, crun, pasta and netavark are installed. Two things block or limit them: **(a)** `/dev/fuse` is `0600 root`, so every `podman run` fails as shipped. **(b)** cgroups are disabled, so `--memory`/`--cpus` are silently ignored. Podman 6 needs cgroup v2 controllers, and on this phone Android holds memory and cpu in v1. The kernel also lacks `CGROUP_PIDS`, `CFS_BANDWIDTH`, `SYSVIPC` and `NF_TABLES`. The plan in §2.3-2.5 fixes this at the platform level: an init rule, Android's own `cgroups.json`, and a KMI-checked kernel. |
| 3 | Astro page to local SpacetimeDB | **Use a direct WebSocket to `ws://127.0.0.1:<port>`.** Chromium treats loopback as a secure context, so a page on `https://shell.powos` can open it, and the app already sets `usesCleartextTraffic`. Lock the port to the PowOS uid with `xt_owner` (built into this kernel). The PowOS user `powos` *is* the app's uid, so the WebView, the session and agents all pass and every other Android app is refused. Proxying through `shouldInterceptRequest` cannot carry WebSockets. Each app gets its own origin `https://<app>.app.powos/`, its own SpacetimeDB identity token handed out by the shell, and only the bridge methods its manifest allows. |
| 4 | Cross-device sync | SpacetimeDB has no replication. **Recommended:** a per-app opt-in. Synced tables carry `(uuidv7, origin, hlc, tombstone)`, writes go through an outbox, and one sync agent per device pair replays changes both ways, last-write-wins per row (CRDT blobs for text). Both servers trust one PowOS token issuer, so an identity is the same on every device. Code and bundles sync through git (`SYNC-ARCHITECTURE.md`), not through SpacetimeDB. |
| 5 | Shape of the app model | Manifest `powos-app.json` (§5.1). Apps live in `~/.local/share/powos/apps/<id>/<version>/`. A registry module in SpacetimeDB drives the launcher, the desktop and agents live. UI changes hot-reload through the shell's existing file watcher. Logic changes re-publish in about 150-550 ms. Logic-only changes roll back instantly; schema rollback needs a snapshot. Widgets come in two tiers: **OWL** (native and cheap) and a **shared-host island** (one renderer per surface, never one WebView per widget). |

**Recommended next step (each needs the user's OK; details in §7):**
1. Prototype "Tier 0 first app". Run SpacetimeDB v2.12 on the phone as a boot-lifetime service, behind the uid-locked
   loopback port. Port the template's db layer to Preact. Write one app plus one shared-host widget, served from
   `https://<app>.app.powos/`.
2. Platform fixes, in risk order. **(a)** `/dev/fuse 0666` through an init rule in PowOS's Magisk `overlay.d`.
   **(b)** A cgroup-v2 memory+cpu trial through `cgroups.json`, `fastboot boot` only, checked for lmkd and OPlus
   hybridswap regressions. **(c)** A kernel with `CGROUP_PIDS`/`CFS_BANDWIDTH`, only if `tools/kmi-check.py` passes.

---

## Measurements (all numbers in one place)

### SpacetimeDB v2.12.0 standalone, aarch64 binary, Arch Linux ARM container on the Mac

| Scenario | RSS | Threads | Idle CPU (one core) | Idle wakeups (voluntary ctxsw) |
|---|---|---|---|---|
| 0 databases | 137 MB | 40 | 0.3-0.7 % | ~170 /s |
| 1 TS database (minimal 1-table module; the SDK bundle is 820 KB) | 181 MB | 43 | — | — |
| 20 TS databases (template `app`, 11 tables) | 531 MB | 66 | 2.2 % | ~525 /s |
| 50 TS databases (template `app`) | 1027 MB | 96 | 3.6 % | ~700 /s |
| 50 TS databases (minimal module) | 874 MB | 95 | 3.9 % | ~710 /s |
| After a restart with 50 databases on disk, none touched | 138-140 MB | 40 | — | — |
| … after touching 1 database | 178 MB | 43 | — | — |
| … after touching all 50 | 676 MB | 93 | 4.4 % | ~680 /s |
| 1 Rust/WASM database (minimal module, 103 KB wasm; first one loads wasmtime: +59 MB) | 196 MB | 46 | — | — |
| 50 Rust/WASM databases (minimal module) | 464 MB | 95 | 4.1 % | ~700 /s |

| Operation | Time |
|---|---|
| Server start to `/v1/ping` | 130-150 ms (also with 50 databases on disk) |
| First `spacetime publish` of a TS module (includes the build) | 343-543 ms |
| Republish, same module (hot swap) | 141-183 ms |
| 49 more publishes in a row | 6.9 s (~140 ms each) |
| `spacetime call` round trip (CLI process plus reducer) | ~90 ms (mostly CLI start-up) |
| 200 reducer calls, 20 live subscribers | server CPU 1.22 s, i.e. ~6 ms CPU per write including fan-out (0 subscribers: 0.95 s) |
| Disk | binaries 178 MB (59 MB tarball). Data: ~2.3 MB per TS database (the module plus its snapshot) |

**What follows from these numbers:**
- **Each loaded TS database costs about 15-17 MB and adds about 11 wakeups per second.** Each one is a V8 isolate
  holding the 820 KB SDK bundle, plus a worker thread. A Rust/WASM database costs about 5.5 MB, but the wakeups
  are the same (~700/s for 50): **idle cost is per loaded database, whatever the language**, so unloading idle
  databases matters more than the choice of module language.
- **Databases load lazily at server start, but are never unloaded at runtime.**
  - After a restart, only the databases something touches get loaded. That is the hook for scale-to-zero.
  - SpacetimeDB has no "unload an idle database" call. That is an upstream request, or a
    host-side policy (see §6.4).
- **Fan-out is cheap.** 20 subscribers added about 30 % to the cost of a write.

### Renderer cost, one shared host vs many pages

Measured in headless Chromium on arm64 with `--renderer-process-limit=1`, which models Android WebView: one
renderer process per app. Each widget is about 45 DOM nodes plus a 1 s timer. Values are the summed PSS of all
Chromium processes.

| Layout | Total PSS | Marginal cost per widget |
|---|---|---|
| Base (1 empty page) | 286 MB | — |
| 1 page with 20 widgets | 300 MB | **~0.4 MB** |
| 1 page with 50 widgets | 311 MB | ~0.4 MB |
| 20 separate pages, 1 widget each | 336 MB | **~2.2 MB** |
| 50 separate pages | 395 MB | ~2.1 MB |
| 1 page with 20 same-origin iframes | 334 MB | ~2.1 MB |

**What the phone shows today** (`dumpsys meminfo com.powos.app`, read-only):
- The app runs **4 WebViews** (home, shade, lock, switcher and so on are each a separate `ShellHost`).
- They share **1 renderer process**: `sandboxed_process0` has 149 MB PSS / 296 MB RSS and 33 threads.
- The app process itself has 392 MB PSS. Of that, graphics is 115 MB (EGL mtrack 82 MB), which is about 20 MB of
  surfaces per attached WebView.

**Extrapolation for the phone:**
- A widget inside an existing host costs about 0.4-1 MB. Real Preact islands carry more state than this synthetic
  widget, so budget about 1 MB.
- An iframe-isolated widget costs about 2-3 MB.
- A *new WebView* costs about 2-5 MB of renderer memory plus about 20 MB of graphics while attached. Its JS also
  loads its own copy of Preact and the SpacetimeDB SDK and opens its own socket.

So N widgets must be N islands in one page per surface, not N WebViews.

### Containers on the phone (measured on device by the manager, 2026-10-19 19:00)

**Stack:** podman 6.1.4, crun, netavark, rootless as `powos` (subuid `100000:65536`).

**Configuration** (`50-powos-phone.conf`, read back by me): `cgroups=disabled`, `netns=host`, `ipcns=host`,
`cgroup_manager=cgroupfs`, fuse-overlayfs storage (home is on f2fs).

**Blocker:** every `podman run` fails with `fuse-overlayfs: failed to open /dev/fuse: Permission denied`. I
confirmed `/dev/fuse` is `crw------- root root` with label `u:object_r:fuse_device:s0`. It is Android's own `/dev`,
bind-mounted into PowOS.

**Measured with an isolated vfs store:**

| What | Value |
|---|---|
| Cold `podman run --rm alpine true` | 310-460 ms |
| 10 detached starts | 2.7 s (~270 ms each) |
| Idle cost per container | conmon ~2.3 MB RSS plus the payload; no measurable idle CPU |
| MemAvailable drop for 10 containers | about 140 MB (noisy; includes the vfs page cache) |
| vfs disk per alpine copy | ~8.7 MB (overlay is needed at scale) |

**Limits and networking:**
- `--memory 64m` is **silently ignored** (no `memory.max` is written).
- Outbound network works through the host netns.
- distrobox 1.8.2.5 is present, with no boxes.

### The phone (read-only, 2026-10-19)

| | |
|---|---|
| Device | OnePlus Open CPH2551, Android 16, SELinux **Enforcing**, 15.5 GB RAM (~6.4 GB available at the time), `/data` 398 GB free |
| Kernel | `5.15.180-o-g298ff0fe2773-dirty` (PowOS's own GKI build, `targets/native/build-gki-kernel.sh`; in `boot_b` since 2026-10-16), `/proc/config.gz` present |
| Rootfs | glibc 2.43, systemd 262 (installed, not PID 1), podman 6.1.4, crun 1.30.1, fuse-overlayfs 1.18, netavark 2.1.0, passt 2026_10_02, nftables 1.1.7. No s6 or runit. |
| Processes | PowOS processes run as `u:r:magisk:s0`, uid `u0_a359` (= the app's uid = `powos`); the app runs as `priv_app` |
| cgroups | v1: `/dev/memcg` (memory), `/dev/cpuctl` (cpu), `/dev/cpuset`, `/dev/blkio`, `/dev/freezer`. v2 at `/sys/fs/cgroup` holds **only the freezer controller** (`/system/etc/cgroups.json` → `Cgroups2.Controllers=[freezer]`) |
| OPlus memcg users | `persist.sys.oplus.hybridswap_app_memcg=true`, `ro.oplus.osense_app_memcg=true`, `ro.boot.memcg=1`; vendor init writes `/dev/memcg/apps`, `/dev/memcg/system` |

**Kernel options:**

| | Options |
|---|---|
| **Present** | `USER_NS`, `PID_NS`, `NET_NS`, `UTS_NS`, `CGROUPS`, `MEMCG`, `CPUSETS`, `CGROUP_SCHED`, `FAIR_GROUP_SCHED`, `CGROUP_FREEZER`, `CGROUP_BPF`, `CGROUP_CPUACCT`, `BLK_CGROUP`, `PSI`, `OVERLAY_FS`, `FUSE_FS`, `VETH`, `BRIDGE`, `TUN`, `IPVLAN`, `DUMMY`, `NETFILTER`, `IP_NF_IPTABLES`, `NF_NAT`, `IP_NF_TARGET_MASQUERADE`, `NETFILTER_XT_MATCH_OWNER`, `XT_MATCH_SOCKET`, `SECCOMP_FILTER`, `BPF_SYSCALL`, `BLK_DEV_LOOP`, `EXT4_FS`, `BINFMT_MISC`, `DEVTMPFS` |
| **Missing** | `CGROUP_PIDS`, `CFS_BANDWIDTH` (so no `cpu.max`, no `--cpus`), `SYSVIPC` (so no IPC namespace and no `ipcns=private`), `POSIX_MQUEUE`, `NF_TABLES` (podman 6/netavark firewalling is nftables-only), `BRIDGE_NETFILTER`, `TMPFS_XATTR`, `CHECKPOINT_RESTORE`, `IP6_NF_NAT`, `MACVLAN`, `VXLAN`, `RT_GROUP_SCHED` |

---

## 1. SpacetimeDB on the phone

### 1.1 Binary

- **Assets.** Every release ships `spacetime-aarch64-unknown-linux-gnu.tar.gz` and
  `spacetimedb-update-aarch64-unknown-linux-gnu` (checked with `gh release view` for v2.1.0 and v2.12.0).
- **Contents.** `spacetimedb-standalone` (136 MB) and `spacetimedb-cli` (50 MB).
- **Libraries.** The binary links only `libstdc++`, `libgcc_s`, `libm`, `libc` and `ld-linux-aarch64`. The phone's
  rootfs has glibc 2.43, the same as the test container, so it works as-is.
- **Building from source would not pay off.** It is a large Rust workspace with wasmtime and V8. On the phone it
  would take tens of minutes and heat the device. Cross-compiling is possible, but there is no reason to while
  upstream ships arm64.
- **Packaging.** Ship the binaries in the phone's central rootfs build, the way everything else ships ("never
  `pacman -Syu` on the phone"). Install them to `/usr/lib/spacetimedb/<ver>/`, with `spacetime` pointing to the
  current version.
- **Versions.** Pin one version fleet-wide. Today the fleet mixes 2.1.0 (Powpanion, the template), 2.8.1 (the agent
  gateway), 2.10.0 and 2.10.2. The client SDK npm version must match the server. Recommendation: move the template
  to 2.12 when this work starts. Its db layer (`src/lib/db.ts`) is React-hooks based, so the port to Preact is
  `preact/hooks` (or `preact/compat`).
- **Start-up keys.** `spacetimedb-standalone start` needs `--jwt-pub-key-path/--jwt-priv-key-path` (PKCS#8 P-256)
  unless they are set in `config.toml`. `spacetime start` (the CLI wrapper) generates them. Persist them; see
  `spacetimedb-astro/notes/stdb-identity-recovery.md`: if the keys rotate, every saved token and the publish
  ownership are lost.

### 1.2 How it runs as a service on the phone

**What exists today:**
- Magisk `service.d/powos.sh` runs `powos-start.sh` at boot. It sets up the mounts (global namespace) and starts
  sshd with `chroot`.
- The PowOS app's `SessionService` runs `powos-session.sh` for each session. That script does `unshare -m`, then
  `pivot_root` into `/data/powos/root`, then runs `powos-rooted-session`.
- **Every new session `kill -TERM -<old pgid>`s the previous session's whole process group.** Anything started by
  `powos-rooted-session` (the `bg` helper) dies whenever the app restarts the desktop.

**Proposal: split PowOS into a *system tier* and a *session tier*.** This is the phone equivalent of systemd's
system and user managers.

- **System tier (boot lifetime).**
  - `powos-start.sh` creates PowOS's persistent mount namespace once: the same `unshare -m` and `pivot_root` as
    `powos-session.sh`.
  - It records the namespace's pid in `/data/powos/system.pid`.
  - Inside it, it starts a supervisor as `powos`, which runs SpacetimeDB, the shared app-runtime container (Tier 1)
    and the sync agent.
- **Session tier.** `powos-session.sh` *joins* that namespace with `nsenter -t $(cat system.pid) -m`, the way
  `powos-run.sh` already joins the session's namespace. It no longer builds its own. The session's process-group
  kill then never reaches system services.
- **Choice of supervisor:**
  1. **`systemd --user` as a plain process (preferred, needs a prototype).**
     - systemd 262 is already in the rootfs.
     - The desktop PowOS uses systemd units, so one unit file
       (`~/.config/systemd/user/powos-stdb.service`, `Restart=always`) serves both platforms. Socket activation
       gives lazy start for Tier 2 containers.
     - It needs a delegated, writable cgroup v2 subtree. That is the same prerequisite as podman limits (§2.4), so
       it lands with the cgroup work.
  2. **s6** (about 1 MB, purpose-built supervision tree, readiness notification) as the dependency-light fallback,
     usable before the cgroup work. It is not in the rootfs today.
- **Data.** Keep it in `/data/powos/root/var/lib/powos/stdb/` (on f2fs, survives reboots) and keep the keys in
  `…/stdb/keys/`, owned by `powos`. Back it up with the rest of `/data/powos`.
- **Port.** Listen on `127.0.0.1:<port>`, never `0.0.0.0` (the phone is on the LAN and the VPN). `:3000` is the
  common default; pick a fixed PowOS port such as `:3410` to avoid clashes with dev servers.
- **Restarts.** The service survives session restarts because it lives in the system tier. It survives reboots
  because `service.d` starts the system tier at boot and data is on disk. A start costs about 150 ms plus lazy
  database loads.

### 1.3 Footprint at scale

See the table above. A **Rust/WASM** module costs about 5.5 MB per loaded database after a one-off 59 MB for the wasmtime engine. A TS one costs about 16 MB (the
TS SDK runtime bundle is 820 KB even for a one-table module).

- Tier 0 with TS modules is fine for about 10-15 *concurrently loaded* apps on the phone (about 300 MB).
- Beyond that, two things are needed: (a) a host policy that keeps only active databases loaded (§6.4), and/or
  (b) Rust modules for long-lived background apps.
- Idle wakeups (about 170/s base plus about 11/s per loaded TS database) are small next to Android's baseline but not
  zero. Measure the battery cost on the device before shipping the service as always-on.

## 2. Containers on the phone

### 2.1 What works

| Area | Status |
|---|---|
| Rootless podman as `powos` | subuids are set up; user, PID, net and UTS namespaces exist |
| Root of PowOS | `pivot_root` (not chroot), so user namespaces are allowed |
| Networking | pasta (podman 6's rootless default) needs no netfilter, so rootless networking works on this kernel |
| Start cost | about 270-460 ms; idle cost about 2.3 MB conmon plus the payload |
| SELinux | Enforcing, but PowOS runs in Magisk's domain (`u:r:magisk:s0`), so it does not get in the way of containers. The cleaner long-term option is a dedicated `powos` domain (§2.3). |

### 2.2 What blocks or limits

| Problem | Effect | Proper fix |
|---|---|---|
| `/dev/fuse` is `0600 root:root` | fuse-overlayfs cannot open it, so `podman run` fails | §2.3 |
| v2 has only the freezer controller; memory and cpu are Android's v1 | podman 6 dropped cgroup v1 (and iptables, slirp4netns, CNI), so it runs `cgroups=disabled` with **no limits** | §2.4 |
| No `CGROUP_PIDS` / `CFS_BANDWIDTH` | no `pids.max`, no `cpu.max` (`--cpus`), even on v2 | §2.5 |
| No `SYSVIPC` / `POSIX_MQUEUE` | `ipcns=host`; images that need SysV shm fail (Steam already has a shim: `targets/android/steam/sysvipc`) | §2.5 (it is KMI-unsafe; `powos.config` already excludes it) |
| No `NF_TABLES` | no netavark bridge networks or port firewalling; rootless uses pasta or the host netns | not needed for the app model; optional kernel item |
| fuse-overlayfs on f2fs | slower than native overlay | native rootless overlay (kernel ≥5.11, which this kernel is) on an **ext4 loop image** (`BLK_DEV_LOOP=y`, `EXT4_FS=y`) mounted at `~/.local/share/containers/storage` |

### 2.3 `/dev/fuse` — platform fix

**Who owns the device node.**
- PowOS has no `/dev` of its own. `powos-start.sh` does `bind /dev "$R/dev"`, so **Android's ueventd is the
  single device manager**, the way udev is on the desktop.
- ueventd creates `/dev/fuse` at coldboot. No `ueventd.rc` rule matches it, so it stays at the default `0600 root`.
  On desktop Linux, udev's `50-udev-default.rules` makes it `0666`. FUSE is designed for unprivileged use; the
  kernel enforces `allow_other` and mount permissions.

**Where ueventd reads its rules.**
- The files are `/system/etc/ueventd.rc`, `/vendor/etc/ueventd.rc`, `/odm/etc/ueventd.rc` and OPlus's
  `/odm/etc/ueventd.reserve.rc`. The init binary's strings show `/odm/ueventd.rc` and `/odm/etc/ueventd.reserve.rc`.
- All of them are on dm-verity read-only partitions.
- ueventd parses them at `early-init`. Magisk's systemless module mount happens at `post-fs-data`, **after**
  ueventd's coldboot. So a `ueventd.rc` overlaid by the module would never be read at boot.
- Changing `vendor`/`odm` images would mean breaking verity. Not recommended.

**Proper fix: an init rule shipped in PowOS's boot chain.**
- Magisk's `overlay.d` in the patched `init_boot` ramdisk injects custom `.rc` files into init. PowOS already
  patches `init_boot` with `targets/native/tools/magisk-patch.sh`.
- init is Android's other owner of static device-node policy; stock `init.rc` uses the same `chmod` for its own
  nodes.
- `/dev/fuse` is a built-in misc device that exists from coldboot and is never re-created, so a rule after coldboot
  is exactly equivalent to a ueventd entry.

```diff
--- /dev/null
+++ targets/native/initramfs/overlay.d/powos.rc        (packed into init_boot by tools/magisk-patch.sh)
+# PowOS device policy on top of ueventd (whose rule files live on verity-protected partitions).
+# /dev/fuse as on every desktop Linux (udev 50-udev-default.rules): rootless podman's fuse-overlayfs,
+# flatpak, sshfs. Runs after ueventd's coldboot created the node.
+on post-fs-data
+    chmod 0666 /dev/fuse
```

(The exact `overlay.d` location depends on how `magisk-patch.sh` assembles the ramdisk. Wire it in there and verify
it with `fastboot boot` before flashing.)

**SELinux.**
- **No policy change is needed today.** The session runs in `u:r:magisk:s0`, which Magisk's policy allows on
  `fuse_device`.
- If PowOS later gets its own domain (recommended: a `powos` domain instead of borrowing Magisk's), the module ships a
  scoped `sepolicy.rule`, never permissive:
  ```
  allow powos fuse_device chr_file { open read write ioctl getattr }
  ```
- Changing the mode does not widen access for Android apps: their domains have no `fuse_device` allow
  (`untrusted_app` is denied by policy).

**Alternative: no FUSE at all.** Native rootless overlay on an ext4 loop image needs no `/dev/fuse` and is faster.
Recommended for container storage *in addition to* the fix above, which flatpak and sshfs also need.

**Not recommended:** `chmod` inside `powos-session.sh` or `powos-start.sh`. The node is global (shared with Android),
and a session script is the wrong owner for device policy.

### 2.4 cgroups — one unified hierarchy with real controllers

**Constraints.**
- Podman 6 requires cgroup v2.
- A controller can be bound to only one hierarchy at a time.
- Android binds memory and cpu to v1 (`/dev/memcg`, `/dev/cpuctl`).

So PowOS gets memory and cpu limits only if **Android moves those controllers to v2**. Android supports this
officially: `cgroups.json` lists them under `Cgroups2.Controllers`, and `task_profiles.json` addresses controllers
by name, not by path.

**Change, shipped by the PowOS system module** (`targets/android/system-module/module/system/etc/cgroups.json`):

```diff
   "Cgroups2": {
     "Path": "/sys/fs/cgroup",
     "Mode": "0775", "UID": "system", "GID": "system",
     "Controllers": [
-      { "Controller": "freezer", "Path": "." }
+      { "Controller": "freezer", "Path": "." },
+      { "Controller": "memory", "Path": ".", "NeedsActivation": true, "Optional": true,
+        "MaxActivationDepth": 3 }
     ]
   }
```

Remove the `memory` entry from `Cgroups` (v1). Moving `cpu` is a second, separate step: OPlus perf and uclamp
tuning write `/dev/cpuctl` directly.

**Timing.**
- `cgroups.json` is read by init's `SetupCgroups()` at `early-init`, before Magisk's module mount.
- Like `ueventd.rc`, the override must therefore come from the `overlay.d`/ramdisk path, not a post-fs-data module
  mount.
- Verify on the device which path `libprocessgroup` reads (`/system/etc/cgroups.json`, plus
  `/vendor/etc/cgroups.json` if present; none exists here).

**PowOS's subtree.**
- An init rule (the same `powos.rc`) runs `mkdir /sys/fs/cgroup/powos`, `chown` to `u0_a359`, and writes
  `+memory +cpu` to `cgroup.subtree_control`.
- The PowOS system tier moves itself in. podman runs `cgroups=enabled` with `cgroup_manager=cgroupfs`.
- `systemd --user` gets its delegated subtree (§1.2) and real `MemoryMax=`, `CPUWeight=` and so on, per service and
  per app.

**Risks. This is the part that needs a careful trial:**
- **lmkd.** Android 13+ lmkd works with memcg v2 (PSI-driven, `memory.pressure` style). This device uses PSI
  (`CONFIG_PSI=y`).
- **OPlus hybridswap / osense.** `persist.sys.oplus.hybridswap_app_memcg`, `ro.oplus.osense_app_memcg`, and
  vendor init writes to `/dev/memcg/apps` and `/dev/memcg/system`. Those will fail. Expect swap and kill behaviour
  to change: the vendor's tuning would be lost, Google's defaults remain.
- **Trial plan.**
  1. Use `fastboot boot` (temporary, nothing flashed) of an init_boot carrying the overlay.
  2. Check `dumpsys meminfo`, `logcat -b events | grep lmk`, app kills under a memory soak, and whether the
     vendor's hybridswap daemon logs errors.
  3. Compare against a stock boot.
- **Fallback if the trial regresses.** Leave Android on v1 and enforce PowOS budgets in user space (the supervisor
  watching PSS, plus SpacetimeDB's own metering), as §6.4 describes. Containers then stay unconfined, which keeps
  Tier 2 rare.

### 2.5 Kernel items

`targets/native/build-gki-kernel.sh` already builds OnePlus's GKI 5.15 from OnePlusOSS with PowOS fragments
(`config/gki/*.config`). `tools/kmi-check.py` checks symbol CRCs against the phone's own vendor modules.
`powos.config`'s KMI rule already excludes `SYSVIPC` because it changes `task_struct`.

| Option | Why | KMI outlook |
|---|---|---|
| `CGROUP_PIDS` | `pids.max` (fork-bomb guard per app) | Adds a cgroup subsystem, which changes `CGROUP_SUBSYS_COUNT` and the `css_set`/`cgroup` arrays. **Likely to change CRCs** of anything reaching `task_struct->cgroups`. Run kmi-check; expect failure. |
| `CFS_BANDWIDTH` | `cpu.max` (`--cpus`, `CPUQuota=`) | Changes `cfs_rq` and `task_group`. **Likely CRC change.** Run kmi-check. |
| `NF_TABLES` (+ `NFT_*`) | netavark bridge networks and firewalling | Adds `netns_nftables` to `struct net`. **Likely CRC change.** Not needed: pasta covers rootless. |
| `TMPFS_XATTR` | rootless overlay upper dirs on tmpfs | Small (`shmem_inode_info`). Run kmi-check. |
| `SYSVIPC`, `POSIX_MQUEUE` | IPC namespace | Known KMI break (documented in `powos.config`) |

**Method.**
1. Add `config/gki/containers.config`.
2. Run `build-gki-kernel.sh`, then `kmi-check.py out/gki/Module.symvers backup/<serial>/vendor_dlkm`.
3. Only if it passes, `fastboot boot` the image and test Android, Wi-Fi, modem, GPU and root.
4. Then flash `boot_b`, keeping `backup/8e5d600d/boot_b.img` and the current `out/boot-powos-gki.img` as undo
   images.

**If KMI fails, two paths:**
- (a) Rebuild the vendor modules too. OnePlusOSS publishes `android_kernel_modules_and_devicetree_oneplus_sm8550`,
  which the script already clones, but only part of `vendor_dlkm` is open source. Risky: display, GPU and touch
  blobs.
- (b) Live without pids and CPU quota. Use `cpu.weight` (v2 `cpu`, with `FAIR_GROUP_SCHED=y`) and `memory.max`
  only. **(b) is the realistic plan.** Memory is the budget that matters on a phone.

**Rules that always apply:** never downgrade firmware (`targets/native/README.md`: anti-rollback); keep the stock and
current boot images; an OTA restores the stock kernel.

## 3. Shell-hosted Astro page to the local SpacetimeDB

**The direct WebSocket works:**
- **Mixed content.** Chromium treats `127.0.0.1`/`localhost` as potentially trustworthy, so `ws://127.0.0.1:<port>`
  from `https://shell.powos` is not blocked as mixed content.
- **Cleartext.** The app already sets `android:usesCleartextTraffic="true"` (`AndroidManifest.xml:64`) and has no
  network security config.
- **CSP.** ShellHost sends no CSP (only `Cache-Control` and `ACAO`, `ShellHost.kt:143`).
- **Still to check:** whether WebView's Local Network Access checks treat a loopback request from an intercepted
  origin as public→local. This is a 5-minute check on the AVD, or on the phone with the user's OK. If it prompts,
  serve app origins as `http://<app>.app.powos` (a secure context is not needed for loopback) or allow the origin
  via WebView settings.

**Transports that do not fit:**
- `shouldInterceptRequest` sees only HTTP requests, so **it cannot proxy WebSockets.**
- A JS-bridge transport (Kotlin OkHttp WebSocket ↔ `postMessage`) works, but it doubles copies and needs
  base64 for SpacetimeDB's binary BSATN frames. Not worth it.
- `wss` with a local CA is unnecessary for loopback and adds key management.

**Lock the port to PowOS.**
- Android's loopback is shared by every app on the phone.
- `powos` is the app's uid (`u0_a359`).
- WebView's network stack runs in the app process (the renderer `u0_i*` does no networking).
- So one rule in a PowOS chain admits the WebView, the session, agents and root, and refuses all other apps
  (`NETFILTER_XT_MATCH_OWNER=y`):

```
iptables -N powos-local; iptables -I OUTPUT -o lo -p tcp --dport <port> -j powos-local
iptables -A powos-local -m owner --uid-owner 10359 -j RETURN   # the PowOS app = powos
iptables -A powos-local -m owner --uid-owner 0 -j RETURN
iptables -A powos-local -j REJECT
```

Install the rule from the system tier. Look the uid up at runtime, never hard-code it.

On the desktop it binds to `127.0.0.1`. Local users are trusted the same way; auth (below) still applies.

**Identity and authorization per app:**
- **Origin per app.** `https://<appid>.app.powos/` is served by the same `shouldInterceptRequest` from the app's
  bundle dir. Each app gets its own localStorage and IndexedDB.
- **Scoped bridge.** Use androidx.webkit `addWebMessageListener(allowedOriginRules)`, so the bridge knows which app
  is calling. The global `addJavascriptInterface` is visible to every frame.
- **One issuer per device set.** SpacetimeDB identity is `hash(iss, sub)`. The trusted shell (Kotlin) holds a PowOS
  signing key and mints a JWT per (user, app): `iss = powos`, `sub = user:<u>` or `agent:<name>`, plus
  `aud = <appid>`.
  - Make both the phone's and the desktop's servers trust that issuer (the server's `certificate-authority` /
    key config).
  - The same user then has the same identity on every device, which §4 depends on.
  - The page gets its token through `apps.token()` on its scoped bridge. It never chooses its own.
- **Manifest permissions are enforced twice:**
  - (a) The shell only answers the bridge methods the manifest lists (`notifications`, `share`, `apps.launch`, …).
  - (b) Cross-app data access goes through grants the registry writes into the owning module's `_grants` table,
    which its reducers check. RLS filters reads only (template note: writes are not gated by RLS).

## 4. Cross-device sync (phone ↔ desktop)

| Option | Offline | Conflicts | Schema changes | Effort | Verdict |
|---|---|---|---|---|---|
| **A. One authoritative server + offline client cache** (PowSync-STDB's model: IndexedDB mutation queue, `src/client/offline.ts`, replayed on reconnect) | The client only, while it stays open | Server order | Easy | Low; it exists | Contradicts "phone works offline with its own server". OK as a client-side add-on. |
| **B. App-level sync: synced tables + outbox + sync agent** | Full; each device is authoritative locally | LWW per row (HLC), optional per-field merge, CRDT blob columns for text | Needs schema versioning both sides; the sync agent refuses to replay across incompatible versions | Medium: a shared module helper plus one generic agent | **Recommended** |
| C. Sync agent that subscribes to *raw tables* and replays them as reducers | Full | No causal info; echo loops unless rows carry an origin | Fragile | Medium | B without the bookkeeping; avoid |
| D. Commit-log / event-log shipping | Full | None (one writer) | Engine-version-coupled | High; no public API | No |
| E. CRDT-only (Automerge/Yjs docs stored as bytes, merged in the module) | Full | Automatic | Docs carry their own schema | Medium | Use *inside* B for collaborative text and lists |

**Option B, as a sketch.** Synced tables are declared in the manifest (`sync.tables`).

1. **Rows.** Each synced row carries `id: uuidv7`, `origin: device`, `hlc: u64`, `deleted: bool`.
2. **Outbox.** Every reducer write also appends `(table, id, hlc, payload)` to `_outbox`.
3. **The sync agent.** It is one process per device in the app-runtime tier. Its own identity is
   `agent:sync` (holding a grant). It:
   - subscribes to `_outbox` on both servers;
   - calls `_sync_apply(batch)` on the other server, which upserts when `hlc` is newer and keeps tombstones;
   - keeps a per-peer cursor in `_sync_state`.
4. **Transport.** WireGuard is already up between the devices. The desktop server is not exposed beyond the VPN,
   and the peer agent connects with a token from the shared issuer.

App *code and bundles* do not travel through SpacetimeDB. They sync like the rest of PowOS state (git,
`docs/SYNC-ARCHITECTURE.md`) or come from the app store/registry, and each device publishes locally.

## 5. The app model

### 5.1 Manifest — `powos-app.json`

```json
{
  "id": "dev.powos.notes",
  "name": "Notes",
  "version": "0.3.0",
  "icon": "icon.svg",
  "ui":      { "entry": "index.html", "dir": "ui/" },
  "module":  { "path": "module/", "lang": "ts", "database": "notes", "stdb": "2.12" },
  "backend": null,
  "widgets": [
    { "id": "recent", "kind": "island", "entry": "widgets/recent.js", "size": "4x2", "minSize": "2x2" },
    { "id": "count",  "kind": "owl",    "file": "widgets/count.owl" }
  ],
  "surfaces": { "launcher": true, "desktop": true, "share": ["text/plain", "image/*"], "notifications": true },
  "permissions": ["notifications", "share", "apps.launch", "grant:dev.powos.calendar:read"],
  "sync":    { "tables": ["note", "tag"], "mode": "lww" },
  "agents":  { "tools": "reducers", "exclude": ["_*"] },
  "budget":  { "phone": { "memMB": 32, "idle": "suspend" }, "desktop": { "memMB": 128 } }
}
```

**The `backend` field.** `null` means Tier 0. `{ "tier": 1, "entry": "backend/main.ts" }` runs code in the shared
runtime container. `{ "tier": 2, "image": "ghcr.io/…:1.2@sha256:…", "arch": ["arm64","amd64"], "idle": "60s" }`
gives the app a dedicated, lazy container.

### 5.2 Tiers (containers first-class, never one per app by default)

| Tier | What runs | Process cost | Limits | When |
|---|---|---|---|---|
| **0 — module-only (default)** | Logic as a SpacetimeDB module in the device's one server | ~16 MB per *loaded* TS database (~5.5 MB for Rust); no extra process | Host-metered: the reducer runs inside SpacetimeDB; SpacetimeDB's energy accounting exists, though not enforced in standalone | Almost all apps |
| **1 — shared app runtime** | One container per device (Bun + common native tools, multi-arch `amd64+arm64`), hosting every app's `backend/` as workers; talks to SpacetimeDB as a client | One container, ~2.3 MB conmon plus the runtime (~40-60 MB for Bun) | Per-worker memory caps in the runtime; container-level `memory.max` once §2.4 lands | Apps that need IO SpacetimeDB can't do (filesystem, long-running fetch, CLI tools) |
| **2 — dedicated** | The app's own image, started lazily (socket or subscription activation), scaled to zero when idle (`idle` in the manifest) | ~270-460 ms cold start on the phone; ~2.3 MB conmon plus the payload | `--memory`/`--cpus` after §2.4/§2.5 | Truly special: GPU tools, other distros, heavy native deps |

The supervisor (§1.2) starts and stops Tier 1 and Tier 2 containers. Agents can request them only through manifest
budgets.

### 5.3 Where apps live

| | Phone (inside PowOS) | Desktop |
|---|---|---|
| Installed apps | `~powos/.local/share/powos/apps/<id>/<version>/{powos-app.json,ui/,module/,widgets/}` plus `current →` symlink | the same path |
| Source (for dev) | `~/Projects/<app>` (from the template) | the same |
| SpacetimeDB data | `/var/lib/powos/stdb/` (system tier) | `/var/lib/powos/stdb/` (systemd system or user service) |
| Shell serving | `https://<id>.app.powos/` → `apps/<id>/current/ui/` through ShellHost (`/data/data/com.powos.app/files/` is bind-mounted into PowOS the same way as `widgets/`) | `powos-app://<id>/` scheme handler in QtWebEngine (`powos-shell`, `docs/DESKTOP-WEB-SHELL.md`) |

### 5.4 Publish, hot reload, rollback

**Build:**
- `powos app build` runs `astro build` into a static `dist/`.
- It bundles the module (`spacetime build`, or `--js-path` for an already-built TS bundle).
- It writes `apps/<id>/<version>/`. Each version holds the module artifact plus its sha256 and the
  `schema.json` it was published with.

**Publish:**
- `powos app publish` flips `current`.
- It runs `spacetime publish -y --js-path|--bin-path <artifact> <database>` against the local server, with the
  PowOS owner identity (keys persisted, §1.1).
- It writes the version into the registry module.

**Hot reload:**
- **UI.** The shell's `HotReload` already watches `files/shell` and emits `files.changed` (`ShellHost.kt:235-290`).
  `shell/hot.ts` swaps CSS in place and reloads pages otherwise. Extend the watcher to `apps/*/current/ui` and
  filter by origin. On the desktop, the same event comes from an inotify watcher in `powos-shell`. In dev mode,
  Astro's own dev server (`shell-dev-url` already exists) gives HMR.
- **Logic.** `spacetime publish` hot-swaps the module in about 140-180 ms (measured). Clients stay on the same
  database. Additive schema changes migrate in place. The template's rules apply: `.default()` with truthy values,
  or `t.option`.

**Rollback:**
- **Logic-only changes (schema unchanged).** Republish the previous version's artifact. This is instant and has no
  data impact.
- **Schema changes.** These are forward-only in SpacetimeDB: republishing an old module whose schema lacks a new
  column counts as a column drop, which is rejected or needs a wipe. So:
  - (a) Keep schemas additive-only. `powos app publish` diffs `schema.json` and refuses destructive changes without
    `--reset`.
  - (b) Snapshot the database before any schema-changing publish. With no per-database export, the snapshot is a
    `SELECT *` dump of each table through the SQL endpoint, replayed into a fresh database on rollback.
  - (c) Always keep the previous UI bundle, so a UI rollback is a symlink flip.

### 5.5 Agents

**Registry.** `powos_registry` is a SpacetimeDB module on each device. Its tables:
- `app`
- `version`
- `widget` (the placements)
- `grant`
- `agent`

The launcher, the desktop and agents *subscribe* to it, so an install appears in the drawer, on the desktop and
in agents' tool lists live.

**Agents are SpacetimeDB clients:**
- Each has its own identity (`agent:<name>`, minted by the same issuer).
- Each holds per-app grants.
- They connect to the same local server.

**Tools come from one generic MCP server (`powos-apps-mcp`):**
- It reads each app's schema (`GET /v1/database/<db>/schema`) and exposes reducers and procedures as tools
  (`<app>.<reducer>`). It skips `_*`, following the template's underscore convention.
- It exposes tables and views as subscribable resources, plus `sql` for one-shot reads.
- This follows the prior art of PowSync-STDB's `@mcp` decorators (`src/mcp/decorators.ts`), generated here from the
  schema instead of decorators.
- Agents stay within their grants, because the modules check `ctx.sender` against `_grants`.
- Existing `powos comms` keeps doing agent-to-agent messages.

**Scaffolding.** `powos app new <name>` copies `~/Projects/spacetimedb-astro`. It swaps React for Preact
(`@astrojs/preact`, `preact/hooks` in `src/lib/db.ts`), adds `powos-app.json`, and adds a `widgets/` entry.

### 5.6 The app runtime: one switch, native first (decided 2026-10-19)

**Lightweight, native and containerless first; containers are a toggle once they are ready on the phone.** The
manifest says *what* an app needs; a setting decides *how* it runs. `lib/apps/powos-runtime` implements it:

| Mode | What runs | Isolation | Phone status |
|---|---|---|---|
| `native` | a plain process under the supervisor (Tier 0 apps: no process at all) | its user; rlimits, nice, ionice | ✅ |
| `sandbox` | the *same binary* under bubblewrap: `--unshare-user --unshare-pid --unshare-uts --unshare-cgroup-try` (never `--unshare-ipc`/`--unshare-all`: no SysV IPC in Android's kernel), `--ro-bind / /`, private `/tmp` `/run`, `/home` and `/var/lib/powos` hidden, only the data dir (+ `needs.write`) writable, `--unshare-net` when `needs.network` is `"none"`, a seccomp denylist (mount/namespaces/BPF/ptrace/keys/kexec/modules/new mount API; `clone` with namespace flags; `clone3` → ENOSYS) and Landlock where the kernel has it | ✅ (no Landlock: `CONFIG_SECURITY_LANDLOCK` is off in this kernel - a kernel item) |
| `container` | podman, for apps that need a foreign userland | full | **not ready yet**: refused (exit 78) until `/dev/fuse` and cgroup v2 land (§2) |

- **Settings.** `powos config app-runtime <mode>` is the default, `powos app runtime <id> <mode>` an app's override,
  both in `/var/lib/powos/runtime/config.json` (the user's, no sudo). The supervisor restarts what a change affects
  within seconds.
- **Flipping never changes the app.** The same command, data dir (bound at the same path), port (the host's network
  namespace), uid (the user namespace maps it to itself, so files and the SpacetimeDB identity stay) - verified on the
  phone by flipping the live SpacetimeDB to `sandbox` and back mid-session.
- **Budgets without cgroups** (the same policy everywhere; hard limits once cgroups exist): rlimits from the manifest
  (`nofile`, `nproc` - per uid, so generous -, `cpuSec` for jobs only, `asMB` only for programs that don't reserve
  huge address space: never V8/wasmtime), `nice`, `io` (ionice class), and the supervisor watching each service's
  process tree in `/proc` every 10 s: RSS over `memMB` → restart (after 3 in 5 minutes: held, never a loop), CPU over
  `cpuPct` for a minute → nice 19 until it calms down. `idle` policies unload (below).
- **Supervisor.** `lib/apps/powos-supervisor`, the system tier's process (§1.2), runs every manifest in
  `/usr/lib/powos/apps/services/`. HACK, by design for now: the real one is `systemd --user` with a delegated cgroup v2
  subtree (§2.4) - one unit per manifest, the same manifests - and this goes.

## 6. Native surfaces, hot reload and lifecycle

### 6.1 Integration matrix

Status: **exists** = works today; **small** = a change of days to existing code; **new** = new work.

| Surface | Platform | Mechanism | Status |
|---|---|---|---|
| Home tile/widget, simple | Phone launcher | **OWL** widget shipped by the app (`widgets/*.owl` → `files/widgets`, `WidgetEngine`), with a new `stdb(db, sql)` source next to `cmd()`/`http()` | OWL **exists**; `stdb` source **new** (Kotlin SpacetimeDB client or a guest-side `stream()` helper) |
| Home tile/widget, rich | Phone launcher | **Shared-host island.** A new `HomeItem.kind: "island"` in `shell/types.ts`/`grid.tsx`. The home page imports the app's widget module (trusted) or mounts a same-origin `<iframe src="https://<id>.app.powos/widgets/…">` (isolated, ~2 MB). One renderer, one SDK, one socket | **new** (grid kind + per-app origin + scoped bridge) |
| Android widgets in home | Phone launcher | `AppWidgets.kt` and `appwidget.tsx` (VirtualDisplay → PNG) | in progress (not for PowOS apps) |
| App window | Phone | A full-screen `ShellHost` WebView on `https://<id>.app.powos/` (one per *open* app, 4 exist today) | **small** (ShellHost already serves arbitrary hosts; add app routing) |
| Drawer, search, recent strip | Phone launcher | `apps.list` (`ShellBridge.kt:265`) merges Android apps and Linux `.desktop` apps (`a:`/`l:` keys). Add `p:<id>` from the registry subscription | **small** |
| Recents/switcher | Phone | `system/Tasks.kt` tasks. A PowOS app window must be a task (its own activity instance or document) | **small–new** |
| Notifications | Phone | Bridge `notifications.*` lists Android notifications only; posting exists only as OWL `notify`. Add `notifications.post` (per-app channel, manifest permission) | **small** |
| Share sheet (send) | Phone | Only OWL `share()` (`WidgetServices.kt:396`). Add bridge `share` | **small** |
| Share sheet (receive) | Phone | `PowosAiActivity` has the SEND filter. Route `surfaces.share` MIME types to apps | **small** |
| App entry | Plasma desktop | `.desktop` file generated from the manifest (`Exec=powos app open <id>`), as `linux/Agents.kt` "new app" already writes | **small** |
| App window | Plasma desktop | QtWebEngine window on `powos-app://<id>/` in `powos-shell` (planned in `docs/DESKTOP-WEB-SHELL.md`, the same `PowosHost.call` bridge contract). Interim: `chromium --app=` against a loopback static server | **new** (interim **small**) |
| Desktop widget | Plasma | **One** plasmoid `com.powos.apps` (QML `WebEngineView`, one profile, so a shared renderer) hosting *all* app islands for that containment. Not one plasmoid instance per widget. `com.powos.manager` is pure QML (`P5Support.DataSource`, no WebEngine) | **new** |
| Tray | Plasma | StatusNotifierItem from `powos-shell` per app that declares it | **new** |
| Notifications | Plasma | `notify-send`/`org.freedesktop.Notifications` (already used in `comms-mcp.py:244`), exposed as bridge `notifications.post` | **small** |
| UI hot reload | Phone | `HotReload` FileObserver → `files.changed` → `shell/hot.ts` | **exists** for the shell; **small** for app dirs |
| UI hot reload | Desktop | inotify in `powos-shell` → the same event | **new** (with powos-shell) |
| Logic hot reload | Both | `spacetime publish` hot swap, ~150 ms; subscriptions carry on | **exists** (SpacetimeDB) + **small** (`powos app publish`) |
| Rollback | Both | Version dirs + `current` symlink + republishing the old artifact (logic-only); snapshot for schema changes | **new** (small CLI) |

### 6.2 OWL vs Astro island for widgets

| | OWL | Astro/Preact island |
|---|---|---|
| Use it for | Glanceable widgets | Interactive or rich widgets |
| Rendering | Native tree (Kotlin evaluates, Preact renders `widget.tree`) | Runs in the shared home page |
| Cost | Near zero | ~0.4-1 MB in the shared host; ~2 MB as an iframe |
| Data sources | Pauses its sources when home is off-screen (`homeStarted/homeStopped`) | Gets the same pause signal |
| Hot reload | Already | Through the new app-dir watch |
| Sandboxing | Sandboxed by construction | Only as an iframe |
| Desktop | Needs an OWL renderer on desktop (`shell/DESIGN.md` plans Kotlin Multiplatform + JS) | Renders unchanged in the desktop plasmoid host |

Both kinds go in the manifest; the shell picks the renderer.

### 6.3 Desktop SpacetimeDB

The desktop runs one SpacetimeDB too, as a systemd unit, the same binary built for x86_64 or aarch64. The same
`powos_registry` and sync agent pair with the phone (§4).

### 6.4 Lifecycle and budgets

**Widgets:**
- The shell already pauses OWL sources off-screen.
- Islands get `visibilitychange` plus `homeStopped`: they unsubscribe and stop timers.
- `useTable`'s 5 s grace then drops the subscription.

**Apps:**
- When a WebView is backgrounded, call `onPause()`/`pauseTimers()`.
- After an idle timer (phone 60 s), destroy the WebView. Its state lives in SpacetimeDB anyway, so reopening is a
  reload plus resubscribe.

**SpacetimeDB.**
- Databases load lazily on first touch (measured). Nothing unloads them at runtime.
- Interim policy: the supervisor restarts the server (~150 ms, 0 loaded) at a quiet moment (screen off, no
  subscriptions) when loaded memory exceeds the budget.
- Ask upstream for idle-database eviction.
- Background apps wake through subscriptions: an agent or the sync agent stays subscribed, the UI does not.

**Per-app budgets that agents can't exceed:**
- Tier 0: reducers run in SpacetimeDB's sandbox (no IO; procedures have an `http.fetch` with an allowlist). The
  registry refuses publishes over the bundle-size budget, and the supervisor tracks per-database RSS (`/metrics`)
  against the manifest budget.
- Tier 1/2: cgroup v2 `memory.max`/`cpu.weight` after §2.4. Until then, Tier 2 stays off on the phone.

**Recommended budgets:**

| Resource | Phone | Desktop |
|---|---|---|
| SpacetimeDB total | ≤ 300 MB loaded (~10-15 TS databases, more as Rust) | ≤ 1.5 GB |
| Per TS database (loaded) | ~16 MB | ~16 MB |
| Per widget | ≤ 1 MB in the shared host; ≤ 3 MB isolated | ≤ 2 MB |
| Per open app (own WebView) | ≤ 30 MB including graphics; at most 3 open apps alive, the rest destroyed after 60 s in the background | ≤ 150 MB |
| Tier 1 runtime | one per device, ≤ 96 MB | ≤ 512 MB |
| Tier 2 | off until §2.4; then ≤ 128 MB each, idle → 0 after 60 s | per manifest |
| Idle wakeups | ≤ 2 /s per widget when visible, 0 off-screen | — |

## 7. What needs the user's OK

1. **Prototype on the phone (Tier 0 first app).**
   - Install SpacetimeDB v2.12 binaries into the rootfs through the central build.
   - Create the system-tier namespace and supervisor (`powos-start.sh`/`powos-session.sh` change).
   - Add the loopback owner rule.
   - Measure idle battery and wakeups on the device.
2. **`/dev/fuse` 0666** through an init rule in PowOS's Magisk `overlay.d` (init_boot repack, `fastboot boot`
   first).
3. **cgroup v2 memory controller trial** through `cgroups.json` in the same overlay. Temporary boot only; check
   lmkd and OPlus hybridswap.
4. **Kernel `containers.config`** (`CGROUP_PIDS`, `CFS_BANDWIDTH`, `TMPFS_XATTR`). Build and kmi-check only; flash
   only if KMI passes and a `fastboot boot` test is clean.
5. **Pin SpacetimeDB 2.12 fleet-wide** and move the template to Preact. This touches `~/Projects/spacetimedb-astro`.

## 8. The prototype on the phone (2026-10-19)

What now exists on the OnePlus Open (user-approved build of the Tier 0 prototype; containers, `/dev/fuse`, cgroup v2
and the kernel deferred):

| Piece | Where | State |
|---|---|---|
| SpacetimeDB 2.12.0, official aarch64 binaries | `targets/android/pkgs/spacetimedb-bin` → `/usr/lib/spacetimedb/2.12.0/`, `spacetime` on PATH; in the image through `out/pkgs` (`install-powos-android.sh` installs every package there), on a running phone through `rooted.sh deploy` | ✅ |
| System tier | `powos-start.sh` → `powos-supervisor` in PowOS's own mount namespace, once per boot; survives desktop restarts | ✅ |
| Port lock | iptables chain `powos-local`: `127.0.0.1:3410` for the app's uid (looked up in `packages.list` each start) and root, `tcp-reset` for the rest | ✅ uid 2000 (shell) and 10200 (another app) refused; root and 10359 pass |
| Runtime switch | `powos-runtime`, `powos config app-runtime`, `powos app runtime` | ✅ native, sandbox; container stubbed |
| Registry | `apps/registry` (Rust) → database `powos-registry`, `install(manifest)`/`remove(id)`, owner-only | ✅ |
| Tier 0 app | `apps/counter` (Rust module `powos-counter`, island `widgets/count.js`, `powos-app.json`) | ✅ installed via `powos app install` |
| Shell | `shell/apps/stdb.ts` (one socket per database for the page, 5 s grace, closed while hidden), `shell/apps/registry.ts`, `shell/ui/island.tsx`, vendored SDK `vendor/spacetimedb.js` (119 KB) | see below |

**Measured on the phone** (SM8550, as `powos`, tests in `/tmp`, cleaned up):

| | Value | Study (Mac) |
|---|---|---|
| SpacetimeDB start → `/v1/ping` | 128 ms | 130-150 ms |
| SpacetimeDB idle, 0 databases loaded | 50.8 MB RSS, 27 threads, 1.4 % of a core, ~144 wakeups/s | 137 MB, 0.3-0.7 %, ~170/s |
| … 2 Rust databases loaded (registry + counter) | 74-78 MB RSS, 31 threads, 3.8-4.4 % of a core, ~435 wakeups/s | — |
| Per loaded Rust database | ~13 MB, **~145 wakeups/s**, ~1.4 % of a core | ~5.5 MB, ~11/s |
| `TOKIO_WORKER_THREADS=2` | 25 threads, wakeups and CPU unchanged: the cost is per database, not per worker | — |
| Start `true`: plain exec / `powos-runtime` native / sandbox / podman (vfs store) | 3-6 ms / 70-87 ms / 79-131 ms / 315-367 ms | podman 310-460 ms |
| Wrapper cost, sandbox | 2 bwrap processes, 0.96 MB + 0.12 MB RSS, 0 wakeups idle | conmon 2.3 MB |
| Sandbox as seen from inside | uid kept (10359), own pid/user ns, CapEff 0, NoNewPrivs 1, seccomp filter on, `/usr` read-only, `unshare` → EPERM | — |
| Supervisor | ~0.1 wakeups/s (one `sigtimedwait` per 10 s tick; a child's exit wakes it) | — |

**What follows:**
- `powos-runtime`'s ~70 ms is Python start-up, paid once per service start, not per request. Sandbox adds ~10-40 ms
  and ~1 MB; podman adds ~250 ms, a storage driver and (on the phone) blocks on `/dev/fuse`.
- **Idle wakeups per database are ~13× the Mac's**, so idle unload is not optional on the phone: the supervisor's
  policy (no client for `idle.quietSec` = 300 s and RSS above `idle.unloadAboveMB` - 60 MB on the phone, 180 on a Mac, per device since the base differs - → restart, which unloads
  everything) brings an untouched server back to its ~144/s base. Next: ask upstream for idle-database eviction, or
  profile the per-database timers (the tokio workers wake ~100×/s each with 2 databases). Battery cost: measure over a
  night with `dumpsys batterystats` before the service is always-on by default.

**Next steps (exact):**
1. **Islands on home** - wire `app:<id>/<widget>` home items into the `panel` kind (`ShellPanels.kt`), the grid
   (`grid.tsx` → `ui/island.tsx`) and the edit sheet (a "PowOS apps" list from the registry); APK.
2. **cgroup v2 memory controller trial** (needs `fastboot boot` over USB - not possible over the VPN):
   1. Extract the current `init_boot` (`backup/<serial>/init_boot_b.img`), unpack with `magiskboot unpack`.
   2. Find the file `libprocessgroup` reads (`strings /system/lib64/libprocessgroup.so | grep cgroups`; expected
      `/system/etc/cgroups.json`, no vendor copy here). Put a copy with `memory` moved from `Cgroups` (v1) to
      `Cgroups2.Controllers` (`"NeedsActivation": true, "Optional": true, "MaxActivationDepth": 3`) into the
      ramdisk's Magisk `overlay.d/powos/cgroups.json`, and `overlay.d/powos.rc` with
      `on early-init` → `mount none /powos/cgroups.json /system/etc/cgroups.json bind` (before `SetupCgroups()`), and
      `on post-fs-data` → `mkdir /sys/fs/cgroup/powos 0755 <powos uid> <powos uid>` +
      `write /sys/fs/cgroup/powos/cgroup.subtree_control +memory`.
   3. `magiskboot repack` → `init_boot-cg2.img`; **`fastboot boot init_boot-cg2.img`** (temporary, nothing flashed).
   4. Check: `cat /sys/fs/cgroup/cgroup.controllers` lists memory; `dumpsys meminfo`; `logcat -b events | grep lmk`
      during a memory soak (open 20 apps); the OPlus hybridswap/osense daemons' logcat for errors on
      `/dev/memcg/*`; compare against a stock boot.
   5. Only if clean: flash `init_boot_b`, keeping the stock image; then podman `cgroups=enabled` and the supervisor
      moves services into `/sys/fs/cgroup/powos/<id>` with real `memory.max` (or `systemd --user`).
3. **Kernel items** (another agent prepares the build): `CGROUP_PIDS`, `CFS_BANDWIDTH`, `TMPFS_XATTR`, and now
   `SECURITY_LANDLOCK` (+ `landlock` already first in `CONFIG_LSM`), each through `tools/kmi-check.py`, `fastboot boot`
   first.
4. Per-app identities from the shell's issuer (HACK in `shell/apps/stdb.ts` until then: server-issued tokens).
5. Session tier joins the system tier's namespace (`nsenter -t <supervisor pid> -m`) instead of building its own,
   once the session's bind mounts (`/run/powos-app`, `files/apps`) are made inside it.

