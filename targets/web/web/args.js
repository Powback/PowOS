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

// ?boot=<name>: the same kernel and machine, a test initramfs instead of PowOS's (packed by assemble.sh from
// out/<name>/initramfs.img), no disk.
//   tcg-check  checksums groups of AArch64 instructions (test/tcg-check), compared with the real CPU's values
//   probe      PowOS's initramfs + test/probe/probe-init: systemd's unit loading as an ordinary process, so a
//              crash is reported by the kernel (PC, registers, library + offset) instead of systemd's handler
Module.testBoots = {
  'tcg-check': 'console=ttyAMA0 rdinit=/init quiet',
  // root= only so the kernel unpacks into ramfs, not a tmpfs capped at RAM/2 (too small for PowOS's initramfs)
  probe: 'console=ttyAMA0 root=/dev/vda rdinit=/probe-init print-fatal-signals=1 norandmaps',
};
Module.testArgs = (name) => {
  const a = Module.powosArgs('');
  a.splice(a.indexOf('-initrd'), 2, '-initrd', `/pack-${name}/initramfs.img`);
  a.splice(a.indexOf('-append'), 2, '-append', Module.testBoots[name]);
  a.splice(a.indexOf('-drive'), 4); // no disk
  return a;
};
