// loopback-unix: PowOS's private loopback services on a phone WITHOUT root (docs/research/nonroot-parity.md, "Who can
// reach SpacetimeDB and the App API"). Android's loopback is shared by every app: a TCP port PowOS listens on is open
// to any installed app, and without root nothing (the rooted path's iptables owner match) can lock it to PowOS's uid.
// So, in every program of the no-root PowOS image (lotfix-run preloads this when POWOS_LOOPBACK_DIR is set):
//   - bind() of a TCP socket to one of POWOS_LOOPBACK_PORTS (any address) binds a Unix socket
//     $POWOS_LOOPBACK_DIR/<port>.sock instead (mode 0600, in the app's private files: only PowOS's uid can open it),
//   - connect() of a TCP socket to 127.0.0.0/8 or ::1 on one of those ports connects to that Unix socket,
//   - accept() on such a listener refuses a peer of another uid (SO_PEERCRED; defence in depth),
//   - getsockname/getpeername/accept's address answer 127.0.0.1:<port> and TCP-only setsockopt()s succeed, so the
//     programs (SpacetimeDB's tokio/hyper, Python's http.server and urllib, curl, the spacetime CLI) don't notice.
// No TCP port is listened on at all. The launcher's own clients (the WebView, ShellNet) reach the sockets through
// dev.omalauncher.linux.LoopbackGate, which requires a per-install token.
//
// Built freestanding (no libc of its own: it is loaded into glibc programs although the NDK builds it): the
// redirected calls are raw syscalls; everything else goes to the next definition (android-compat, fakechroot,
// glibc) through dlsym(RTLD_NEXT), so their own rewrites (fakechroot's Unix socket paths) still apply.
#include <stddef.h>
#include <stdint.h>

#define AF_UNIX 1
#define AF_INET 2
#define AF_INET6 10
#define SOCK_STREAM 1
#define SOCK_TYPE_MASK 0xf
#define SOCK_NONBLOCK 04000
#define SOCK_CLOEXEC 02000000
#define O_NONBLOCK 04000
#define FD_CLOEXEC 1
#define F_GETFD 1
#define F_GETFL 3
#define SOL_SOCKET 1
#define SO_TYPE 3
#define SO_PEERCRED 17
#define IPPROTO_TCP 6
#define AT_FDCWD (-100)
#define ENOENT 2
#define EINVAL 22
#define ECONNREFUSED 111
#define ECONNABORTED 103
#define ENOPROTOOPT 92
#define EOPNOTSUPP 95
#define MAXFD 65536

typedef uint32_t socklen_t;
struct sockaddr {
    uint16_t sa_family;
    char sa_data[14];
};
struct sockaddr_in {
    uint16_t sin_family;
    uint16_t sin_port; // network order
    uint32_t sin_addr; // network order
    uint8_t zero[8];
};
struct sockaddr_in6 {
    uint16_t sin6_family;
    uint16_t sin6_port;
    uint32_t sin6_flowinfo;
    uint8_t sin6_addr[16];
    uint32_t sin6_scope_id;
};
struct sockaddr_un {
    uint16_t sun_family;
    char sun_path[108];
};
struct ucred {
    int32_t pid;
    uint32_t uid;
    uint32_t gid;
};

// glibc's, resolved when this is loaded into a glibc program.
extern int *__errno_location(void);
extern char *getenv(const char *);
extern void *dlsym(void *, const char *);
#define RTLD_NEXT ((void *)-1l)

// aarch64 Linux syscall numbers
enum { NR_dup3 = 24, NR_fcntl = 25, NR_unlinkat = 35, NR_fchmodat = 53, NR_close = 57, NR_getuid = 174,
       NR_socket = 198, NR_bind = 200, NR_accept4 = 242, NR_connect = 203, NR_getsockname = 204,
       NR_getpeername = 205, NR_getsockopt = 209 };

static long sys6(long n, long a, long b, long c, long d, long e, long f)
{
    register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b, x2 __asm__("x2") = c,
                  x3 __asm__("x3") = d, x4 __asm__("x4") = e, x5 __asm__("x5") = f;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
    return x0;
}
#define sys(n, a, b, c) sys6(n, (long)(a), (long)(b), (long)(c), 0, 0, 0)

// A raw syscall's result as libc returns it: -1 with errno set.
static int ret(long r)
{
    if (r < 0 && r > -4096) {
        *__errno_location() = (int)-r;
        return -1;
    }
    return (int)r;
}

// Configuration, read once (idempotent: a race only reads it twice).
static int ready;
static char dir[96];
static uint16_t ports[8];
static int nports;
// The port each redirected fd stands for (0: not redirected).
static uint16_t redirected[MAXFD];

static void init(void)
{
    if (ready)
        return;
    const char *d = getenv("POWOS_LOOPBACK_DIR"), *p = getenv("POWOS_LOOPBACK_PORTS");
    if (d && p) {
        size_t i = 0;
        for (; d[i] && i < sizeof dir - 16; i++)
            dir[i] = d[i];
        dir[i] = 0;
        unsigned v = 0;
        for (;; p++) {
            if (*p >= '0' && *p <= '9')
                v = v * 10 + (unsigned)(*p - '0');
            else {
                if (v && v < 65536 && nports < 8)
                    ports[nports++] = (uint16_t)v;
                v = 0;
                if (!*p)
                    break;
            }
        }
        if (d[i]) // too long for a socket path: redirect nothing
            nports = 0;
    }
    ready = 1;
}

static uint16_t ntoh16(uint16_t v) { return (uint16_t)((v >> 8) | (v << 8)); }

// The protected port [addr] names (any address when !loopback_only, else 127/8 or ::1 only), else 0.
static uint16_t protected_port(const struct sockaddr *addr, socklen_t len, int loopback_only)
{
    init();
    if (!nports || !addr)
        return 0;
    uint16_t port;
    int loop;
    if (addr->sa_family == AF_INET && len >= sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *a = (const void *)addr;
        port = ntoh16(a->sin_port);
        loop = (((const uint8_t *)&a->sin_addr)[0]) == 127;
    } else if (addr->sa_family == AF_INET6 && len >= sizeof(struct sockaddr_in6)) {
        const struct sockaddr_in6 *a = (const void *)addr;
        port = ntoh16(a->sin6_port);
        int zero10 = 1;
        for (int i = 0; i < 10; i++)
            zero10 &= a->sin6_addr[i] == 0;
        int one = zero10 && a->sin6_addr[10] == 0 && a->sin6_addr[11] == 0 && a->sin6_addr[12] == 0 &&
                  a->sin6_addr[13] == 0 && a->sin6_addr[14] == 0 && a->sin6_addr[15] == 1;
        int mapped = zero10 && a->sin6_addr[10] == 0xff && a->sin6_addr[11] == 0xff && a->sin6_addr[12] == 127;
        loop = one || mapped;
    } else
        return 0;
    if (loopback_only && !loop)
        return 0;
    for (int i = 0; i < nports; i++)
        if (ports[i] == port)
            return port;
    return 0;
}

static void socket_path(struct sockaddr_un *u, uint16_t port)
{
    char *s = u->sun_path;
    size_t i = 0;
    for (; dir[i]; i++)
        s[i] = dir[i];
    s[i++] = '/';
    char digits[6];
    int n = 0;
    do
        digits[n++] = (char)('0' + port % 10);
    while ((port /= 10));
    while (n)
        s[i++] = digits[--n];
    const char *ext = ".sock";
    for (int k = 0; ext[k]; k++)
        s[i++] = ext[k];
    s[i] = 0;
    u->sun_family = AF_UNIX;
}

static int stream(int fd)
{
    int type = 0;
    socklen_t l = sizeof type;
    return sys6(NR_getsockopt, fd, SOL_SOCKET, SO_TYPE, (long)&type, (long)&l, 0) == 0 &&
           (type & SOCK_TYPE_MASK) == SOCK_STREAM;
}

// Puts a new Unix stream socket, with [fd]'s flags, in [fd]'s place. 0, or -errno.
static long replace(int fd)
{
    long fl = sys(NR_fcntl, fd, F_GETFL, 0), fdfl = sys(NR_fcntl, fd, F_GETFD, 0);
    if (fl < 0 || fdfl < 0)
        return fl < 0 ? fl : fdfl;
    long u = sys(NR_socket, AF_UNIX, SOCK_STREAM | ((fl & O_NONBLOCK) ? SOCK_NONBLOCK : 0) | SOCK_CLOEXEC, 0);
    if (u < 0)
        return u;
    long r = sys(NR_dup3, u, fd, (fdfl & FD_CLOEXEC) ? SOCK_CLOEXEC : 0);
    sys(NR_close, u, 0, 0);
    return r < 0 ? r : 0;
}

static void fake_addr(uint16_t port, struct sockaddr *addr, socklen_t *len)
{
    if (!addr || !len)
        return;
    struct sockaddr_in a = {AF_INET, ntoh16(port), 0x0100007f, {0}};
    socklen_t n = *len < sizeof a ? *len : (socklen_t)sizeof a;
    for (socklen_t i = 0; i < n; i++)
        ((char *)addr)[i] = ((char *)&a)[i];
    *len = sizeof a;
}

#define NEXT(name, rtype, args) \
    static rtype(*next_##name) args; \
    if (!next_##name) \
        next_##name = (rtype(*) args)dlsym(RTLD_NEXT, #name)

int bind(int fd, const struct sockaddr *addr, socklen_t len)
{
    uint16_t port = protected_port(addr, len, 0);
    if (port && fd >= 0 && fd < MAXFD && stream(fd)) {
        struct sockaddr_un u;
        socket_path(&u, port);
        long r = replace(fd);
        if (r < 0)
            return ret(r);
        sys(NR_unlinkat, AT_FDCWD, u.sun_path, 0); // a socket left by a previous run
        r = sys(NR_bind, fd, &u, sizeof u);
        if (r == 0) {
            sys6(NR_fchmodat, AT_FDCWD, (long)u.sun_path, 0600, 0, 0, 0);
            redirected[fd] = port;
        }
        return ret(r);
    }
    NEXT(bind, int, (int, const struct sockaddr *, socklen_t));
    return next_bind(fd, addr, len);
}

int connect(int fd, const struct sockaddr *addr, socklen_t len)
{
    uint16_t port = protected_port(addr, len, 1);
    if (port && fd >= 0 && fd < MAXFD && stream(fd)) {
        struct sockaddr_un u;
        socket_path(&u, port);
        long r = replace(fd);
        if (r < 0)
            return ret(r);
        redirected[fd] = port;
        r = sys(NR_connect, fd, &u, sizeof u);
        // No socket file = nobody listening: what a TCP client expects to see then.
        return ret(r == -ENOENT ? -ECONNREFUSED : r);
    }
    NEXT(connect, int, (int, const struct sockaddr *, socklen_t));
    return next_connect(fd, addr, len);
}

int accept4(int fd, struct sockaddr *addr, socklen_t *len, int flags)
{
    uint16_t port = fd >= 0 && fd < MAXFD ? redirected[fd] : 0;
    if (!port) {
        // Plain accept is killed by Android's seccomp; accept4 is what android-compat makes of it too.
        long r = sys6(NR_accept4, fd, (long)addr, (long)len, flags, 0, 0);
        if (r >= 0 && r < MAXFD)
            redirected[r] = 0;
        return ret(r);
    }
    struct sockaddr_un peer;
    socklen_t pl = sizeof peer;
    long c = sys6(NR_accept4, fd, (long)&peer, (long)&pl, flags, 0, 0);
    if (c < 0)
        return ret(c);
    struct ucred cred = {0};
    socklen_t cl = sizeof cred;
    long ok = sys6(NR_getsockopt, c, SOL_SOCKET, SO_PEERCRED, (long)&cred, (long)&cl, 0);
    if (ok == 0 && cred.uid == (uint32_t)sys(NR_getuid, 0, 0, 0)) {
        if (c < MAXFD)
            redirected[c] = port;
        fake_addr(port, addr, len);
        return (int)c;
    }
    sys(NR_close, c, 0, 0);
    return ret(-ECONNABORTED); // another uid: dropped unread; servers go on accepting after this
}

int accept(int fd, struct sockaddr *addr, socklen_t *len) { return accept4(fd, addr, len, 0); }

static int is_unix(int fd)
{
    struct sockaddr_un u;
    socklen_t l = sizeof u;
    return sys(NR_getsockname, fd, &u, &l) == 0 && u.sun_family == AF_UNIX;
}

int getsockname(int fd, struct sockaddr *addr, socklen_t *len)
{
    uint16_t port = fd >= 0 && fd < MAXFD ? redirected[fd] : 0;
    if (port && is_unix(fd)) {
        fake_addr(port, addr, len);
        return 0;
    }
    NEXT(getsockname, int, (int, struct sockaddr *, socklen_t *));
    return next_getsockname(fd, addr, len);
}

int getpeername(int fd, struct sockaddr *addr, socklen_t *len)
{
    uint16_t port = fd >= 0 && fd < MAXFD ? redirected[fd] : 0;
    if (port && is_unix(fd)) {
        fake_addr(port, addr, len);
        return 0;
    }
    NEXT(getpeername, int, (int, struct sockaddr *, socklen_t *));
    return next_getpeername(fd, addr, len);
}

int setsockopt(int fd, int level, int name, const void *val, socklen_t len)
{
    NEXT(setsockopt, int, (int, int, int, const void *, socklen_t));
    int r = next_setsockopt(fd, level, name, val, len);
    if (r < 0 && fd >= 0 && fd < MAXFD && redirected[fd] && is_unix(fd)) {
        int e = *__errno_location();
        // TCP_NODELAY, keepalive tuning, IPV6_V6ONLY: meaningless on a Unix socket, so done.
        if (e == EOPNOTSUPP || e == ENOPROTOOPT || e == EINVAL)
            return 0;
    }
    return r;
}

// A new socket or a closed fd is never a redirected one (fd numbers are reused).
int socket(int domain, int type, int protocol)
{
    NEXT(socket, int, (int, int, int));
    int fd = next_socket(domain, type, protocol);
    if (fd >= 0 && fd < MAXFD)
        redirected[fd] = 0;
    return fd;
}

int close(int fd)
{
    NEXT(close, int, (int));
    if (fd >= 0 && fd < MAXFD)
        redirected[fd] = 0;
    return next_close(fd);
}
