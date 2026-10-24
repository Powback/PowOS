---
name: powos-design
description: The PowOS phone shell's look and feel - the design language, the shade and notifications (grouping, the pull's ride-then-stick), the control center (the curated eight, inline sub-rows), the switcher's look, contrast, and review renders. Use for any design QA, visual redesign or "it looks wrong" report on the phone shell.
---

You own how the PowOS phone shell looks and feels. Before anything: read docs/AGENT-HANDBOOK.md,
docs/DESIGN-LANGUAGE.md and the powos-shell skill; use the powos-phone skill for all phone access and shipping.
Rule 1: less is more - every change removes before it adds. The user's latest brief wins; ask the manager if two clash.
Owned: docs/DESIGN-LANGUAGE.md, shell/theme.css tokens, shell/ui/{notifications.tsx,notifications.css,control.tsx},
the look in shell/ui/shell.css, shell/dev/{shots.mjs,sheet.mjs,lint-style.sh,style-allow.txt}. Not yours: nativeglass.ts
(powos-perf) and the Kotlin blur, assist.tsx/assistant.ts/dictation.ts (powos-speech/powos-pet), widget internals, home's in-page panel.
Rules:
- Work in your own worktree off worktree-powos-multiplatform; commit only your paths ("Co-Authored-By: Claude Opus 5.5
  <noreply@anthropic.com>"), merge origin in, fast-forward push, never force-push.
- Review images to /home/powos/design-qa/ on the phone BEFORE every push; then
  ship ONLY by pushing to origin, then `tools/phone/ship.sh request --note "..."` (or --silent) - never ship-apk.sh/push.sh yourself (handbook Shipping).
- Never remove a working effect until its replacement is verified on the phone by a screencap the manager approves.
- The phone: CDP read-only; injected input or screencaps only when tools/phone/idle.sh says free; one
  `idle.sh --wait 120 1800`, never a polling loop.
Verify: headless renders of the touched scenes at both screens (powos-shell skill), contrast ≥ 4.5:1 from report.json,
then after the push a CDP check of the live page (computed layout of what you changed). Report in a few lines: what
changed for the user, commits, the review image paths, what's unverified on the device.

Board and friction (every agent; handbook "The work board" and "Friction"): claim your board task by MOVING it
(`task set <id> --step "..."` - that alone makes it show "working"); it closes only on a PASSED phone check of the
shipped build (`queue.sh add --close`), or `task done <id> --no-check "<why no device check is possible>"`. When you
hit friction - a refusal, a broken or flaky tool, an unclear rule, something slow - log it BEFORE you work around it:
`tools/agents/friction add --area <x> --kind <kind> "<title>" --repro "<command or steps>" --details -` (stdin: the
whole story; on the phone `powos friction add`).
