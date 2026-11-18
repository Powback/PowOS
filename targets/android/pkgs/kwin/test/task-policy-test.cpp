// 0066's decisions (anland_task_policy.h): a new window that took the focus from a full-screen task opens in front of
// it; a restored full-screen window that has the focus and draws nothing is kicked, at most restoreKicksMax times.
// 0068's: which undecorated window draws its own frame (no PowOS bar) and which is borderless (PowOS's bar).
#include "anland_task_policy.h"

#include <cstdio>
#include <cstdlib>

using namespace KWin::AnlandTaskPolicy;

static int failures = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

int main()
{
    // The 11-08 02:03 case: KWin's Remote Control prompt took the focus from Broforce's full-screen task.
    CHECK(opensOverFullScreen(true, true, false));
    // A window that didn't take the focus leaves the game alone (a web window as before).
    CHECK(!opensOverFullScreen(true, false, false));
    // No full-screen task: as before.
    CHECK(!opensOverFullScreen(false, true, false));
    // A second full-screen window is a game of its own.
    CHECK(!opensOverFullScreen(true, true, true));

    // Drawing: wait.
    CHECK(restoreWatch(5000, 100, true, false, 0) == RestoreWatch::Wait);
    // Focus and no commit for 3 s: kick.
    CHECK(restoreWatch(5000, 3000, true, false, 0) == RestoreWatch::Kick);
    CHECK(restoreWatch(5000, 4000, true, false, 1) == RestoreWatch::Kick);
    // A prompt in front has the focus: the game's own pause, never kicked.
    CHECK(restoreWatch(5000, 5000, false, false, 0) == RestoreWatch::Wait);
    // Still minimized (it keeps asking): wait for its task's focus.
    CHECK(restoreWatch(5000, 5000, true, true, 0) == RestoreWatch::Wait);
    // Enough kicks, or watched long enough: done.
    CHECK(restoreWatch(5000, 5000, true, false, restoreKicksMax) == RestoreWatch::Done);
    CHECK(restoreWatch(restoreWatchMs + 1, 5000, true, false, 0) == RestoreWatch::Done);

    // drawsOwnFrame(clientSideDecorated, undecoratedByHints, resizable, coversOutput, movedItself)
    // GTK / Chrome / Brave: _GTK_FRAME_EXTENTS - their own frame, whatever else.
    CHECK(drawsOwnFrame(true, true, true, false, false));
    CHECK(drawsOwnFrame(true, false, false, true, false));
    // Steam: _MOTIF_WM_HINTS no decorations, resizable, opened at its own size - its own frame.
    CHECK(drawsOwnFrame(false, true, true, false, false));
    // Broforce under Proton (Wine WS_POPUP / Unity -popupwindow), min = max size: borderless, PowOS's bar (11-08).
    CHECK(!drawsOwnFrame(false, true, false, false, false));
    // A borderless full-screen game (opened at the screen's size; Wine reports it resizable then): PowOS's bar.
    CHECK(!drawsOwnFrame(false, true, true, true, false));
    // A borderless window that drags itself by its own title bar (a fixed-size launcher): its own frame after all.
    CHECK(drawsOwnFrame(false, true, false, false, true));
    // Not undecorated by hints and no frame extents (a splash, an odd toolkit): PowOS's bar.
    CHECK(!drawsOwnFrame(false, false, true, false, false));

    // 0074: the app's own full-screen task keeps a full-screen window's geometry -> it takes the new screen with the
    // root (game-resize 11-11 03:20: Besiege on the cover, landscape -> portrait, left at 2484x1116 in a 1116x2484 root).
    CHECK(followsScreenWithRoot(false, true, true, true));
    // 0076: the game's own full-screen task (opened full screen: every Steam game) follows too - 0074 left it out and
    // game-resize 11-18 failed on it (My Friend Pedro unfolded again -> floating 1360x1707, Besiege cover portrait ->
    // Unity re-made its window 391x2484): no "size" came after the task's surface was re-made.
    CHECK(followsScreenWithRoot(true, false, true, true));
    CHECK(followsScreenWithRoot(true, true, true, true));
    // A floating task (its size is not the screen's), a window not full screen, or geometry not the task's: wait.
    CHECK(!followsScreenWithRoot(false, false, true, true));
    CHECK(!followsScreenWithRoot(false, true, false, true));
    CHECK(!followsScreenWithRoot(false, true, true, false));
    CHECK(!followsScreenWithRoot(true, false, false, true));
    CHECK(!followsScreenWithRoot(true, false, true, false));

    // 0075: a window exported over a standing full-screen task that did not take the focus is held off screen (Steam's
    // main window re-exported by the unfold's "export-new 1" went in front of My Friend Pedro, 11-18 21:55).
    CHECK(heldBehindFullScreen(true, false, false, false));
    // It took the focus (a prompt: 0066 opens it in front; the user brought its app forward): not held.
    CHECK(!heldBehindFullScreen(true, true, false, false));
    // The game's own dialog (same process as a task), or a full-screen window (a game of its own): not held.
    CHECK(!heldBehindFullScreen(true, false, true, false));
    CHECK(!heldBehindFullScreen(true, false, false, true));
    // No full-screen task stands: opens as before.
    CHECK(!heldBehindFullScreen(false, false, false, false));
    // A full-screen task stands while live, and through a fold/rotate's surface swap ("in the background" ~1 s)...
    CHECK(fullScreenTaskStands(true, -1));
    CHECK(fullScreenTaskStands(false, 0));
    CHECK(fullScreenTaskStands(false, screenSwapGraceMs - 1));
    // ...but not once it has been out of sight longer (the user went home), nor if it never was live.
    CHECK(!fullScreenTaskStands(false, screenSwapGraceMs));
    CHECK(!fullScreenTaskStands(false, -1));

    if (failures) {
        return 1;
    }
    std::printf("task-policy-test: ok\n");
    return 0;
}
