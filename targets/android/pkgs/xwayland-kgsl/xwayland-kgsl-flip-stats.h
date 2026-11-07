/*
 * PowOS (patch 0013): what Xwayland did with each Present of a client's DRI3 buffer on KGSL - flipped it (the
 * client's dma-buf attached to the window's wl_surface as is) or copied it into the window's own buffer, and for
 * a copy the first rule of xwl_present_check_flip that said no - counted per 30 s for one log line. No X server,
 * no EGL, so test/flip-stats-test.c runs it.
 *
 * Why: lfdevs's 0003 refused every flip on KGSL surfaceless ("this backend must use the copy path"), so each frame of
 * a full-screen game cost Xwayland a fence wait, a window-sized glamor blit and a glFinish (xwl_present_flush) before
 * KWin drew the window again: Xwayland 19-20 % CPU at Broforce's 38 fps (bf-quiet 2026-11-05 04:19). The copy was
 * only needed for buffers Xwayland itself must export (EGL image export); a DRI3 buffer already IS a dma-buf, so
 * 0013 hands it to the compositor (linux-dmabuf) and lets Present flip it. The line says whether the game really
 * flips (and if not, why) on the device, instead of inferring it from CPU numbers.
 * Included by xwayland-present.c (patch 0013) and test/flip-stats-test.c.
 */
#ifndef XWAYLAND_KGSL_FLIP_STATS_H
#define XWAYLAND_KGSL_FLIP_STATS_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define XWL_KGSL_FLIP_PERIOD_US (30ull * 1000 * 1000)

/* The first check_flip rule that refused (in check order), or UNCHECKED: Present never asked (a PresentOptionCopy
 * request, or a target MSC already past) - or FAILED: check_flip said yes but xwl_present_flip couldn't attach. */
enum xwl_kgsl_noflip {
    XWL_NOFLIP_UNCHECKED, XWL_NOFLIP_NO_WINDOW, XWL_NOFLIP_OFFSET, XWL_NOFLIP_SIZE, XWL_NOFLIP_NOT_DRI3,
    XWL_NOFLIP_NO_BUFFER, XWL_NOFLIP_TOPLEVEL, XWL_NOFLIP_CLIPPED, XWL_NOFLIP_REDIRECTED, XWL_NOFLIP_SURFACE_SIZE,
    XWL_NOFLIP_SYNC, XWL_NOFLIP_DEPTH, XWL_NOFLIP_FAILED, XWL_NOFLIP_COUNT
};

static const char *const xwl_kgsl_noflip_names[XWL_NOFLIP_COUNT] = {
    "unchecked", "no-window", "offset/valid", "size", "not-dri3", "no-buffer", "toplevel", "clipped", "redirected",
    "surface-size", "sync", "depth", "flip-failed"
};

/* PowOS (patch 0018): one X window's shape as check_flip compared it - its id, its drawable (x, y, w, h: screen
 * coordinates) and its winSize region (extents and rectangle count: a bounding shape or a clip by the parent shows
 * as a smaller extent or > 1 rect). */
struct xwl_kgsl_flip_win {
    uint32_t id;
    int x, y, w, h;
    int x1, y1, x2, y2;
    int nrects;
};

/* PowOS (patch 0018): the first present per period that a size rule refused ("toplevel": the present window's
 * region isn't its pixmap toplevel's; "surface-size": not the xwl_window's toplevel's), with both windows' shapes
 * and how many levels the present window is below the toplevel - so the line says WHY a full-screen game copies
 * (a Wine client child smaller than its whole window, a WM-sized toplevel, a shape) instead of it being guessed. */
struct xwl_kgsl_flip_refusal {
    enum xwl_kgsl_noflip why;   /* XWL_NOFLIP_UNCHECKED: none recorded this period */
    unsigned depth;             /* levels from the present window up to the toplevel (0: it is the toplevel) */
    struct xwl_kgsl_flip_win present, top;
};

struct xwl_kgsl_flip_stats {
    uint64_t period_start_us;   /* 0: not started */
    unsigned flips;
    unsigned copies[XWL_NOFLIP_COUNT];
    struct xwl_kgsl_flip_refusal refusal;
};

/* Keep the period's first size refusal (later ones the same period are only counted). */
static inline void
xwl_kgsl_flip_note_refusal(struct xwl_kgsl_flip_stats *s, const struct xwl_kgsl_flip_refusal *r)
{
    if (s->refusal.why == XWL_NOFLIP_UNCHECKED && r->why != XWL_NOFLIP_UNCHECKED)
        s->refusal = *r;
}

static inline size_t
xwl_kgsl_flip_win_desc(const struct xwl_kgsl_flip_win *w, char *buf, size_t len)
{
    return (size_t) snprintf(buf, len, "0x%x %dx%d%+d%+d region %d,%d-%d,%d (%d rect%s)", (unsigned) w->id,
                             w->w, w->h, w->x, w->y, w->x1, w->y1, w->x2, w->y2, w->nrects,
                             w->nrects == 1 ? "" : "s");
}

static inline void
xwl_kgsl_flip_start(struct xwl_kgsl_flip_stats *s, uint64_t now_us)
{
    if (!s->period_start_us)
        s->period_start_us = now_us ? now_us : 1;
}

static inline void
xwl_kgsl_flip_note_flip(struct xwl_kgsl_flip_stats *s, uint64_t now_us)
{
    xwl_kgsl_flip_start(s, now_us);
    s->flips++;
}

static inline void
xwl_kgsl_flip_note_copy(struct xwl_kgsl_flip_stats *s, enum xwl_kgsl_noflip why, uint64_t now_us)
{
    xwl_kgsl_flip_start(s, now_us);
    if ((unsigned) why >= XWL_NOFLIP_COUNT)
        why = XWL_NOFLIP_UNCHECKED;
    s->copies[why]++;
}

/* The period's line into buf once 30 s have gone by (then a new period starts); 0 = nothing to say yet. */
static inline int
xwl_kgsl_flip_line(struct xwl_kgsl_flip_stats *s, uint64_t now_us, char *buf, size_t len)
{
    unsigned copies = 0, i;
    size_t n;

    for (i = 0; i < XWL_NOFLIP_COUNT; i++)
        copies += s->copies[i];
    if (!s->period_start_us || now_us - s->period_start_us < XWL_KGSL_FLIP_PERIOD_US || !(copies + s->flips))
        return 0;
    n = (size_t) snprintf(buf, len, "Xwayland KGSL: last %us: %u Present flips, %u copies",
                          (unsigned) ((now_us - s->period_start_us) / 1000000), s->flips, copies);
    for (i = 0; i < XWL_NOFLIP_COUNT && n < len; i++)
        if (s->copies[i])
            n += (size_t) snprintf(buf + n, len - n, " %s=%u", xwl_kgsl_noflip_names[i], s->copies[i]);
    if (n < len)
        n += (size_t) snprintf(buf + n, len - n, "\n");
    if (s->refusal.why != XWL_NOFLIP_UNCHECKED && n < len) {
        n += (size_t) snprintf(buf + n, len - n, "Xwayland KGSL: first %s refusal: present window ",
                               xwl_kgsl_noflip_names[s->refusal.why]);
        if (n < len)
            n += xwl_kgsl_flip_win_desc(&s->refusal.present, buf + n, len - n);
        if (n < len)
            n += (size_t) snprintf(buf + n, len - n, ", %u level%s below toplevel ", s->refusal.depth,
                                   s->refusal.depth == 1 ? "" : "s");
        if (n < len)
            n += xwl_kgsl_flip_win_desc(&s->refusal.top, buf + n, len - n);
        if (n < len)
            snprintf(buf + n, len - n, "\n");
    }
    memset(s, 0, sizeof(*s));
    s->period_start_us = now_us;
    return 1;
}

#endif
