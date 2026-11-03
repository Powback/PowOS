/*
 * display_consumer's stop wake (set_wake_fd): a consumer stopping while the producer sends no frame returns from its
 * waits at once. 11-03 the ship's Linux window check: "the consumer's stop took 2135 ms" - nativeStopWindow joined a
 * render thread blocked up to 5 s in refresh_done_tagged for an idle KWin window's next frame (and the event thread's
 * 500 ms poll after it). Run: targets/android/app/engine/src/test/native/run.sh
 *
 * The test is the producer (KWin's side): it takes the HELLO's fds over a socketpair, answers FDS_READY, and sends
 * frames on the fence channel - or none, for the stop case.
 */
#define _GNU_SOURCE
#include <stddef.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "display_consumer.h"
#include "protocol.h"
#include "socket_utils.h"

static int failures;
#define CHECK(c, ...) do { if (!(c)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok: " __VA_ARGS__); printf("\n"); } } while (0)

static long now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

struct waiter { display_ctx *ctx; int ret; long ms; };

static void *wait_frame(void *arg)
{
    struct waiter *w = arg;
    long t0 = now_ms();
    int fence = -1;
    uint8_t tag = 0;
    w->ret = refresh_done_tagged(w->ctx, &fence, &tag);
    w->ms = now_ms() - t0;
    return NULL;
}

int main(void)
{
    int ctrl[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, ctrl) < 0) { perror("socketpair"); return 2; }
    display_ctx *ctx = NULL;
    if (connect_to_deamon_surface(&ctx, ctrl[0], 5) < 0) { printf("FAIL: connect\n"); return 2; }

    /* Producer: the HELLO's fds { buf_ready, fence, data, shm, audio }, then FDS_READY. */
    uint8_t hello[64];
    int fds[5], got = 0;
    if (recv_fds(ctrl[1], hello, sizeof(struct ctrl_msg) + sizeof(uint32_t), fds, 5, &got) <= 0 || got != 5) {
        printf("FAIL: hello fds (%d)\n", got);
        return 2;
    }
    int fence_w = fds[1];
    struct ctrl_msg ready = { .type = CTRL_MSG_FDS_READY, .size = 0 };
    send_all(ctrl[1], &ready, sizeof(ready));

    int buf = memfd_create("buf", 0);
    struct buf_info info = { .stride = 64, .width = 16, .height = 16, .format = 0, .modifier = 0, .offset = 0 };
    push_dmabufs(ctx, &buf, &info, 1);

    int wake = eventfd(0, EFD_CLOEXEC);
    set_wake_fd(ctx, wake);

    /* 1. A frame still comes through with the wake fd set (not readable). */
    CHECK(select_dmabuf(ctx, 0) == 0, "select_dmabuf leaves fallback");
    char b = 0;
    send(fence_w, &b, 1, 0);
    struct waiter w1 = { .ctx = ctx };
    wait_frame(&w1);
    CHECK(w1.ret == 1, "a producer frame is a frame (%d) with the wake fd set", w1.ret);

    /* 2. No frame: the stop's wake returns the frame wait at once (it waited up to 5 s). */
    select_dmabuf(ctx, 0);
    struct waiter w2 = { .ctx = ctx };
    pthread_t th;
    pthread_create(&th, NULL, wait_frame, &w2);
    usleep(100000);
    long t0 = now_ms();
    eventfd_write(wake, 1);
    pthread_join(th, NULL);
    long joined = now_ms() - t0;
    CHECK(w2.ret == -1, "the woken frame wait is no frame (%d)", w2.ret);
    CHECK(joined <= 100, "the render thread's join returned %ld ms after the wake (want <= 100; was the producer's next frame, up to 5000)", joined);

    /* 3. The event thread's poll returns at once too (it waited its 500 ms). */
    struct OutputEvent ev;
    t0 = now_ms();
    int r = poll_output_event(ctx, &ev, 2000);
    long ms = now_ms() - t0;
    CHECK(r == 0 && ms <= 100, "poll_output_event woken: %d in %ld ms (want 0 in <= 100)", r, ms);

    /* 4. The wake was no failure: the connection is up (not fallback) - a frame after it is still a frame. */
    select_dmabuf(ctx, 0);
    send(fence_w, &b, 1, 0);
    set_wake_fd(ctx, -1);
    struct waiter w4 = { .ctx = ctx };
    wait_frame(&w4);
    CHECK(w4.ret == 1, "no fallback after the wake: the next frame is a frame (%d)", w4.ret);

    /* 5. Control - without a wake fd the poll waits its timeout (what the old stop waited on). */
    t0 = now_ms();
    poll_output_event(ctx, &ev, 300);
    ms = now_ms() - t0;
    CHECK(ms >= 250, "no wake fd: poll_output_event waits its timeout (%ld ms)", ms);

    printf(failures ? "display_consumer_wake_test: %d FAILED\n" : "display_consumer_wake_test: PASS\n", failures);
    return failures ? 1 : 0;
}
