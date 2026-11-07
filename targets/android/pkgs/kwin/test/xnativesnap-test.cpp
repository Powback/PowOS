// kwin 0065: an X window within one device pixel of its output is configured to the output exactly
// (src/utils/xnativesnap.h). Built by run.sh against the src-tree.sh tree, no Qt.
#include "xnativesnap.h"
#include <cassert>
#include <cstdio>

using namespace KWin::XNativeSnap;

int main()
{
    // the Open's inner screen: 2268x2440 px at Xwayland scale 2.25 = 1008x1084.44 logical
    const Box inner = outputBox(0, 0, 1008, 2440 / 2.25, 2.25);
    assert(inner.x == 0 && inner.y == 0 && inner.w == 2268 && inner.h == 2440);
    // the rounded logical height (1084) is 2439 px: the game's window there snaps to the screen
    Box out;
    assert(snap(Box{0, 0, 2268, 2439}, inner, &out));
    assert(out.w == 2268 && out.h == 2440 && out.x == 0 && out.y == 0);
    // one px off at any edge snaps; already exact does not (nothing to do)
    assert(snap(Box{1, 0, 2267, 2440}, inner, &out) && out.w == 2268);
    assert(snap(Box{0, 0, 2269, 2441}, inner, &out) && out.h == 2440);
    assert(!snap(inner, inner, &out));
    // two px off, a floating window, a smaller one: left alone
    assert(!snap(Box{0, 0, 2268, 2438}, inner, &out));
    assert(!snap(Box{372, 151, 2268, 2440}, inner, &out));
    assert(!snap(Box{0, 0, 1116, 2484}, inner, &out));
    // the cover (exact at 2.25) and a second output at a fractional offset: edges converted, outputs abut
    const Box cover = outputBox(0, 0, 1116 / 2.25, 2484 / 2.25, 2.25);
    assert(cover.w == 1116 && cover.h == 2484);
    const Box right = outputBox(1008, 0, 1008, 2440 / 2.25, 2.25);
    assert(right.x == 2268 && right.w == 2268);
    assert(snap(Box{2268, 0, 2268, 2439}, right, &out) && out.x == 2268 && out.h == 2440);
    assert(!snap(Box{0, 0, 2268, 2439}, Box{0, 0, 0, 0}, &out));
    std::puts("xnativesnap ok");
    return 0;
}
