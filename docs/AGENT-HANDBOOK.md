# Agent handbook: how the PowOS phone pieces connect

Read this first; it replaces digging through the code. Keep it current when you learn something an agent had to dig
for (one line each).

## Reaching the phone (OnePlus Open, rooted)
- `tools/phone/adb.sh <adb args>`: adb over the VPN (powos-vadb's server, 10.13.13.7:5555) from any session.
  Files you push must be under `$HOME` (Colima shares only the home directory).
- `tools/phone/root.sh <script>`: run a local bash script as root INSIDE PowOS (chroot of /data/powos/root).
- As the session user (KWin, the user's apps, the session env): `tools/phone/adb.sh shell su -c "sh /data/powos/powos-run.sh '<cmd>'"`.
  NEVER `sudo` through powos-run.sh: it pops a password dialog on the user's screen.
- `tools/phone/idle.sh` -> `idle=<s> screen=<Awake|Dozing>`. Drive the phone (input, screenrecord, journeys,
  session-restarting installs) only at idle>=120 and screen=Awake. Never wake the screen with key events (refused).
- WebView devtools (shell pages): `tools/phone/adb.sh forward tcp:9333 localabstract:webview_devtools_remote_$(pid of com.powos.app)`,
  then `docker run --rm --network container:powos-vadb -v $HOME/...:/t oven/bun:1 bun /t/cdp.ts <page-suffix> '<js>'`
  (an evaluator: ~/.claude/jobs/af8ebd0c/tmp/cdp.ts - copy it).
- Logs: `tools/phone/adb.sh shell logcat -d -v time | grep <Tag>`; crashes `logcat -b crash`. App tags: PowosRecents,
  PowosGlassBlur, PowosBackdrop, PowosLiquidGlass, speech, PowosNavGesture, PowosSwitcher.

## Shipping
- Shell (web) files: `shell/push.sh --vpn --note "plain words" <files>` - the gate (tsc + headless boot of every page)
  must pass; never bypass it. Check the phone's override folder (/data/data/com.powos.app/files/shell) first: an
  override beats the APK's copy; merge, don't clobber.
- APK: `tools/phone/ship-apk.sh --note "plain words"` - one build/install at a time across all agents (lock),
  clean tree only, waits for the user to be idle 60 s (an install restarts the PowOS session), verifies the app
  came back. Don't call targets/android/build-app.sh + install yourself.
- PowOS (Linux) files: through the deploy scripts (targets/android/rooted/powos-deploy.sh) as registered units
  (`powos units`, units/<host>/*.json); never unmanaged host installs.
- PowOS apps: `powos app new|build|install|ui|publish|dev` (lib/apps/powos-app), run inside PowOS.

## Where things live
- Shell: shell/ (Preact+TS). Pages = modes (`index.html?mode=lock|shade|assist|glasses`, home = no mode). Bridge
  JS<->Kotlin: shell/bridge.ts + shell/types.ts (events list); Kotlin side ShellBridge.kt.
- Theme/material: shell/theme.css tokens (`--glass-*`, `--lift*`, `.tile`, `.surface`); design rules
  docs/DESIGN-LANGUAGE.md (rule 1: less is more, reduce complexity).
- Glass: CSS frost picture shell/ui/glass.ts (lock face); live compositor blur for home shell/ui/nativeglass.ts ->
  GlassBlur.kt (SurfaceFlinger blur regions); liquid refraction LiquidGlass.kt + WallpaperBackdrop.kt (OFF by default).
- Widgets: shell built-ins (shell/ui panels), OWL widgets (.owl: evaluated by the Kotlin engine, drawn by
  shell/ui/owl.tsx from the trees it sends), PowOS-app islands (apps' ui/widgets). See EVERY widget at every size:
  `shell/dev/preview.sh` (or `powos app preview <dir|file.owl|id>`) - contact sheets + fit checks, mock data in
  shell/dev/preview/data/<id>.json; the gate runs it (--fast) when a push touches what draws widgets.
  - OWL off the phone: `owl trees` (targets/android/app/owl/src/cli/.../Trees.kt, a port of WidgetTree.kt - keep in
    step) evaluates a widget per tile size; preview.sh builds owl.jar with
    `./gradlew -q --offline --configure-on-demand :owl:owlJar` in android-app-dev-android-builder (volume
    powos-android-gradle; it's locked while an APK builds - the old jar is used then). `java -jar owl.jar check f.owl`.
  - OWL widgets on the phone: files/widgets/*.owl (= PowOS's ~/.config/omalauncher/widgets), hot-reloaded; push
    with adb to /data/local/tmp (rm the folder first: adb push into an existing folder nests it), su cp + chown
    u0_a359 + `restorecon -F`, then md5 against the repo's assets/widgets.
  - OWL layout = Compose's: an unsized Text/Grid/Canvas/chart or a Row of weights takes the column's width; a Row's
    fixed-width items don't spread without `fill: width`; size text from tileWidth/tileHeight, never a fixed cap.
  - Islands get { host, app, cells }: measure the real area (ResizeObserver) - never guess rows from cells.
- Speech: one shared recognizer (targets/android/app .../ui/Speech.kt), bridge events speech.state/done/permission.
- Assist overlay: VoiceInteractionService session (PowosAssistSession.kt) hosting shell mode=assist.
- Deploy notes/errors to the user: deploy notes = tools/deploy-note.sh -> notification; shell errors are captured in
  shell/index.html (boot.report) and sent to the manager; manager mail = ai.mail events.
- Agents/board: `powos agents task list|add|done`, spool /run/powos-app/agents (agentsd).
- In the shell, deploy notes and agents' mail to the user both arrive as "ai.mail" (AgentMail[], deploy notes `from: "deploy"`);
  the page's own errors are window error/unhandledrejection events (index.html's boot.report also keeps them in window.__powosBoot.errors).
- A shell layer that needs a PowOS app's tables vendors its bindings: `apps/vendor.sh <app>` -> shell/vendor/<db>.js
  (+ a .d.ts, a line in vendor/VERSIONS); then
  useDb/useRows from shell/apps/stdb.ts (socket closed 5 s after the page hides). Example: shell/ui/pet.tsx.
  A module change ships with its vendored bindings (`apps/vendor.sh <app>`) and a publish (`apps/install.sh <app>
  publish`): shell/push.sh and ship-apk compare the bindings with the phone's live modules (tools/phone/bindings-check.sh,
  in their one phone call), publish this commit's module when the bindings are ahead of it, else refuse with the fix.
  On home a stale table shows in shell-errors as `stdb: <db>: ... bindings stale for <table>` and isn't subscribed.
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
- The app's pid changes on every install/crash: re-run the devtools `adb forward` after one.
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
- Commit only your paths; never force-push; rebase often (several agents edit shell/ui at once).
- `HACK:` markers need a row in docs/REMOTE-POWOS.md section 4 (test-hack-registry).
- The Mac's bash is 3.2: no `declare -A`, guard empty arrays under `set -u`.
- Battery: NO battery-based rules - neither for agents' work nor in the product (the user's call, 2026-10-21 10:01).
  The product behaves the same at any battery level unless the user asks otherwise (Android's own battery saver
  switching compositor blur off is Android's, not ours).
- Review images (contact sheets, before/after, pet steps) go to the PHONE before you push, so the manager can look
  first: /home/powos/design-qa/ (pet: /home/powos/pet-review/) inside PowOS =
  /data/powos/root/home/powos/... (push with tools/phone/adb.sh, then `su -c cp` + chown 10359:10359).
- NEVER poll the phone in a loop (no 10 s / 60 s adb checks, no "until idle" loops from the Mac): each call is a new VPN
  connection and keeps the phone's radio awake - agents' polling was most of its WireGuard traffic and CPU, and the
  battery ran flat on 2026-10-21 with several agents polling all afternoon. Instead, wait for an EVENT: comms mail
  (`powos comms watch`, wait_for_message), a push/ship result, shell-error mail; or make ONE check when you need it.
  Waiting for the phone to be free is `tools/phone/idle.sh --wait IDLE_S MAX_S` (one held call; the waiting runs on the
  phone) - ship-apk uses it. Batch several commands into one adb call. Not a battery-based behaviour: the product and
  your work never change with the battery level; this is about not wasting the phone.
- Commit before you push a shell file: an APK install resets all shell overrides (only committed work survives).
- The assist overlay's circle-to-select + crop flow is core, never "chrome": never remove it.
