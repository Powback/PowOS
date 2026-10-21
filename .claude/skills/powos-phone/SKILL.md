---
name: powos-phone
description: Use whenever you need to reach, inspect, test, or ship to the PowOS phone (OnePlus Open) - adb over the VPN, root inside PowOS, the user-idle check, WebView devtools, logcat tags, shell pushes and the locked APK build/install queue.
---

Read `docs/AGENT-HANDBOOK.md` (repo root) first - it is the map of how the phone pieces connect.

Tools (repo `tools/phone/`):
- `adb.sh <args>` - adb to the phone from any session (files under $HOME only).
- `root.sh <script>` - run a script as root inside PowOS.
- `idle.sh` - `idle=<s> screen=<state>`; drive the phone only at idle>=120 and screen=Awake; never wake it.
  To WAIT for that, `idle.sh --wait 120 MAX_S` (one held call, the wait runs on the phone) - never a polling loop from
  the Mac (docs/AGENT-HANDBOOK.md).
- `ship-apk.sh --note "..."` - the ONLY way to build+install the APK (lock, clean tree, idle wait, verify).
Shell files: `shell/push.sh --vpn --note "..." <files>` (gate must pass; check the phone's overrides first).

Never: sudo via powos-run.sh, touch injection while the user is active, waking the screen, force-push,
unregistered host installs, bypassing the gate.
