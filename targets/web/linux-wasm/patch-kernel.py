#!/usr/bin/env python3
"""PowOS patches over the Linux/Wasm kernel source (idempotent):
- drivers/block/wasm_blk.c (kernel/wasm_blk.c here): the disk streamed by the page, read-only;
- drivers/video/fbdev/wasmfb.c (kernel/wasmfb.c): /dev/fb0, drawn on a canvas by the page;
- drivers/input/misc/wasminput.c (kernel/wasminput.c): keyboard + pointer from the page's canvas;
- their Kconfig entries and Makefile lines;
- the wasm32_nommu defconfig enables them, EROFS (the filesystem on that disk) and the framebuffer console;
- arch/wasm/kernel/process.c: two processes starting at once could get the same CPU (see below).

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
for opt in ('NET', 'SYSVIPC', 'INOTIFY_USER', 'MEMFD_CREATE'):
    s = s.replace('# CONFIG_%s is not set\n' % opt, '')
# devtmpfs: the kernel makes /dev/fb0, /dev/wasmblk0, ttys and /dev/urandom itself (the initramfs ships few nodes).
for opt in ('CONFIG_BLK_DEV_WASM=y', 'CONFIG_EROFS_FS=y', 'CONFIG_FB=y', 'CONFIG_FB_WASM=y',
            'CONFIG_FRAMEBUFFER_CONSOLE=y', 'CONFIG_DEVTMPFS=y',
            'CONFIG_INPUT_MISC=y', 'CONFIG_INPUT_WASM=y', 'CONFIG_INPUT_EVDEV=y',
            # What a desktop needs from the kernel: Unix sockets (D-Bus, Wayland, Qt's socketpair), inotify (file
            # watching in Qt/KDE), memfd (Wayland shared-memory buffers), SysV IPC.
            'CONFIG_NET=y', 'CONFIG_UNIX=y', 'CONFIG_INOTIFY_USER=y', 'CONFIG_TMPFS=y', 'CONFIG_MEMFD_CREATE=y',
            'CONFIG_SYSVIPC=y'):
    if opt not in s:
        s += opt + '\n'
open(p, 'w').write(s)
# Every user task gets a CPU (a Web Worker) of its own. user_task_set_affinity() picked the first free one but marked
# it taken only after cpu_device_up() - which waits for the page to start a new Worker - so two processes starting
# together could both pick it (two tasks on one Worker). Found while chasing a boot hang - that one turned out to be
# the canvas shell's startup (now run by init, see initramfs/init) - but the race is real: claim the CPU atomically
# before bringing it up; release it if that fails.
p = os.path.join(k, 'arch/wasm/kernel/process.c')
s = open(p).read()
old_pick = '''	if (!cpu_online(cpu)) {
		BUG_ON(!cpu_possible(cpu));
'''
new_pick = '''	/* PowOS: claim it before the (sleeping) bring-up, or a concurrent caller picks the same CPU. */
	if (cpumask_test_and_set_cpu(cpu, &user_cpus))
		goto hack;

	if (!cpu_online(cpu)) {
		BUG_ON(!cpu_possible(cpu));
'''
old_up = '''		retval = cpu_device_up(get_cpu_device(cpu));
		if (retval)
			return retval;
'''
new_up = '''		retval = cpu_device_up(get_cpu_device(cpu));
		if (retval) {
			cpumask_clear_cpu(cpu, &user_cpus);
			return retval;
		}
'''
if 'PowOS: claim it' not in s:
    assert old_pick in s and old_up in s, 'process.c changed upstream: re-check user_task_set_affinity'
    s = s.replace(old_pick, new_pick, 1).replace(old_up, new_up, 1)
    open(p, 'w').write(s)

# NOMMU loads a program by reading the whole .wasm into ONE physically contiguous allocation (fs/binfmt_wasm.c
# vm_mmap), and the arch never set ARCH_FORCE_MAX_ORDER, so the generic MAX_PAGE_ORDER 10 (4 MiB) capped program
# size: a 27 MiB Qt program failed with "nommu: Allocation of length 27672576 ... failed". 15 = 128 MiB blocks.
p = os.path.join(k, 'arch/wasm/Kconfig')
s = open(p).read()
if 'ARCH_FORCE_MAX_ORDER' not in s:
    s += '''
# PowOS: programs (and their data) are single contiguous allocations on NOMMU - allow up to 128 MiB.
config ARCH_FORCE_MAX_ORDER
	int
	default 15
'''
    open(p, 'w').write(s)

# A program's main stack is a fixed allocation on NOMMU, and upstream made it 2 pages (8 KiB): enough for BusyBox,
# not for Qt - PCRE2's compiler ran off its end into the heap ("memory access out of bounds" in malloc).
p = os.path.join(k, 'fs/binfmt_wasm.c')
s = open(p).read()
old = '#define WASM_STACK_SIZE\t\t(2UL * PAGE_SIZE)'
if old in s:
    s = s.replace(old, '#define WASM_STACK_SIZE\t\t(1UL << 20) /* PowOS: 1 MiB (was 2 pages) - Qt needs real stacks */')
    open(p, 'w').write(s)
else:
    assert 'PowOS: 1 MiB' in s, 'binfmt_wasm.c changed upstream: re-check WASM_STACK_SIZE'

print('kernel: wasm_blk + EROFS, wasmfb + fbcon, wasminput + evdev')
