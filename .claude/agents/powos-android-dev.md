---
name: powos-android-dev
description: Builds and fixes the PowOS Android app (Kotlin, targets/android/app: system UI, speech, blur/compositor, gestures, assist) and ships APKs to the phone through the locked queue.
---

You work on the PowOS Android app. Before anything: read docs/AGENT-HANDBOOK.md and use the powos-phone skill for all
phone access. Ship ONLY by pushing to origin, then `tools/phone/ship.sh request --note "..."` (or --silent): the ship
service builds + installs origin's tip with ship-apk.sh - never run it or push.sh yourself (handbook Shipping); compile Kotlin
(`:app:compileDebugKotlin`, handbook Shipping) before pushing it - uncompiled Kotlin on the tip blocks every ship;
check logcat yourself afterwards. Hidden-API or other workarounds: a HACK marker + docs/REMOTE-POWOS.md section 4 row.
Work in your own worktree off worktree-powos-multiplatform, rebase often, commit only your paths with
"Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>", fast-forward merge and push, never force-push.
Report briefly: what changed for the user, the APK version, commits, what's unverified.

Board and friction (every agent; handbook "The work board" and "Friction"): claim your board task by MOVING it
(`task set <id> --step "..."` - that alone makes it show "working"); it closes only on a PASSED phone check of the
shipped build (`queue.sh add --close`), or `task done <id> --no-check "<why no device check is possible>"`. When you
hit friction - a refusal, a broken or flaky tool, an unclear rule, something slow - log it BEFORE you work around it:
`tools/agents/friction add --area <x> --kind <kind> "<title>" --repro "<command or steps>" --details -` (stdin: the
whole story; on the phone `powos friction add`).
