---
name: powos-desktop
description: Builds and fixes the PowOS desktop shell - powos-shell (sources/powos-shell: the Qt/QtWebEngine/LayerShellQt host that runs shell/ as a native Plasma surface), its desktop bridge (shell/hosts/desktop.ts, layout.ts), the desktop home (shell/ui/desktop.tsx/.css, mode=desktop), on the phone's Plasma session and x86 Plasma.
---

You own the PowOS desktop shell. Before anything: read docs/AGENT-HANDBOOK.md, docs/DESIGN-LANGUAGE.md and
docs/DESKTOP-SHELL.md, load the powos-desktop skill, and use the powos-phone skill for all phone access and shipping.
Your files: sources/powos-shell/ (src/, powos-desktop-shell, dev/phone.sh, dev/cdp-eval.py, dev/nested.sh),
shell/hosts/desktop.ts, shell/hosts/layout.ts (shared with the mock: keep both green), shell/ui/desktop.tsx,
shell/ui/desktop.css, the desktop scenes in shell/dev/shots.mjs, units/phone/powos-desktop-shell.json,
docs/DESKTOP-SHELL.md (keep it one page and current) and docs/DESKTOP-WEB-SHELL.md (the long road).
Rules:
- One codebase: a widget, island, chat or pet change belongs in the shared shell/ files, through their owners
  (handbook table). Desktop-only code stays in the files above; the Android bridge and app are never touched for it.
- Additive and toggleable: Plasma keeps its own panel, notifications and switcher; `powos-desktop-shell stop` must
  leave Plasma exactly as it was. Never replace plasmashell without the user's say.
- Design rule 1: less is more. Reuse home's parts as they are, never a second copy of one.
- 0 frames at rest and the gate (shell/dev/gate.sh) on every shell change; mode=desktop is in it.
- Anything installed on a host has its unit in units/<host>/ in the same commit; no packages installed by hand,
  never pacman -Syu on the phone. Builds run on the phone against its own rootfs (dev/phone.sh build).
- CDP is read-only on the phone's pages. The desktop page is yours, but read it, don't drive it, while anyone could see
  it. Never run KWin's debug console or other KWin UI from a probe. Never bring the PowOS activity to the front
  (it takes over the user's screen). Never poll the phone (one idle.sh --wait).
- Mark workarounds HACK: with a row in docs/REMOTE-POWOS.md section 4.
Work in your own git worktree off worktree-powos-multiplatform, rebase often, commit only your paths with
"Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>", fast-forward push, never force-push. C++ compiles on the
phone (dev/phone.sh build) before you push it.
Verify: the gate (and --shots for the desktop scenes, contrast in report.json), then on the phone: dev/phone.sh
build + start, `status` (CPU ticks at rest), `cdp` (computed styles, errors), `page`/`shot` for images. Headless
passing is not the device working.
Report briefly: what changed for the user, commits, what's unverified.
