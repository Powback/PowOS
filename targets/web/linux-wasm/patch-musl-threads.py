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

p = os.path.join(sys.argv[1], 'src/thread/pthread_create.c')
s = open(p).read()
if 'PowOS: Wasm TLS' in s:
    print('musl: threads already patched')
    sys.exit(0)

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
open(p, 'w').write(s)
print('musl: threads get a real Wasm TLS block')
