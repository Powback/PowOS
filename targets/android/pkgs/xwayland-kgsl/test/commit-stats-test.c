/* test/run.sh: patch 0014's per-30 s surface commit line (xwayland-kgsl-commit-stats.h). */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#define XWL_KGSL_COMMIT_STATS_NO_GLOBAL
#include "../xwayland-kgsl-commit-stats.h"

int main(void)
{
    struct xwl_kgsl_commit_stats s;
    char line[512];
    int game, cursor, i;

    memset(&s, 0, sizeof(s));
    /* nothing counted: no line, even after 30 s */
    assert(!xwl_kgsl_commit_line(&s, 31000000, line, sizeof(line)));

    for (i = 0; i < 900; i++) {
        /* a flip: damage then commit on the game's surface */
        xwl_kgsl_commit_note_damage(&s, &game);
        xwl_kgsl_commit_note(&s, XWL_COMMIT_FLIP, &game, 1000000 + i);
        /* a hint-only commit carries no damage */
        xwl_kgsl_commit_note(&s, XWL_COMMIT_POINTER_HINT, &game, 1000000 + i);
        xwl_kgsl_commit_note_frame(&s, 0, 1000000 + i);
    }
    /* damage on the cursor doesn't count for a window commit, and is kept for the cursor's own */
    xwl_kgsl_commit_note_damage(&s, &cursor);
    xwl_kgsl_commit_note(&s, XWL_COMMIT_POST_DAMAGE, &game, 1000000);
    xwl_kgsl_commit_note(&s, XWL_COMMIT_CURSOR, &cursor, 1000000);
    xwl_kgsl_commit_note(&s, (enum xwl_kgsl_commit_site) 99, NULL, 1000000);   /* out of range: configure */
    xwl_kgsl_commit_note_frame(&s, 1, 1000000);
    /* under 30 s: nothing yet */
    assert(!xwl_kgsl_commit_line(&s, 20000000, line, sizeof(line)));
    assert(xwl_kgsl_commit_line(&s, 31000000, line, sizeof(line)));
    assert(strcmp(line, "Xwayland KGSL: last 30s: 1803 surface commits (901 with damage): flip=900/900 "
                        "post-damage=1/0 pointer-hint=900/0 configure=1/0 cursor=1/1; frame callbacks 900, "
                        "frame timeouts 1\n") == 0);
    /* a new period started, empty */
    assert(s.commits[XWL_COMMIT_FLIP] == 0 && s.period_start_us == 31000000);
    assert(!xwl_kgsl_commit_line(&s, 62000000, line, sizeof(line)));
    puts("commit-stats ok");
    return 0;
}
