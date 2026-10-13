// Semaphores for programs under Andromarchy's runtime (no root, Android): SysV semaphores (semget/semop/semctl)
// emulated in shared files, and POSIX named semaphores (sem_open) kept in the rootfs. Developed here as a
// standalone LD_PRELOAD for testing (tools/lab/phone-sim.sh); shipped inside android-compat.c by
// patches/andromarchy/0004.
//
// Why: Android's app seccomp filter kills SysV IPC (android-compat answers ENOSYS instead), and glibc's sem_open
// opens /dev/shm internally (no /dev/shm on Android, and fakechroot cannot redirect glibc's internal open). Valve's
// Steam client asserts on both ("semaphore creation failed", "Function not implemented") and stalls before its UI.
//
// SysV sets live in files under /tmp/.sysv (inside the rootfs, through fakechroot): sem.<id> holds the set (a lock
// word, a change counter and the values) mapped shared by every process; key.<key> names the id of a keyed set.
// Waits are futex waits on the change counter (futex is allowed for apps). Not emulated: SEM_UNDO (ignored),
// permission checks, GETNCNT/GETZCNT (0).
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/futex.h>
#include <semaphore.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/mman.h>
#include <sys/sem.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define SYSV_DIR "/tmp/.sysv"
#define SHM_DIR "/tmp/.shm" // android-compat's place for shm_open segments
#define SEM_MAGIC 0x53454d31u
#define SEM_MAX 4096

struct semset {
    uint32_t magic;
    int32_t nsems;
    int32_t lock;    // 0 free, 1 locked, 2 locked with waiters
    uint32_t seq;    // bumped on every change: waiters sleep on it
    int32_t removed; // IPC_RMID: waiters return EIDRM
    int32_t key;
    int32_t mode;
    int32_t pad;
    struct { int32_t val, pid; } v[];
};

union semun {
    int val;
    struct semid_ds *buf;
    unsigned short *array;
};

static long futex(void *addr, int op, uint32_t val, const struct timespec *ts)
{
    return syscall(SYS_futex, addr, op, val, ts, NULL, 0);
}

static void lock(struct semset *s)
{
    int c = 0;
    if (__atomic_compare_exchange_n(&s->lock, &c, 1, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED))
        return;
    if (c != 2)
        c = __atomic_exchange_n(&s->lock, 2, __ATOMIC_ACQUIRE);
    while (c) {
        futex(&s->lock, FUTEX_WAIT, 2, NULL);
        c = __atomic_exchange_n(&s->lock, 2, __ATOMIC_ACQUIRE);
    }
}

static void unlock(struct semset *s)
{
    if (__atomic_exchange_n(&s->lock, 0, __ATOMIC_RELEASE) == 2)
        futex(&s->lock, FUTEX_WAKE, 1, NULL);
}

static void changed(struct semset *s)
{
    __atomic_add_fetch(&s->seq, 1, __ATOMIC_RELEASE);
    futex(&s->seq, FUTEX_WAKE, INT_MAX, NULL);
}

static size_t set_size(int nsems)
{
    return sizeof(struct semset) + (size_t)nsems * sizeof(((struct semset *)0)->v[0]);
}

static void set_path(char *buf, size_t n, int id)
{
    snprintf(buf, n, SYSV_DIR "/sem.%d", id);
}

// Per-process cache of mapped sets (id -> mapping).
static struct { int id; struct semset *s; } cache[64];

static struct semset *map_set(int id)
{
    for (size_t i = 0; i < sizeof cache / sizeof cache[0]; i++)
        if (cache[i].s && cache[i].id == id)
            return cache[i].s;
    char p[PATH_MAX];
    set_path(p, sizeof p, id);
    int fd = open(p, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        errno = EINVAL;
        return NULL;
    }
    struct stat st;
    struct semset *s = MAP_FAILED;
    if (fstat(fd, &st) == 0 && (size_t)st.st_size >= sizeof(struct semset))
        s = mmap(NULL, st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (s == MAP_FAILED || s->magic != SEM_MAGIC) {
        errno = EINVAL;
        return NULL;
    }
    for (size_t i = 0; i < sizeof cache / sizeof cache[0]; i++)
        if (!cache[i].s) {
            cache[i].id = id;
            cache[i].s = s;
            break;
        }
    return s;
}

static int new_set(key_t key, int nsems, int mode)
{
    mkdir(SYSV_DIR, 01777);
    char p[PATH_MAX], tmp[PATH_MAX];
    snprintf(tmp, sizeof tmp, SYSV_DIR "/.new.%d.%ld", getpid(), (long)random());
    int fd = open(tmp, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0666);
    if (fd < 0)
        return -1;
    struct semset s0 = {.magic = SEM_MAGIC, .nsems = nsems, .key = key, .mode = mode & 0777};
    if (ftruncate(fd, set_size(nsems)) < 0 || pwrite(fd, &s0, sizeof s0, 0) != sizeof s0) {
        close(fd);
        unlink(tmp);
        return -1;
    }
    close(fd);
    // A fresh id, published atomically by renaming the complete file in (no hard links on Android).
    for (int tries = 0; tries < 100; tries++) {
        int id = (int)(((unsigned)random() ^ ((unsigned)getpid() << 12)) & 0x3fffffff) + 1;
        set_path(p, sizeof p, id);
        if (syscall(SYS_renameat2, AT_FDCWD, tmp, AT_FDCWD, p, 1 /* RENAME_NOREPLACE */) == 0)
            return id;
        if (errno != EEXIST)
            break;
    }
    unlink(tmp);
    errno = ENOSPC;
    return -1;
}

int semget(key_t key, int nsems, int semflg)
{
    if (nsems < 0 || nsems > SEM_MAX) {
        errno = EINVAL;
        return -1;
    }
    if (key == IPC_PRIVATE)
        return new_set(key, nsems ? nsems : 1, semflg);
    mkdir(SYSV_DIR, 01777);
    char kp[PATH_MAX];
    snprintf(kp, sizeof kp, SYSV_DIR "/key.%x", (unsigned)key);
    for (int tries = 0; tries < 200; tries++) {
        int fd = open(kp, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            char b[32] = {0};
            ssize_t n = read(fd, b, sizeof b - 1);
            close(fd);
            if (n <= 0) { // being published by another process
                usleep(1000);
                continue;
            }
            if ((semflg & IPC_CREAT) && (semflg & IPC_EXCL)) {
                errno = EEXIST;
                return -1;
            }
            int id = atoi(b);
            struct semset *s = map_set(id);
            if (!s || s->removed) { // stale key file (set removed): take the name over
                unlink(kp);
                continue;
            }
            if (nsems > s->nsems) {
                errno = EINVAL;
                return -1;
            }
            return id;
        }
        if (!(semflg & IPC_CREAT)) {
            errno = ENOENT;
            return -1;
        }
        int id = new_set(key, nsems ? nsems : 1, semflg);
        if (id < 0)
            return -1;
        char tmp[PATH_MAX], b[32];
        snprintf(tmp, sizeof tmp, SYSV_DIR "/.key.%d", id);
        int n = snprintf(b, sizeof b, "%d\n", id);
        fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
        if (fd >= 0 && write(fd, b, n) == n && close(fd) == 0 &&
            syscall(SYS_renameat2, AT_FDCWD, tmp, AT_FDCWD, kp, 1 /* RENAME_NOREPLACE */) == 0)
            return id;
        // Lost the race to another creator: drop ours, use theirs.
        unlink(tmp);
        char p[PATH_MAX];
        set_path(p, sizeof p, id);
        unlink(p);
    }
    errno = ENOSPC;
    return -1;
}

int semtimedop(int semid, struct sembuf *sops, size_t nsops, const struct timespec *timeout)
{
    struct semset *s = map_set(semid);
    if (!s)
        return -1;
    struct timespec end;
    if (timeout) {
        clock_gettime(CLOCK_MONOTONIC, &end);
        end.tv_sec += timeout->tv_sec;
        end.tv_nsec += timeout->tv_nsec;
        if (end.tv_nsec >= 1000000000L) {
            end.tv_sec++;
            end.tv_nsec -= 1000000000L;
        }
    }
    for (;;) {
        lock(s);
        if (s->removed) {
            unlock(s);
            errno = EIDRM;
            return -1;
        }
        int ok = 1, nowait = 0;
        for (size_t i = 0; i < nsops; i++) {
            if (sops[i].sem_num >= (unsigned)s->nsems) {
                unlock(s);
                errno = EFBIG;
                return -1;
            }
            int v = s->v[sops[i].sem_num].val, op = sops[i].sem_op;
            if ((op < 0 && v + op < 0) || (op == 0 && v != 0)) {
                ok = 0;
                nowait |= sops[i].sem_flg & IPC_NOWAIT;
            }
        }
        if (ok) { // all or nothing, as the kernel does
            for (size_t i = 0; i < nsops; i++) {
                s->v[sops[i].sem_num].val += sops[i].sem_op;
                s->v[sops[i].sem_num].pid = getpid();
            }
            changed(s);
            unlock(s);
            return 0;
        }
        uint32_t seq = __atomic_load_n(&s->seq, __ATOMIC_ACQUIRE);
        unlock(s);
        if (nowait) {
            errno = EAGAIN;
            return -1;
        }
        struct timespec rel, *prel = NULL;
        if (timeout) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            rel.tv_sec = end.tv_sec - now.tv_sec;
            rel.tv_nsec = end.tv_nsec - now.tv_nsec;
            if (rel.tv_nsec < 0) {
                rel.tv_sec--;
                rel.tv_nsec += 1000000000L;
            }
            if (rel.tv_sec < 0) {
                errno = EAGAIN;
                return -1;
            }
            prel = &rel;
        }
        if (futex(&s->seq, FUTEX_WAIT, seq, prel) < 0 && errno == EINTR) {
            errno = EINTR;
            return -1;
        }
    }
}

int semop(int semid, struct sembuf *sops, size_t nsops)
{
    return semtimedop(semid, sops, nsops, NULL);
}

int semctl(int semid, int semnum, int cmd, ...)
{
    union semun arg = {0};
    va_list ap;
    va_start(ap, cmd);
    if (cmd == SETVAL || cmd == SETALL || cmd == GETALL || cmd == IPC_STAT || cmd == IPC_SET || cmd == SEM_STAT)
        arg = va_arg(ap, union semun);
    va_end(ap);
    struct semset *s = map_set(semid);
    if (!s)
        return -1;
    int r = 0;
    lock(s);
    switch (cmd) {
    case GETVAL:
        r = semnum < s->nsems ? s->v[semnum].val : (errno = EINVAL, -1);
        break;
    case GETPID:
        r = semnum < s->nsems ? s->v[semnum].pid : (errno = EINVAL, -1);
        break;
    case GETNCNT:
    case GETZCNT:
        r = 0;
        break;
    case SETVAL:
        if (semnum >= s->nsems || arg.val < 0) {
            errno = semnum >= s->nsems ? EINVAL : ERANGE;
            r = -1;
        } else {
            s->v[semnum].val = arg.val;
            changed(s);
        }
        break;
    case GETALL:
        for (int i = 0; i < s->nsems; i++)
            arg.array[i] = (unsigned short)s->v[i].val;
        break;
    case SETALL:
        for (int i = 0; i < s->nsems; i++)
            s->v[i].val = arg.array[i];
        changed(s);
        break;
    case IPC_STAT:
    case SEM_STAT:
        memset(arg.buf, 0, sizeof *arg.buf);
        arg.buf->sem_nsems = s->nsems;
        arg.buf->sem_perm.mode = s->mode;
        arg.buf->sem_perm.__key = s->key;
        arg.buf->sem_perm.uid = arg.buf->sem_perm.cuid = getuid();
        arg.buf->sem_perm.gid = arg.buf->sem_perm.cgid = getgid();
        break;
    case IPC_SET:
        s->mode = arg.buf->sem_perm.mode & 0777;
        break;
    case IPC_RMID: {
        s->removed = 1;
        changed(s);
        char p[PATH_MAX];
        set_path(p, sizeof p, semid);
        unlink(p);
        if (s->key != IPC_PRIVATE) {
            snprintf(p, sizeof p, SYSV_DIR "/key.%x", (unsigned)s->key);
            unlink(p);
        }
        break;
    }
    default:
        errno = EINVAL;
        r = -1;
    }
    unlock(s);
    return r;
}

// POSIX named semaphores: glibc keeps them as files in /dev/shm, opened internally; here in the rootfs's /tmp/.shm
// (where android-compat keeps shm_open segments), through fakechroot.
static int sem_file(const char *name, char *buf, size_t n)
{
    while (*name == '/')
        name++;
    if (!*name || strchr(name, '/')) {
        errno = EINVAL;
        return -1;
    }
    snprintf(buf, n, SHM_DIR "/sem.%s", name);
    return 0;
}

sem_t *sem_open(const char *name, int oflag, ...)
{
    char p[PATH_MAX];
    if (sem_file(name, p, sizeof p) < 0)
        return SEM_FAILED;
    mode_t mode = 0;
    unsigned value = 0;
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        mode = va_arg(ap, mode_t);
        value = va_arg(ap, unsigned);
        va_end(ap);
    }
    mkdir(SHM_DIR, 01777);
    for (int tries = 0; tries < 100; tries++) {
        if (!(oflag & O_EXCL)) {
            int fd = open(p, O_RDWR | O_CLOEXEC);
            if (fd >= 0) {
                sem_t *s = mmap(NULL, sizeof(sem_t), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
                close(fd);
                return s == MAP_FAILED ? SEM_FAILED : s;
            }
            if (errno != ENOENT || !(oflag & O_CREAT))
                return SEM_FAILED;
        }
        // Create complete, then publish without replacing (rename; no hard links on Android).
        char tmp[PATH_MAX];
        snprintf(tmp, sizeof tmp, SHM_DIR "/.sem.%d.%ld", getpid(), (long)random());
        int fd = open(tmp, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode ? mode : 0600);
        if (fd < 0)
            return SEM_FAILED;
        sem_t init;
        sem_init(&init, 1, value);
        if (write(fd, &init, sizeof init) != sizeof init) {
            close(fd);
            unlink(tmp);
            return SEM_FAILED;
        }
        if (syscall(SYS_renameat2, AT_FDCWD, tmp, AT_FDCWD, p, 1 /* RENAME_NOREPLACE */) == 0) {
            sem_t *s = mmap(NULL, sizeof(sem_t), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            close(fd);
            return s == MAP_FAILED ? SEM_FAILED : s;
        }
        int e = errno;
        close(fd);
        unlink(tmp);
        if (e != EEXIST || (oflag & O_EXCL)) {
            errno = e;
            return SEM_FAILED;
        }
    }
    errno = EAGAIN;
    return SEM_FAILED;
}

int sem_close(sem_t *s)
{
    return munmap(s, sizeof(sem_t));
}

int sem_unlink(const char *name)
{
    char p[PATH_MAX];
    if (sem_file(name, p, sizeof p) < 0)
        return -1;
    return unlink(p);
}

// get_robust_list(0, ...): the calling thread's glibc robust-mutex list head. The runtime's glibc never registers
// it (set_robust_list is neutralized: Android's app seccomp filter kills it), so the kernel answers NULL, and
// Valve's Steam client - which walks glibc's list itself for its cross-process mutexes - aborted with "pthreads futex
// robust_list is corrupt". Found without glibc's struct offsets: locking a robust mutex makes glibc link it into
// THREAD_SELF->robust_head, with the mutex's __prev pointing at the head. Answered here without a syscall (the
// filter may not allow get_robust_list either).
#include <pthread.h>
static void *robust_head_of_self(void)
{
    static __thread void *head;
    if (!head) {
        pthread_mutexattr_t a;
        pthread_mutex_t m;
        pthread_mutexattr_init(&a);
        pthread_mutexattr_setrobust(&a, PTHREAD_MUTEX_ROBUST);
        pthread_mutex_init(&m, &a);
        if (pthread_mutex_lock(&m) == 0) {
            head = m.__data.__list.__prev;
            pthread_mutex_unlock(&m);
        }
        pthread_mutex_destroy(&m);
        pthread_mutexattr_destroy(&a);
    }
    return head;
}

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
    if (nr == SYS_get_robust_list && (a[0] == 0 || a[0] == gettid())) {
        void *h = robust_head_of_self();
        if (h && a[1] && a[2]) {
            *(void **)a[1] = h;
            *(size_t *)a[2] = 3 * sizeof(void *); // struct robust_list_head
            return 0;
        }
    }
    return next(nr, a[0], a[1], a[2], a[3], a[4], a[5]);
}
