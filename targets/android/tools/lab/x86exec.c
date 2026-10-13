// Lab only (not shipped): the x86 part of Andromarchy's execve hook (patches/andromarchy/0002) as a standalone
// LD_PRELOAD, for testing in a plain aarch64 container. An exec of an x86/x86-64 ELF becomes
// "box64 <program> <args>" (what binfmt_misc would do on a PC; Android apps cannot register binfmt).
// On the Colima build VM, Rosetta IS registered with binfmt (flag F): without this hook, x86 programs would
// silently run under Rosetta, not box64. lab.sh checks /proc/*/maps for Rosetta after each run.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <spawn.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

static int x86_program(const char *path)
{
    unsigned char h[20];
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    ssize_t r = read(fd, h, sizeof h);
    close(fd);
    if (r < (ssize_t)sizeof h || memcmp(h, "\x7f" "ELF", 4))
        return 0;
    unsigned m = h[18] | (h[19] << 8);
    return m == 3 || m == 62;
}

static const char *emu(void)
{
    return getenv("LAB_X86_EMU") ? getenv("LAB_X86_EMU") : "/usr/bin/box64";
}

// argv for "box64 <program> <argv[1..]>" in a (caller-sized) buffer of argc + 3 entries.
static void x86_argv(char **a, const char *path, char *const argv[])
{
    size_t k = 0, i = 1;
    a[k++] = (char *)emu();
    a[k++] = (char *)path;
    for (; argv && argv[0] && argv[i]; i++)
        a[k++] = argv[i];
    a[k] = NULL;
}

static size_t count(char *const argv[])
{
    size_t n = 0;
    while (argv && argv[n])
        n++;
    return n;
}

int execve(const char *path, char *const argv[], char *const envp[])
{
    static int (*next)(const char *, char *const[], char *const[]);
    if (!next)
        next = dlsym(RTLD_NEXT, "execve");
    if (path && x86_program(path)) {
        char *a[count(argv) + 3];
        x86_argv(a, path, argv);
        return next(emu(), a, envp);
    }
    return next(path, argv, envp);
}
int execv(const char *path, char *const argv[]) { extern char **environ; return execve(path, argv, environ); }

// Python 3.14's subprocess uses posix_spawn: glibc's own clone + execve, past the hook above (Andromarchy's
// android-compat.c reimplements posix_spawn over fork + its execve for the same reason).
int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa, const posix_spawnattr_t *at,
                char *const argv[], char *const envp[])
{
    static int (*next)(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *,
                       char *const[], char *const[]);
    if (!next)
        next = dlsym(RTLD_NEXT, "posix_spawn");
    if (path && x86_program(path)) {
        char *a[count(argv) + 3];
        x86_argv(a, path, argv);
        return next(pid, emu(), fa, at, a, envp);
    }
    return next(pid, path, fa, at, argv, envp);
}
