---
name: powos-phone
description: Use whenever you need to reach, inspect, test, or ship to the PowOS phone (OnePlus Open) - adb over the VPN, root inside PowOS, the user-idle check, WebView devtools, logcat tags, shell pushes and the locked APK build/install queue.
---

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
  from what's live, all notes in one notification. `ship.sh status` = requests, live sha, last ships. ship-apk.sh and
  push.sh refuse to run outside it (`--direct` = a logged emergency). `shell/push.sh --errors` = the phone's shell errors.
- Also: cpu.sh, idle-sample.sh, review-image.sh, app-src.sh, bindings-check.sh, bridge-check.sh, record/, verify/.

Never: poll the phone, mutate live pages over CDP, touch real devices (lights) without the user's say, sudo via
powos-run.sh, inject input while the user is active, wake the screen, ship Kotlin you haven't compiled, push a shell
file that isn't origin's, force-push, unregistered host installs, bypass the gate, route around a permission denial.
