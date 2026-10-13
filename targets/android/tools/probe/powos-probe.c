// powos-probe: what an unrooted Android app may do that Wine/Proton and Mesa's zero-copy path need.
// Each check runs in a forked child, so a seccomp kill (SIGSYS) is reported instead of ending the probe.
// Output: one line per check, "<name> ALLOWED ret=<r> errno=<e>" | "<name> KILLED sig=<n>" | "<name> DEV ..." .
// Built for the rootfs (glibc, aarch64) by tools/device-test.sh; also runs in the lab container as a baseline.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/dma-heap.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/ipc.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef __NR_futex_waitv
#define __NR_futex_waitv 449
#endif
#ifndef __NR_clone3
#define __NR_clone3 435
#endif
#ifndef __NR_close_range
#define __NR_close_range 436
#endif
#ifndef __NR_pidfd_open
#define __NR_pidfd_open 434
#endif
#ifndef __NR_epoll_pwait2
#define __NR_epoll_pwait2 441
#endif

static void check(const char *name, long (*fn)(void))
{
    fflush(stdout);
    pid_t p = fork();
    if (p == 0) {
        errno = 0;
        long r = fn();
        printf("%-22s ALLOWED ret=%ld errno=%d (%s)\n", name, r, errno, errno ? strerror(errno) : "ok");
        fflush(stdout);
        _exit(0);
    }
    int st = 0;
    waitpid(p, &st, 0);
    if (WIFSIGNALED(st))
        printf("%-22s KILLED sig=%d%s\n", name, WTERMSIG(st), WTERMSIG(st) == SIGSYS ? " (seccomp)" : "");
}

// futex_waitv with no futexes: EINVAL when the syscall exists and is allowed (Proton's fsync needs it).
static long t_futex_waitv(void) { return syscall(__NR_futex_waitv, NULL, 0, 0, NULL, 0); }
static long t_userfaultfd(void) { return syscall(__NR_userfaultfd, O_CLOEXEC | O_NONBLOCK); }
static long t_memfd(void) { return syscall(__NR_memfd_create, "probe", MFD_CLOEXEC); }
static long t_pidfd_open(void) { return syscall(__NR_pidfd_open, getpid(), 0); }
static long t_close_range(void) { return syscall(__NR_close_range, 1000, 1001, 0); }
static long t_clone3(void) { return syscall(__NR_clone3, NULL, 0); } // EINVAL if allowed
static long t_epoll_pwait2(void) { return syscall(__NR_epoll_pwait2, -1, NULL, 1, NULL, NULL, 0); }
static long t_unshare_user(void) { return unshare(CLONE_NEWUSER); }  // bwrap / pressure-vessel
static long t_sched_affinity(void)
{
    cpu_set_t s;
    return sched_getaffinity(0, sizeof s, &s);
}
static long t_sysv_shm(void)
{
    long id = syscall(__NR_shmget, IPC_PRIVATE, 4096, 0600);
    if (id >= 0)
        syscall(__NR_shmctl, id, IPC_RMID, NULL); // don't leave the segment behind
    return id;
}
static long t_ptrace_me(void) { return syscall(__NR_ptrace, 0 /* TRACEME */, 0, 0, 0); }
static long t_personality(void) { return syscall(__NR_personality, 0xffffffff); }
static long t_mlock(void)
{
    static char b[4096];
    return mlock(b, sizeof b);
}

static void dev(const char *path)
{
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0)
        fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        printf("%-22s DEV open failed: %s\n", path, strerror(errno));
        return;
    }
    if (strstr(path, "dma_heap")) {
        struct dma_heap_allocation_data a = {.len = 1 << 20, .fd_flags = O_RDWR | O_CLOEXEC};
        if (ioctl(fd, DMA_HEAP_IOCTL_ALLOC, &a) == 0) {
            void *m = mmap(NULL, a.len, PROT_READ | PROT_WRITE, MAP_SHARED, a.fd, 0);
            printf("%-22s DEV open ok, 1 MiB dma-buf alloc ok (fd %u), mmap %s\n", path, a.fd,
                   m == MAP_FAILED ? strerror(errno) : "ok");
        } else {
            printf("%-22s DEV open ok, alloc failed: %s\n", path, strerror(errno));
        }
    } else {
        printf("%-22s DEV open ok\n", path);
    }
    close(fd);
}

int main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    check("futex_waitv", t_futex_waitv);
    check("userfaultfd", t_userfaultfd);
    check("memfd_create", t_memfd);
    check("pidfd_open", t_pidfd_open);
    check("close_range", t_close_range);
    check("clone3", t_clone3);
    check("epoll_pwait2", t_epoll_pwait2);
    check("unshare(NEWUSER)", t_unshare_user);
    check("sched_getaffinity", t_sched_affinity);
    check("shmget(SysV)", t_sysv_shm);
    check("ptrace(TRACEME)", t_ptrace_me);
    check("personality", t_personality);
    check("mlock", t_mlock);
    // Zero-copy Vulkan presentation: Turnip on KGSL exports swapchain images as dma-bufs only when it can open
    // one of these (tu_knl_kgsl.cc); KWin then imports them as EGLImages instead of a CPU copy.
    dev("/dev/dma_heap/system");
    dev("/dev/dma_heap/system-uncached");
    dev("/dev/ion");
    dev("/dev/kgsl-3d0");
    dev("/dev/udmabuf");
    dev("/dev/ntsync");
    dev("/dev/dri/renderD128");
    return 0;
}
