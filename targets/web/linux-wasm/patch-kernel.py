#!/usr/bin/env python3
"""PowOS patches over the Linux/Wasm kernel source (idempotent):
- drivers/block/wasm_blk.c (kernel/wasm_blk.c here): the disk streamed by the page, read-only;
- drivers/video/fbdev/wasmfb.c (kernel/wasmfb.c): /dev/fb0, drawn on a canvas by the page;
- drivers/input/misc/wasminput.c (kernel/wasminput.c): keyboard + pointer from the page's canvas;
- their Kconfig entries and Makefile lines;
- the wasm32_nommu defconfig enables them, EROFS (the filesystem on that disk) and the framebuffer console.

    patch-kernel.py <kernel source dir>"""
import os, shutil, sys

k = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
shutil.copy(os.path.join(here, 'kernel', 'wasm_blk.c'), os.path.join(k, 'drivers/block/wasm_blk.c'))
shutil.copy(os.path.join(here, 'kernel', 'wasmfb.c'), os.path.join(k, 'drivers/video/fbdev/wasmfb.c'))
shutil.copy(os.path.join(here, 'kernel', 'wasminput.c'), os.path.join(k, 'drivers/input/misc/wasminput.c'))

p = os.path.join(k, 'drivers/input/misc/Kconfig')
s = open(p).read()
if 'INPUT_WASM' not in s:
    entry = '''config INPUT_WASM
	bool "Wasm host keyboard and pointer (PowOS)"
	depends on WASM
	help
	  Keyboard and pointer events from the Wasm host (the web page's canvas).

'''
    i = s.rindex('endif')
    s = s[:i] + entry + s[i:]
    open(p, 'w').write(s)

p = os.path.join(k, 'drivers/input/misc/Makefile')
s = open(p).read()
if 'wasminput.o' not in s:
    s += '\nobj-$(CONFIG_INPUT_WASM)\t+= wasminput.o\n'
    open(p, 'w').write(s)

p = os.path.join(k, 'drivers/video/fbdev/Kconfig')
s = open(p).read()
if 'FB_WASM' not in s:
    entry = '''config FB_WASM
	bool "Wasm host framebuffer (PowOS)"
	depends on FB && WASM
	select FB_SYSMEM_HELPERS
	select FB_PROVIDE_GET_FB_UNMAPPED_AREA
	help
	  /dev/fb0 shown on a canvas by the Wasm host (the web page).

'''
    i = s.index('source "drivers/video/fbdev/omap/Kconfig"')
    s = s[:i] + entry + s[i:]
    open(p, 'w').write(s)

p = os.path.join(k, 'drivers/video/fbdev/Makefile')
s = open(p).read()
if 'wasmfb.o' not in s:
    s += '\nobj-$(CONFIG_FB_WASM)\t+= wasmfb.o\n'
    open(p, 'w').write(s)

p = os.path.join(k, 'drivers/block/Kconfig')
s = open(p).read()
if 'BLK_DEV_WASM' not in s:
    entry = '''config BLK_DEV_WASM
	bool "Wasm host block device (PowOS)"
	depends on WASM
	help
	  A read-only disk streamed by the Wasm host (the web page), on demand.

'''
    i = s.rindex('endif # BLK_DEV')
    s = s[:i] + entry + s[i:]
    open(p, 'w').write(s)

p = os.path.join(k, 'drivers/block/Makefile')
s = open(p).read()
if 'wasm_blk.o' not in s:
    s += '\nobj-$(CONFIG_BLK_DEV_WASM)\t+= wasm_blk.o\n'
    open(p, 'w').write(s)

p = os.path.join(k, 'arch/wasm/configs/wasm32_nommu_defconfig')
s = open(p).read()
# EROFS sits under the "Miscellaneous filesystems" menu, which the wasm defconfig turns off: without this the
# EROFS line is silently dropped (mount: "No such device").
s = s.replace('# CONFIG_MISC_FILESYSTEMS is not set\n', 'CONFIG_MISC_FILESYSTEMS=y\n')
s = s.replace('# CONFIG_FB is not set\n', 'CONFIG_FB=y\n')
s = s.replace('# CONFIG_INPUT_MISC is not set\n', 'CONFIG_INPUT_MISC=y\n')
s = s.replace('# CONFIG_INPUT_EVDEV is not set\n', 'CONFIG_INPUT_EVDEV=y\n')
# devtmpfs: the kernel makes /dev/fb0, /dev/wasmblk0, ttys and /dev/urandom itself (the initramfs ships few nodes).
for opt in ('CONFIG_BLK_DEV_WASM=y', 'CONFIG_EROFS_FS=y', 'CONFIG_FB=y', 'CONFIG_FB_WASM=y',
            'CONFIG_FRAMEBUFFER_CONSOLE=y', 'CONFIG_DEVTMPFS=y',
            'CONFIG_INPUT_MISC=y', 'CONFIG_INPUT_WASM=y', 'CONFIG_INPUT_EVDEV=y'):
    if opt not in s:
        s += opt + '\n'
open(p, 'w').write(s)
print('kernel: wasm_blk + EROFS, wasmfb + fbcon, wasminput + evdev')
