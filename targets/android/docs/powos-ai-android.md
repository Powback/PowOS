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

## Next

- A native chat for the manager in the launcher: a tile/screen rendering `powos manager --json-events` (the event
  stream the KDE widget already uses - bubbles, tool panels), instead of the manager's terminal.
- Android entry points: a share target ("send to PowOS AI"), a Quick Settings tile, the assistant gesture
  (VoiceInteractionService) - each opening the manager with what was shared.
- Agent mail as Android notifications with actions (reply inline: `powos comms send manager ...`), and the manager's
  inbox on the lock screen.
- `powos android` for more of the phone: calendar and contacts (the PowOS app's providers), location, the camera,
  intents (`powos android share <file>`); and the launcher's state (pages, tiles, the drawer) to read and arrange.
