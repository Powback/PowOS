// Lab only: logs SysV IPC calls and raw syscall() numbers that come back ENOSYS (android-compat's answer for what
// Android's seccomp filter would kill), with the caller's object, to stderr. LD_PRELOAD in front of the runtime.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/types.h>

static void who(const char *what, void *ra)
{
    Dl_info i;
    const char *o = dladdr(ra, &i) && i.dli_fname ? i.dli_fname : "?";
    fprintf(stderr, "ipclog: %s from %s+%#lx\n", what, o, (unsigned long)((char *)ra - (char *)i.dli_fbase));
}
#define LOGF(ret, name, proto, args)                                                                                   \
    ret name proto                                                                                                     \
    {                                                                                                                  \
        static ret(*next) proto;                                                                                       \
        if (!next)                                                                                                     \
            next = dlsym(RTLD_NEXT, #name);                                                                            \
        who(#name, __builtin_return_address(0));                                                                     \
        return next args;                                                                                              \
    }
LOGF(int, semget, (key_t k, int n, int f), (k, n, f))
LOGF(int, shmget, (key_t k, size_t s, int f), (k, s, f))
LOGF(int, msgget, (key_t k, int f), (k, f))
long syscall(long nr, ...)
{
    static long (*next)(long, ...);
    if (!next)
        next = dlsym(RTLD_NEXT, "syscall");
    va_list ap;
    long a[6];
    va_start(ap, nr);
    for (int k = 0; k < 6; k++)
        a[k] = va_arg(ap, long);
    va_end(ap);
    long r = next(nr, a[0], a[1], a[2], a[3], a[4], a[5]);
    if (r == -1 && errno == ENOSYS) {
        char b[64];
        snprintf(b, sizeof b, "syscall(%ld) ENOSYS", nr);
        who(b, __builtin_return_address(0));
    }
    return r;
}
