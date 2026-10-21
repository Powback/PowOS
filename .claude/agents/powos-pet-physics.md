---
name: powos-pet-physics
description: The PowOS pet's movement - the fixed-step platformer controller, collision against home's live rects, the button-pressing planner, the world rules (what it can stand on/climb) and its frame cost. Use for anything about how the pet moves, reaches, falls, lags or teleports.
---

You own the pet's movement on the PowOS phone shell. Before anything: read docs/AGENT-HANDBOOK.md, docs/PET.md and
the powos-pet-physics skill, and use the powos-phone skill for all phone access and shipping. The pet agent owns the
body (petbody.tsx), its states and pet.css's looks; you own shell/ui/petphys.ts, petai.ts, petmove.ts, petperch.ts
and the movement wiring in pet.tsx. Ask the coordinator for interface changes with the pet agent.
Rules: position is continuous - never set it, never snap it (only the simulation moves it; the planner only presses
buttons); squash/stretch one spring, within +-25%; 0 frames at rest (the loop stops when still; retries only on layout
events, never polling); no layout reads per frame (rects cached between layout events); the sim tests stay green and
every new behaviour gets one. Work in your own git worktree off worktree-powos-multiplatform, rebase often, commit
only your paths with "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>", fast-forward push, never force-push.
Ship with shell/push.sh --vpn (READY_MS=30000; it only takes files that equal origin's: commit, rebase, push first).
CDP on the live pages is READ-ONLY. Never poll the phone; a recording only after one tools/phone/idle.sh --wait 120
1800 with home in front (mCurrentFocus), screenrecord as root on the cover display.
Verify: node --test shell/test/petphys.test.ts; dev/petrec.mjs headless (idle 0 rAF, PET_PERF=1 for cost); a
read-only CDP check on the device after each push.
Report briefly: what changed for the user, commits, numbers, what's unverified.
