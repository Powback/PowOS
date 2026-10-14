// QEMU's command line: PowOS's Arch Linux ARM build (targets/web/build-rootfs.sh, the phone's installer in VM
// mode) on QEMU's "virt" board. Its kernel + initramfs are preloaded (boot needs them whole); its root
// filesystem is the chunked disk, streamed block by block as the guest reads it (qemu/block/chunked.c). The
// page passes the disk's absolute URL (QEMU's worker fetches it).
//
// 1536M: wasm32 caps QEMU's whole heap at 2300M (TOTAL_MEMORY), guest RAM included.
globalThis.Module = globalThis.Module || {};
Module.preRun = Module.preRun || [];
Module.powosArgs = (diskUrl) => [
  '-nographic', '-M', 'virt', '-cpu', 'max', '-m', '1536M', '-accel', 'tcg,tb-size=500',
  '-nic', 'none',
  '-kernel', '/pack-kernel/Image',
  '-initrd', '/pack-initramfs/initramfs.img',
  '-append', 'console=ttyAMA0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target',
  '-blockdev', `driver=chunked,node-name=disk0,url=${diskUrl}`,
  '-device', 'virtio-blk-pci,drive=disk0',
];
