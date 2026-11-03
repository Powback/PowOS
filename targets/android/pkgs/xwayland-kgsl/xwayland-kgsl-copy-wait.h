/*
 * PowOS: what a Present copy from a client's DRI3 buffer found when it asked for the client's rendering fence
 * (patch 0008's wait), counted per 30 s for one log line - no X server, no EGL, so test/copy-wait-test.c runs it.
 *
 * Why: Broforce on KGSL (2026-11-03 19:02, bf-overlay-watch.sh) left 7 of 90 of Xwayland's OWN copies of the game
 * window checkered black (1.4-2.1 %, clean 0.06 %): the copy read the game's swapchain image before the game's GPU
 * had finished writing it, with 0008's wait in place. The wait only waits when the dma-buf carries a pending
 * client fence: a buffer whose fence had already signalled, or that carries none, is copied at once. These counts
 * say which happens on the device, per copy:
 *   waited  the fence was pending: the copy waited for it (how long: sum/max)
 *   drawn   the client's own fence was there and had signalled
 *   stub    EXPORT_SYNC_FILE gave the kernel's stub: the fence had already signalled or there was none. Not "no
 *           fence attached": kernel patch 0005 (dma_buf_resv_fence, __dma_fence_unwrap_merge) drops signalled fences
 *           and returns the stub, and Mesa attaches a real KGSL fence on every present (kgsl-fence, 2026-11-03).
 *   failed  the export failed (errno other than ENOTTY)
 * Included by xwayland-glamor-gbm.c / xwayland-present.c (patch 0011) and test/copy-wait-test.c.
 */
#ifndef XWAYLAND_KGSL_COPY_WAIT_H
#define XWAYLAND_KGSL_COPY_WAIT_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define XWL_KGSL_COPY_WAIT_PERIOD_US (30ull * 1000 * 1000)

enum xwl_kgsl_copy_fence { XWL_KGSL_COPY_WAITED, XWL_KGSL_COPY_DRAWN, XWL_KGSL_COPY_STUB, XWL_KGSL_COPY_FAILED };

struct xwl_kgsl_copy_wait_stats {
    uint64_t period_start_us;   /* 0: not started */
    unsigned waited, drawn, stub, failed;
    uint64_t wait_sum_us, wait_max_us;
    unsigned waits_done;        /* waits that ended (sum/max are over these) */
};

/* The kind of a sync_file's first fence from its driver name (SYNC_IOC_FILE_INFO's sync_fence_info.driver_name):
 * the kernel's stub fence ("stub") means nothing unsignalled was on the buffer (signalled, or none). */
static inline int
xwl_kgsl_copy_fence_is_stub(const char *driver_name, uint32_t num_fences)
{
    return num_fences == 0 || (driver_name && strcmp(driver_name, "stub") == 0);
}

static inline void
xwl_kgsl_copy_wait_note(struct xwl_kgsl_copy_wait_stats *s, enum xwl_kgsl_copy_fence what, uint64_t now_us)
{
    if (!s->period_start_us)
        s->period_start_us = now_us ? now_us : 1;
    switch (what) {
    case XWL_KGSL_COPY_WAITED: s->waited++; break;
    case XWL_KGSL_COPY_DRAWN: s->drawn++; break;
    case XWL_KGSL_COPY_STUB: s->stub++; break;
    case XWL_KGSL_COPY_FAILED: s->failed++; break;
    }
}

static inline void
xwl_kgsl_copy_wait_done(struct xwl_kgsl_copy_wait_stats *s, uint64_t waited_us)
{
    s->waits_done++;
    s->wait_sum_us += waited_us;
    if (waited_us > s->wait_max_us)
        s->wait_max_us = waited_us;
}

/* The period's line into buf once 30 s have gone by (then a new period starts); 0 = nothing to say yet. */
static inline int
xwl_kgsl_copy_wait_line(struct xwl_kgsl_copy_wait_stats *s, uint64_t now_us, char *buf, size_t len)
{
    unsigned copies = s->waited + s->drawn + s->stub + s->failed;

    if (!s->period_start_us || now_us - s->period_start_us < XWL_KGSL_COPY_WAIT_PERIOD_US || !copies)
        return 0;
    snprintf(buf, len,
             "Xwayland KGSL: last %us: %u Present copies from client buffers: %u waited for the client's GPU fence "
             "(avg %.1f ms, max %.1f ms), %u already drawn, %u with the fence already signalled or none (stub), "
             "%u export failures\n",
             (unsigned) ((now_us - s->period_start_us) / 1000000), copies, s->waited,
             s->waits_done ? s->wait_sum_us / 1000.0 / s->waits_done : 0.0, s->wait_max_us / 1000.0,
             s->drawn, s->stub, s->failed);
    memset(s, 0, sizeof(*s));
    s->period_start_us = now_us;
    return 1;
}

#endif
