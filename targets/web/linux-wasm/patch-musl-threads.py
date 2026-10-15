#!/usr/bin/env python3
"""PowOS patch over Linux/Wasm's musl (idempotent): working POSIX threads.

Upstream pthread_create() passes musl's thread pointer (the new struct pthread) as clone()'s TLS argument, and the
runtime (linux-worker.js) installs that as the new instance's __tls_base - the base of LLVM's Wasm TLS block, which is
something else entirely. So a new thread had no TLS block: every _Thread_local read whatever happened to be there,
including musl's own __musl_tp, so pthread_self() returned 0 in the thread. On exit the thread then found itself
"alone" (NULL->next == NULL) and called exit(0) - the whole process ended with status 0 the moment its first thread
returned (std::thread, Qt's threads, ...).

Fix: carve a real Wasm TLS block off the top of the new thread's stack, initialize it from this module's TLS image
(__wasm_init_tls, which also sets the caller's __tls_base - so put ours back right after), store the new thread
pointer in its __musl_tp, and hand that block to clone() as the TLS.

And the Wasm port's __clone() wrapper (src/linux/clone.c, which unpacks the varargs for the assembly _Clone) took
the tls and ctid arguments only with CLONE_CHILD_SETTID - pthreads pass CLONE_SETTLS | CLONE_CHILD_CLEARTID, so the
kernel got tls 0 (the block above never arrived) and no ctid (the futex pthread_join waits on was never cleared).
The varargs are positional (ptid, tls, ctid): take each one when any flag at or after it says it is there.

    patch-musl-threads.py <musl source dir>"""
import os, sys

p = os.path.join(sys.argv[1], 'src/linux/clone.c')
s = open(p).read()
old = '''	if (flags & (CLONE_PIDFD | CLONE_PARENT_SETTID | CLONE_CHILD_SETTID))
		ptid = va_arg(ap, pid_t *);
	if (flags & CLONE_CHILD_SETTID) {
'''
new = '''	/* PowOS: positional (ptid, tls, ctid) - pthreads pass CLONE_SETTLS | CLONE_CHILD_CLEARTID. */
	if (flags & (CLONE_PIDFD | CLONE_PARENT_SETTID | CLONE_SETTLS | CLONE_CHILD_SETTID | CLONE_CHILD_CLEARTID))
		ptid = va_arg(ap, pid_t *);
	if (flags & (CLONE_SETTLS | CLONE_CHILD_SETTID | CLONE_CHILD_CLEARTID)) {
'''
if 'PowOS: positional' not in s:
    assert old in s, 'clone.c changed upstream: re-check the __clone varargs patch'
    open(p, 'w').write(s.replace(old, new, 1))
    print('musl: __clone passes tls and ctid')

# Static constructors: Wasm has no .init_array - wasm-ld puts them in __wasm_call_ctors, which upstream's runtime
# called before _start, i.e. before musl initialized itself (page size from auxv, malloc). A C++ program whose static
# constructors allocate (every Qt program: plugin registration) got NULL from malloc and died in qBadAlloc. Run them
# where .init_array would run, and export a marker telling the runtime (linux-worker.js) not to call them early.
p = os.path.join(sys.argv[1], 'src/env/__libc_start_main.c')
s = open(p).read()
old = 'static void libc_start_init(void)\n{\n\t_init();\n'
if 'PowOS: Wasm ctors' not in s:
    assert old in s, '__libc_start_main.c changed upstream: re-check the Wasm constructors patch'
    s = s.replace(old, '''#ifdef __wasm__
/* PowOS: Wasm ctors - run by libc (below), not by the runtime before libc is up (see patch-musl-threads.py). */
void __wasm_call_ctors(void);
int __powos_libc_runs_ctors = 1;
#endif
static void libc_start_init(void)
{
\t_init();
#ifdef __wasm__
\t__wasm_call_ctors();
#endif
''', 1)
    open(p, 'w').write(s)
    print('musl: static constructors run after libc init')

# Thread stacks: musl's default is 128 KiB (glibc: 8 MiB). Qt runs real work on threads (the QML type loader), and
# Wasm has no guard pages - an overflow silently corrupts whatever lies below the stack (seen as "unaligned access"
# traps on garbage pointers in the loader thread). 2 MiB default; programs can still ask for more or less.
p = os.path.join(sys.argv[1], 'src/internal/pthread_impl.h')
s = open(p).read()
old = '#define DEFAULT_STACK_SIZE 131072\n'
if 'PowOS: thread stacks' not in s:
    assert old in s, 'pthread_impl.h changed upstream: re-check DEFAULT_STACK_SIZE'
    s = s.replace(old, '#define DEFAULT_STACK_SIZE (2 << 20) /* PowOS: thread stacks (patch-musl-threads.py), was 128 KiB */\n', 1)
    open(p, 'w').write(s)
    print('musl: 2 MiB default thread stacks')

p = os.path.join(sys.argv[1], 'src/thread/pthread_create.c')
s = open(p).read()
# Each part checks its own marker, so a tree patched by an older version of this script gets the newer parts.
if 'PowOS: Wasm TLS' not in s:
    anchor = '\tnew->sysinfo = self->sysinfo;\n'
    clone = 'ret = __clone((c11 ? start_c11 : start), stack, flags, args, &new->tid, TP_ADJ(new), &__thread_list_lock);'
    assert anchor in s and clone in s, 'pthread_create.c changed upstream: re-check the Wasm TLS patch'
    s = s.replace(anchor, anchor + '''
#ifdef __wasm__
	/* PowOS: Wasm TLS block for the new thread (see patch-musl-threads.py), off the top of its stack. */
	void *wasm_tls;
	{
		unsigned char *mine = __builtin_wasm_tls_base();
		unsigned char *blk = (unsigned char *)(((uintptr_t)stack - __builtin_wasm_tls_size())
			& -(uintptr_t)__builtin_wasm_tls_align());
		__wasm_init_tls(blk);
		__set_tls_base(mine);
		*(uintptr_t *)(blk + ((unsigned char *)&__musl_tp - mine)) = (uintptr_t)TP_ADJ(new);
		wasm_tls = blk;
		stack = blk;
	}
#else
	void *wasm_tls = TP_ADJ(new);
#endif
''', 1)
    s = s.replace(clone, clone.replace('TP_ADJ(new)', 'wasm_tls'), 1)
    decl = '#include "pthread_impl.h"\n'
    assert decl in s
    s = s.replace(decl, decl + '''#ifdef __wasm__
/* PowOS: linker-synthesized (__wasm_init_tls) and arch/wasm clone.S (__set_tls_base). */
void __wasm_init_tls(void *);
void __set_tls_base(void *);
#endif
''', 1)
    print('musl: threads get a real Wasm TLS block')

# Stack alignment: the Wasm C ABI keeps __stack_pointer 16-byte aligned and clang relies on it (it forms addresses
# like (sp + 320) | 12). musl only aligns a new thread's stack to the pointer size - every other arch's __clone
# assembly aligns to 16, the Wasm _Clone does not - so on a misaligned thread stack those ORs produced addresses 4
# bytes off: Qt's QML loader thread read a QString from the wrong place ("unaligned access" on its refcount).
if 'PowOS: 16-byte aligned' not in s:
    old_args = '\tstack -= sizeof(struct start_args);\n'
    assert old_args in s, 'pthread_create.c changed upstream: re-check the stack alignment patch'
    s = s.replace(old_args, old_args + '''#ifdef __wasm__
\t/* PowOS: 16-byte aligned stack top for the new thread (the Wasm ABI's; see patch-musl-threads.py). */
\tstack = (void *)((uintptr_t)stack & -(uintptr_t)16);
#endif
''', 1)
    print('musl: thread stacks 16-byte aligned')

open(p, 'w').write(s)
