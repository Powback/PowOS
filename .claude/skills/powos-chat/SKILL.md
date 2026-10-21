---
name: powos-chat
description: Use when changing PowOS AI's chat - how the manager's messages render (tool steps, choice cards, presentations, Markdown), the manager's present/present_choices tools, its event stream, or the phone's PowosAiChat items.
---

# PowOS AI's chat: how a manager turn becomes what the user sees

## The path
1. The phone (PowosAiChat.kt) runs one turn per message inside PowOS: `powos manager --once-stdin --json-events`
   (lib/ai/manager/manager.sh -> manager.py over `claude -p --input-format stream-json`).
2. manager.py normalizes claude's stream to one JSON event per line: `assistant {text}`, `tool_use {name, hint}`,
   `tool_result {ok, text (160 chars, one line: the terminal's), out (2 KB, lines kept: the chat's)}`, `turn_done`,
   `inbox`, `session`.
3. PowosAiChat.kt keeps items (User / Assistant / Tool{name,hint,ok,out} / Note, last 300, a JSON-lines file) and
   hands them to the shell as `ai.chat` / `ai.changed` (types.ts ChatItem). Unknown event kinds are dropped - a new
   kind needs an APK; a new block inside assistant text does not.
4. The shell renders: chat.tsx (the drawer's chat, the one chat surface) and powai.tsx (the AI page's latest turn +
   history) both go through ui/rich.tsx: `Thread` folds consecutive tool items into one `ToolRun`, `Said` splits an
   assistant text into prose (Markdown via md.ts) and blocks.

## The fenced-block protocol (manager.py `_rich_block`)
The comms MCP has `present_choices {question, options[2-8], multi}` and `present {title, format md|html, body}` -
registered only when COMMS_AGENT_ID=manager (the only stream a chat renders). The tool itself just answers the model
("end your turn"); manager.py, on seeing the tool_use, emits an extra assistant event whose text is
    ```choices            or        ```present
    {one JSON line}                 {"title":..,"format":..,"body":..}   (body capped at 64 KB)
    ```                             ```
So any consumer of the stream gets it (the KDE plasmoid shows it as code). Only these two names are blocks
(rich.tsx BLOCK); every other fence is code inside the prose. Tools named present / present_choices are hidden from
tool runs (shownElsewhere). AskUserQuestion is disallowed for the manager (--disallowedTools): headless, nobody can
answer it.
A choice tap = askQueued(option) (multi: joined ", "); "other…" = openAssistant + focus the pill. A card counts as
answered when a user item follows it (Thread passes `reply`); then only the question stays.

## Security
- Android injects the app's JavaScript bridge into EVERY frame, iframes included. HTML presentations therefore get
  `sandbox=""` (no scripts) + a CSP meta (`default-src 'none'; img-src https: data:; style-src 'unsafe-inline'`).
  The theme's text colour is injected as values (the frame can't read the shell's tokens); no color-scheme (a
  mismatching one paints an opaque canvas).
- md.ts escapes everything first; links only http(s) (opened outside via apps/native.ts openLink, data-link), images
  only https/data:image. Test it with hostile input (`<script>`, `javascript:` links) after any change.

## Shipping and what bit
- The gate (shell/dev/gate.sh) refuses a push when a local file a page names (html href/src, a script's "./ui/x.css")
  isn't in what the phone will serve: an index.html override once named ui/rich.css before rich.css was there. Push a
  page with what it names, in one push.
- An APK install resets every override: commit + push to origin first, or a later APK drops your shell push.
- Before pushing, compare the installed APK's shell (~/.cache/powos-gate/installed/<key>/shell) with yours.
- manager.py / comms-mcp.py reach the phone only through `targets/android/rooted/rooted.sh deploy --note ".."` (needs
  local adb to the phone; it installs lib/ai/manager since a27042e). Check inside PowOS:
  `tools/phone/root.sh` a script that greps /usr/lib/powos/ai/manager/manager.py and runs comms-mcp.py tools/list with
  COMMS_AGENT_ID=manager.
- No endless animation (the compositor re-blurs every frame): a running step is a still accent dot.

## Tests
- `python3 test/tier1/test-manager.py` (RichBlockTests), `python3 test/tier1/test-comms.py` (PresentTests).
- Shell: link node_modules into your worktree's shell/ (remove it before ship-apk: it needs a clean tree), then
  `shell/node_modules/.bin/tsc --noEmit -p shell` and
  `SHOTS_ONLY='^(chat|chat-open|ai-chat|present|present-md|present-html)$' shell/dev/gate.sh --tree --shots DIR`
  (sample conversations: CHAT_SAMPLE / PRESENT_SAMPLE in shell/dev/shots.mjs). Read the PNGs and report.json's
  lowContrast. The headless font has no bold face: check bold on the phone.
