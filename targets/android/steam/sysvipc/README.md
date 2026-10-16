# sysvipc-emu: System V IPC for x86 Steam on Android kernels

Android's GKI kernel has no System V IPC (`CONFIG_SYSVIPC` off: `semget`/`shmget` return ENOSYS). The x86 Steam
client needs SysV semaphores; without them it asserts in `threadtools.cpp` ("Function not implemented",
"semaphore creation failed") and stalls. FEX passes these syscalls straight to the kernel, so the fix sits in the
x86 guest: an `LD_PRELOAD` library that implements `sem*`/`shm*` on files in `/dev/shm` with futex waits, built for
i686 and x86-64 (the loader skips the one whose ELF class doesn't match).

Vendored unchanged from [LeeSiWal/y700-linux](https://github.com/LeeSiWal/y700-linux) `steam-kit/sysvipc/`
(commit b4272524d5ff7914a6cd3b329da701d3170a9964, 2026-09-21), Apache License 2.0 (`LICENSE.y700-linux`). Their
Steam setup (Lenovo Y700, stock GKI) also needed a fake bwrap and a container-less runtime for lack of user
namespaces; PowOS's rooted mode has those (namespaces kernel + pivot_root), so only this part is used.

Build (arm64 Ubuntu 24.04 container, cross gcc; glibc 2.39 - the Fedora 44 x86 RootFS has a newer one, fine):

    targets/android/steam/sysvipc/build.sh    # -> targets/android/out/sysvipc/sysvipc-emu.tar.gz

Kernel alternative: `targets/native/config/gki/sysvipc.config` (needs Halium's KABI-padding patch to keep the
vendor modules loading - see that file).
