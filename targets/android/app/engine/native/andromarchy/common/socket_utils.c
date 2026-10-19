#ifndef _GNU_SOURCE
#define _GNU_SOURCE /* struct ucred */
#endif
#include "socket_utils.h"

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

int send_fds(int sock, const void *data, size_t data_len,
             const int *fds, int fd_count)
{
    struct iovec iov = {
        .iov_base = (void *)data,
        .iov_len  = data_len,
    };

    char cmsg_buf[CMSG_SPACE(sizeof(int) * fd_count)];
    memset(cmsg_buf, 0, sizeof(cmsg_buf));

    struct msghdr msg = {
        .msg_iov        = &iov,
        .msg_iovlen     = 1,
        .msg_control    = cmsg_buf,
        .msg_controllen = sizeof(cmsg_buf),
    };

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type  = SCM_RIGHTS;
    cmsg->cmsg_len   = CMSG_LEN(sizeof(int) * fd_count);
    memcpy(CMSG_DATA(cmsg), fds, sizeof(int) * fd_count);

    ssize_t n = sendmsg(sock, &msg, MSG_NOSIGNAL);
    return (n == (ssize_t)data_len) ? 0 : -1;
}

int recv_fds(int sock, void *data, size_t data_len,
             int *fds, int fd_count, int *fds_received)
{
    struct iovec iov = {
        .iov_base = data,
        .iov_len  = data_len,
    };

    char cmsg_buf[CMSG_SPACE(sizeof(int) * fd_count)];
    memset(cmsg_buf, 0, sizeof(cmsg_buf));

    struct msghdr msg = {
        .msg_iov        = &iov,
        .msg_iovlen     = 1,
        .msg_control    = cmsg_buf,
        .msg_controllen = sizeof(cmsg_buf),
    };

    ssize_t n = recvmsg(sock, &msg, 0);
    if (n <= 0)
        return -1;

    *fds_received = 0;
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    if (cmsg && cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS) {
        int count = (cmsg->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        if (count > fd_count)
            count = fd_count;
        memcpy(fds, CMSG_DATA(cmsg), sizeof(int) * count);
        *fds_received = count;
    }

    return (int)n;
}

/* PowOS: a socket address is a path, or "@name" for Linux's abstract namespace. An abstract socket is no file: it
 * needs no directory and no SELinux sock_file permission, which a privileged app (priv_app) has nowhere in its own
 * data. It has no file permissions either, so both ends check who is on the other side (unix_peer_trusted). The
 * name is exactly the bytes after '@', without a NUL: abstract names are length-exact. */
int unix_address(const char *address, struct sockaddr_un *addr, socklen_t *len)
{
    size_t n = strlen(address);

    memset(addr, 0, sizeof(*addr));
    addr->sun_family = AF_UNIX;
    if (n == 0 || n >= sizeof(addr->sun_path) || (address[0] == '@' && n == 1)) {
        errno = EINVAL;
        return -1;
    }
    if (address[0] == '@') {
        memcpy(addr->sun_path + 1, address + 1, n - 1); /* sun_path[0] stays 0: abstract */
        *len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + n);
    } else {
        memcpy(addr->sun_path, address, n);
        *len = (socklen_t)sizeof(*addr);
    }
    return 0;
}

/* The process on the other end of a connected socket runs as this process's user or as root: the display daemon,
 * the app and the rooted session's KWin (the user powos, whose uid is the app's) share one uid. */
int unix_peer_trusted(int fd)
{
    struct ucred cred;
    socklen_t len = sizeof(cred);

    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) < 0)
        return 0;
    return cred.uid == getuid() || cred.uid == 0;
}

int connect_unix(const char *path)
{
    struct sockaddr_un addr;
    socklen_t addr_len;

    if (unix_address(path, &addr, &addr_len) < 0)
        return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -1;
    if (connect(fd, (struct sockaddr *)&addr, addr_len) < 0) {
        close(fd);
        return -1;
    }
    /* Any process may bind an abstract name first: talk only to a daemon of this user (or root). */
    if (path[0] == '@' && !unix_peer_trusted(fd)) {
        close(fd);
        errno = EPERM;
        return -1;
    }
    return fd;
}

int send_all(int fd, const void *buf, size_t len)
{
    const uint8_t *p = buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, p + sent, len - sent, MSG_NOSIGNAL);
        if (n <= 0) {
            if (n < 0 && errno == EINTR)
                continue;
            return -1;
        }
        sent += n;
    }
    return 0;
}

int recv_all(int fd, void *buf, size_t len)
{
    uint8_t *p = buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, p + got, len - got, 0);
        if (n <= 0) {
            if (n < 0 && errno == EINTR)
                continue;
            return -1;
        }
        got += n;
    }
    return 0;
}
