/* test/run.sh: patch 0013's per-30 s flip/copy line and 0018's first size refusal (xwayland-kgsl-flip-stats.h). */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../xwayland-kgsl-flip-stats.h"

int main(void)
{
    struct xwl_kgsl_flip_stats s;
    char line[768];
    int i;

    memset(&s, 0, sizeof(s));
    /* nothing counted: no line, even after 30 s */
    assert(!xwl_kgsl_flip_line(&s, 31000000, line, sizeof(line)));

    for (i = 0; i < 1100; i++)
        xwl_kgsl_flip_note_flip(&s, 1000000 + i);
    xwl_kgsl_flip_note_copy(&s, XWL_NOFLIP_TOPLEVEL, 1000000);
    xwl_kgsl_flip_note_copy(&s, XWL_NOFLIP_TOPLEVEL, 1000000);
    xwl_kgsl_flip_note_copy(&s, XWL_NOFLIP_UNCHECKED, 1000000);
    xwl_kgsl_flip_note_copy(&s, (enum xwl_kgsl_noflip) 99, 1000000);   /* out of range counts as unchecked */
    /* under 30 s: nothing yet */
    assert(!xwl_kgsl_flip_line(&s, 20000000, line, sizeof(line)));
    assert(xwl_kgsl_flip_line(&s, 31000000, line, sizeof(line)));
    assert(strcmp(line, "Xwayland KGSL: last 30s: 1100 Present flips, 4 copies unchecked=2 toplevel=2\n") == 0);
    /* a new period started, empty */
    assert(s.flips == 0 && s.period_start_us == 31000000);
    assert(!xwl_kgsl_flip_line(&s, 62000000, line, sizeof(line)));

    /* copies only: every reason name prints */
    for (i = 0; i < XWL_NOFLIP_COUNT; i++)
        xwl_kgsl_flip_note_copy(&s, (enum xwl_kgsl_noflip) i, 62000000);
    assert(xwl_kgsl_flip_line(&s, 93000000, line, sizeof(line)));
    assert(strstr(line, " 0 Present flips, 13 copies unchecked=1 no-window=1 offset/valid=1 size=1 not-dri3=1"));
    assert(strstr(line, " redirected=1 surface-size=1 sync=1 depth=1 flip-failed=1\n"));
    assert(!strstr(line, "refusal"));   /* no geometry recorded: one line only */

    /* 0018: the period's first size refusal is kept with both windows' shapes, later ones only counted */
    {
        struct xwl_kgsl_flip_refusal r = {
            .why = XWL_NOFLIP_TOPLEVEL, .depth = 1,
            .present = { 0x1600005, 0, 0, 2268, 2439, 0, 0, 2268, 2439, 1 },
            .top = { 0x1600003, 0, 0, 2268, 2440, 0, 0, 2268, 2440, 1 },
        };
        struct xwl_kgsl_flip_refusal later = r;
        struct xwl_kgsl_flip_refusal none = { .why = XWL_NOFLIP_UNCHECKED };

        xwl_kgsl_flip_note_refusal(&s, &none);          /* "nothing" never takes the slot */
        assert(s.refusal.why == XWL_NOFLIP_UNCHECKED);
        xwl_kgsl_flip_note_copy(&s, XWL_NOFLIP_TOPLEVEL, 93000000);
        xwl_kgsl_flip_note_refusal(&s, &r);
        later.why = XWL_NOFLIP_SURFACE_SIZE;
        later.present.h = 5;
        xwl_kgsl_flip_note_copy(&s, XWL_NOFLIP_SURFACE_SIZE, 93000000);
        xwl_kgsl_flip_note_refusal(&s, &later);
        assert(xwl_kgsl_flip_line(&s, 124000000, line, sizeof(line)));
        assert(strcmp(line, "Xwayland KGSL: last 31s: 0 Present flips, 2 copies toplevel=1 surface-size=1\n"
                            "Xwayland KGSL: first toplevel refusal: present window 0x1600005 2268x2439+0+0 region "
                            "0,0-2268,2439 (1 rect), 1 level below toplevel 0x1600003 2268x2440+0+0 region "
                            "0,0-2268,2440 (1 rect)\n") == 0);
        /* reset with the period */
        assert(s.refusal.why == XWL_NOFLIP_UNCHECKED);
    }
    puts("flip-stats ok");
    return 0;
}
