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
- Widgets: shell built-ins (shell/ui), OWL widgets (rendered by the Kotlin OWL engine ON THE PHONE ONLY - the mock has
  no trees; shell/dev/sample-trees.json is empty), PowOS-app islands (apps' ui/widgets).
- Speech: one shared recognizer (targets/android/app .../ui/Speech.kt), bridge events speech.state/done/permission.
- Assist overlay: VoiceInteractionService session (PowosAssistSession.kt) hosting shell mode=assist.
- Deploy notes/errors to the user: deploy notes = tools/deploy-note.sh -> notification; shell errors are captured in
  shell/index.html (boot.report) and sent to the manager; manager mail = ai.mail events.
- Agents/board: `powos agents task list|add|done`, spool /run/powos-app/agents (agentsd).
- GPU box 192.168.50.195: voice stack units (hosts/gpu-195/, units/gpu-195/), voiceagent.pow; plan docs/GPU-SERVERS-PLAN.md.

## Rules that bite
- Commit only your paths; never force-push; rebase often (several agents edit shell/ui at once).
- `HACK:` markers need a row in docs/REMOTE-POWOS.md section 4 (test-hack-registry).
- The Mac's bash is 3.2: no `declare -A`, guard empty arrays under `set -u`.
- Battery under 40%: keep on-device testing light.
