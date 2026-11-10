// kwin 0069: a task-kept full-screen window's "leave full screen" at a stale size is refused
// (src/utils/fullscreenleave.h). Built by run.sh against the src-tree.sh tree, no Qt.
#include "fullscreenleave.h"
#include <cassert>
#include <cstdio>

using KWin::FullScreenLeave::staleSize;

int main()
{
    const double s = 2.25; // the Open's inner screen: 2268x2440 px = 1008x1084.44 logical
    // unfold from folded portrait: the window is still the cover's 1116x2484 px (496x1104 logical at 2.25) -> kept
    assert(staleSize(true, 496, 1104, 1008, 2440 / s, s));
    // the window already the task's new size, the root not yet: also stale (the other order)
    assert(staleSize(true, 1008, 2440 / s, 496, 1104, s));
    // rotated: landscape window in a portrait root
    assert(staleSize(true, 2440 / s, 1008, 1008, 2440 / s, s));
    // the game's own windowed toggle: it still covers its screen when it asks -> it leaves
    assert(!staleSize(true, 1008, 2440 / s, 1008, 2440 / s, s));
    // 0065's rounding: 1084 logical (2439 px) on a 1084.44 screen is the screen
    assert(!staleSize(true, 1008, 1084, 1008, 2440 / s, s));
    // two device px off is a size of its own
    assert(staleSize(true, 1008, 1084 - 2 / s, 1008, 2440 / s, s));
    // a full screen the task doesn't keep (Plasma's, a desktop window): KWin's usual leave
    assert(!staleSize(false, 496, 1104, 1008, 2440 / s, s));
    // no output: never refused
    assert(!staleSize(true, 496, 1104, 0, 0, s));
    std::puts("fullscreenleave-test: ok");
    return 0;
}
