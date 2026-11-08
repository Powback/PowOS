// 0066's decisions (anland_task_policy.h): a new window that took the focus from a full-screen task opens in front of
// it; a restored full-screen window that has the focus and draws nothing is kicked, at most restoreKicksMax times.
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

    if (failures) {
        return 1;
    }
    std::printf("task-policy-test: ok\n");
    return 0;
}
