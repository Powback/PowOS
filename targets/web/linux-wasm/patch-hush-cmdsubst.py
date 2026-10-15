#!/usr/bin/env python3
"""Linux/Wasm BusyBox hush: command substitution $(...) through clone() instead of vfork().

Wasm can't return twice from one stack frame, so vfork() doesn't exist there; the upstream port already moved hush's
pipeline children to clone(fn, CLONE_VM | CLONE_VFORK). generate_stream_from_string() (command substitution) still
called xvfork(): its child body becomes a function, started with clone() on NOMMU (fork() on MMU, as before).
Run on shell/hush.c (after the upstream wasm patch); idempotent."""
import sys

p = sys.argv[1]
s = open(p).read()
if 'generate_stream_child' in s:
    sys.exit(0)

start = s.index('static int generate_stream_from_string(const char *s, pid_t *pid_p)\n{')
body_start = s.index('\tif (pid == 0) { /* child */\n', start)
body_end = s.index('\t/* parent */\n\t*pid_p = pid;', body_start)
child = s[body_start + len('\tif (pid == 0) { /* child */\n'):body_end]
# The child block ends with "\t}\n\n" (closing the if): drop it, the function closes instead.
child = child.rstrip()
assert child.endswith('}'), child[-80:]
child = child[:-1].rstrip() + '\n'

fn = '''#if !BB_MMU
/* Linux/Wasm: the command substitution child, started with clone() (no vfork() in Wasm). It re-executes the shell. */
static int generate_stream_child(void *arg)
{
	const char *s = ((void **)arg)[0];
	int *channel = ((void **)arg)[1];
	char ***to_free_p = ((void **)arg)[2];
# define to_free (*to_free_p)
''' + child.replace('\t\t', '\t') + '''# undef to_free
	_exit(127); /* re_execute_shell does not return */
}
#endif

'''
head = s[:start]
func = s[start:body_start]
func = func.replace('\tpid = BB_MMU ? xfork() : xvfork();\n', '''#if BB_MMU
	pid = xfork();
#else
	{
		void *arg[] = { (void *)s, channel, &to_free };
		pid = clone(generate_stream_child, NULL, CLONE_VM | CLONE_VFORK | SIGCHLD, arg);
		if (pid < 0)
			bb_simple_perror_msg_and_die("clone");
	}
#endif
''')
mmu_child = '''#if BB_MMU
	if (pid == 0) { /* child */
''' + child.replace('# if BB_MMU\n', '# if 1\n', 1) + '''	}
#endif

'''
s = head + fn + func + mmu_child + s[body_end:]
open(p, 'w').write(s)
print('hush: command substitution via clone()')
