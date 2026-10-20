# Phone kernel for container limits (OnePlus Open)

PowOS runs rootless podman on the OnePlus Open. This kernel lets it put hard limits on each app: process
count (`pids.max`), CPU quota (`cpu.max` / `cpu.cfs_quota_us`) and memory, and it adds nftables for netavark.
The prior analysis is in `docs/POWOS-APPS-FEASIBILITY.md` §2.4–2.5.

**Status (2026-10-20): built and checked on the Mac. Not booted yet.** Nothing was flashed or written to the
phone, and it was not rebooted. The next step is a `fastboot boot` session with the phone on USB and the user
present (§7).

| | |
|---|---|
| Device | OnePlus Open CPH2551 (EEA), serial `8e5d600d`, SM8550, active slot **b**, bootloader unlocked, Magisk 30.7 |
| Firmware | OxygenOS `CPH2551_16.0.5.1301(EX01)`, Android 16, security patch 2026-09 |
| Running kernel | `5.15.180-o-g298ff0fe2773-dirty #4 SMP PREEMPT Fri Oct 16 21:07:11 UTC 2026`: PowOS's own build (`targets/native/build-gki-kernel.sh`: namespaces + futex_waitv), flashed to boot_b on 2026-10-16/17. Stock is `5.15.197-android13-8-o-01214-gbee5b6ef6244`. |
| Compiler (`/proc/version`) | `Android (8508608, based on r450784e) clang version 14.0.7`, LLD 14.0.7 (same as stock) |
| Images | boot, init_boot and vendor_boot all use header **v4**. boot holds only the kernel (ramdisk size 0, empty cmdline). init_boot holds the Magisk-patched ramdisk. vendor_boot holds the DTB, the vendor ramdisk and 450 first-stage modules. |
| Vendor modules | 450 in the vendor_boot ramdisk and 386 in vendor_dlkm (live `vendor_dlkm_b` sha256 = stock `507748a1…`), vermagic `5.15.197-g9f779dbfeb4d SMP preempt mod_unload modversions aarch64` |
| Module ABI | `MODVERSIONS=y` (symbol CRCs are checked at load), `MODULE_SIG=y` + `MODULE_SIG_PROTECT=y` (not FORCE), `LTO_CLANG_FULL` + `CFI_CLANG`, `ANDROID_KABI_RESERVE=y`, `TRIM_UNUSED_KSYMS` off |

## 1. Kernel source for this firmware

- **The exact 16.0.5.1301 source is not published.** On 2026-10-19, `git ls-remote` showed OnePlusOSS
  `android_kernel_common_oneplus_sm8550` with only `oneplus/sm8550_b_16.0.0_oneplus_open` = `298ff0fe2773`
  ("CPH2551_16.0.3.500(EX01) … android13-5.15-2025-05_r6", SUBLEVEL 180) and `…_v_15.0.0_…`. The shipped
  16.0.5.1301 kernel is 5.15.197, so OnePlus is one maintenance release behind.
  - `android_kernel_modules_and_devicetree_oneplus_sm8550` and `android_kernel_oneplus_sm8550` (msm-kernel,
    which contains WALT) have the same `b_16.0.0` branch. `kernel_manifest` has no Open entry.
- **Why the 16.0.3.500 tree is still safe.** The KMI is frozen within android13-5.15, and the phone has run a
  kernel built from this tree since 2026-10-16. That kernel passes `tools/kmi-check.py` (CRCs) against the
  phone's own 836 vendor modules, and Wi-Fi, modem, GPU, display and root were checked on it. The new kernel
  is that kernel plus three patches. Every check below compares against it, not against an unknown stock
  build.

## 2. What podman, crun, pasta and netavark need

I ran moby's `contrib/check-config.sh` against the phone's `/proc/config.gz`:

| Missing | Matters for PowOS? | Done here |
|---|---|---|
| `CGROUP_PIDS` | yes: `--pids-limit`, fork-bomb guard | **yes** |
| `CFS_BANDWIDTH` | yes: `--cpus`, `cpu.max` | **yes** |
| `NF_TABLES`, `NFT_CT/NAT/MASQ/FIB*` | netavark's firewall driver (podman 5+ is nftables-only), `nft`, iptables-nft | **yes, as modules** |
| `IPC_NS` (`SYSVIPC`, `POSIX_MQUEUE`) | `ipcns=private`. Workaround today: `ipcns=host` plus the SysV shim | no. Adds `task_struct` fields; it could be done with the same technique as below, but nobody asked for it |
| `CGROUP_DEVICE` | no. On cgroup v2, crun uses eBPF device programs (`CGROUP_BPF=y`) | – |
| `BRIDGE_NETFILTER`, `IP6_NF_NAT`, `IP6_NF_TARGET_MASQUERADE`, `XT_MATCH_ADDRTYPE`, `IP_VS*` | Docker's iptables mode only. netavark with nftables doesn't use them | – |
| `CGROUP_PERF`, `CGROUP_HUGETLB`, `NET_CLS_CGROUP`, `VXLAN`, `MACVLAN`, `BTRFS` | not needed for the app model | – |

pasta needs `TUN` and user namespaces, and crun needs user, PID and mount namespaces. All of these are already
on.

## 3. KMI impact, option by option

"KMI" here means two things the vendor modules depend on:
- **(1) symbol CRCs** (MODVERSIONS refuses a module on any mismatch);
- **(2) the byte layout of every struct they touch**, which CRCs only partly cover.

Both are checked:
- (1) with `targets/native/tools/kmi-check.py` against all 836 vendor modules;
- (2) with `targets/android/kernel/tools/layout-diff.py`, which compares the `pahole` dump of every named
  struct, union and enum between the running kernel's vmlinux and the new one, using offsets, sizes and holes
  from BTF.

| Option | Built the normal way | What this kernel does instead | Result |
|---|---|---|---|
| `CGROUP_PIDS` | Adds a cgroup subsystem. `CGROUP_SUBSYS_COUNT` goes from 7 to 8, so `css_set.subsys[]` (the **first** member), `cgroup.subsys[]`, `e_csets[]` and friends grow, and every later field shifts. **KMI break.** | **Patch 0001:** pids takes the subsystem id of `net_prio`, the last subsystem in this config. Count, ids and every layout stay the same. genksyms still sees `net_prio` (`__GENKSYMS__`), so CRCs don't change. `cgroup.c` gives the pids static keys their CRCs explicitly. | Image only |
| `CFS_BANDWIDTH` | Adds 8 fields to `struct cfs_rq`. That struct is embedded early in `struct rq`, so most of `rq` shifts. It also turns the zero-size `task_group.cfs_bandwidth` into ~250 bytes, which shifts `uclamp*` and `android_vendor_data1`. `sched-walt`, `oplus_bsp_sched_assist`, `oplus_bsp_frame_boost` and others include `kernel/sched/sched.h` and read these at fixed offsets. **KMI break, and a silent one.** | **Patch 0002:** the bandwidth state lives *beside* the structs. Each group `cfs_rq` is allocated as `struct cfs_rq_ext { cfs_rq; cfs_rq_bw; }`, and the root `cfs_rq` inside `struct rq` uses a per-CPU `cfs_rq_bw`. Each task group comes from a `task_group_ext` cache, and the root group uses a static `root_cfs_bandwidth`. Accessors are `cfs_rq_bw()` and `tg_cfs_bandwidth()`. genksyms sees the stock definitions. | Image only |
| `NF_TABLES` (+`NFT_*`, `=m`) | Adds `struct netns_nftables nft` to `struct net`, which shifts every later netns member (`ct`, `ft`, `xfrm`, …) even with `=m`. **KMI break.** | **Patch 0003:** nf_tables' generation cursor moves into its own per-netns data (`struct nftables_pernet`, first member, guarded by `BUILD_BUG_ON`; `nf_tables_net_id` is exported so the `nft_*` modules can reach it). `struct net` stays stock, and nf_tables plus 21 `nft_*` modules load as `.ko`. The built-in code changes in one place: `nf_nat_proto.c` gains two **added** exports (`nf_nat_inet_(un)register_fn`). | Image + `.ko` |

**Pre-check (before the full build).**
- I compiled `kernel/sched`, `kernel/cgroup`, `net/core` and `net/netfilter` with the patches and config.
- Every `__crc_*` in their `.symversions` was identical to the running kernel's. The only exception was the
  two added nf_nat exports.
- The full-build results are in §6.

**What the patches give up.**
- **net_prio.** The `net_prio` cgroup controller goes away.
  - Android doesn't mount it: hierarchy 0 in `/proc/cgroups`, and it is not in `cgroups.json`.
  - No vendor module imports a net_prio symbol. The only `*_cgrp_*` imports are `cpu_cgrp_subsys`,
    `memory_cgrp_subsys` and `memory_cgrp_subsys_enabled_key`.
  - Its struct fields stay in place, unused: `net_device.priomap` (always NULL) and `sock_cgroup_data.prioidx`
    (always 0).
- **Throttling is invisible to the vendor modules.** They were built with `CFS_BANDWIDTH=n`, so their inlined
  `cfs_rq_throttled()` returns 0.
  - WALT's MVP picker (`walt_cfs_replace_next_task_fair`, `kernel/sched/walt/walt_cfs.c:1687`, comment
    "TODO If CFS_BANDWIDTH is enabled, we might pick from a throttled cfs_rq") can therefore run a task from a
    throttled group.
  - `set_next_entity()` checks `on_rq`, so this doesn't corrupt the rbtree, but that task escapes its quota
    while WALT treats it as MVP.
  - MVP tasks are top-app, binder and low-latency threads. Container processes in their own cgroup are none of
    those.
  - WALT also keeps counting throttled tasks' demand, which makes its frequency guesses slightly high.
  - Watch for both during the test (§7, checks C6/C7).

## 4. Route

**Route (a), extended. Only the kernel `Image` changes, and the nftables modules are built against it. Route
(b) is not needed for any of the three options.**

- (a) pure: build the options as modules against the stock KMI. Only `NF_TABLES` is tristate. `CGROUP_PIDS`
  and `CFS_BANDWIDTH` are `bool` and must be built in, so pure (a) can't deliver them.
- (b): rebuild GKI plus **all** vendor modules, then repack vendor_boot and vendor_dlkm. Rejected:
  - The published source is 16.0.3.500, not 16.0.5.1301, so a rebuilt vendor set would be a different build
    from what ships. That means different firmware-interface assumptions for display, GPU, camera and modem
    blobs, which is exactly the mismatch the task says not to ship.
  - It would mean replacing 836 modules in two partitions (vendor_dlkm is dm-verity'd in `super`).
  - With the KMI-preserving patches it buys nothing.
- The vendor modules, vendor_boot, vendor_dlkm, dtbo and init_boot (Magisk) stay exactly as they are. A test
  or a flash touches **boot only**.

## 5. Build

Reproducible: `targets/android/kernel/build-containers-kernel.sh`. It runs `extract-vendor-modules.sh` first if
needed. It uses the same Docker builder image (`targets/native/docker/gki`, amd64 under Rosetta) and the same
`powos-gki-cache` volume as the native kit:

1. Google clang **r450784e** (Android 8508608, clang 14.0.7, the compiler `/proc/version` reports).
2. A separate git worktree `kernel_platform/common-containers` of the OnePlus tree at `298ff0fe2773`. It is
   recreated whenever the patch set changes, and the running kernel's tree stays untouched. The script applies
   `targets/native/patches/gki/*.patch` (futex_waitv) and `targets/android/kernel/patches/000{1,2,3}*.patch`.
3. Config: `gki_defconfig` + `targets/native/config/gki/*.config` + `targets/android/kernel/config/containers.config`.
   The build fails if any fragment line didn't stick. It also fails if any `.config` line differs from the
   running kernel's, apart from the fragment and nf_tables' own `NF_TABLES_*`/`NFT_*` sub-options. Actual diff:
   exactly the 28 expected lines.
4. The script reuses the running kernel's module-signing key from the volume (never printed), so its modules
   verify on either kernel.
5. Outputs, checks and boot images:
   - It builds `Image Image.gz modules`, copies 22 nftables `.ko` files (stripped and signed by
     `modules_install`), and writes their `insmod` order.
   - The pahole layout diff runs against the running kernel, and `kmi-check.py` runs against the 836 vendor
     modules plus the new `.ko`s.
   - Boot images: the stock `boot_b` header (OS version 13.0.0, patch level 2026-09, v4) with this kernel
     swapped in, plus the RAM-only `-v2test` variant (§7.4).

Not committed: the artifacts in `targets/android/kernel/out/` (gitignored).

<!-- RESULTS -->

## 6. Results (build of 2026-10-20)

| Check | Result |
|---|---|
| Config drift vs the running kernel | 28 lines, exactly the fragment plus nf_tables sub-options |
| Struct layouts (`out/layout-diff.txt`) | 10586 shared types, **all identical**. New types only: `cfs_rq_bw`, `cfs_rq_ext`, `task_group_ext`, `pids_cgroup`, `cfs_schedulable_data`. `struct cfs_bandwidth` changed, as allowed. `task_group` lost only its zero-size member; `uclamp*`, `android_vendor_data1` and the KABI slots sit at the same offsets, and the size is 512 in both. |
| Symbol CRCs (`out/kmi-check.txt`) | `858 modules checked against 15424 kernel symbols`: 450 vendor_boot + 386 vendor_dlkm + 22 new. **OK, no mismatch.** The 1831 "not exported by the kernel" are module-to-module symbols, the same count as on the running kernel. |
| Kernel | `5.15.180-o-g298ff0fe2773-dirty` (the same release string as the running kernel; tell the two apart with `uname -v` or `/proc/cgroups` listing `pids`) |
| nftables modules (`out/modules/load-order.txt`) | `nf_tables nft_chain_nat nft_compat nft_connlimit nft_counter nft_ct nft_fib nft_fib_ipv6 nft_fib_ipv4 nft_fib_inet nft_hash nft_limit nft_masq nft_nat nft_numgen nft_objref nft_quota nft_redir nft_reject nft_reject_inet nft_reject_ipv4 nft_reject_ipv6` |

Artifacts (`targets/android/kernel/out/`, not committed; the full list including each `.ko` is in `out/SHA256SUMS`):

| file | sha256 |
|---|---|
| `boot-powos-containers.img` (candidate, 48918528 bytes) | `e8205808a49aa1259d0d50e2fc1ff61e9a8b71fc5425c6a10da99f2c347000d6` |
| `boot-powos-containers-v2test.img` (RAM-only, cmdline `cgroup_no_v1=memory,cpu`) | `4cb9b4e037f0ea59a03462d29707f29fd5409c32e21c6543aead4a8065608ae5` |
| `Image` | `2e54d9a065f6ea289a34c64ef123414957f9d7e3d6d8458706e0279f928bf989` |
| `Image.gz` | `a31614300b01b87a6c84c20e9abd83c0fd1e9ba471c7704f6480db5b350e8fc3` |
| `Module.symvers` | `31af749cf80a25616e7a67a686c1d80a9aa9306e80949a03d3e74e470d136714` |
| `modules/nf_tables.ko` | `f16a599b770a74ec860e73f7df99fba32735b4a11e8b23d78345c13ef170742e` |

**Build time.** Compiling all objects takes about 50 min. The full-LTO `vmlinux` link is single-threaded under
Rosetta and takes **1.5–2.5 h**, depending on load on the Mac. The script reruns `gki_defconfig` every time,
so each run relinks; the last (incremental) run took 92 min. End to end, this first build took about 7.5 h
wall-clock, including three failed attempts:
1. clang segfaulted once compiling `drivers/interconnect/core.o` (a Rosetta flake; just rerun);
2. the pids static keys had no CRCs, so the link failed — fixed in patch 0001 (`cgroup.c`);
3. `nf_tables_net_id` was not exported — fixed in patch 0003.

## 7. USB test (user present, phone on the Mac's own USB-C port)

**Use `fastboot boot` only: it loads the image into RAM and writes nothing.**
- This works on this bootloader with header v4 plus the init_boot split. The namespaces and futex kernels were
  tested this way (PLAN.md).
- The bootloader takes the kernel from the RAM image and the ramdisk from the **flashed** init_boot_b (Magisk)
  and vendor_boot_b. **Root is therefore kept during the test**, and nothing needs patching with magiskboot.
- Use the Android SDK's fastboot (`~/Library/Android/sdk/platform-tools/fastboot`). Homebrew's fastboot gets
  killed by macOS (ROOTING.md).

### 7.0 Before

```bash
cd targets/android/kernel
shasum -a 256 -c out/SHA256SUMS                      # artifacts are the ones in §6
ADB=adb ./phone-test.sh check > out/check-before.txt # baseline on the current kernel (pids absent, no cfs_quota)
```

Backups exist and are verified (§8); don't take new ones. Battery should be above 50 %.

### 7.1 Boot the candidate (Android layout untouched)

```bash
adb reboot bootloader
~/Library/Android/sdk/platform-tools/fastboot boot out/boot-powos-containers.img
# wait for the lock screen, unlock, then:
./phone-test.sh check | tee out/check-after.txt
```

If it doesn't reach the lock screen within about 3 minutes, see §8 (rollback): hold power + volume-down. The
next boot is the old kernel again.

### 7.2 nftables modules

`./phone-test.sh nft`:
- pushes `out/modules/` to `/data/local/tmp/powos-nft`;
- `insmod`s them in `load-order.txt` order;
- creates, lists and deletes a throwaway `inet powos_test` table with the PowOS root's `nft`.

### 7.3 Limits on plain cgroup files

`./phone-test.sh limits`. Android's v1 layout is left as it is.
- **pids** (v2): `pids.max=5`, then 8 forks. Expect "can't fork" errors and a `pids.events` max count above 0.
- **cpu** (v1 cpuctl): `cfs_quota_us=20000` on a 100 ms period, with a 5 s busy loop. Expect `nr_throttled` > 0
  and about 4 s of `throttled_time`.
- **memory** (v1 memcg, which already works on the stock kernel): 64M limit, then a 200 MB hog. Expect it to be
  killed and `failcnt` > 0.

### 7.4 Full podman command (RAM-only experiment, optional)

Podman 6 is cgroup-v2-only, and Android keeps memory and cpu on v1. `out/boot-powos-containers-v2test.img` is
the same kernel with `cgroup_no_v1=memory,cpu` on the boot cmdline. This is what the `podman` subcommand needs.
- **Expected side effects for that one boot:**
  - Android can't mount `/dev/memcg` or `/dev/cpuctl` (init logs it and continues);
  - per-app memcg, the cpuctl top-app/background groups and their boosts are gone, so UI performance can be
    worse and lmkd falls back to PSI;
  - **never flash this image.**

```bash
adb reboot bootloader
~/Library/Android/sdk/platform-tools/fastboot boot out/boot-powos-containers-v2test.img
./phone-test.sh check     # v2 controllers: "cpu memory pids"
./phone-test.sh podman    # podman run --pids-limit 10 --cpus 0.2 --memory 64m alpine (in the PowOS root, as root)
adb reboot                # back to the normal kernel
```

This runs rootful podman in the PowOS root with `--cgroup-manager=cgroupfs --cgroups=enabled`. Rootless needs a
delegated v2 subtree owned by the PowOS user (the init rule in feasibility §2.4), which is a userspace change.

### 7.5 Go / no-go

All of these must hold on the candidate image (7.1–7.3) before anyone flashes it:

| # | Check | Go |
|---|---|---|
| C1 | boots to the lock screen, `uname -v` shows the new build date | yes |
| C2 | display: both panels (inner and cover), fold/unfold, brightness | normal |
| C3 | touch on both panels; fingerprint unlock (the dumpsys line plus a real unlock) | works |
| C4 | Wi-Fi connects; `check` shows "Wi-Fi is enabled" | yes |
| C5 | modem/IMS: same `mVoiceRegState/mDataRegState` as `check-before.txt`, a call and SMS if a SIM is in, VoLTE if it was on before | no worse than before. **Note:** the 2026-10-19 baseline on the current kernel already showed `OUT_OF_SERVICE` (emergency only), so compare against the baseline, not against "in service" |
| C6 | camera: the camera app opens front and back, and `Number of camera devices: 8` | yes |
| C7 | no new `disagrees about version`/`Unknown symbol` in `dmesg`; `cat /proc/modules \| wc -l` the same as before (526) | yes |
| C8 | `/proc/cgroups` lists `pids` (where net_prio was); `/sys/fs/cgroup/cgroup.controllers` contains `pids`; `/dev/cpuctl/cpu.cfs_quota_us` exists | yes |
| C9 | `phone-test.sh nft`: all modules load, `nft: OK` | yes |
| C10 | `phone-test.sh limits`: pids refused, cpu throttled, memory killed | yes |
| C11 | 10 minutes of normal use (scrolling, an app switch, PowOS session) with no lag spikes, no WALT `WALT_BUG` / `sched` warnings in `dmesg`, battery drain normal | yes |
| C12 | `-v2test` (optional): `podman run --pids-limit 10 --cpus 0.2 --memory 64m alpine` shows `pids.max=10 cpu.max=20000 100000 memory.max=67108864`, refuses forks, throttles and OOM-kills at 64m | yes |

**No-go if any of these happen:**
- any of C1–C10 fails;
- the phone reboots by itself (`/proc/last_kmsg`, or the pstore under `/sys/fs/pstore`, after the reboot);
- WALT warnings appear in `dmesg`.

To roll back, just reboot (§8).


## 8. Rollback

`fastboot boot` writes nothing, so **rollback for every test in §7 is a reboot.** Hold power + volume-down, or
run `adb reboot`. The phone comes back on the kernel in boot_b, which is the futex kernel the phone already
runs.

If the phone doesn't come back on its own:
1. Force a reboot with power + volume-up held about 10 s.
2. Pick "Start" in the bootloader. The flashed slot b is unchanged.

Undo images for a later flash, all sha256-verified against the live partitions on 2026-10-19:

| what | image |
|---|---|
| current boot_b (futex kernel) | `~/Projects/PowOS/backups/oneplus-open/2026-10-19-before-containers-kernel/boot_b.img` `b8bf6ec6…` |
| stock boot_b | `targets/native/backup/8e5d600d/boot_b.img` = `stock-16.0.5.1301-EX01/boot.img` `07dba7ac…` |
| init_boot_b (Magisk), vendor_boot_b, dtbo_b, vbmeta_b, vbmeta_system_b, vbmeta_vendor_b, vendor_dlkm_b | same folder, see `SHA256SUMS`; all identical to the 2026-10-16 backups, only boot_b changed since |
| persist, modemst1, modemst2, fsg, everything else | `targets/native/backup/8e5d600d/` (2026-10-16) + NAS `~/nas/PowCache/backups/oneplus-open-8e5d600d/` |

## 9. Making it permanent (separate decision, not done)

Only after every go check in §7 passes:
1. `fastboot flash boot_b out/boot-powos-containers.img`, or write it with root `dd` the way the futex kernel
   went in (PLAN.md).
   - Undo: `fastboot flash boot_b ~/Projects/PowOS/backups/oneplus-open/2026-10-19-before-containers-kernel/boot_b.img`.
   - init_boot (Magisk), vendor_boot and vendor_dlkm are not touched.
2. Load the nftables modules at boot from the PowOS system module (`targets/android/system-module`), e.g.
   `post-fs-data.sh` `insmod`s `out/modules/` in `load-order.txt` order from the module directory. They are
   signed with the kernel's key and vermagic-compatible. A mismatching kernel (stock, after an OTA) refuses them
   cleanly with "disagrees about version"; nothing crashes.
3. Put memory and cpu on cgroup v2 for podman `--memory/--cpus`. This is Android userspace, not this kernel,
   and is still open:
   - `cgroups.json` is read before Magisk mounts modules (feasibility §2.4).
   - `cgroup_no_v1=` on the boot cmdline works (the `-v2test` image) but takes per-app memcg and the cpuctl
     boost groups away from Android.
   - Until that's solved, PowOS can enforce the same limits **today** through the v1 files the `limits` test
     uses: run podman with `--cgroups=disabled` (as now) and have the supervisor put the container's conmon in
     `/dev/memcg/powos/<app>` (`memory.limit_in_bytes`), `/dev/cpuctl/powos/<app>` (`cpu.cfs_quota_us`) and
     `/sys/fs/cgroup/powos/<app>` (`pids.max`) before it starts. Children inherit all three.

## 10. OTAs

An OxygenOS OTA rewrites the inactive slot's boot, init_boot, vendor_boot, vendor_dlkm and dtbo, then switches
slots. The phone then boots the **stock** kernel without root, so these limits are gone (nothing breaks):
- the nftables modules are refused cleanly;
- pids is missing from the v2 controllers;
- `cpu.cfs_quota_us` is missing.

Re-apply:
1. Turn automatic updates off (PLAN.md rule). Take the OTA, and before rebooting use Magisk → "Install to
   inactive slot".
2. After the reboot, check the new firmware's kernel:
   - `uname -r`;
   - extract its vendor_boot and vendor_dlkm modules with `extract-vendor-modules.sh <dir with the new stock
     images>`;
   - rerun `build-containers-kernel.sh`, which runs `kmi-check` against the **new** vendor modules.
3. If OnePlusOSS has published the new firmware's source by then, point `BRANCH` at it. The patches are small
   and should rebase. The `HEAD` pin is the OnePlus tree.
4. Repeat §7 (`fastboot boot` first), then flash to the new active slot's boot.

Never flash an image built for an older firmware onto a newer slot just because it booted before. The KMI check
must pass against the modules that are actually on the slot.
