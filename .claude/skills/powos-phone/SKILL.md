---
name: powos-phone
description: Use to reach, inspect, ship to, verify, or measure perf on the PowOS phone (OnePlus Open) or emulator - adb/root/idle/cdp, the locked ship/ship-apk queue, device verify checks (gesture journeys, frame-stepping, Broforce, idle CPU), and phone perf (frames/paints, blur cost, WebView traces).
---

## Quick recipe
- Files: `tools/phone/{adb,root,user,idle,cdp,ship,ship-apk,shot,cpu,idle-sample,review-image,app-src,bindings-check,bridge-check}.sh`
  (one adb call each), `tools/phone/verify/*.sh` (131 checks, header says where it runs), `queue.sh`, shared libs
  `e2e-lib.sh`/`bf-lib.sh`.
- Build: n/a (bash checks, no compile step); this skill is phone ACCESS/shipping/verifying/perf, not a build target.
  A check needing a fresh KWin: queue `kwin-install.sh MIN` first, same task.
- Check (emu first, then phone): `tools/phone/idle.sh` (idle=<s> screen=<state>); read-only state via
  `tools/phone/cdp.sh eval <page> '<js>'`; a real device check goes through
  `tools/phone/verify/queue.sh add [--dev emu|auto] <task> <check.sh>` (never run one by hand outside a window);
  off-queue by hand: `POWOS_DEVICE=emu LOCK_HELD=1 tools/phone/verify/<check>.sh ...`.
- Perf: `AWAKE_ONLY=1 idle.sh --wait 120 1800` then `cpu.sh [secs]`, `cdp.sh idle|raster|profile|net`, `idle-sample.sh`
  (budget ~3% of one core idle on home, screen on; 0 frames/paints/rAF at rest).
- Ship/land: `tools/agents/land.sh "msg" -- <paths> [--ship "note"] [--queue <check args>]` then END YOUR TURN.
  Never ship-apk/push/queue-wait yourself.
- Web windows on the glass: `tools/phone/verify/window-render.sh` (exit 0 PASS / 1 FAIL / 2 SKIP: user active, locked,
  folded, the test app already open). Waits for a free unfolded phone, opens Calculator through webwindows.tsx
  `openWindow` (the dock's path), screencaps the `.webwindow-body` rect: PASS needs >=35% of it to differ from the same
  rect before the open (an empty hole shows the page under it), no flat fill (dominant colour <97%, edges >=0.3%), and
  a tap dispatched on the body (Body's handler -> `webwindows.input` -> helper) to change the app's pixels (>=0.1%, >3x
  noise). Closes only its own window. Shots + log in `$WR_OUT/<stamp>/`. The ship service runs it by itself after any
  shell/APK ship touching `webwindows*`, `WebWindows*.kt`, `WebWindowLaunch.kt`, `FreeformTasks.kt`, `SystemFloat.kt`,
  `home.tsx`, `shell.css` (ship.sh `window_gate`): a FAIL = "WINDOWS BROKEN" in `ship.sh status`, the ship marked failed,
  the coder mailed - fix forward, no rollback.
- Evidence off PowOS's root: `tools/phone/pull-root.sh <path-under-/data/powos/root> <mac-dir>` (plain `adb.sh pull` there is Permission denied; it copies via `su cp` to /data/local/tmp first).
- Friction: `tools/agents/friction add --area phone --kind <refused|broken-tool|flaky-check|unclear-rule|slow> "<title>" --repro "<cmd>"`.

### verify
- `queue.sh add --dev emu <task> <check.sh> [args]` (or `--dev auto`: the check's `# lanes:` header picks); phone-only checks (games/fold/kernel/Linux session) refuse `--dev emu`.
- Friction: `tools/agents/friction add --area verify --kind <flaky-check|unclear-rule|...> "<title>" --repro "<cmd>"`.

## powos-phone



Read `docs/AGENT-HANDBOOK.md` (repo root) first - it is the map of how the phone pieces connect, who owns what, and
the cross-cutting rules (Shipping, Rules that bite). This is the short form.

Tools (repo `tools/phone/`, all one adb call each):
- `adb.sh <args>` - adb to the phone from any session (files under $HOME only).
- `root.sh <script>` / `user.sh <script>` - run a local script inside PowOS as root / as the session user.
- `idle.sh` - `idle=<s> screen=<Awake|Dozing|Asleep> act=<s>`; drive the phone only at idle>=120 and screen=Awake;
  never wake it. To WAIT: ONE `idle.sh --wait 120 MAX_S` (the wait runs on the phone) - never a polling loop;
  `AWAKE_ONLY=1` in front when you need the screen on (it otherwise also returns when the screen is off).
- `cdp.sh pages|eval <page> '<js>'|idle|raster` - WebView devtools, READ-ONLY on live pages.
- Shipping (shell or APK): commit -> rebase -> push to origin -> `ship.sh request --note "..."` (or `--silent`), then
  end your turn. ONE ship service (launchd com.powos.ship-runner) ships origin's tip after 60 s without new commits:
  ship-apk.sh if Kotlin/APK inputs changed since the installed build, else push.sh of the shell files that differ
  from what's live, all notes in one notification. `ship.sh status` = requests, live sha, last ships; `ship.sh pause|resume` holds every ship (recoveries). ship-apk.sh and
  push.sh refuse to run outside it (`--direct` = a logged emergency). `shell/push.sh --errors` = the phone's shell errors.
- Also: cpu.sh, idle-sample.sh, review-image.sh, app-src.sh, bindings-check.sh, bridge-check.sh, record/, verify/.
- `sdkmanager`/`avdmanager` need a Java the Mac doesn't have: `sdkmanager` runs inside the `android-builder`
  image (`tools/phone/compile-check.sh`, `targets/android/tools/warm-builder.sh`); `tools/emu/emu.sh create`
  sidesteps `avdmanager` entirely by writing the AVD config file by hand instead (f102).

Never: poll the phone, mutate live pages over CDP, touch real devices (lights) without the user's say, sudo via
powos-run.sh, inject input while the user is active, wake the screen, ship Kotlin you haven't compiled, push a shell
file that isn't origin's, force-push, unregistered host installs, bypass the gate, route around a permission denial.

## verify


Access and rules: the powos-phone skill (tools/phone/adb.sh, root.sh, idle.sh). This is the how-to for verifying.

Scripts: `tools/phone/verify/` (header of each says where it runs).
- Every check runs through ONE queue: `tools/phone/verify/queue.sh add <board-task> <script> [args]` (returns at once;
  the runner takes one free window for all queued checks, LOCK_HELD=1, result on the board task; `queue.sh list`).
  A Mac-side check script uses window-lock.sh (honours LOCK_HELD) and exits 3 on a real touch (re-queued).
- `add [--close] [--name TEXT] [--screen inner|cover] <task> <cmd>`: marks the task's step "phone check queued" (the AI
  page's "test now"; the result's step replaces it). The runner stays up while jobs are queued (a window that didn't
  come is waited for again) - "test now" needs one waiting. A job exiting 0 with a `^FAIL` line is a FAIL; a FAIL gets a
  screenshot (design-qa/verify-<job>.png) as the task's review image. QUEUE_IDLE_S: the idle the window needs (120).
- Test now: the page's verify.go (VerifyRun.kt) writes PowOS's /tmp/powos-verify-go (= /data/powos/root/tmp, mode 644,
  readable by adb's shell user); `VERIFY_GO=1 idle.sh --wait` returns `go=<task|all>` at its next 5 s check; the runner
  runs only those jobs and clears it. /run/powos-app is NOT readable by shell (SELinux) - flags go in /tmp.
- Status pill (VerifyRun.kt, window "PowOS verify status", TYPE 2017, skip-screenshot): the runner writes
  /run/powos-app/verify/status.json (its own folder: FileObservers on one folder share one inotify watch and the last
  started gets every event - a widget's watch on /run/powos-app once ate the pill's "done") as a heartbeat every HB_S
  (4) s while a check runs ({name,task,k,n,screen,el,budget,prev}; {done,summary} at the end -> a notification), each
  one adb call killed after 15 s. The pill ticks the elapsed time itself and hides with a "Phone test stopped"
  notification after 30 s without a beat. Its ONLY touch target is the x at its right end (AttachedSurfaceControl
  setTouchableRegion, Android 14+; the rest is touch-through): it writes /tmp/powos-verify-stop; the next beat (or the
  wait's 5 s look) sees it - injected or real, no touch-counter guard any more: the check is killed (TERM, KILL after
  5 s), stays queued, tries not counted, and the runner PAUSES (~/.cache/powos-verify-queue/paused): it stays up, its
  wait returns only for the go flag (GO_ONLY=1). pause() writes {done,paused,summary}: the pill says "Tests paused
  [Resume]" for 15 s (Resume = go=all), then only the notification + the AI page's "checks paused · resume" are left.
  While runnable checks wait for a window > 10 s (the user on the phone, a game), wait_pill writes {done,wait,n,ttl}:
  "Tests wait · phone in use" + x (ttl 200 s, rewritten every 150 s). `done:true` on both: older APKs just hide.
  The pill logs each state change (logcat PowosVerify "pill PAUSED: Tests paused [Resume]", "pill tap: stop").
  Mac: `queue.sh pause|resume`. Checks: test-now.sh, pill-stop.sh (taps x on itself, a detached asserter checks).
- Runner state for the page: /data/local/tmp/powos-verify-runner (adb's shell user's: PowOS /tmp is not writable by
  it) = waiting|paused|running|idle|stopped; idle.sh's wait (VERIFY_STATE) touches it every 5 s, phone_sh (RSTATE)
  rewrites it. Bridge verify.state (VerifyRun.state, a root stat) -> "verify.state" {state, age}; paused or age > 45 s
  -> "checks paused · resume" (hidden on hosts without verify.state).
- Sub-steps: every beat carries the check's current step + how long it has run, shown on the pill's third line (the
  json's "prev", also "step"/"stepel"): "waiting for the game window · 45 s · tap to stop" under "Testing: <check>"
  and "k of N · m:ss". The step = PowOS's /tmp/powos-verify-step if the check wrote one (plain text, as the session
  user, its mtime = its start; cleared at each job's start), else the log's last meaningful line (adb push/pull noise
  dropped, <= 60 chars). Write steps with bf-lib.sh pill(): sourced on the phone, or Mac-side as
  `BF_ADB=$A . bf-lib.sh` (only pill(), over adb) - bf-pacing/run/checker/fold do. No step: the line shows the last result.
- Budget: `add --budget S` (job file `budget=`, default 300). Past it the runner kills the check: "FAIL timeout" on
  the board, the pill's next line (prev) and the summary. A runner TERM writes done too (the pill goes at once).
- Clear a stuck pill (old APK): write `{"done":true}` to /run/powos-app/verify-status.json the way status() does.
- Test the runner off the phone - ONLY with a temp HOME and queue (a test once took the real verify lock): HOME=<tmp>
  QUEUE_DIR=<tmp> QUEUE_PHONE=<dir: stub adb.sh/user.sh/shot.sh + a copy of idle.sh> QUEUE_NO_TREE=1 (the real
  verify-runner checkout untouched) QUEUE_COPY=<any file> QUEUE_HERE=<verify dir> bash queue.sh run. The stub adb.sh
  runs `shell` commands with /data/local/tmp and /data/powos/root mapped to a temp dir, decodes phone_sh's base64 with
  /tmp/ and /run/powos-app mapped, answers dumpsys with mWakefulness=Awake, no-ops the touchmon. launchd: a test label
  (QUEUE_AGENT=<label>) whose plist sets HOME/QUEUE_* - never load a second real runner.
- Jobs run in the runner's own checkout `.claude/worktrees/verify-runner` (made if missing, node_modules linked,
  fast-forwarded - reset if dirty - to origin before each window): `add` stores cwd + command repo-relative when they
  are inside any PowOS worktree (absolute only otherwise), and old jobs with a `.claude/worktrees/*` cwd are rewritten
  at run time. So PUSH what the check needs before queueing; `worktree.sh done` right after is fine (it lists them).
- The runner execs a private temp copy of verify-runner's queue.sh (code changes land at the next runner start; a pull
  can't change it mid-run). ONE runner, ever: lock dir ~/.cache/powos-verify-queue/runner.lock (its pid; a dead pid's
  is taken over); a second `queue.sh run` exits "runner already running (pid N)".
- It runs as the launchd agent com.powos.verify-runner (unit units/mac/verify-runner-mac.json, plist + deploy
  tools/phone/verify/runner-deploy.sh install|remove|status), in the user/<uid> domain (headless Mac: no gui domain;
  LimitLoadToSessionType Background), cwd the verify-runner checkout. `queue.sh add` kickstarts it (loads it first
  after a reboot). KeepAlive SuccessfulExit=false: a kill/crash restarts it; nothing queued: it exits 0.
  WatchPaths never fired in this domain (FSEvents; dir or file) - don't rely on it. Restart on new code:
  `kill $(cat ~/.cache/powos-verify-queue/runner.pid)` (TERM trap: check stays queued, locks freed; launchd restarts
  it). Stop for a while: `launchctl bootout user/$(id -u)/com.powos.verify-runner`; remove: `runner-deploy.sh remove`.
- Mac: `journey.sh` (one wait + verify lock + gest.sh runs + pull, `RUNS="A B C D"`), `frames.sh` (gaps / sheet / overview),
  `bf-run.sh` (Broforce ~10 min check; `NO_START=1` while the user plays it themselves).
- Phone (pushed by the above, or `adb.sh push` + `su -c sh`): `gest.sh`, `cpu-sample.sh`, `bf-sample.sh`, `sf-latency.sh`;
  in the session as powos: `bf-start.sh`, `bf-stop.sh`.
- Artefacts go to `~/.cache/powos-verify/<date>` (scratch: not on the disk watchdog's list today, but put the evidence
  that matters in the report).

## Is the user there? (touch IRQs, not lastUserActivity)
- `tools/phone/idle.sh` -> `idle=<s> screen=<Awake|Dozing|Asleep> act=<s>`. `idle` = seconds since the touch panels'
  interrupt counters (`touch-00`/`touch-01` in /proc/interrupts) last moved: only a real finger moves them.
- `act` (dumpsys power lastUserActivityTime) is NOT a user signal: screen-bright wakelocks, an APK install restarting
  com.powos.app and anyone's injected input all reset it. Injected input does NOT move touch IRQs - so your own journey
  looks "idle" to IRQ-only monitors (the supervisor's IdleSample once flagged 22% CPU during a verify run: gate passive
  samples on BOTH idle>=120 and act>=120).
- Wait with one `idle.sh --wait 120 MAX_S`. Inside a journey, abort if the IRQ sum changes:
  `awk '/touch-0/{s+=$2+$3+$4+$5+$6+$7+$8+$9} END{print s}' /proc/interrupts` before each step.
- Windows are rare while the user is around (minutes). Take ~/.cache/powos-verify.lock for the window; check
  `pidof com.powos.app` before/after (an install mid-run = void). Note the installed APK: `dumpsys package com.powos.app | grep lastUpdateTime`.

## Gesture journeys (`verify/journey.sh` runs `verify/gest.sh` on the phone as Android root)
- Screencaps from the Mac: `tools/phone/shot.sh` (the ON display; refuses off/black). On the phone: the ON display id from
  `dumpsys display` (`state ON`), never a fixed id - bare `screencap` takes the inner screen, black while folded.
- Cover screen (folded, `dumpsys device_state` CLOSED): 1116x2484, display id from `dumpsys SurfaceFlinger --display-id`
  (cover = the active viewport in `dumpsys display`, port 132). `screenrecord --display-id <id> --bit-rate 40000000 --time-limit N out.mp4 &`;
  `screencap -d <id> -p x.png` at each step (multiple displays: always pass the id).
- Home flick: `input swipe 558 2475 558 1300 140`. Switcher (swipe-up-and-hold): `input motionevent DOWN 558 2475`,
  MOVEs up to ~1850, `sleep 1`, `UP`. Page left/right: `input swipe 900 1300 150 1300 220` and back.
- PowOS AI page: swipe right from page 1 starting away from the side-gesture edge (`input swipe 350 1400 1060 1400 350`);
  a swipe from x=150 is eaten by the edge gesture. Confirm with a screencap before trusting the run.
- An app to go home from without opening anything new: bring Settings forward
  `am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10200000 -n com.android.settings/.Settings`.
- Restore: home's page, the app order; delete your files. `/data/local/tmp/*` root files: `chmod 644` before adb pull;
  `tools/phone/adb.sh pull` mounts only existing paths: pull into an existing folder, then rename.
- Scripts: never edit one while it runs (bash reads as it goes - kill, edit, restart); the Mac's bash is 3.2 (no
  mapfile); zsh doesn't split `$VAR` into words - use arrays or call bash.

## Unfolded / unattended runs (`verify/unfolded-checks.sh`, `verify/owed-checks.sh` - queue them)
- Inner screen without the hinge: `cmd device_state state 3` (OPENED); restore with `cmd device_state state reset`
  (not `state 0`: that blanks the inner screen of a phone that is physically open). Screen size: `wm size` (a dumpsys
  display parse once came back empty and every swipe went to 0,0 - refuse to inject without a size).
  mCommittedState reads OPENED before display 0 switches: poll `wm size` for the inner size (>2000 wide, up to ~15 s),
  don't trust a fixed sleep (float-desktops once read the cover's 1116x2484 3 s after state 3).
- `cdp.sh eval` prints a JSON string (`"{\"marked\":4}"`): unescape before grepping `"key":value` (running-dot once
  failed on a home with 4 marked cells).
- Android's keyguard is the window `NotificationShade` (not named lock): while `dumpsys window policy` shows
  `mIsShowing=true` the screen dozes after ~10 s mid-run. No PIN: `wm dismiss-keyguard`, then PowOS's face
  (`PowosLockActivity`) is a swipe up.
- Tap a WebView field only after a read-only CDP check that it is ON screen (rect inside the viewport, its page
  `.shown`): a hidden AI-page field's coordinates once tapped the dock's Termux icon. Never type into a terminal.
- Waking the screen (`input keyevent KEYCODE_WAKEUP`) only with the user's own go, as its own visible command (the
  permission system shows it) - never inside a script, never on an agent's say-so.
- After a reboot the adb link drops and comes back (`docker exec powos-vadb adb connect 10.13.13.7:5555`); a run cut
  off mid-way leaves things open - restore by hand (Back, home, device_state reset). Other agents flash kernels:
  check `cat /proc/uptime` before blaming your input for a reboot.
- Seen in the assist overlay with nobody speaking: "Субтитры создавал DimaTorzok" in the field (a Whisper silence
  hallucination) - report to powos-voice if it recurs.

## User journeys for the manager (`verify/e2e-desktop.sh`, `verify/e2e-appapi.sh`; 2026-10-23)
- "Use the phone like a user" rounds: real injected taps/swipes at spots read over read-only CDP, one screenshot per
  step on the phone (`/home/powos/design-qa/e2e-<journey>/<round>/NN-<step>.png` + `steps.txt`: file, what was done,
  PASS/FAIL/NOTE), the manager reviews them as a user. The rules live in `verify/e2e-lib.sh` (step/pass/fail, publish,
  restore): every DOWN is checked against the verify pill's window frame first ("PowOS verify status", top centre -
  the floating windows' title bars run under it) and refused there; only new tasks of the journey's apps and Linux
  apps it started are closed; the start page / the app in front come back; home.get + home.wide must hash the same.
- Queue a round: `verify/e2e-queue.sh` (desktop parts 1-3 with --screen inner, then appapi; board task
  manager-end-to-end-user-journeys-on-the-phone-qa, no --close; the last part of each mails the manager
  "E2E round N ready: <dir>"). ship.sh queues one after every successful ship (`--if-idle`: never two waiting).
- Over 300 s: split into parts (`--part K --of N`), each a job, steps numbered from (K-1)*25+1, a re-run replaces only
  its own files and steps.txt lines.
- A soft FAIL doesn't stop a journey (more screenshots); exit 0 with FAIL lines is the runner's FAIL.

## Reading a FAIL
- First check which commit ran it: the runner's checkout (verify-runner) ff's per job, but a fix pushed after the job
  started isn't in it (`git -C .claude/worktrees/verify-runner reflog` vs the log's time). wide-home's 00:40 FAIL ran
  a pre-fix copy.
- A query by class (`.bar-pill`) matches the user's own widgets too: scope it to the element you mean (`> .bar`).
- Before blaming a check for user data, compare with the backup the feature made (wide: home.wide.backup).
- **Every `FAIL` line names the stage that failed and its evidence - never just the symptom.** "KWin didn't come
  back" once hid that the logout request never reached the app at all (f91); report each stage a multi-step check
  passes through (request written / app saw it / session restarted / new pid, or whatever the check's own stages
  are) as it's reached, and on failure say which stage and what was seen there, not only the final symptom.
- Toybox's `grep` has no `\|` alternation in a basic regex (no `-E`): `grep -v "a\|b"` silently drops nothing -
  bf-present once picked 6 buffer-less container layers this way and read "no presents" as a compositor fault
  (f101, fixed in 616fdd94). Use `grep -E`/`grep -iE` for alternation, always.
- A reference screenshot/hash for a visual check must exclude **live and UI-owned pixels** - a moving live
  wallpaper, or chrome the checking UI itself draws (home's own overlay, the verify pill) - or a frame of motion
  or the check's own furniture fails the comparison for reasons that have nothing to do with the thing under test
  (plasma-transparent's reference once included home's UI and a moving live wallpaper, fixed in 08671d8d). Crop or
  mask those regions out before hashing/diffing, and say so in the check's header.

## Frame-stepping (`verify/frames.sh <mp4> gaps|sheet T0 T1|overview`; ffmpeg in a container, files under $HOME)
- `docker run --rm -v "$PWD":/w -w /w --entrypoint ffmpeg linuxserver/ffmpeg:latest ...` (ffprobe the same way).
- screenrecord is variable-rate: list frame times
  `ffprobe -v error -select_streams v -show_entries frame=pts_time -of csv=p=0 x.mp4`, find the transition by its gaps.
- Contact sheet of every frame in a window, numbered:
  `-vf "select='between(t\,5.95\,6.75)',scale=140:-1,drawtext=text='%{n} %{pts\:flt}':x=2:y=2:fontsize=11:fontcolor=yellow:box=1:boxcolor=black,tile=13x4" -fps_mode passthrough -frames:v 1 sheet.png`;
  overview at `fps=4`; full-res frames around a suspect with `select='between(n\,205\,209)',scale=372:-1,tile=5x1`.
- Read the sheets as images. Report gaps as "frames N-M, t1-t2 s, ~X ms" with the mp4 path.
- Known (2026-10-21): swipe home hides home's content ~290-430 ms (bare wallpaper + switcher's "Clear all") before
  it pops in - check whether that's fixed before calling a home-transition item done.

## Gesture monitors (dup checks)
- `dumpsys input` can contain FROZEN dispatcher snapshots (e.g. under "ANR:" from an old CoverPadActivity ANR) that
  list monitors again: grep counts 2-3x. Count only the live section (before the first "ANR:"), or compare ownerPid:
  `dumpsys input | grep -oE "powos-gestures, id=[0-9]+.*ownerPid=[0-9]+" | sed -E "s/inputConfig.*ownerPid/ownerPid/" | sort -u`
  - the live one's ownerPid = `pidof com.powos.app`. Expected: exactly one "[Gesture Monitor] powos-gestures".

## Idle CPU
- `tools/phone/idle-sample.sh [secs]` (perf agent's; per process, appends ~/.local/state/powos-perf/idle.log), `cpu.sh`, or
  `verify/cpu-sample.sh` (app / renderer / session split + touch IRQs during the window).
  Count app + its WebView renderer (`webview:sandboxed_process`, comm `ocessService0:0`) + the session (plasmashell,
  kwin_wayland, Xwayland, python3 services). Budget ~3% of one core idle on home, screen on. The supervisor's daily
  sample: /var/log/powos/idle-cpu.log (inside PowOS, root.sh).

## Broforce (Steam 274190, Proton/FEX) - `verify/bf-run.sh`; needs ~14 min of screen: an away window or the user plays
1. Before: is Steam running (`pgrep -a steam` in PowOS)? Count stats lines:
   `grep -c "Xwayland KGSL" /data/powos/root/run/powos-app/hyprland.log` (the session log despite the name; KWin session; times UTC).
2. As the session user (`su -c "sh /data/powos/powos-run.sh 'sh /var/tmp/x.sh'"`, script copied to /data/powos/root/var/tmp):
   `powos sleep never steam`, then `cd /home/powos; setsid -f steam steam://rungameid/274190 >/tmp/bflog/steam-start.out 2>&1 </dev/null`.
3. Memory every 15 s (`bf-sample.sh`, Android root): MemAvailable (/proc/meminfo), DMA-BUF total
   `dmabuf_dump -b | sed -nE 's/.*Total DMA-BUF size\(bytes\): ([0-9]+).*/\1/p'`, Xwayland's dma-buf fds
   `ls -l /proc/$(pidof Xwayland)/fd | grep -c dmabuf`, game pid `pgrep -f Broforce_beta.exe`. Expect flat (~600 MB
   DMA-BUF since c8ab446; the leak was 1.8 -> 3.2 GB in 4 min, growing after exit).
4. Frame pacing (`sf-latency.sh`): layer names from `dumpsys SurfaceFlinger --list` (strip `RequestedLayerState{`...` parentId=...}`), then
   `dumpsys SurfaceFlinger --latency "<layer>"` -> present-time deltas (col 3): mean/fps, max, count over 1.5x vsync.
   And the new KGSL lines: `Xwayland KGSL: last 30s: N commits (F forced..., H held back at 4 buffers), R buffers released, up to M held`
   - healthy: R == N, M <= 4, H rare.
5. After ~10 min: close the game (`pkill -f Broforce_beta.exe`), `steam -shutdown` if Steam wasn't running before,
   `powos sleep never --remove steam`; one more memory line 60 s later (memory comes back?).

## The shell gate under load (shell/dev/gate.mjs; learned 2026-10-23)
- A gate run is ~25 pages in one headless Chromium. Under load (two agent gates at once at --cpu-shares 256, Mac
  load 15-20) frames and timers fall behind the clock. A fixed `sleep(500)` before an assertion then fails with no
  code change, and a failing gate blocks every ship (ship-apk pre-gates the tip). Rule: **no fixed wait before an
  assertion.** Wait on the state the assertion needs, at most ~3 s, and keep the assertion as it was:
  `window.__gw` is on every page (installed by open()): `until(f, ms=3000)` (f may be async; returns whether it
  held), `settled(f, sel)` (f holds, no animation, then 2 frames), `steady(f, n=3)` (a JSON measure unchanged over
  n frames: catches motion that scripts drive, which getAnimations() never sees), `still(sel)`, `frames(n)` (a
  frame, or 500 ms without one), `mod(path)`.
  Node side: `restAt(page, viewport, like)` for the relayout steps.
- Pitfalls seen:
  - still() went true before a transition had begun. shade-overpull measured its rest marks mid-open (68 px off).
    So also wait for `.riding` to be gone and steady() the rects.
  - A scroll-driven animation (the dock's `animation-timeline: scroll()` edge fade) is "running" forever. Count
    only `a.timeline === document.timeline`. Before this fix every relayout-unfold wait ran its full 3 s (34 s).
  - The relayout "fresh" layout was measured 800 ms after ready, before the tiles (and a widget's "$$$$" text)
    settled, so all 4 steps "moved". Measure only after restAt().
  - Preact useEffect runs after paint. editsheet.tsx's open effect sets `appPicker = false`. A click on "+ app"
    before that frame left the picker shut ("A-Z list has 0 apps"). Click only once the sheet is settled().
  - An "empty spot on home" read with elementFromPoint ignores native windows: a floating window over it takes the
    touch. Pick spots with e2e-lib.sh freept (skips every windows.list window + its title bar). Injected drags: the
    DOWN and its first MOVE past slop in ONE adb call; a DOWN alone held to the next call is a long press (edit mode).
  - A long press is a timer (grid.tsx LONG_PRESS_MS 420, MARQUEE_DWELL 180): wait for `.carried` / gesture.ts
    `held`, not 520 ms. The hold itself (the scenario: dwell before the moves) can stay a sleep.
  - The reverse case: a synthetic drag on a tile must pass SLOP (10 px) in its FIRST move. Otherwise the long-press
    timer stays armed. Under load one dispatch took ~770 ms, the timer fired, and the pull turned into a lift
    (search-launcher: "pulled up from the widget: the drawer didn't open", editing on). Pace a finger's moves with
    setTimeout(16), not frames: timers fire in deadline order, frames don't.
  - "Promise was collected" (relayout-*, edit-search): evaluates that awaited `importShim("./state.ts")` again under
    load. The checks import through `window.__gw.mod(path)` now (one import per page, cached); none have been seen
    since. If it still happens, whenReady's checkOnce reloads the page and runs the check once more. The reload
    matters: a retry on the same page found the first try's state (a search widget placed, edit mode on) and
    failed on that.
- Reproduce a load-only failure: `GATE_ONLY='^relayout-'` (a regex on run names; the rest are skipped) and
  `GATE_THROTTLE=6` (CDP Emulation.setCPUThrottlingRate on every page), e.g.
  `GATE_ONLY=relayout GATE_THROTTLE=6 READY_MS=60000 IDLE_MS=0 shell/dev/gate.sh --tree`. Throttling one case
  alone is NOT the same load. The old search-launcher passed at 6x alone and failed only with many pages
  contending, so also run two whole gates at once. Raise READY_MS (60-120 s) when throttling many pages, or boot
  "not ready" hides the cases.
- Left as times on purpose (scenario, not a wait before an assertion): the finger's hold before a drag
  (marquee dwell, overpull's 120 ms), a finger's 16 ms move pacing, the pet's exercise pacing, SETTLE_MS (boot errors
  after ready) and the idle check's own windows.


## Latest hand-off (2026-10-24, board task more-phone-checks-run-on-the-emulator-lane)

Classified all 95 directly-queued verify checks for the emulator lane (`# lanes:` header per check,
`--dev auto`, `--android-only`), pushed as commit 4ec76979. Confirmed on re-test:
- `resize-probe.sh --apps calc` - **PASS** (the one solid proof so far).
- `window-scroll.sh --android-only` - **FAIL**: home took the scroll on a Chrome window. Open: Chrome
  handling the swipe differently on the emulator, or a real touch-routing bug also on the phone? Look
  before trusting this lane for Chrome scroll checks.
- `e2e-desktop.sh --part 2/3` and `--part 1/3 --android-only` - both **FAIL**: `no dock cell for
  Calculator/Chrome`. Root cause: the emulator's home dock isn't provisioned with them pinned like
  the phone's; `tools/emu/emu.sh` create/testwin likely needs to pin them.
- `float-desktops.sh` / `panel-lift.sh` - re-fixed once but **STILL FAIL**, same messages; friction
  f81 reopened (x2). Root cause not confirmed.
- `window-max.sh calc --round emuf1` / `window-rec.sh --app calc --two --android-only --pages-only` -
  still pending.

Friction: f79-f82 (first pass), f130/f131 (context overhead), f134 (no lane metadata), f138 (land.sh
missing in a fresh worktree), f81 reopened, f142 (dock cells missing on the emulator). Don't call the
emulator lane "proven" for window-scroll/e2e-desktop/float-desktops/panel-lift until resolved. Full
original with exact log lines: `HISTORY.md`.

## perf


# PowOS phone performance

Budget (the user, 2026-10-21): ~3% of one core idle on home, screen on; 0 frames, paints and rAF on every page at
rest. Keep the blur - make it cheap.

## Tools (repo tools/phone/)
- `AWAKE_ONLY=1 idle.sh --wait 120 1800`: one call that returns when the screen is on and nobody touched it for 120 s
  (without AWAKE_ONLY it also returns on screen OFF - no use for an idle-home sample).
- `cpu.sh [secs] [top]`: per-process CPU from /proc (% of ONE core; the phone has 8: 800 = all busy). Read-only.
- `cdp.sh pages | eval <page> '<js>' | idle [secs] [page] | raster [secs]`: forwards the app's devtools socket
  (pid changes per install) and runs cdp.ts in powos-vadb's network. `idle`: per page compositor frames, paints,
  rAF, timers, layouts, running animations from one devtools.timeline trace (tracing is browser-wide: one tracer,
  events split by frame/layer tree). `raster`: busiest cc/viz/gpu/blink events per thread. All read-only.
- `idle-sample.sh [secs]`: refuses unless idle>=120 + Awake; cpu.sh + cdp idle + gfxinfo; logs one line to
  ~/.local/state/powos-perf/idle.log.
- Per-thread: /proc/<pid>/task/*/stat (utime+stime, HZ=100). Java hot spots: `simpleperf record -t <tid> -g
  --duration 15` then `simpleperf report --children --sort symbol`.
- `cdp.sh profile [secs] [page]`: V8 CPU profile, self/inclusive ms/s per function and per component (blob modules
  named by sourceURL). `cdp.sh net`: per-page WebSocket frames/requests. `cdp.sh idle` lists "askers" (who requested
  each rAF/timer/restyle, from the .stack trace category). All read-only. Heavy traces (raster) inflate the IO/mojo
  task counts themselves: judge "tasks/s" without tracing.
- Glass knobs (CDP, home): `__glass.live.counts` (measures/sends per s, resets on read), `.kicks` (what started the
  last measures), `.hold(true)` (measure but don't send), `.compute(false)` (drag frames measured, not computed).
- Drawer drag cost on the phone: `shell/dev/perf/drag-raster.sh [secs] ["label=css" | "label=js:ON|OFF"]`, PROFILE=1
  for per-function JS; takes the free window + verify lock itself, or LOCK_HELD=1 under `tools/phone/verify/queue.sh`.
  Don't wait for windows yourself: `tools/phone/verify/queue.sh add <board-task> <script> [args]` and end the turn.
- Finding what changes the DOM: a MutationObserver/rAF wrapper via `cdp.sh eval` - only inside a free idle window.
- Headless: `shell/dev/gate.sh --tree` runs the idle check (2 s after a 3 s settle: no rAF, no layer paint, no
  endless animation). On a busy Mac `READY_MS=30000`. Drawer drag probes: shell/dev/perf/ (powos-shell skill, drawer section).
- Deploying rooted-side files over the VPN (rooted.sh calls plain `adb`): `PATH="$PWD/tools/phone/bin:$PATH"
  targets/android/rooted/rooted.sh deploy --note "..."` (tools/phone/bin/adb wraps adb.sh). A restart of the
  supervisor/sleepd afterwards: kill their pids (/data/powos/root/run/...) and `sh /data/powos/powos-start.sh`.
- Phone side: powos-supervisor's daily IdleSample -> /var/log/powos/idle-cpu.log (+ `powos-supervisor status`),
  a low-priority note when over 3%. Screen on = DRM `/sys/class/drm/card*-DSI-*/dpms` On (backlight files read 0).

## Found (2026-10-21)
- Endless CSS pulses (PowOS AI's working dots) = 60 frames/s and a SurfaceFlinger blur pass each: static dots now.
- nativeglass measured on any style write anywhere (widgets' numbers, the pet's transform): now only on what
  carries glass (a surface or its ancestors), plus ResizeObserver on surfaces; `__glass.live.counts` for sends/s.
- A widget whose value changes re-renders its tile: performance widget 2 s -> 5 s (budget: <= 1 update / 5 s).
- The warm assist WebView in a hidden session window counted itself visible: WebView.onPause in onHide.
- The app ran interpreted after every install (no profile, dexopt status=verify): install-app.sh installs
  with pm.dexopt.install=speed (HACK until a baseline profile).
- plasmashell behind Android's home: powos-panel-responsive polled it with evaluateScript every 3 s (now RandR
  events); plasmashell itself is frozen 15 s after PowOS goes off screen (powos-sleep-gui -> sleepd
  gui-desktop-freeze), thawed on screen, on D-Bus (the log names the caller), and 2 s every 5 min.
- powos-supervisor: full /proc scan every 10 s was its whole cost; now every 60 s.
- WireGuard CPU is traffic: the phone's own `claude` uploads to claude-auth (tens of MB), agents' adb calls; not
  keepalive.

- Every touch on home ran the full glass measure per frame (58/s in use): touches now measure only during a drawer
  drag (tracks or .home.dragging). Drawer drags are computed from gesture.ts's "drawer" Web Animations' keyframes
  (one measure at the start), and innerWidth/innerHeight/devicePixelRatio are read on resize only (each read forced
  a style recalc mid-frame). Drag cost left: ~38 ms/s nativeglass (1/3 is the per-frame postMessage of regions) and
  the WebView's own drawing; holding region sends changed nothing measurable - no host-side fade needed.
- Baselines (2026-10-22): idle home app 4.3 + renderer 1.1-2.0 % of a core; drawer drag app ~105 / renderer ~97 /
  SF ~62 (total ~356). Re-measure on kernel changes.

## Widget engine wakes (Kotlin, 2026-10-22)
- Idle home = the tiles in assets/widgets/*.owl (today, fetch, terminal, games, performance). Polled sources sleep
  `WidgetInstance.nextWake(every, now)`: on the interval's wall-clock boundary, so 5 s / 15 s / 1 m / 30 m sources
  wake at the SAME instant (one wake, tiles reach the page in one frame). Headless count: WakeScheduleTest (prints
  "wakes/min": 12 aligned = the performance tile's 5 s; 13 on own phases, drifting apart by each update's length).
  Engine total on an idle home: ~325 wakes/min before (5 tile clocks x 60 + media 12 + sources 13) -> 12. Unit tests in the warm container: rsync
  the worktree to a private /tmp/<name>/PowOS (not /work), and ALSO pass `-I` an init script setting
  `layout.buildDirectory` elsewhere - init.d puts every build in /tmp/gradle-build/<rootProject.name>, so a private
  copy alone still clobbers the shared build dirs (done once, 2026-10-22).
- Gone: ShellWidgets.clock looked at every watched tile each 1 s (60 wakes/min per tile, ~300 on home): now
  snapshotFlow on engine.visible + spec.program.animated. Media.updates() ticked every 5 s with 3 binder calls
  forever once a control center asked media.state: now callbacks on every active session + MediaListener.changes for
  access; 1 s ticks only while something plays. fetch's android.system 5 s -> 30 s (binder + tile eval each).
- Left: performance tile's own 5 s (its point); while music plays the 1 s position tick runs even screen off
  (ShellMedia keeps listening) - gate on visibility if it shows up. Sources pause when no home activity is started
  (WidgetEngine.visible = ShellActivity onStart/onStop; screen off stops it).

## Delivery pipeline (Mac)
- APK: build-app.sh uses the warm builder (targets/android/tools/warm-builder.sh, container powos-gradle-warm, unit
  gradle-warm-mac): every worktree rsync'd into /work, Gradle daemon warm - 11-12 s end to end; falls back to the cold
  android-app-dev `make build` (~2-8 min; POWOS_COLD_BUILD=1). `PUBLISH=0 warm-builder.sh build <app dir>` = timing
  without touching output/. No BuildConfig in the app (a per-build versionCode in it recompiled javac every build):
  the stamp goes to the manifest via androidComponents; read the version at runtime (AppVersion.kt).
  targets/android/tools/profile-build.sh: Gradle --profile cold vs no-change inside the ship lock.
- Gate: pages share one transpile (gate.mjs, cached by hash in ~/.cache/powos-gate/tx; GATE_SHARED_TX=0 = old way).
- Mac load is mostly not ours (stickman train.py, the kernel builder's Rosetta clang LTO): leave the user's jobs.

## Pitfalls
- touch IRQs don't see injected input: also check Android's lastUserActivity (`dumpsys power`).
- A 2 s `top` catches periodic ticks and overstates them; sample 30-60 s.
- My own probes show up (a stuck `tr` loop hit 100%): kill them, keep phone-side loops bounded.
- An idle sample while another agent installs an APK or a page is broken is not a sample.
- A bash -c '...' script must not contain an apostrophe (even in a comment); `set -o pipefail` + `sed ... missing-file
  | head` exits non-zero - guard with `|| true`.
- `docker run --rm` per call costs ~1 s; prefer a long-lived container + `docker exec` for repeated work.
- Ship only pushed commits (ship-apk enforces it); commit, rebase, push, then ship.
- Cross-cutting causes (endless animations, nativeglass MutationObserver, inherited custom properties): handbook
  "Rendering cost". Each new one found goes there, not only here.
