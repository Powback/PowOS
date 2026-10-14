// QEMU's command line for PowOS's Arch Linux ARM build (targets/web/build-rootfs.sh, the phone's installer in VM
// mode) on QEMU's "virt" board. The machine itself is machine.json - the one definition the browser and the
// snapshot builder (build-snapshot.sh, native QEMU) share: a snapshot only restores on the identical machine.
//
// Its kernel + initramfs are preloaded (small: Image.gz + a virtio/ext4-only initramfs); its root filesystem is the
// chunked disk, streamed block by block as the guest reads it (qemu/block/chunked.c). The page passes the disk's
// absolute URL (QEMU's worker fetches it).
//
// machine.json notes:
//   memory  wasm32 caps QEMU's whole heap at 2300M (TOTAL_MEMORY): guest RAM + the TCG translation cache + the
//           preloaded files must fit (1536M RAM + a 500M cache ran out: Aborted(OOM)).
//   cpu     neoverse-n1 (ARMv8.2, no SVE): cheaper to emulate than "max" (the kernel boots ~2x faster); v8.2
//           because our FEX build targets it. (systemd's crash under qemu-wasm was not the CPU model: it was the
//           Wasm backend's 32-bit carry, patches/qemu/0005.)
//   append  systemd.default_device_timeout_sec: emulated udev is slow; the 90 s default could time out a boot.
globalThis.Module = globalThis.Module || {};
Module.preRun = Module.preRun || [];

Module.powosArgs = (m, diskUrl, { resume = false, snapshot = '' } = {}) => [
  // The screen is QEMU's graphical console on the page's canvas (-display web: qemu/ui/web.c, web/display.js); the
  // serial console stays on the terminal below it.
  '-display', 'web', '-serial', 'stdio', '-monitor', 'none',
  '-M', m.machine, '-cpu', m.cpu, '-m', m.memory, '-accel', 'tcg,tb-size=256',
  ...(m.devices || []).flatMap((d) => ['-device', d]),
  '-nic', 'none',
  '-kernel', `/pack-kernel/${m.kernel}`,
  '-initrd', `/pack-initramfs/${m.initrd}`,
  '-append', m.append,
  // -drive, not -blockdev: -blockdev checks driver names against QEMU's QAPI schema, which only knows upstream
  // drivers; -drive finds "chunked" in the block layer's registry. A resumed snapshot also sees the blocks its
  // machine had written: the overlay build-snapshot.sh saved next to that snapshot's state (snapshots/<id>/, the id
  // from snapshot.json), so a newer build never mixes its disk with an older published state.
  '-drive', `if=none,id=disk0,format=raw,file.driver=chunked,file.url=${diskUrl}` +
    (resume ? `,file.overlay=snapshots/${snapshot}/overlay.bin` : ''),
  '-device', 'virtio-blk-pci,drive=disk0',
  // Resume: the machine state native QEMU saved at the login prompt, instead of booting.
  ...(resume ? ['-incoming', 'file:/pack-state/vm.state'] : []),
];

// ?boot=<name>: the same kernel and machine, a test initramfs instead of PowOS's (packed by assemble.sh from
// out/<name>/initramfs.img), no disk.
//   tcg-check  checksums groups of AArch64 instructions (test/tcg-check), compared with the real CPU's values
//   probe      PowOS's initramfs + test/probe/probe-init: systemd's unit loading as an ordinary process, so a
//              crash is reported by the kernel (PC, registers, library + offset) instead of systemd's handler
Module.testBoots = {
  'tcg-check': 'console=ttyAMA0 rdinit=/init quiet',
  // root= only so the kernel unpacks into ramfs, not a tmpfs capped at RAM/2 (too small for big initramfses)
  probe: 'console=ttyAMA0 root=/dev/vda rdinit=/probe-init print-fatal-signals=1 norandmaps',
};
Module.testArgs = (m, name) => {
  const a = Module.powosArgs({ ...m, append: Module.testBoots[name] }, '');
  a.splice(a.indexOf('-initrd'), 2, '-initrd', `/pack-${name}/initramfs.img`);
  a.splice(a.indexOf('-drive'), 4); // no disk
  return a;
};
