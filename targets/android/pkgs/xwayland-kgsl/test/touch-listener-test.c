/* PowOS 0017: a touch event with no selecting client on its listener's window (xwayland-kgsl-touch-listener.h),
 * no X server. Run: test/run.sh (Docker gcc). The case is the one in the phone's KWin log (design-qa/
 * bf-black-20261103-000740/kwin-log-fail.txt): BUG at Xi/exevents.c:1396 on Broforce's (Wine) focus flips. */
#include <stdio.h>
#include "../xwayland-kgsl-touch-listener.h"

static int fails;
#define EXPECT(cond) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); fails++; } } while (0)

int main(void)
{
    /* Wine deselected touch on its window mid-sequence (entry kept, bits zeroed): the listener is gone. */
    EXPECT(xwl_touch_classify_miss(1, 0) == XWL_TOUCH_MISS_DESELECTED);
    /* Its entry left the window's list while the resource still resolves: gone too. */
    EXPECT(xwl_touch_classify_miss(0, 0) == XWL_TOUCH_MISS_DESELECTED);
    EXPECT(xwl_touch_classify_miss(0, 1) == XWL_TOUCH_MISS_DESELECTED);
    /* A pointer-emulating listener that selects ButtonPress but not Motion: only this event is skipped. */
    EXPECT(xwl_touch_classify_miss(1, 1) == XWL_TOUCH_MISS_NOT_SELECTED);

    /* A deselected listener is rejected on a begin/update (ownership moves on or the record ends) ... */
    EXPECT(xwl_touch_should_reject(XWL_TOUCH_MISS_DESELECTED, 0, 0));
    /* ... never on a TouchEnd (the record ends anyway; a reject's own TouchEnd must not recurse) ... */
    EXPECT(!xwl_touch_should_reject(XWL_TOUCH_MISS_DESELECTED, 1, 0));
    /* ... never once it has its end, and a merely unselected event type never drops the listener. */
    EXPECT(!xwl_touch_should_reject(XWL_TOUCH_MISS_DESELECTED, 0, 1));
    EXPECT(!xwl_touch_should_reject(XWL_TOUCH_MISS_NOT_SELECTED, 0, 0));
    EXPECT(!xwl_touch_should_reject(XWL_TOUCH_MISS_NOT_SELECTED, 1, 0));

    /* Log: first of each kind, then one in every 256. */
    struct xwl_touch_miss_stats s = { 0 };
    int logged = 0;
    for (int i = 0; i < 512; i++)
        logged += xwl_touch_miss_count(&s, XWL_TOUCH_MISS_NOT_SELECTED);
    EXPECT(logged == 3 && s.not_selected == 512 && s.deselected == 0);
    EXPECT(xwl_touch_miss_count(&s, XWL_TOUCH_MISS_DESELECTED) == 1 && s.deselected == 1);
    EXPECT(xwl_touch_miss_count(&s, XWL_TOUCH_MISS_DESELECTED) == 0);

    if (fails)
        return 1;
    printf("touch-listener-test: ok\n");
    return 0;
}
