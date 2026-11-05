/*
 * PowOS (patch 0014): every wl_surface.commit Xwayland sends on KGSL, counted per call site for one line per 30 s,
 * with how many carried damage (KWin redraws only for those), plus the frame callbacks that came back and the Present
 * frame timers that fired instead (0013's 100 ms KGSL flip timeout). No X server, no Wayland, so
 * test/commit-stats-test.c runs it.
 *
 * Why: KWin's window task saw ~2 damaged commits per drawn Broforce frame with 0013's flips (kwin 3.65 probe,
 * docs/research/window-task-direct-scanout.md: 368-430 commits / 5 s for 200 drawn) while Xwayland's own lines
 * counted ~30 flips/s and ~0.2 window-buffer commits/s - the second commit had no name. This line names it per site
 * on the device instead of inferring it.
 * Included by xwayland-screen.c (the instance + the line), xwayland-window.c, xwayland-present.c, xwayland-input.c,
 * xwayland-cursor.c (patch 0014) and test/commit-stats-test.c.
 */
#ifndef XWAYLAND_KGSL_COMMIT_STATS_H
#define XWAYLAND_KGSL_COMMIT_STATS_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define XWL_KGSL_COMMIT_PERIOD_US (30ull * 1000 * 1000)

enum xwl_kgsl_commit_site {
    XWL_COMMIT_FLIP,          /* xwl_present_flip: a client buffer attached */
    XWL_COMMIT_POST_DAMAGE,   /* xwl_screen_post_damage: the window's own buffer */
    XWL_COMMIT_POINTER_HINT,  /* xwl_seat_emulate_pointer_warp: a locked pointer's cursor position hint */
    XWL_COMMIT_INPUT_SHAPE,   /* xwl_set_shape: an input shape */
    XWL_COMMIT_SURFACE_ID,    /* send_surface_id_event_serial / xwayland_shell association */
    XWL_COMMIT_CONFIGURE,     /* xdg/libdecor configure, fullscreen, scale changes, root surface */
    XWL_COMMIT_CURSOR,        /* the pointer cursor's own surface */
    XWL_COMMIT_COUNT
};

static const char *const xwl_kgsl_commit_names[XWL_COMMIT_COUNT] = {
    "flip", "post-damage", "pointer-hint", "input-shape", "surface-id", "configure", "cursor"
};

struct xwl_kgsl_commit_stats {
    uint64_t period_start_us;               /* 0: not started */
    unsigned commits[XWL_COMMIT_COUNT];
    unsigned damaged[XWL_COMMIT_COUNT];     /* of those, with a damage request since the surface's last commit */
    unsigned frame_callbacks;               /* window frame callbacks that came back */
    unsigned frame_timeouts;                /* Present frame timers that fired (no callback in time) */
    const void *damage_surface;             /* the surface the pending damage was asked on (NULL: none) */
};

static inline void
xwl_kgsl_commit_start(struct xwl_kgsl_commit_stats *s, uint64_t now_us)
{
    if (!s->period_start_us)
        s->period_start_us = now_us ? now_us : 1;
}

static inline void
xwl_kgsl_commit_note_damage(struct xwl_kgsl_commit_stats *s, const void *surface)
{
    s->damage_surface = surface;
}

static inline void
xwl_kgsl_commit_note(struct xwl_kgsl_commit_stats *s, enum xwl_kgsl_commit_site site, const void *surface,
                     uint64_t now_us)
{
    xwl_kgsl_commit_start(s, now_us);
    if ((unsigned) site >= XWL_COMMIT_COUNT)
        site = XWL_COMMIT_CONFIGURE;
    s->commits[site]++;
    if (surface && s->damage_surface == surface) {
        s->damaged[site]++;
        s->damage_surface = NULL;
    }
}

static inline void
xwl_kgsl_commit_note_frame(struct xwl_kgsl_commit_stats *s, int timed_out, uint64_t now_us)
{
    xwl_kgsl_commit_start(s, now_us);
    if (timed_out)
        s->frame_timeouts++;
    else
        s->frame_callbacks++;
}

/* The period's line into buf once 30 s have gone by (then a new period starts); 0 = nothing to say yet. */
static inline int
xwl_kgsl_commit_line(struct xwl_kgsl_commit_stats *s, uint64_t now_us, char *buf, size_t len)
{
    unsigned total = 0, damaged = 0, i;
    size_t n;

    for (i = 0; i < XWL_COMMIT_COUNT; i++) {
        total += s->commits[i];
        damaged += s->damaged[i];
    }
    if (!s->period_start_us || now_us - s->period_start_us < XWL_KGSL_COMMIT_PERIOD_US ||
        !(total + s->frame_callbacks + s->frame_timeouts))
        return 0;
    n = (size_t) snprintf(buf, len, "Xwayland KGSL: last %us: %u surface commits (%u with damage):",
                          (unsigned) ((now_us - s->period_start_us) / 1000000), total, damaged);
    for (i = 0; i < XWL_COMMIT_COUNT && n < len; i++)
        if (s->commits[i])
            n += (size_t) snprintf(buf + n, len - n, " %s=%u/%u", xwl_kgsl_commit_names[i], s->commits[i],
                                   s->damaged[i]);
    if (n < len)
        n += (size_t) snprintf(buf + n, len - n, "; frame callbacks %u, frame timeouts %u\n", s->frame_callbacks,
                               s->frame_timeouts);
    memset(s, 0, sizeof(*s));
    s->period_start_us = now_us;
    return 1;
}

#ifndef XWL_KGSL_COMMIT_STATS_NO_GLOBAL
extern struct xwl_kgsl_commit_stats xwl_kgsl_commits;   /* xwayland-screen.c */
/* A wl_surface.commit counted for its site (a statement: safe under an unbraced if/else). */
#define XWL_KGSL_SURFACE_COMMIT(site, surface) do { \
        xwl_kgsl_commit_note(&xwl_kgsl_commits, (site), (surface), GetTimeInMicros()); \
        wl_surface_commit(surface); \
    } while (0)
#endif

#endif
