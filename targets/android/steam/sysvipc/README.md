# sysvipc-emu: System V IPC for x86 Steam on Android kernels

Android's GKI kernel has no System V IPC (`CONFIG_SYSVIPC` off: `semget`/`shmget` return ENOSYS). The x86 Steam
client needs SysV semaphores; without them it asserts in `threadtools.cpp` ("Function not implemented",
"semaphore creation failed") and stalls. FEX passes these syscalls straight to the kernel, so the fix sits in the
x86 guest: an `LD_PRELOAD` library that implements `sem*`/`shm*` on files in `/dev/shm` with futex waits, built for
i686 and x86-64 (the loader skips the one whose ELF class doesn't match).

Vendored from [LeeSiWal/y700-linux](https://github.com/LeeSiWal/y700-linux) `steam-kit/sysvipc/`
(commit b4272524d5ff7914a6cd3b329da701d3170a9964, 2026-09-21), Apache License 2.0 (`LICENSE.y700-linux`). Their
Steam setup (Lenovo Y700, stock GKI) also needed a fake bwrap and a container-less runtime for lack of user
namespaces; PowOS's rooted mode has those (namespaces kernel + pivot_root), so only this part is used.

PowOS change (2026-10-23): `semctl` SETVAL/SETALL set the semaphore's sempid to the caller, as Linux does (upstream left
it 0). Valve's named events (the Steam client's single-instance event behind `~/.steam/steam.pipe`) treat a semaphore
whose GETPID is 0 or a dead pid, with nobody waiting, as abandoned and `IPC_RMID` it: the next Steam process to open
the running client's event removed it, the client's own `semop` on it failed with EIDRM from then on, and every
command line forwarded to a running Steam (`steam steam://rungameid/<id>`, `steam -shutdown`) was dropped.
`sysv-test self` checks it (kernel SysV passes it too).

Build (arm64 Ubuntu 24.04 container, cross gcc; glibc 2.39 - the Fedora 44 x86 RootFS has a newer one, fine):

    targets/android/steam/sysvipc/build.sh    # -> targets/android/out/sysvipc/sysvipc-emu.tar.gz

Kernel alternative, not taken: `CONFIG_SYSVIPC=y` in a config fragment is silently dropped by the GKI build (tried
2026-10-16: the built kernel still had it off). Enabling it needs Halium's patch that moves the SysV fields of
task_struct into the ANDROID_KABI_RESERVE padding, so the phone's vendor modules keep loading (Droidian/RainOS).
