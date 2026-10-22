---
name: powos-verify
description: Use when verifying a PowOS phone fix on the device itself - idle windows, injected gesture journeys with screenrecord and frame-stepping, gesture-monitor/dup checks, idle CPU samples, and game checks (Broforce frame pacing, Xwayland dma-buf). Learned 2026-10-21.
---

Access and rules: the powos-phone skill (tools/phone/adb.sh, root.sh, idle.sh). This is the how-to for verifying.

Scripts: `tools/phone/verify/` (header of each says where it runs).
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
- Restore: home's page, the app order; delete your files. `/data/local/tmp/*` root files: `chmod 644` before adb pull.

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
