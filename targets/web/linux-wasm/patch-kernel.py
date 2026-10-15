#!/usr/bin/env python3
"""PowOS patches over the Linux/Wasm kernel source (idempotent):
- drivers/block/wasm_blk.c (kernel/wasm_blk.c here): the disk streamed by the page, read-only;
- its Kconfig entry and Makefile line;
- the wasm32_nommu defconfig enables it and EROFS (the compact read-only filesystem on that disk).

    patch-kernel.py <kernel source dir>"""
import os, shutil, sys

k = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
shutil.copy(os.path.join(here, 'kernel', 'wasm_blk.c'), os.path.join(k, 'drivers/block/wasm_blk.c'))

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
for opt in ('CONFIG_BLK_DEV_WASM=y', 'CONFIG_EROFS_FS=y'):
    if opt not in s:
        s += opt + '\n'
open(p, 'w').write(s)
print('kernel: wasm_blk + EROFS')
