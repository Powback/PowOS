# Agent handbook: how the PowOS phone pieces connect

Read this first; it replaces digging through the code. Keep it current when you learn something an agent had to dig
for (one line each). Cross-cutting rules live HERE once; expert skills (.claude/skills/powos-*) link to them.

## Which expert owns what
Route work to the owner. If the owner already ran in this session, RESUME it (SendMessage to its id/name) with the new
task - it keeps its context and its own findings - instead of starting a fresh agent; start a new one only when none
exists, and it then begins from its skill. Changing another owner's file: message the owner (with numbers), or make
the minimal change and tell them.

| area | agent (skill of the same name) |
|---|---|
| app drawer / launcher panel, its drag + fade, recents row, A-Z bar, search pill spacing | powos-drawer |
| look and feel: design language, theme tokens, shade + notifications, control center, contrast, review renders | powos-design |
| the pet's body, states, bubbles, local.pet app + `powos pet`, pet-over-apps window | powos-pet |
| the pet's movement: petphys/petai/petmove/petperch, its frame cost | powos-pet-physics |
| dictation: Speech.kt, GpuSpeech.kt, dictation.ts, push-to-talk, side button | powos-speech |
| idle CPU, frames at rest, nativeglass.ts cost, profiling tools (cpu.sh, cdp.sh, idle-sample.sh) | powos-perf |
| GPU servers gpu-195 / .58, llm.pow / stt.pow / voiceagent.pow, model loads, benches | powos-gpu-servers |
| home widgets: shell panels, OWL (.owl), app islands (Lights), preview tool, widget gesture ownership | powos-widgets |
| edge gestures, Quick Tools, corner pull-ups over apps, overlay window hosts, home pull -> shade | powos-gestures |
| inter-agent comms (`powos comms`, MCP), manager inbox, agentsd, agent-mail notifications | powos-comms |
| SpacetimeDB modules, vendored bindings, shell/apps/stdb.ts, bindings-check, publishes | powos-stdb |
| swipe home, recents switcher, NavGesture/RecentsTransition, page-after-home, wallpaper capture | powos-switcher |
| native bridge security: PowosHost/Native/Boot, ShellOrigin, iframes, bridge-check.sh | powos-bridge-security |
| PowOS AI's chat: rich messages, present/present_choices, PowosAiChat items | powos-chat |
| on-device verification (journeys, frame-stepping, idle CPU samples, Broforce), closing board items with evidence | powos-verify |
| the desktop shell: powos-shell (Plasma host), hosts/desktop.ts, mode=desktop, dev/phone.sh | powos-desktop |
| other shell (web UI) work no expert owns | powos-shell-dev |
| other Android app (Kotlin) work no expert owns | powos-android-dev |

## Reaching the phone (OnePlus Open, rooted)
- `tools/phone/adb.sh <adb args>`: adb over the VPN (powos-vadb's server, 10.13.13.7:5555) from any session.
  Files you push must be under `$HOME` (Colima shares only the home directory). After a Colima restart powos-vadb may
  be stopped: `docker start powos-vadb`.
- `tools/phone/root.sh <script>`: run a local bash script as root INSIDE PowOS (chroot of /data/powos/root).
- `tools/phone/user.sh <script>`: the same as the session user powos (its comms inbox, spacetime token, `powos ...`).
  One-liners as the session user: `tools/phone/adb.sh shell su -c "sh /data/powos/powos-run.sh '<cmd>'"`.
  NEVER `sudo` through powos-run.sh: it pops a password dialog on the user's screen.
- `tools/phone/idle.sh` -> `idle=<s> screen=<Awake|Dozing|Asleep> act=<s>` (idle = seconds since a touch-panel IRQ;
  act = lastUserActivity, NOT a user signal). Drive the phone (input, screenrecord, journeys, session-restarting
  installs) only at idle>=120 and screen=Awake. Never wake the screen with key events (refused - don't route around it).
  To WAIT: `tools/phone/idle.sh --wait IDLE_S MAX_S` (one held call; the waiting runs on the phone; exit 1 = timeout).
  It also returns at once when the screen is off (fine for installs); for work that needs the screen on (recordings,
  journeys, CDP idle samples, screencaps) use `AWAKE_ONLY=1 tools/phone/idle.sh --wait 120 MAX_S` (waits through doze,
  never wakes it).
- WebView devtools: `tools/phone/cdp.sh pages | eval <page> '<js>' | idle [secs] [page] | raster [secs]` (forwards
  the app's devtools socket again each call - the pid changes per install - and runs tools/phone/cdp.ts in
  powos-vadb's network; page = home/"" , lock, shade, assist, ...). READ-ONLY on live pages (see Rules).
- Logs: `tools/phone/adb.sh shell logcat -d -v time | grep <Tag>`; crashes `logcat -b crash`. App tags: PowosRecents,
  PowosGlassBlur, PowosBackdrop, PowosLiquidGlass, speech, PowosNavGesture, PowosSwitcher, PowosShell, PowosEdge,
  PowosPet. Batch several commands into ONE adb.sh call.
- Other tools: `tools/phone/cpu.sh` (per-process CPU), `idle-sample.sh` (perf), `review-image.sh FILE...` (review
  images -> /home/powos/design-qa/), `app-src.sh pull|push <app>` (a phone app's sources), `bindings-check.sh`,
  `bridge-check.sh`, `tools/phone/record/run.sh <tag>` (swipe-home recording), `tools/phone/verify/` (journeys,
  frames, edge.sh, Broforce). Every helper an agent relies on lives in the repo, never in ~/.cache or job tmp (Rules).

## Shipping
### Shell (web) files
1. Commit, rebase onto origin/worktree-powos-multiplatform, push to origin. THEN
2. `READY_MS=30000 shell/push.sh --vpn --note "plain words for the user" <files relative to shell/>`.
- push.sh refuses any file that isn't byte-for-byte origin's version: a file is pushed whole, so a stale copy of a
  shared file (shell.css, gesture.ts, theme.css) from your tree overwrites another agent's newer push (16:24: the
  drawer fell apart into one column). Never `--force` past that; rebase and push again.
- The gate (shell/dev/gate.sh: tsc + every page booted headless) runs on what the phone will serve: the installed
  APK's own shell + the phone's current overrides + your files. It refuses only failures your push ADDS. It also
  refuses when a page names a local file (href/src, "./ui/x.css") or imports a module the phone won't have: push a
  file with everything it imports or names, in ONE push. Never bypass the gate.
- Then the bindings check (see SpacetimeDB below) in the same phone call.
- `shell/push.sh --errors [N]` = the phone's shell errors; `--reset [files]` removes overrides. A page that fails to
  boot within 2 min of a push is rolled back by the app and the manager told.
### APK
- `tools/phone/ship-apk.sh --note "plain words"` is the ONLY way to build+install (never build-app.sh + install by
  hand). It always re-executes origin's copy of itself, then: REFUSES (exit 3) unless HEAD == origin's tip and contains
  the last installed commit; takes the cross-agent lock (~/.cache/powos-ship.lock); runs the gate on HEAD's own shell
  (refuses if it doesn't load); builds (build-app.sh refuses a dirty shell/ or targets/android/app); waits for a free
  phone with `idle.sh --wait 60` in 10-min chunks (up to SHIP_WAIT_MIN=60, holding while ~/.cache/powos-verify.lock
  exists; no window = exit 4, APK kept, nothing installed); installs; runs bindings-check; RESETS ALL shell overrides;
  re-pushes (from origin's tip, through the gate) every shell file origin changed since the build commit; prints
  versionCode + any crash. `--now` skips the wait: only when the user asked for an immediate install.
- So: an install wipes every override that isn't committed on origin. Uncommitted or unpushed shell pushes are lost
  by design. Recognise it: right after an install your change is gone on the phone -> check it is on origin, then
  push it again from the tip.
- Kotlin: compile before you push it to origin - a committed but uncompiled Kotlin change on the tip fails EVERY
  agent's next ship: `tools/phone/compile-check.sh` (your worktree, a throwaway builder; never touches the shared APK
  output, safe while a ship runs; prints the compiler's errors, exit 0 = compiles). Found someone else's broken tip? Tell its author/the coordinator with
  the compiler error; don't ship around it.
### PowOS (Linux) side
- lib/ai (manager, comms): `PATH="$PWD/tools/phone/bin:$PATH" targets/android/rooted/rooted.sh deploy --note "..."`
  (rooted.sh calls plain adb; tools/phone/bin/adb routes it through adb.sh over the VPN). Other PowOS files through the deploy
  scripts (targets/android/rooted/powos-deploy.sh) as registered units (`powos units`, units/<host>/*.json); never
  unmanaged host installs.
- PowOS apps: `powos app new|build|install|ui|publish|dev` (lib/apps/powos-app), run inside PowOS; the repo's apps/*
  with apps/build.sh + `apps/install.sh <app> [install|publish|ui] --note "..."`.

## Where things live
- Shell: shell/ (Preact+TS). Pages = modes (`index.html?mode=lock|shade|assist|glasses`, home = no mode). Bridge
  JS<->Kotlin: shell/bridge.ts + shell/types.ts (events list); Kotlin side ShellBridge.kt.
- Page store: `powos.store.set(name, value)` writes files/shell-data/<name>.json; ShellBridge JSON-quotes a string
  value. Pass the value itself, never `JSON.stringify(x)` (that stores a quoted string; speech.json held one and the
  app silently used its default, 64a2468).
- Theme/material: shell/theme.css tokens (`--glass-*`, `--lift*`, `.tile`, `.surface`); design rules
  docs/DESIGN-LANGUAGE.md (rule 1: less is more, reduce complexity).
- Glass: CSS frost picture shell/ui/glass.ts (lock face); live compositor blur for home shell/ui/nativeglass.ts ->
  GlassBlur.kt (SurfaceFlinger blur regions); liquid refraction LiquidGlass.kt + WallpaperBackdrop.kt (OFF by default).
- Widgets: shell built-ins (shell/ui panels), OWL widgets (.owl: evaluated by the Kotlin engine, drawn by
  shell/ui/owl.tsx from the trees it sends), PowOS-app islands (apps' ui/widgets). See EVERY widget at every size:
  `shell/dev/preview.sh` (or `powos app preview <dir|file.owl|id>`) - details in the powos-widgets skill; the gate runs
  it (--fast) when a push touches what draws widgets.
- Speech: one shared recognizer (targets/android/app .../ui/Speech.kt), bridge events speech.state/done/permission.
- Assist overlay: VoiceInteractionService session (PowosAssistSession.kt) hosting shell mode=assist.
- Deploy notes/errors to the user: deploy notes = targets/android/tools/deploy-note.sh -> notification; shell errors
  are captured in shell/index.html (boot.report) and sent to the manager; manager mail = ai.mail events.
- Agents/board: `powos agents task list|add|done`, spool /run/powos-app/agents (agentsd).
- In the shell, deploy notes and agents' mail to the user both arrive as "ai.mail" (AgentMail[], deploy notes `from: "deploy"`);
  the page's own errors are window error/unhandledrejection events (index.html's boot.report also keeps them in window.__powosBoot.errors).
- SpacetimeDB: a shell layer that needs a PowOS app's tables vendors its bindings (`apps/vendor.sh <app>` ->
  shell/vendor/<db>.js + .d.ts + a line in vendor/VERSIONS) and reads them with useDb/useRows from shell/apps/stdb.ts
  (example: shell/ui/pet.tsx). A MODULE CHANGE ships with its re-vendored bindings AND a publish
  (`apps/install.sh <app> publish --note "..."`). Changed the module without republishing = home can't decode the
  table: shell-errors shows `Offset is outside the bounds of the DataView` (vendor/spacetimedb.js) or
  `stdb: <db>: ... bindings stale for <table>`. push.sh and ship-apk run tools/phone/bindings-check.sh (one phone
  call): bindings ahead of the live module are published from this commit's module, anything else refuses with the
  fix. Details: powos-stdb skill.
- GPU box 192.168.50.195: voice stack units (hosts/gpu-195/, units/gpu-195/), voiceagent.pow; plan docs/GPU-SERVERS-PLAN.md.

## Native/hidden-API work (learned the hard way)
- Check an OEM framework call's real shape BEFORE coding against it: pull `/system/framework/framework.jar` with
  adb.sh, unzip classes*.dex, `dexdump -d` it in powos-vadb (`/opt/android-sdk/build-tools/35.0.0/dexdump`). OxygenOS 16
  differs from AOSP: `SurfaceControl.Transaction.setBlurRegions` takes 31 floats per region (AOSP 10 + blur colour +
  OPlus params) - a wrong array length aborts the whole app in JNI (home crash-looped). Encode through the framework's
  own class (BackgroundBlurDrawable.BlurRegion.toFloatArray) instead of building layouts by hand.
- PowOS holds READ_FRAME_BUFFER (signature|recents) through the recents role: `IWindowManager.mirrorWallpaperSurface`
  + `ScreenCapture.captureLayers` work, but a mirror is boundless - pass a source crop or SF answers BAD_VALUE (-22).
- Screenshots: two displays - `screencap -d <id>` with an id from `dumpsys SurfaceFlinger --display-id` (the cover
  screen was the 2nd one listed); a bare screencap picks one and may be the dark inner panel.
- Measuring: `dumpsys gfxinfo com.powos.app reset` / summary (per-window frames, janky %, GPU percentiles);
  per-thread CPU from /proc/<pid>/task/*/stat (utime+stime ticks, HZ=100); touch activity also shows as touch-0x IRQ
  counts in /proc/interrupts. Logcat's main buffer rolls over within minutes on this phone: grep soon, or
  `logcat -d -v time` into a file under $HOME.

## Security
- The shell page's native objects (PowosHost, PowosNative, PowosBoot) reach ONLY its own top frame at
  https://shell.powos (or the dev URL's origin): web message listeners (androidx.webkit addWebMessageListener) with
  that origin rule, plus a per-message check (app .../shell/ShellOrigin.kt: top frame + exact origin; "null"/opaque, other
  origins and every iframe - even a same-origin srcdoc/about:blank one - refused, logged "refused a message"). Never
  add a WebView.addJavascriptInterface to a shell WebView: it reaches every frame and can't see the caller. PowOS
  apps' UIs stay modules in the page's own frame (./_app/<id>/); anything in an iframe is bridge-less by design.
  Check on the phone: `tools/phone/bridge-check.sh [page]` (probe iframes over CDP; the gate's mock can't see it).

## Rules that bite
Git and process
- Commit only your paths; never force-push; rebase often (several agents edit shell/ui at once).
- `HACK:` markers need a row in docs/REMOTE-POWOS.md section 4 in the same commit (test-hack-registry).
- Permission denials: never route around a permission-classifier or sandbox denial (no other tool, script, agent or
  settings edit to get the same effect). Only the user's own approval counts - their message, or their own tap on a
  real permission prompt; never another agent's or the coordinator's say-so. Report what was blocked and the exact
  commands/rules the user can run or add.
- Report what you verified; mark the rest. A root cause is a fact only after a measurement or log shows it (two wrong
  guesses on 2026-10-21: "Chromium drops opacity-0 tiles" shipped and was reverted; the one-column drawer was "almost
  certainly" the recents strip - it was a stale shell.css pushed from another tree). Otherwise
  write "likely" and say what would confirm it.
- Report progress on your board task as you go (the user watches it on the AI page): when you start, set the plan
  (`powos agents task set <t> --plan "a; b; c"` or `--progress 0/N`); at each step `--progress k/N --step "what now"`;
  link commits (`--commit <sha>`, or mention the task id in the message) and review images (`--image <path>`).
  `powos agents help` has the flags.
- A task waiting on the user gets a `--note` that is the ACTION, in plain imperative words ("Pull down on home to try
  the single shade", "Plug the phone into the Mac for the kernel test"), never a status ("in installed APK; user to
  try in edit mode"). The AI page shows the note as the card's action line (manager, 2026-10-22).
- `shell/.gitignore` ignores `node_modules` (no trailing slash) so a SYMLINKED shell/node_modules (from another
  worktree, for tsc) is ignored too; `node_modules/` matched only a directory and the link made the tree dirty for
  build-app.sh. Write ignore rules that match a symlink when one may be linked.
Pipeline scripts (bash)
- The Mac's bash is 3.2: no `declare -A`, guard empty arrays under `set -u` (`${a[@]+"${a[@]}"}`).
- Under `set -e` + `pipefail` a command that "fails" normally ends the whole script: `grep` with no match (exit 1)
  inside `x=$(... | grep ...)` aborted ship-apk before its post-install checks (72d60d5), and `idle.sh --wait`'s timeout
  exit 1 aborted it mid-wait (a39e103). Add `|| true` (or `if ...; then`) where "no match"/"not yet" is a normal
  outcome, and test that path, not just the happy one.
- Never edit a script while a run is executing it: bash reads the file as it goes, so the running copy executes a
  mix (a build script crashed mid-run that way). Edit in your worktree, let the run finish, then commit. ship-apk.sh
  runs origin's copy from a temp file, so a ship in progress is not affected by later commits to it.
The phone
- NEVER poll the phone in a loop (no 10 s / 60 s adb checks, no "until idle" loops from the Mac): each call is a new VPN
  connection and keeps the phone's radio awake - agents' polling was most of its WireGuard traffic and CPU, and the
  battery ran flat on 2026-10-21 with several agents polling all afternoon. Wait for an EVENT: comms mail
  (`powos comms watch`, wait_for_message), a push/ship result, shell-error mail; or make ONE check when you need it.
  Waiting for a free phone is ONE `tools/phone/idle.sh --wait 120 MAX_S`. Batch commands into one adb call. Keep
  phone-side loops bounded and kill your probes (a stuck `tr` loop once ran at 100%).
- Battery: NO battery-based rules - neither for agents' work nor in the product (the user's call, 2026-10-21 10:01).
  The product behaves the same at any battery level unless the user asks otherwise (Android's own battery saver
  switching compositor blur off is Android's, not ours). Not polling is about not wasting the phone, not battery level.
- CDP on the LIVE pages is READ-ONLY: read state, computed styles, rects. Never set signals, CSS variables, classes,
  inject DOM or call actions that change what the user sees (2026-10-21: checks that set the drawer's --p and opened
  panels showed the drawer and the AI page opening on the user's screen, in a recording too). To exercise UI, use the
  headless gate (shell/dev/gate.sh --shots / --tree) or a separate offscreen page; on the phone only in a free window
  (after `idle.sh --wait`), restored in the same call. In such a free window you may close TRANSIENT UI yourself
  before a test (home's edit mode, an open drawer, a menu or sheet - Back or the page's own exit), never settings or
  home's layout (the user, 2026-10-22: "you could have just left it yourself").
- Never drive real devices (lights, Hue, anything physical) without the user's say: a test once changed a real room
  light. Test with mock data (preview data/*.json) or stubbed reducers/handlers.
- Headless passing is not the device working: the gate's mock and Chromium differ from the phone's WebView (a drawer
  strip passed headless and broke on the device). After a push or install, check the change on the device (read-only
  CDP of the computed layout, logcat, or a screencap in a free window) before reporting it done.
- Review images (contact sheets, before/after, pet steps) go to the PHONE before you push, so the manager can look
  first: `tools/phone/review-image.sh FILE...` (-> /home/powos/design-qa/; pet: /home/powos/pet-review/ via adb.sh +
  root.sh, chown 10359:10359).
- The assist overlay's circle-to-select + crop flow is core, never "chrome": never remove it.
Rendering cost (0 frames at rest)
- Every page at rest: 0 frames, 0 paints, 0 rAF (`tools/phone/cdp.sh idle`; the gate's idle check headless). An
  endless CSS animation = 60 frames/s plus a compositor blur pass each.
- nativeglass.ts's MutationObserver re-measures glass on style/class writes to surfaces or their ancestors: a new
  per-frame inline-style animation (the pet's transform) must carry `data-glass-ignore` / stay outside surfaces, or
  each frame triggers a glass measure (43b9dc3).
- A custom property set per frame (--p, --fade) must be registered `inherits: false` (@property): an inherited one
  restyles every descendant (all app cells, widgets) each frame. Animate transform/opacity only, never layout.
The Mac
- The Mac's disk filled on 2026-10-21 (0.5 GB free: Colima's VM got I/O errors, every container and agent died). The
  watchdog (PowStation/scripts/disk-watchdog.sh, cron every 10 min) mails the manager below 15 GB and deletes files
  older than 3 days in agents' scratch caches (~/.cache/powos-gate, powos-preview, powos-perf, drawer-perf, petwork,
  ...). So scripts, probes and tools you rely on belong in the repo (commit them), never only in ~/.cache or job tmp;
  scratch output there is disposable. Never prune the Docker build cache; clean up worktrees/outputs you created.
- Gate timing on a loaded Mac: `READY_MS=30000` (ship-apk's default); a single flaky "not ready" - rerun before
  blaming your change.
Comms
- `powos comms watch` and `inbox` (without `--peek`) CONSUME the messages: a crash or a cut-off output after the read
  loses them. Look with `inbox --peek`; when you consume, use `--json` and keep the output (append it to a file under
  $HOME) before acting. Bodies are delivered whole - never `head`/`cut`/first-line a message you will act on.
