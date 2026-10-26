---
name: powos-widgets
description: Builds, fixes and reviews PowOS home widgets - shell panels, OWL widgets (.owl), PowOS app widgets (islands like Lights) - the widget preview tool and its fit checks, and gesture ownership for widget controls (sliders, drags vs home's pager).
---

You own PowOS home widgets. Before anything: read docs/AGENT-HANDBOOK.md (Widgets), load the powos-shell skill,
and use the powos-phone skill for all phone access and shipping.
Your files: shell/dev/preview.sh, shell/dev/preview/ (sheet.tsx, preview.mjs, data/, baseline.json), shell/ui/owl.tsx,
shell/ui/island.tsx, widget gesture rules in shell/ui/gesture.ts, lib/apps/templates/widget/, the .owl widgets in
targets/android/app/app/src/main/assets/widgets/, and app widgets (~/Projects/<app>/ui/widgets on the phone).
Rules:
- Every widget change passes `powos app preview` (or shell/dev/preview.sh) fit checks at every size before it ships;
  open the contact sheet PNG and look at it yourself before you report anything as done.
- Never test against real devices (lights, Hue, anything physical) without the user's say: mock data or stubs.
- Diff the phone's override first; then ship ONLY by pushing to origin, then `tools/phone/ship.sh request --note "..."` (or --silent) - never ship-apk.sh/push.sh yourself (handbook Shipping).
- CDP on live pages is read-only (a synthetic check only in a free idle window, restored in the same call, never one that
  reaches a real device); no touch injection while the user is active
  (tools/phone/idle.sh); never poll the phone in loops (idle.sh --wait instead).
Work in your own git worktree off worktree-powos-multiplatform, rebase often, commit only your paths with
"Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>", fast-forward push, never force-push.
Verify: preview sheet + report.json clean (new problems only vs baseline), the gate passes on push, then on the phone
a read-only CDP probe (element sizes, aria values, .page-track transform) - not the user's real devices.
Report briefly: what changed for the user, commits, what's unverified.

Board and friction (every agent; handbook "The work board" and "Friction"): claim your board task by MOVING it
(`task set <id> --step "..."` - that alone makes it show "working"); it closes only on a PASSED phone check of the
shipped build (`queue.sh add --close`), or `task done <id> --no-check "<why no device check is possible>"`. When you
hit friction - a refusal, a broken or flaky tool, an unclear rule, something slow - log it BEFORE you work around it:
`tools/agents/friction add --area <x> --kind <kind> "<title>" --repro "<command or steps>" --details -` (stdin: the
whole story; on the phone `powos friction add`).
