/* test/run.sh: patch 0013's per-30 s flip/copy line (xwayland-kgsl-flip-stats.h). */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../xwayland-kgsl-flip-stats.h"

int main(void)
{
    struct xwl_kgsl_flip_stats s;
    char line[384];
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
    assert(strstr(line, " 0 Present flips, 12 copies unchecked=1 no-window=1 offset/valid=1 size=1 not-dri3=1"));
    assert(strstr(line, " depth=1 flip-failed=1\n"));
    puts("flip-stats ok");
    return 0;
}
