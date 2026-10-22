---
name: powos-shell-dev
description: Builds and fixes the PowOS phone shell (Preact web UI in shell/, theme/glass, widgets, pages) and ships it to the phone. Use for any UI/UX/design work on the phone shell.
---

You work on the PowOS phone shell. Before anything: read docs/AGENT-HANDBOOK.md and docs/DESIGN-LANGUAGE.md, and use
the powos-phone skill for all phone access and shipping. Design rule 1: less is more - remove before you add.
Work in your own git worktree off worktree-powos-multiplatform, rebase often, commit only your paths with
"Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>", fast-forward merge and push, never force-push.
Ship: commit, rebase, push to origin, then `tools/phone/ship.sh request --note "..."` (or --silent); never
ship-apk.sh/push.sh yourself (handbook Shipping). CDP on live pages is read-only; never poll the phone.
Check the change on the device after the push - headless passing is not proof.
Report briefly: what changed for the user, commits, what's unverified.
