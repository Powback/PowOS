---
name: powos-bridge-security
description: Use when touching how the PowOS shell page talks to the Android app - the native objects PowosHost/PowosNative/PowosBoot, ShellOrigin/ShellHost origin checks, iframes/presentations/web content inside the shell, or tools/phone/bridge-check.sh.
---

## Threat model
- WebView.addJavascriptInterface injects the object into EVERY frame of the page (iframes included, sandboxed
  ones too - checked on the phone: an opaque-origin presentation frame had PowosHost) and the Java side cannot
  tell who called. The host API can fetch with the user's secrets, launch/uninstall apps, change settings - so any
  script in any iframe owned the phone. That is why the objects are no longer JS interfaces.
- Now: androidx.webkit `WebViewCompat.addWebMessageListener(web, name, rules, listener)` in ShellHost.kt. The
  WebView injects only into frames matching `rules`, and the listener gets the sender's origin + isMainFrame.

## Allowed
- `ShellOrigin.rules(devUrl)`: `https://shell.powos` (never hits the network; ShellHost serves every request) plus
  the dev server's origin when a dev URL is set. If the WebView rejects the rule set, ShellHost falls back to the
  shell origin only (logged "origin rules ... refused").
- `ShellOrigin.allowed(origin, isMainFrame, rules)`: top frame AND exact origin in rules. Nothing else.

## Refused (and logged, tag PowosShell: "<name>: refused a message from an iframe|the top frame at <origin>")
- any iframe, even same-origin srcdoc/about:blank (they inherit the parent's origin, so origin alone can't tell);
- "null"/opaque origins (sandboxed frames, data: URLs), empty/missing origin, any other origin.
- Answers always go to the top frame (ShellBridge.respond), so a subframe never needs the bridge.

## Page side
- shell/bridge.ts and shell/apps/native.ts talk via `window.PowosHost.postMessage(...)`; index.html's boot guard
  handles PowosBoot and an older APK. The desktop's call() is unchanged. PowOS app UIs (./_app/<id>/) are modules
  in the top frame, so Lights/Shopping/Sketch keep their bridge; anything in an iframe is bridge-less by design.

## Tests
- JVM: `cd targets/android/app && ./gradlew :app:testDebugUnitTest --tests dev.omalauncher.shell.ShellOriginTest`
- Live: `tools/phone/bridge-check.sh [page]` (home by default; lock, shade, assist...). Over CDP it adds 0x0 probe
  iframes (srcdoc, about:blank, sandboxed, data:) that each try one harmless apps.list call. Exit 0 = top frame
  has the bridge and no probe could use it; 1 = leak or no bridge; 2 = couldn't run. It hangs while the phone
  dozes (WebView paused) - run only with screen Awake and idle>=120 (tools/phone/idle.sh); never wake the phone.
- After any ship: `tools/phone/adb.sh shell "logcat -d -v time | grep 'refused a message'"` should be empty in
  normal use; a hit from the top frame at https://shell.powos means the check broke the shell itself.
