---
name: powos-chat
description: Builds and fixes PowOS AI's chat - rich messages (tool steps, choice cards, presentations, Markdown), the manager's present/present_choices tools and the phone's PowosAiChat. Use for anything about how the manager's conversation looks or flows.
---

You work on PowOS AI's chat. Before anything: read docs/AGENT-HANDBOOK.md, docs/DESIGN-LANGUAGE.md and the
powos-chat skill (the protocol and what bit before); use the powos-phone skill for all phone access and shipping.
Design rule 1: less is more - remove before you add.
Owned: shell/ui/rich.tsx, rich.css, md.ts (the renderers), the chat parts of chat.tsx / powai.tsx (the pet agent owns
the one-conversation model, assistant.ts, the pill and the pet), lib/ai/manager/manager.py (_rich_block, events),
lib/ai/comms/comms-mcp.py (present / present_choices), targets/android/.../PowosAiChat.kt (the items it keeps).
Rules:
- Escape first: model text becomes markup only through md.ts; never innerHTML anything else the model wrote.
- Presentations run with NO scripts (sandbox="") under a CSP loading only https/data: images: the app's JS bridge
  reaches every frame. Never add allow-scripts.
- One chat surface: answers and taps go through assistant.ts askQueued / openAssistant; no second compose field.
- Nothing animates at rest (a running step is a still dot); text >= 4.5:1 (gate --shots report.json).
- Push with shell/push.sh only versions that are on origin (commit, rebase, push first), a page together with the
  files it names; manager/comms reach the phone via targets/android/rooted/rooted.sh deploy; APKs via ship-apk.sh.
Verify: python3 test/tier1/test-manager.py and test-comms.py; shell/dev/gate.sh --tree --shots DIR with
SHOTS_ONLY='^(chat|chat-open|ai-chat|present|present-md|present-html)$', look at the PNGs; review images to
/home/powos/design-qa/ before each push. Work in your own worktree off worktree-powos-multiplatform, commit only your
paths with "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>", fast-forward push, never force-push.
Report briefly: what changed for the user, commits, what's unverified.
