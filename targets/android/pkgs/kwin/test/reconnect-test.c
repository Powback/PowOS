/* kwin 0059: the desktop's try_exit_fallback() never waits on KWin's thread. A fake display daemon (a unix socket that
 * answers HELLO with screen info, then counts PICKUP_FDS and answers nothing - no consumer) and the patched
 * display_producer.c: every call returns -1 at once (was: a 100 ms poll each), one PICKUP_FDS goes out however many
 * calls (the daemon keeps it), and a bad answer (FDS_READY without the fds) lets the next call ask again.
 * Built by run.sh against the src-tree.sh tree (display_producer.c + socket_utils.c). */
#define _GNU_SOURCE
#include "display_producer.h"
#include "protocol.h"
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static int listen_fd, daemon_fd = -1;
static volatile int pickups;

static void *daemon_main(void *arg)
{
    (void) arg;
    daemon_fd = accept(listen_fd, NULL, NULL);
    struct ctrl_msg hdr;
    if (read(daemon_fd, &hdr, sizeof(hdr)) != sizeof(hdr) || hdr.type != CTRL_MSG_PRODUCER_HELLO)
        return NULL;
    uint8_t reply[sizeof(struct ctrl_msg) + sizeof(struct screen_info)];
    struct ctrl_msg r = { .type = CTRL_MSG_SCREEN_INFO, .size = sizeof(struct screen_info) };
    struct screen_info si = { 1116, 2484, 1, 120 };
    memcpy(reply, &r, sizeof(r));
    memcpy(reply + sizeof(r), &si, sizeof(si));
    if (write(daemon_fd, reply, sizeof(reply)) != (ssize_t) sizeof(reply))
        return NULL;
    while (read(daemon_fd, &hdr, sizeof(hdr)) == sizeof(hdr))
        if (hdr.type == CTRL_MSG_PICKUP_FDS)
            __atomic_add_fetch(&pickups, 1, __ATOMIC_SEQ_CST);
    return NULL;
}

static double now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static int fails;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL: " __VA_ARGS__); printf("\n"); fails++; } } while (0)

static void settle(void) { usleep(20000); } /* the daemon thread reads what was sent */

int main(void)
{
    char path[] = "/tmp/reconnect-test.sock";
    unlink(path);
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    strcpy(a.sun_path, path);
    listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (bind(listen_fd, (struct sockaddr *) &a, sizeof(a)) || listen(listen_fd, 1)) {
        perror("bind");
        return 2;
    }
    pthread_t th;
    pthread_create(&th, NULL, daemon_main, NULL);
    display_ctx *ctx = NULL;
    if (connect_to_deamon(&ctx, path) < 0) {
        printf("FAIL: handshake\n");
        return 1;
    }
    double worst = 0;
    for (int i = 0; i < 10; i++) {
        double t0 = now_ms();
        int r = try_exit_fallback(ctx);
        double ms = now_ms() - t0;
        if (ms > worst)
            worst = ms;
        CHECK(r == -1, "no consumer: try_exit_fallback() = %d, want -1", r);
    }
    CHECK(worst < 20, "no consumer: a call took %.1f ms (must not wait; was a 100 ms poll)", worst);
    settle();
    CHECK(pickups == 1, "no consumer: %d PICKUP_FDS for 10 calls, want 1 (the daemon keeps the request)", pickups);

    /* A bad answer (FDS_READY without its fds): that request is used up - the next call asks again. */
    struct ctrl_msg bad = { .type = CTRL_MSG_FDS_READY, .size = 0 };
    CHECK(write(daemon_fd, &bad, sizeof(bad)) == sizeof(bad), "write");
    settle();
    double t0 = now_ms();
    CHECK(try_exit_fallback(ctx) == -1, "bad answer: still in fallback");
    CHECK(now_ms() - t0 < 20, "bad answer: no wait");
    CHECK(is_fallback(ctx), "bad answer: is_fallback");
    try_exit_fallback(ctx);
    settle();
    CHECK(pickups == 2, "after a bad answer: %d PICKUP_FDS, want 2", pickups);

    printf("%s: try_exit_fallback worst %.2f ms, %d pickups\n", fails ? "FAIL" : "PASS", worst, pickups);
    disconnect(ctx);
    return fails ? 1 : 0;
}
