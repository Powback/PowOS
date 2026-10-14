// QEMU's command line: PowOS's Arch Linux ARM build (targets/web/build-rootfs.sh, the phone's installer in VM
// mode) on QEMU's "virt" board. Its kernel + initramfs are preloaded (boot needs them whole); its root
// filesystem is the chunked disk, streamed block by block as the guest reads it (qemu/block/chunked.c). The
// page passes the disk's absolute URL (QEMU's worker fetches it).
//
// Memory: wasm32 caps QEMU's whole heap at 2300M (TOTAL_MEMORY): guest RAM + the TCG translation cache +
// the preloaded kernel/initramfs (held as files, and the initramfs copied again into guest RAM) must fit.
// 1536M RAM + 500M cache ran out (Aborted(OOM)). TODO: a slim initramfs (virtio + ext4 only) frees ~350M.
//
// CPU: neoverse-n1 (ARMv8.2, no SVE), not "max": with max, glibc picks SVE/MOPS routines, and systemd crashed
// (SEGV in PID 1) under qemu-wasm's young wasm code generator. v8.2 because our FEX build targets it.
globalThis.Module = globalThis.Module || {};
Module.preRun = Module.preRun || [];
Module.powosArgs = (diskUrl) => [
  '-nographic', '-M', 'virt', '-cpu', 'neoverse-n1', '-m', '1024M', '-accel', 'tcg,tb-size=256',
  '-nic', 'none',
  '-kernel', '/pack-kernel/Image',
  '-initrd', '/pack-initramfs/initramfs.img',
  '-append', 'console=ttyAMA0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target',
  // -drive, not -blockdev: -blockdev checks driver names against QEMU's QAPI schema, which only knows upstream
  // drivers; -drive finds "chunked" in the block layer's registry.
  '-drive', `if=none,id=disk0,format=raw,file.driver=chunked,file.url=${diskUrl}`,
  '-device', 'virtio-blk-pci,drive=disk0',
];
