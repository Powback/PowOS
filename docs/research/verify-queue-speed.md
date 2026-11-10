# Verify queue speed: where the phone's idle time goes (2026-11-10)

User, 11-10: "debug the testing steps they should take like 3s each but to me it seems idle for so fucking long".
31 jobs queued; the OnePlus sat idle for most of the night.

## Measured (runner.log + util.log, 2026-11-09 22:00 to 11-10 04:55)

| where the time went | seconds | note |
|---|---|---|
| between windows (no check running, jobs runnable) | 8134 | 10 gaps: 225, 850, 48, 810, 2141, 1553, 642, 585, 374, 906 s |
| inside windows | 7105 | 21 verdicts on 4356 s (~207 s per verdict) |
| of which timeouts (killed at the budget) | 3307 | 10 runs, ~330 s each (switcher-launch, ww-clamp, shade, plasma-down) |
| of which precond rc 3 (setup failed, nobody touched) | 1261 | 13 runs; 4 x window-bench ~40 s on "a game runs" |
| of which touched | 533 | 4 runs |

Per call (measured 04:58, OnePlus over the VPN):

| call | before | after |
|---|---|---|
| `adb.sh shell true` (docker exec powos-vadb) | 0.11-0.28 s | same |
| `idle.sh` | 0.73 s | same |
| `cdp.sh eval home …` | 0.67 s | same |
| `user.sh <script>` (push via a throwaway container + powos-run) | 3.1-3.4 s | 1.3 s |
| `root.sh <script>` | ~3 s | 1.3 s |

So one step really is ~1-3 s; the night was lost between steps and between windows, not in them.

## Causes, biggest first

1. **A game a killed check started stayed up (900 s gap + 9 skipped games jobs + 4 x 40 s window-bench).**
   04:21:35 game-audio-flow started Broforce and was stopped at 04:22:08 (touched) inside its `sleep 40`; its own
   `bf-stop.sh` never ran. idle.sh then treats a running game as the user playing for `GAME_IDLE_S` (900 s): the next
   window came at 04:37:12 = 04:22:08 + 904 s, as "game=away" - nine games jobs skipped, and window-bench parts 1-4
   each did their unfold/lock/home setup (~40 s) before "SKIP: [setup] a game runs: not now" (rc 3 precond).
2. **The window ran on the user's 30 s screen-off timeout.** The 04:20 wake set the timeout to 30 min, the 04:22 touch
   restored the user's 30 s, and the 04:37 window found the screen already on, so nothing held it. At 04:46:58 it
   dozed between checks (`mLastSleepReason=timeout`): ww-clamp said "home: screen not on (Dozing)" (rc 3 early), and the
   panels' suspend moved the touch IRQ counters at 04:47:00, which the touch watcher read as a finger. The runner saw
   idle < 120 s, ended the window with 25 jobs runnable and started waiting for `WAKE_IDLE_S` (600 s) again.
   **That is the 04:47:16 silence: the runner was alive (pid 15151, in `idle.sh --wait 120 180`), not stuck.**
3. **Every window entry paid 180 + 120 s at least.** window_lock only tried `wl_wake` after a whole 180 s chunk had
   timed out, and idle.sh's "Awake for IDLE_S" streak started at each `--wait` call's first look, not at the
   screen's real wake: even a screen the queue itself had just woken (or one on for an hour) waited another 120 s.
4. **user.sh/root.sh pushed their script through a throwaway container** (adb.sh's `docker create/cp/start` path for
   files outside $HOME, e.g. ww_us's mktemp): ~1.7 s of each ~3 s call; window checks make dozens.
5. Fixed sleeps in wwc-lib: 3 s after an unfold, 1.5 s after the closes (now polled).
6. Timeouts: switcher-launch / ww-clamp burnt 300 s budgets on a hidden home page; already fixed in 7e9e7890 (CDP
   bounds, 230 s step deadline) which the runner picked up at 04:54.

## Fixes (agent/queue-speed)

- `queue.sh`: `game_up` before every games job; after it (any end: verdict, rc 3, touched, timeout, stop) a game that
  wasn't running before and wasn't handed on warm is closed (`game_left` -> `warm_stop`). A failed adb read is never
  read as "no game before" (no risk of closing the user's game).
- `window-lock.sh`: `wl_hold` - a window that finds the screen on saves the user's timeout and holds it at 30 min,
  restored at the window's end (`wl_sleep`, as for a woken phone; runner.log says "held the screen on for N jobs").
  `wl_wake` is tried before every wait, in 60 s chunks (`WL_CHUNK_S`), and writes `powos-queuewake`; the
  keyguard dismiss polls Awake instead of `sleep 1`.
- `idle.sh`: the Awake streak counts from `mLastWakeTime`, and a wake that is the queue's own counts as served. The
  touch watcher (V=4) masks a screen-off by timeout (it is not a finger).
- `user.sh` / `root.sh`: the script goes over the adb shell's stdin - one adb call, no container.
- `wwc-lib.sh`: unfold and close waits polled at 0.25-0.5 s.

## Expected after

- Between windows with nobody on the phone: was >= 300 s (180 s chunk + 120 s streak), often 600-900 s; now the
  wake comes at the first look and the streak is served: ~5 s (one `idle.sh`, the wake, one held-connection sample).
- No 900 s game-away window caused by the queue's own game; games jobs and window-bench run instead of skipping.
- No mid-window doze, so no fake touch ending the window.
- Per step: user.sh/root.sh 3.2 -> 1.3 s; a wwc check's fixed waits -3.5 s.
- Per verdict: tonight ~207 s of window time (timeouts dominate); with 7e9e7890's deadlines and the precond loops
  gone, the small window checks should land at their own run time (ww-close-min 60 s, progress-notify 28 s) - the
  hourly utilization line in runner.log is the measure to compare next night.

Not changed: `WAKE_IDLE_S` (600 s after a real touch, the user's rule) and `GAME_IDLE_S` for a game the user started.

## E2E journey steps: per-step time, before and after (2026-11-10)

Round 252 of `e2e-desktop.sh` (board `manager-end-to-end-user-journeys-on-the-phone-qa`): parts 1 and 2 were killed
by the queue at 450 s with every step passing; part 3 passed in 180 s. The logs had no timestamps, so the per-step
times below come from the screenshots' mtimes on the phone (`ls --full-time .../design-qa/e2e-desktop/252/`).

**Before** (Mac load 14-24):

| part | setup (job start -> first shot) | per step |
|---|---|---|
| 1 | 93 s | 97, 33, 29, 69, 46, 40 s (7 steps by 08:02:23; killed in step 8's put-away at 450 s) |
| 2 | 61 s | 37, 68, 48, 17, 9, 8, 10, 14, 13, 40, 30, 20, 17, 12, 11, 16, 16 s (killed at step 44's close) |
| 3 | 29 s | 13, 17, 10, 12, 23, 14, 28, 6, 19 s |

Where it went (measured on the Mac at load ~24, read-only calls):

| call | cost | per step |
|---|---|---|
| `ev`/`hcall` (cdp.sh: adb.sh devtools lookup + adb.sh forward + warm-runner `docker inspect` + `docker exec bun` + python3) | 1.1-3.2 s | 5-20 calls (`win`, `waitwin` polls, `winrects`, `freept`, `put_away`'s 4 list reads) = 10-40 s |
| step screenshot (`shot.sh --phone`: 2 adb calls; on the phone `screencap -p` ~2 s + a raw screencap + `dumpsys window`) | 3-4 s | 1 |
| touch guard (`touched` = `useract`, an adb `dumpsys power` round trip) at every `chk` and `step` | 0.7-1.5 s | 2-4 = 2-5 s |
| fixed settle sleeps (`sleep 1.2..3` after each input) | 1-3 s | 1-3 |

So a step was 80-90 % Mac-side process/docker round trips around a phone that had long finished.

**Changes** (generic, every e2e journey and every `cdp.sh` user):

- `cdp.sh`: the devtools forward is cached (`CDP_FWD_CACHE_S`, 60 s, in `~/.cache/powos-cdp/fwd.<port>`); `cdp.ts`
  exits 3 when its endpoint doesn't answer (a new app pid) and only then is the forward made afresh and the call run
  again. `cdp-warm.sh`: the container check (`docker inspect`) once per `CDP_WARM_OK_S` (30 s), retried on a missing
  container. Measured: an eval **1.1-1.5 s -> 0.2 s** (cached path).
- `shot.sh --phone --bg`: the capture runs in the background ON the phone (one adb call, **0.6 s** instead of 3-4 s);
  its verdict goes to `<dir>/.shots`, and `e2e-lib.sh` merges blank/refused verdicts into steps.txt at publish.
- `e2e-lib.sh`: every injected input (`tap/swipe/press/mdown/mmove/mup/mpath` via `inj`) checks the touch watch's
  count on the phone in the same adb call, so the separate `touched` read runs at most every 8 s
  (`E2E_TOUCH_EVERY_S`). `waitwin` polls every 0.3 s; the fixed `sleep 3`/`2.5` before `waitwin` polls are gone.
- Timestamps: every step line in the queue log reads `-- NN-step.png: ... [+<s since the last step> s, t=<s> s]`.
- Budget: `queue.sh` exports `QUEUE_BUDGET_S`; no step or input starts after budget - 40 s (`E2E_RESERVE_S`); a
  watchdog TERMs whatever Mac call is blocked at that moment; the part ends with `FAIL ... out of budget at step X`,
  its restore closes what it opened and steps.txt is published (no more queue kill mid-step). If a part still can't
  fit, raise `--of`.

**After** (expected from the measured call costs; the next queued round's `[+N s]` lines are the measurement):
a step of ~8 page reads + 1 shot + 1-2 inputs + its settle sleep: ~4 s + 0.6 + 1.5 + 1.5 = **~6-8 s at load ~24,
3-5 s at a quiet Mac** (was 10-97 s). Part 1 (25 steps) fits 410 s even at the worst measured step costs of part 3.
