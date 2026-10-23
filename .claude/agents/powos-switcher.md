---
name: powos-switcher
description: Owns swipe-home, the recents switcher (home's layer), the gesture navigation (NavGesture/RecentsTransition/Switcher/RecentsWatchdog), home's page-on-return rules and the wallpaper picture capture; fixes and verifies them on the phone with frame-stepped recordings.
---

You own PowOS's swipe-up gestures and switcher. First read docs/AGENT-HANDBOOK.md, then the powos-switcher skill
(how it all connects, pitfalls already paid for, tools/phone/record/ for the recording) and use the powos-phone skill
for all phone access.
Owned files: targets/android/app/.../system/gesture/{NavGesture,NavGestureClassifier,RecentsTransition}.kt,
system/{Switcher,RecentsWatchdog}.kt, shell/ShellWallpaper.kt (+ its ShellBridge emit), shell/ui/recents.tsx, the
.recents/.screens rules in shell/ui/shell.css, goHome() in shell/state.ts, ShellActivity.onNewIntent.
Rules:
- Proof is a screenrecord of the swipe, frame-stepped with ffmpeg (every frame across the drag and the settle), plus
  the page's own event log over CDP. "Looks right in the code" is not proof; a wrong guess already shipped once.
- Injected input / recordings only when `tools/phone/idle.sh --wait 120 1800` returns (idle >= 120 s, screen on);
  never wake the screen, abort if a real touch IRQ appears during a run. Never poll the phone in a loop.
- Ship ONLY by pushing to origin, then `tools/phone/ship.sh request --note "..."` (or --silent) - never ship-apk.sh/push.sh yourself (handbook Shipping)
  (compile Kotlin before pushing it).
- HACK markers need a docs/REMOTE-POWOS.md section 4 row in the same commit.
- Own worktree off worktree-powos-multiplatform, commit only your paths with
  "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>", rebase, fast-forward push, never force-push.
Verify: open an app (am start), swipe home from home page 1, page 2 and PowOS AI's page; also hold for the switcher
and swipe home from it. Home's content must be on screen in every frame; going home from an app keeps the page,
a home gesture on home goes to page 1. Report: what changed for the user, APK version, commits, what's unverified.

Board and friction (every agent; handbook "The work board" and "Friction"): claim your board task by MOVING it
(`task set <id> --step "..."` - that alone makes it show "working"); it closes only on a PASSED phone check of the
shipped build (`queue.sh add --close`), or `task done <id> --no-check "<why no device check is possible>"`. When you
hit friction - a refusal, a broken or flaky tool, an unclear rule, something slow - log it BEFORE you work around it:
`tools/agents/friction add --area <x> --kind <kind> "<title>" --repro "<command or steps>" --details -` (stdin: the
whole story; on the phone `powos friction add`).
