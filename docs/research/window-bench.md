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

## 11-10 budget: four parts, each with its own clock (agent/windows-epic)

Every queued run since 11-07 ended `FAIL timeout` (300 s) without a verdict: the full bench (storm + per-app gestures +
rotate + fold + five) needs ~2x the budget, and each never-live launch in the storm waited the full 20 s. The bench
now runs as `--round R --part K --of 4` (1 storm | 2 open gestures switch close | 3 open rotate fold close | 4 five;
`--phases "..."` picks any set), same round folder. Each part keeps its own clock (`BENCH_BUDGET_S`, 255 s): a phase
that would start past it FAILs naming it, the storm stops starting cycles at it (FAIL "k of N cycles"), and three
never-live launches in a row end the storm (FAIL). Every part ends with a verdict, PASS or a named FAIL.

## 11-10 close-host and the part 1/2 timeouts (agent/close-host)

- **close-host 1.5-3 s was the check, not the close.** p1 part 3 (05:38-05:39): calc's touch reached the app at
  05:38:51.556 (PowosShade), the host closed window 10 at .566 and task 3246 was removed at .594: 38 ms touch to task
  gone; settings 05:39:02.235 -> .275, 40 ms; Linux windows: KWin quit and "4/4" in 1 ms. The bench started its clock
  on the Mac before `tap` (offpill's `dumpsys window windows` + `input tap`'s start) and polled `webwindows.list` from
  the Mac, each poll a CDP hop of 2-8 s at Mac load 35. Now timed in the page: pointerdown -> the host's list (the
  bridge, ~10 ms a call) no longer has it (`arm_js`/`hostgone`).
- **Storm close "-" every cycle:** the page's 2 s limit ran from the arming, and offpill + `input tap` took > 2 s.
  The limit now runs from the pointerdown (tier1 `test-window-bench-arm.sh`, control included).
- **Part 1 timeout:** a storm cycle took 58 s (switch/close each polled up to 10 times, a CDP hop each) and the fixed
  25 s left for the after step was 70+ s short. Reads are one waiting page call; the room kept is 2x the measured
  leak count + 15 s, and a cycle starts only when the last cycle's length fits.
- **Part 2 timeout:** five gesture rounds of 35-50 s each; `phase` checked only the phase's start. `room` now checks
  each open/gestures/close item against the last one's length and FAILs "out of budget" instead of a 300 s kill.
- **p2 part 2 (47ddb09c, 06:28-06:33) still killed:** the guards worked (gestures settings and close FAILed "out of
  budget"), but the work ended 257 s in and the end (restore, end shot, layout check, publish) took > 43 s. Now: soft
  budget 210 s, a watchdog at 275 s that kills the running call tree and ends the part with a FAIL (tier1 checks it
  stops a 30 s call), and six parts (`--of 6`, gestures split over two). Its 17 FAILs: open-drawn x3 and resize-settle
  x2 are Mac-clock screencap polls (8.7-10.9 s); drag/resize fps 30-44 and p95 50-100 ms x8 ran beside Broforce
  (p1 without a game: 58-95 fps), so not judged; switch "-" x2 (the reason is now logged); out of budget x2.
- **open-drawn and resize-settle on the phone clock (agent/close-host, round 3):** `wb-drawn.sh` runs on the phone,
  started before the action; the page logs `wb-go <tag> <epoch ms> <rect>` (open: at live; resize: two frames after the
  pointerup) and the watcher screenshots that rect (screencap + `window-render.py drawn` in the chroot, ~0.3 s a round,
  first live try 105 ms) until it is a picture; the bench reads one line. Mac load no longer enters either number.
- **A game up is noticed by every check:** `game-lib.sh` (`game_up`: Steam's `reaper SteamLaunch AppId=`, the queue's
  test) replaces `steam_app_` (missed Broforce, p2) and the per-script `SteamLaunch AppId=` counts.
- **p3 part 1 "leaks" were the storm's own missed taps:** baseline 0 0 0 0, then switch/close "not within 2000 ms of
  the tap" in cycles 3, 6, 10, 12 left windows 8 and 11 open (host 2, layers 5, tasks 1). The bar's left quarter and the
  close button's centre lay under the window opened a moment before. Taps now go to an uncovered spot (`vispt`,
  elementFromPoint); a close that still misses is the close metric's "-" and the host closes it (logged), so the leak
  counts measure real leaks. Windows up before the bench are named in a NOTE and left alone (the queue closes a killed
  job's own: `ww_close_new`).
- **p3 rotate 23-30 s / unfold 33 s were the check's clock, not the product:** logcat 09:15:13.370 "screen 2440x2268"
  -> home laid out at .534 (164 ms), no window errors after; the next rotation came 32 s later because `settle_all`
  polled per window a host call, a page call and a Mac screenshot (2-8 s each). Not wb-drawn (rotate never used it).
  Now `rot_arm`: the page waits for the new size, every bench window live and still for 3 frames, and logs their rects;
  `wb-drawn.sh` (started in the same phone call as the rotation / unfold, its start the clock) waits until every rect is
  drawn (`window-render.py drawnall`). KWin 3.78's rotation sizing is untested by this run (the APK was c669f861).
- **Storm close "-" in all 20 cycles (p3 09:24):** `vispt`'s elementFromPoint found no spot even with nothing covering
  the window; it now tests geometry (no window at or above its z-index covers the spot).
- **leak-ww-layers 2 with 0 windows left:** read again for up to 10 s and named in `leak-layers.txt` (a late release
  vs a real leak; the names say whose).
- Environment, not fixed here: one CDP eval is 2-8 s at Mac load ~35, setup (unfold, lock, home) took 2 min of
  part 1, and `drawn`/resize-settle are Mac-clock screencap polls (inflated the same way).

## 11-10 baseline (WINDOWS_FIX_PLAN.md 0.5, 0.6): every window check's last verdict

Read from the verify queue (`~/.cache/powos-verify-queue/runner.log` and `done/*.log`), 11-07..11-10. No window check
has a PASS on the phone in that span. Kind (0.6): **real** = the bug the check exists for, **check** = the check
itself, **env** = the phone/session at the time.

| check | board task | last result | kind | why |
|---|---|---|---|---|
| `ww-clamp.sh` | a-window-can-land-out-of-bounds | 11-10 02:20 FAIL timeout | check | open judged ok; then home's page answered nothing for the screen size ("no bar point (544 448) or screen size") and the cleanup ran past 300 s |
| `ww-stop.sh` | linux-web-window-stop-takes-2-1-s | 11-10 02:05 FAIL timeout | check | it runs all of `window-render --hidden`; the Android step (Calculator on a hidden display, "never mirrored") timed out at 210 s before the Linux step, so the Linux stop was never measured. The hidden-mirror hang may be a real bug of its own |
| `switcher-launch.sh` | launch-closes-overview | 11-10 02:13 FAIL timeout | check/env | no output after the build header for 300 s: home's page calls hang inside `wwc_start` |
| `plasma-modes.sh` | plasma-down | 11-10 01:3x FAIL timeout | check/env | home's `apps.launch` answered empty (kwin 3.74 running), then a touch-IRQ read hung |
| `window-task-ime.sh` | linux-apps-opened-as-their-own-task | 11-10 02:31 SKIP | env | the running KWin has no window-ime cap (0043 not in the session) |
| `kwin-hung-client.sh` | a-hung-game-crashes-kwin | 11-09 SKIP (ENV) | env | no `kwin_wayland` running at check time |
| `ww-popups.sh` | native-windows | 11-08 FAIL precondition, then SKIP folded | check/env | setup failed three times with the phone idle; then the phone was folded |
| `ww-resize.sh` | native-windows | 11-07 FAIL rc=1, then rc 3 (early) x5 | check | 11-07: `wwpt: command not found`; per-app jobs (kate, dolphin, calc, with resize-trace.py) queued 11-10 01:09, no verdict yet |
| `window-bench.sh` | window-handling-benchmark | 11-08 FAIL timeout (x9) | check | the full bench needed ~2x the budget; split into 4 parts 11-10 (above), parts queued 11-10 02:50 |
| `ww-opens.sh`, `ww-close-min.sh`, `ww-popup-x11.sh` | (three tasks) | queued 11-09 17:2x, rc 3 (touched/early) | - | no verdict yet: the user's phone was in use in every window |
| `ww-glue.sh` | native-windows | none since 11-08 | - | queued 11-10 02:5x |

Common cause of the check/env rows on 11-10's build 73df319d: **home's page stops answering CDP calls in the runner's
window** (an empty reply or a hang): ww-clamp, switcher-launch and plasma-modes all stop there. This is the first thing
to fix for phase 0's "done when" (a verdict within the budget), before any window bug can be judged.

Numbers (`pf=`, `lag=`, missed vsyncs per resize, the perfetto verdict from `resize-trace.py`): none yet - they come
from the queued `ww-resize` per-app jobs and window-bench parts 2-3; this section gets them when they land.

The emulator lane (plan 0.2) ran no job since 10-28: nobody queued one (`queue.sh add --dev emu` starts its runner;
two jobs of 10-28 still wait). Its lock also held "1 dead-holder", left in the real `~/.cache/powos-emu.lock` by
`test/tier1/test-emu-lock.sh`; on the Mac pid 1 fails `kill -0` (EPERM) so it was reclaimed, but as root it would block.
Hardened on agent/windows-p0 (pid 1 / junk is never a holder; the test uses a private cache dir).
