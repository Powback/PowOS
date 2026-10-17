# PowOS AI on Android

Status: first slice, 2026-10-17. PowOS AI (`powos ai`, its persistent manager, the agents' comms) is PowOS's agent
system; on a phone it is the phone's agent too - the launcher uses it, and it reaches Android.

## Done

- **The launcher's agent is PowOS AI** whenever the PowOS session runs (rooted mode): `POWOS_AI` in
  `linux/Agents.kt`, `AgentStore.default`. Every agent entry point follows - the prompt bar ("ask PowOS AI"),
  editing / reviewing / publishing / fixing a widget, "new app". It runs as the persistent manager:
  `powos manager --once <prompt>` answers, then the conversation stays open (`exec powos manager`, which resumes
  it - one memory across the phone's entry points). Read-only prompts (something untrusted) run `--safe`.
  Without the session (the no-root guest) the launcher keeps Omarchy's coding agents.
- **The launcher's files in PowOS**: its widgets and styles (`files/widgets`, `files/style`) are bound to
  `~/.config/omalauncher/{widgets,style}` in PowOS (rooted/powos-session.sh) - where the widget prompts expect them,
  and where PowOS AI and the user's shell edit what the home screen draws.
- **`powos android`** (lib/android.sh): Android from PowOS, over adb to the phone itself - `apps`, `open <app>
  [--full]`, `running`, `notifications`, `notify <title> [text]`, `screenshot`. In `powos help`, so every agent's
  prompt (generated from it) knows it.
- **Agents reach the user on Android**: `notify_user` / `powos comms notify` also post an Android notification on a
  phone (comms-mcp.py `_phone_notify`).
- The agents' shared context (`config/ai/context/capabilities.md`) has a "PowOS on a phone" section.

- **A native chat** (`PowosAiActivity` + `PowosAiChat`, its own task "PowOS AI"): each message is one manager turn,
  `powos manager --once-stdin --json-events` in the session, drawn from the same normalized events the KDE widget
  uses (assistant text, tool use with ok/err). The manager keeps the conversation (its session for `~`, which
  `powos manager` in a terminal continues); the phone keeps what it showed (`files/powos-ai/chat.jsonl`).
  The launcher's prompt bar and search open it ("ask PowOS AI: ..."); in the PowOS session they no longer offer
  to install the proot Linux - PowOS is the Linux.
- **Android entry points**: the share sheet ("PowOS AI": text, or a file copied to `/run/powos-app/powos-ai-shared/`,
  put in the field for the user's words), the assistant gesture (ACTION_ASSIST: pick PowOS as the phone's digital
  assistant app), a Quick Settings tile (`PowosAiTile`).
- **Agent mail with inline reply**: `notify_user` / `powos comms notify` on a phone write
  `/run/powos-app/agent-mail/<id>.json`; the app (`AgentMail`) posts each as a notification - tap for the chat,
  Reply answers inline (`powos comms send <agent> <text>`, into that agent's inbox).
- **Claude on the phone**: PowOS AI needs the `claude` CLI - `powos ai install claude` (native installer, in
  `~/.local/bin`, now on the rooted session's PATH) and `powos config claude-endpoint http://claude-auth.pow`
  (the fleet's auth authority, as a follower: no login on the phone).

## Next

- Stream a turn into the chat as it happens across sessions: the manager's long-running mode (repl, with the live
  inbox) behind the chat instead of a process per turn, so agent mail arrives in the conversation too.
- Markdown in the chat (code blocks, lists), and voice input (the launcher's speech) in the chat field.
- `powos android` for more of the phone: calendar and contacts (the PowOS app's providers), location, the camera,
  intents (`powos android share <file>`); and the launcher's state (pages, tiles, the drawer) to read and arrange.
- First-run setup of Claude on the phone from the app (install + endpoint), instead of by hand.
