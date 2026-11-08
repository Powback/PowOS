# Window bench (11-07)

The user, 11-07 00:2x: "we really need to benchmark and fix all the window handling", "it feels very bugged
sometimes", "focus on performance atm", "no windows not loading etc"; and later: "it means rapidly opening and
closing apps seeing how responsive everything is measuring framedrops etc".

## The bench

- `tools/phone/verify/window-bench.sh` (verify queue, idle window). First the storm: STRESS_N (20) open/switch/close
  cycles at user speed over Kate, Dolphin, Konsole, Calculator and Settings, with per-cycle tap->frame, tap->live, switch
  and close->gone times, home's dropped and janky frames plus p95/p99 (rAF, marked per cycle), gfxinfo, leaks (page/host
  windows, ww layers, tasks, PSS) and slowdown (last third / first third). Then each app on its own: open
  (frame/live/drawn), the not-loading detector (live but flat for > 3 s, or never live in 20 s), drag and resize
  fps/p95, resize settle, switch, maximise/restore, rotate, fold/unfold settle, five at once and close. Each one has a
  budget. Output goes to `bench.tsv` and `storm.tsv` in the run's OUT, with window, KWin and logcat logs.
- Gate `ww-bench-unfolded` (WB1-WB4, shell/dev/gate.mjs) covers the page side: placeholder frame, live, maximise/restore
  settle and close, each frame-timed. It PASSes.

## Before: window log on the phone, 11-01..11-07 (9574 lines, read-only)

| what | n | p50 | p90 / max |
|---|---|---|---|
| Android open -> shown, display helper cold-started by that open | 36 | 1055 ms | 2774 ms p90 |
| Android open -> shown, helper already running | 85 | 367 ms | 710 ms p90 |
| Linux "as a web window" -> live (Dolphin) | 29 | 258 ms | 449 ms max |
| Linux -> live (Kate) | 17 | 256 ms | 3920 ms max |
| close, 1/4 -> 4/4 layers | 325 | 1 ms | 6 ms max |
| opens logged "slow, over 1000 ms" | 32 of 355 | | |
| RENDER STALL rebinds | 11 | | (home-perf-swipe fde3e890 owns this) |

Linux "live" was consumer up + 250 ms, so it was never a frame (see below). That is why the Linux live times are a flat
~255 ms.

## Fixed (agent/window-bench)

1. **Windows not loading / live but blank** (Dolphin 11-06 16:46). The window log shows `consumer up` and then `live`
   270 ms later, with no frame logged. Live was declared on a timer, so the page dropped the placeholder over a content
   layer that had no buffer yet, which shows as an empty hole. Now live = the consumer's first present (`FirstFrame`,
   `WebWindowSource.presented` -> `nativeWindowPresents`). If no frame comes within 1.5 s, KWin is asked to lay the
   window out again (HACK, registry row). If none comes at 25 s the wait ends and the page's LINUX_START says "never
   drew" with a close button. The log now has "first frame N ms after its consumer came up, M ms after open".
2. **Slowest open step**: the display helper's app_process start (~0.7-2 s) landed on the first Android window after
   every app start (30% of opens). It is now started 3 s after home's page starts unfolded, and whenever the page asks
   `webwindows.enabled` (`WebWindows.warmHelper`).

## After

Owed: the phone run (queued 00:26, job 20261107-002605-58023) and a second run after the APK ships.

## 11-08 storm: "NOT LOADING storm 6 kate / 7 dolphin / 9 calc" (agent/storm-popups)

Not the launch path. Every failing app was one whose close in an earlier cycle had missed: logcat has no `close window
21/22/24` for Kate/Dolphin/Calculator at their storm closes, and cycle 5's close tap on Calculator closed Settings (25)
instead. With the old window still up, the next launch only raised it (one app, one window), so the bench saw no new
window and waited 20 s. Two causes:

1. **Product (RZ7)**: cascaded windows sit 32 dp apart, exactly a resize zone's depth, so the newer window's invisible
   top zone covered the whole visible strip of the window under it - its bar and its close button. A tap there grabbed
   the newer window. Now a press on an outer zone that lands on another window's frame is that window's: a button there
   is pressed, else that window comes on top (`zonePassedOn`, ui/webwindows.tsx). Gate: desktops `grabCascade` (fails
   without the fix: "left it open", "left 907 on top").
2. **Bench**: the storm passed bare ids to `barpt`, which took its uiautomator path, so every switch was "-" and the
   lower window was never raised before its close; the close readout was taken once at 0.25 s ("null"). Now `w<id>`, the
   readouts poll up to 2.5 s, and a launch that only raised a window from before fails at 1.5 s saying so.

## 11-08 ww-popups: "no click on Steam's menu bar opened a menu"

ww-popups clicked with xdotool. Its XTEST goes through Xwayland's EIS, and KWin answers that with a "Remote Control"
prompt (`org.kde.kwin.eisprompter` in KWin's log, the same as broforce-fps.md 11-08) that shows in a web window nobody
answers, so no click arrived. The check now taps the way a finger does (`input tap` at the X point times the window's
scale, the user's path for "steam menus") and dismisses menus with a tap on an empty spot of the page, so it uses no X
input at all.
