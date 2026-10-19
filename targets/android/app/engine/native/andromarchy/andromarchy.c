#define _GNU_SOURCE /* accept4 */
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "common/protocol.h"
#include "common/socket_utils.h"

#define MAX_EVENTS 16
/* Hello fd set: { buf_ready, fence, data, shm, audio }. The daemon only relays
 * the fds; it never interprets the slots. */
#define MAX_FDS    5

/* PowOS: one pair per surface id - 0 is the desktop, others are PowOS windows shown as their own Android tasks
 * (docs/powos-window-tasks.md). A pair is what the daemon was before: one consumer, one producer, the consumer's
 * screen info and its deposited fds. */
#define MAX_PAIRS 16

enum role { ROLE_CONSUMER, ROLE_PRODUCER, ROLE_CONTROL };

struct pair;

struct client {
    int  ctrl_fd;
    enum role role;
    struct pair *pair;       /* consumer / producer */
    uint32_t control_role;   /* control: CONTROL_ROLE_* */
};

struct pair {
    bool used;
    uint32_t id;
    struct client *consumer;
    struct client *producer;
    struct screen_info stored_screen;
    bool has_screen_info;
    int deposited_fds[MAX_FDS];
    int deposited_fd_count;
    bool producer_waiting_screen;
    bool producer_waiting_fds;
};

static struct pair pairs[MAX_PAIRS];
/* The control relay: KWin (CONTROL_ROLE_COMPOSITOR) and the PowOS app (CONTROL_ROLE_APP). */
static struct client *controls[2];
static int epoll_fd;
static volatile bool running = true;
/* Listening on "@name" (abstract namespace) rather than a socket file: see main(). */
static bool abstract_socket;

/* PowOS: the desktop's (surface 0) screen as the app knew it when it started this daemon (--screen WxH@mHz), for a
 * producer that connects before any consumer did. Without it the producer (KWin's Anland backend, connect_to_deamon)
 * waited in its handshake for the first consumer - the PowOS desktop on screen - and with it KWin's whole startup and
 * every client of it (kcminit, the portals, plasmashell): a session the app started while the phone showed anything
 * else (the launcher after an update, a reboot) came up only once the desktop was opened, seconds of Plasma starting
 * in front of the user (12 minutes blocked on 2026-10-19). The first consumer's own screen info replaces it; KWin
 * resizes its output to the consumer's buffers on import (rotation, fold), so a provisional size that differs is
 * harmless. */
static struct screen_info provisional_screen;
static bool has_provisional_screen;

static void daemon_log(const char *format, ...)
{
    struct timeval now;
    struct tm *local_time;
    va_list args;

    if (gettimeofday(&now, NULL) == 0 &&
        (local_time = localtime(&now.tv_sec)) != NULL) {
        fprintf(stderr, "%02d-%02d %02d:%02d:%02d.%03ld  ",
                local_time->tm_mon + 1, local_time->tm_mday,
                local_time->tm_hour, local_time->tm_min, local_time->tm_sec,
                now.tv_usec / 1000);
    } else {
        fputs("00-00 00:00:00.000  ", stderr);
    }

    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
}

static void daemon_perror(const char *message)
{
    int saved_errno = errno;

    daemon_log("%s: %s\n", message, strerror(saved_errno));
}

static const char *default_socket_path(void)
{
    static char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    const char *tmpdir = getenv("TMPDIR");

    if (!tmpdir || tmpdir[0] == '\0')
        tmpdir = "/data/data/com.termux/files/usr/tmp";

    if (snprintf(path, sizeof(path), "%s/andromarchy/display_daemon.sock", tmpdir) >=
        (int)sizeof(path)) {
        daemon_log("daemon: default socket path is too long\n");
        exit(1);
    }

    return path;
}

/* "WxH" or "WxH@mHz" (refresh in milli-Hz, as the consumer reports it). */
static bool parse_screen(const char *arg, struct screen_info *si)
{
    unsigned w = 0, h = 0, mhz = 0;
    int n = sscanf(arg, "%ux%u@%u", &w, &h, &mhz);
    if (n < 2 || w == 0 || h == 0 || w > 16384 || h > 16384)
        return false;
    si->width = w;
    si->height = h;
    si->format = 1; /* PIXEL_FORMAT_RGBA_8888, what the consumer reports (native_consumer.c) */
    si->refresh = n == 3 ? mhz : 60000;
    return true;
}

/* andromarchy [--socket] PATH [--screen WxH[@mHz]] */
static const char *parse_socket_path(int argc, char **argv)
{
    const char *path = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--screen") == 0 && i + 1 < argc) {
            has_provisional_screen = parse_screen(argv[++i], &provisional_screen);
            if (!has_provisional_screen)
                daemon_log("daemon: ignoring bad --screen %s\n", argv[i]);
        } else if (strcmp(argv[i], "--socket") == 0) {
            if (i + 1 >= argc || argv[i + 1][0] == '\0') {
                daemon_log("usage: andromarchy [--socket PATH] [PATH] [--screen WxH[@mHz]]\n");
                exit(1);
            }
            path = argv[++i];
        } else if (!path) {
            path = argv[i];
        }
    }
    return path ? path : default_socket_path();
}

static int ensure_socket_parent(const char *sock_path)
{
    char dir[sizeof(((struct sockaddr_un *)0)->sun_path)];
    char *slash;

    if (strlen(sock_path) >= sizeof(dir)) {
        daemon_log("daemon: socket path is too long\n");
        return -1;
    }

    strcpy(dir, sock_path);
    slash = strrchr(dir, '/');
    if (!slash)
        return 0;
    *slash = '\0';
    if (dir[0] == '\0')
        return 0;

    if (mkdir(dir, 0700) < 0 && errno != EEXIST) {
        daemon_perror("mkdir");
        return -1;
    }
    return 0;
}

static void handle_signal(int sig)
{
    (void)sig;
    running = false;
}

static void client_free(struct client *c)
{
    if (!c) return;
    if (c->ctrl_fd >= 0) {
        epoll_ctl(epoll_fd, EPOLL_CTL_DEL, c->ctrl_fd, NULL);
        close(c->ctrl_fd);
    }
    free(c);
}

static struct pair *pair_get(uint32_t id, bool create)
{
    struct pair *free_slot = NULL;
    for (int i = 0; i < MAX_PAIRS; i++) {
        if (pairs[i].used && pairs[i].id == id)
            return &pairs[i];
        if (!pairs[i].used && !free_slot)
            free_slot = &pairs[i];
    }
    if (!create || !free_slot)
        return NULL;
    memset(free_slot, 0, sizeof(*free_slot));
    free_slot->used = true;
    free_slot->id = id;
    return free_slot;
}

static void clear_deposited_fds(struct pair *p)
{
    for (int i = 0; i < p->deposited_fd_count; i++)
        close(p->deposited_fds[i]);
    p->deposited_fd_count = 0;
}

/* A pair with neither side left is forgotten (its id may come back with a new task). */
static void pair_release_if_empty(struct pair *p)
{
    if (p->consumer || p->producer)
        return;
    clear_deposited_fds(p);
    p->used = false;
}

static int send_ctrl(int fd, uint32_t type)
{
    struct ctrl_msg msg = { .type = type, .size = 0 };
    return send_all(fd, &msg, sizeof(msg));
}

static int send_screen_info_msg(struct pair *p, int fd)
{
    struct ctrl_msg hdr = { .type = CTRL_MSG_SCREEN_INFO, .size = sizeof(struct screen_info) };
    uint8_t buf[sizeof(struct ctrl_msg) + sizeof(struct screen_info)];
    memcpy(buf, &hdr, sizeof(hdr));
    memcpy(buf + sizeof(hdr), &p->stored_screen, sizeof(p->stored_screen));
    return send_all(fd, buf, sizeof(buf));
}

static void try_deliver_fds(struct pair *p)
{
    if (!p->producer || p->deposited_fd_count < MAX_FDS) {
        p->producer_waiting_fds = true;
        return;
    }

    struct ctrl_msg msg = { .type = CTRL_MSG_FDS_READY, .size = 0 };
    if (send_fds(p->producer->ctrl_fd, &msg, sizeof(msg),
                 p->deposited_fds, p->deposited_fd_count) < 0) {
        daemon_log("daemon: surface %u: failed to send fds to producer\n", p->id);
        p->producer_waiting_fds = true;
        return;
    }

    if (p->consumer)
        send_ctrl(p->consumer->ctrl_fd, CTRL_MSG_FDS_READY);

    for (int i = 0; i < p->deposited_fd_count; i++)
        close(p->deposited_fds[i]);
    p->deposited_fd_count = 0;
    p->producer_waiting_fds = false;

    daemon_log("daemon: surface %u: fds delivered to producer\n", p->id);
}

/* Whether c still holds a role (events for a client freed earlier in the same epoll batch are skipped). */
static bool client_current(struct client *c)
{
    if (c->role == ROLE_CONTROL)
        return c->control_role < 2 && controls[c->control_role] == c;
    return c->pair && c->pair->used
        && (c == c->pair->consumer || c == c->pair->producer);
}

/*
 * Tear down whichever role this client holds, reset the associated state, then free
 * it. Used both for real disconnects (EPOLLHUP / recv error) and to evict a stale
 * client when a new one takes over the same role -- whether the old client is still
 * alive or already a ghost, finding one is reason enough to drop it.
 *
 * The role pointer is cleared BEFORE client_free() so that any event still queued for
 * this client in the current epoll batch fails the client_current() guard in the main
 * loop and is skipped instead of dereferencing freed memory.
 */
static void drop_client(struct client *c)
{
    if (!c)
        return;
    if (c->role == ROLE_CONTROL) {
        if (c->control_role < 2 && controls[c->control_role] == c) {
            daemon_log("daemon: control (%s) disconnected\n", c->control_role == CONTROL_ROLE_APP ? "app" : "compositor");
            controls[c->control_role] = NULL;
        }
    } else if (c->pair) {
        struct pair *p = c->pair;
        if (c == p->consumer) {
            daemon_log("daemon: surface %u: consumer disconnected\n", p->id);
            p->consumer = NULL;
            /* The deposited fds belong to the consumer that just left; a future producer
             * must never be handed this stale set. Drop them together with the consumer. */
            clear_deposited_fds(p);
        } else if (c == p->producer) {
            daemon_log("daemon: surface %u: producer disconnected\n", p->id);
            p->producer = NULL;
            p->producer_waiting_screen = false;
            p->producer_waiting_fds = false;
        }
        pair_release_if_empty(p);
    }
    client_free(c);
}

/* A HELLO's optional surface id (its payload); none = 0, the desktop. */
static uint32_t hello_id(const struct ctrl_msg *hdr, const uint8_t *payload)
{
    uint32_t id = 0;
    if (hdr->size == sizeof(uint32_t))
        memcpy(&id, payload, sizeof(id));
    return id;
}

static void relay_control(struct client *from, const uint8_t *payload, uint32_t size)
{
    struct client *to = controls[from->control_role == CONTROL_ROLE_APP ? CONTROL_ROLE_COMPOSITOR : CONTROL_ROLE_APP];
    if (!to) {
        daemon_log("daemon: control message dropped, no %s connected\n",
                   from->control_role == CONTROL_ROLE_APP ? "compositor" : "app");
        return;
    }
    uint8_t buf[sizeof(struct ctrl_msg) + CONTROL_MAX_PAYLOAD];
    struct ctrl_msg hdr = { .type = CTRL_MSG_CONTROL, .size = size };
    memcpy(buf, &hdr, sizeof(hdr));
    memcpy(buf + sizeof(hdr), payload, size);
    if (send_all(to->ctrl_fd, buf, sizeof(hdr) + size) < 0)
        drop_client(to);
}

static void handle_client_data(struct client *c)
{
    struct ctrl_msg hdr;
    int fds[MAX_FDS];
    int fd_count = 0;

    int n = recv_fds(c->ctrl_fd, &hdr, sizeof(hdr), fds, MAX_FDS, &fd_count);
    if (n <= 0) {
        drop_client(c);
        return;
    }

    uint8_t payload[CONTROL_MAX_PAYLOAD];
    if (hdr.size > 0) {
        if (hdr.size > sizeof(payload) || recv_all(c->ctrl_fd, payload, hdr.size) < 0) {
            for (int i = 0; i < fd_count; i++)
                close(fds[i]);
            drop_client(c);
            return;
        }
    }

    if (c->role == ROLE_CONTROL) {
        for (int i = 0; i < fd_count; i++)
            close(fds[i]);
        if (hdr.type == CTRL_MSG_CONTROL)
            relay_control(c, payload, hdr.size);
        return;
    }

    struct pair *p = c->pair;
    switch (hdr.type) {
    case CTRL_MSG_CONSUMER_HELLO:
        if (c == p->consumer && fd_count >= MAX_FDS - 1) {
            clear_deposited_fds(p);
            memcpy(p->deposited_fds, fds, sizeof(int) * fd_count);
            p->deposited_fd_count = fd_count;
            fd_count = 0;
            daemon_log("daemon: surface %u: consumer re-deposited %d fds\n", p->id, p->deposited_fd_count);
            if (p->producer_waiting_fds)
                try_deliver_fds(p);
        }
        break;

    case CTRL_MSG_SCREEN_INFO:
        if (c == p->consumer && hdr.size == sizeof(struct screen_info)) {
            struct screen_info si;
            memcpy(&si, payload, sizeof(si));
            /* Always accept the consumer's screen info, even if it differs from a
             * previous connection — the Android display may have rotated or switched
             * resolution. Overwrite and forward to any waiting producer. */
            p->stored_screen = si;
            p->has_screen_info = true;
            daemon_log("daemon: surface %u: screen info %ux%u fmt=%u\n",
                       p->id, si.width, si.height, si.format);
            if (p->producer_waiting_screen && p->producer) {
                send_screen_info_msg(p, p->producer->ctrl_fd);
                p->producer_waiting_screen = false;
            }
        }
        break;

    case CTRL_MSG_PICKUP_FDS:
        if (c == p->producer)
            try_deliver_fds(p);
        break;

    default:
        break;
    }
    for (int i = 0; i < fd_count; i++)
        close(fds[i]);
}

static void handle_new_connection(int listen_fd)
{
    int client_fd = accept4(listen_fd, NULL, NULL, SOCK_CLOEXEC);
    if (client_fd < 0)
        return;
    /* An abstract socket has no file permissions: only this user (the app, KWin as powos) and root may connect. */
    if (abstract_socket && !unix_peer_trusted(client_fd)) {
        daemon_log("daemon: refused a connection from another user\n");
        close(client_fd);
        return;
    }

    struct ctrl_msg hdr;
    int fds[MAX_FDS];
    int fd_count = 0;

    int n = recv_fds(client_fd, &hdr, sizeof(hdr), fds, MAX_FDS, &fd_count);
    if (n < (int)sizeof(struct ctrl_msg)) {
        for (int i = 0; i < fd_count; i++)
            close(fds[i]);
        close(client_fd);
        return;
    }
    uint8_t payload[sizeof(uint32_t)];
    if (hdr.size > sizeof(payload) || (hdr.size > 0 && recv_all(client_fd, payload, hdr.size) < 0)) {
        for (int i = 0; i < fd_count; i++)
            close(fds[i]);
        close(client_fd);
        return;
    }

    struct client *c = calloc(1, sizeof(*c));
    if (!c) {
        for (int i = 0; i < fd_count; i++)
            close(fds[i]);
        close(client_fd);
        return;
    }
    c->ctrl_fd = client_fd;

    if (hdr.type == CTRL_MSG_CONSUMER_HELLO || hdr.type == CTRL_MSG_PRODUCER_HELLO) {
        const uint32_t id = hello_id(&hdr, payload);
        struct pair *p = pair_get(id, true);
        if (!p) {
            daemon_log("daemon: no room for surface %u\n", id);
            for (int i = 0; i < fd_count; i++)
                close(fds[i]);
            close(client_fd);
            free(c);
            return;
        }
        c->pair = p;
        if (hdr.type == CTRL_MSG_CONSUMER_HELLO) {
            /* Evict any prior consumer (alive or ghost) and its stale deposit before this
             * one takes over the role. */
            if (p->consumer) {
                drop_client(p->consumer);
                p = pair_get(id, true); /* the eviction may have released an otherwise empty pair */
                c->pair = p;
            }
            c->role = ROLE_CONSUMER;
            p->consumer = c;

            clear_deposited_fds(p);
            memcpy(p->deposited_fds, fds, sizeof(int) * fd_count);
            p->deposited_fd_count = fd_count;
            daemon_log("daemon: surface %u: consumer connected, %d fds\n", id, fd_count);

            if (p->producer_waiting_fds)
                try_deliver_fds(p);
        } else {
            for (int i = 0; i < fd_count; i++)
                close(fds[i]);
            /* Evict any prior producer (alive or ghost) before this one takes over. */
            if (p->producer) {
                drop_client(p->producer);
                p = pair_get(id, true);
                c->pair = p;
            }
            c->role = ROLE_PRODUCER;
            p->producer = c;
            p->producer_waiting_screen = false;
            p->producer_waiting_fds = false;
            daemon_log("daemon: surface %u: producer connected\n", id);

            if (!p->has_screen_info && id == 0 && has_provisional_screen) {
                p->stored_screen = provisional_screen;
                p->has_screen_info = true;
                daemon_log("daemon: surface 0: no consumer yet, provisional screen %ux%u\n",
                           provisional_screen.width, provisional_screen.height);
            }
            if (p->has_screen_info)
                send_screen_info_msg(p, client_fd);
            else
                p->producer_waiting_screen = true;
        }
    } else if (hdr.type == CTRL_MSG_CONTROL_HELLO && hdr.size == sizeof(uint32_t)) {
        for (int i = 0; i < fd_count; i++)
            close(fds[i]);
        uint32_t role;
        memcpy(&role, payload, sizeof(role));
        if (role > CONTROL_ROLE_APP) {
            close(client_fd);
            free(c);
            return;
        }
        if (controls[role])
            drop_client(controls[role]);
        c->role = ROLE_CONTROL;
        c->control_role = role;
        controls[role] = c;
        daemon_log("daemon: control (%s) connected\n", role == CONTROL_ROLE_APP ? "app" : "compositor");
    } else {
        for (int i = 0; i < fd_count; i++)
            close(fds[i]);
        close(client_fd);
        free(c);
        return;
    }

    struct epoll_event ev = { .events = EPOLLIN | EPOLLHUP | EPOLLERR, .data.ptr = c };
    epoll_ctl(epoll_fd, EPOLL_CTL_ADD, client_fd, &ev);
}

int main(int argc, char **argv)
{
    const char *sock_path = parse_socket_path(argc, argv);

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    signal(SIGPIPE, SIG_IGN);

    /* PowOS: "@name" listens in the abstract namespace (socket_utils.c), no file: what the rooted session uses, as
     * a privileged app may not create socket files in its data. A path is a socket file, as before. */
    abstract_socket = sock_path[0] == '@';
    if (!abstract_socket) {
        if (ensure_socket_parent(sock_path) < 0)
            return 1;
        unlink(sock_path);
    }
    int listen_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (listen_fd < 0) {
        daemon_perror("socket");
        return 1;
    }

    struct sockaddr_un addr;
    socklen_t addr_len;
    if (unix_address(sock_path, &addr, &addr_len) < 0) {
        daemon_log("daemon: bad socket address %s\n", sock_path);
        return 1;
    }

    /* An abstract name is held for as long as its socket is open: a daemon of the previous session that is still
     * exiting holds it for a moment (the app ends leftover daemons before it starts this one, SessionService). */
    int bound = -1;
    for (int attempt = 0; attempt < 50; attempt++) {
        bound = bind(listen_fd, (struct sockaddr *)&addr, addr_len);
        if (bound == 0 || !abstract_socket || errno != EADDRINUSE)
            break;
        usleep(100 * 1000);
    }
    if (bound < 0) {
        daemon_perror("bind");
        return 1;
    }
    if (listen(listen_fd, 16) < 0) {
        daemon_perror("listen");
        return 1;
    }

    epoll_fd = epoll_create1(0);
    struct epoll_event ev = { .events = EPOLLIN, .data.ptr = NULL };
    epoll_ctl(epoll_fd, EPOLL_CTL_ADD, listen_fd, &ev);

    daemon_log("daemon: listening on %s\n", sock_path);

    struct epoll_event events[MAX_EVENTS];
    while (running) {
        int nfds = epoll_wait(epoll_fd, events, MAX_EVENTS, 1000);
        for (int i = 0; i < nfds; i++) {
            if (events[i].data.ptr == NULL) {
                handle_new_connection(listen_fd);
            } else {
                struct client *c = events[i].data.ptr;
                /* A client freed earlier in this same batch -- a real disconnect, or
                 * one evicted by a new connection taking over its role -- leaves a
                 * stale event behind. Skip anything that is no longer a current role
                 * so we never touch freed memory. */
                if (!client_current(c))
                    continue;
                if (events[i].events & (EPOLLHUP | EPOLLERR))
                    drop_client(c);
                else
                    handle_client_data(c);
            }
        }
    }

    for (int i = 0; i < MAX_PAIRS; i++) {
        if (!pairs[i].used)
            continue;
        clear_deposited_fds(&pairs[i]);
        client_free(pairs[i].consumer);
        client_free(pairs[i].producer);
    }
    client_free(controls[0]);
    client_free(controls[1]);
    close(listen_fd);
    close(epoll_fd);
    if (!abstract_socket)
        unlink(sock_path);
    daemon_log("daemon: shutdown\n");
    return 0;
}
