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
  (the fleet's auth authority, as a follower: no login on the phone). When its login lapses: the native sign-in below.

## Native Claude sign-in (no `/login` in terminals)

The phone (rooted or not) notices when Claude's login is **missing** or **needs a refresh** and offers a **Login**
button where the user sees it. It is **claude-login end to end** (`~/Projects/claude-login`: the real `claude /login`
run headless, the subscription URL it prints, the pasted `code#state` typed back into that same process). Nothing in
PowOS builds an OAuth URL or exchanges a code.

- **Two backends, picked by how this machine's claude is configured** (`lib/ai/manager/fleet_login.py`,
  `powos manager --fleet-login status|word|login`):
  - **authority** - an endpoint (`/etc/powos/ai/endpoint.conf`: `ANTHROPIC_BASE_URL=http://claude-auth.pow` + the
    tenant's secret). State from the authority's `GET /auth/check` (whose tenant the secret is) and `GET /tenants`
    (that tenant's `auth.ok / hasCreds / needsReauth / lastError`). Login = the authority's `POST /oauth/start` and
    `/oauth/complete` (which run claude-login there), authorized with the tenant's own secret. The authority stays
    the only refresher: the phone never holds a refresh token or writes a `.credentials.json`.
  - **direct** - no endpoint (a sellable non-root install): claude-login runs in PowOS's Linux
    (`POWOS_CLAUDE_LOGIN`=its `dist/cli.js`, or `claude-login` on PATH) and writes the image's own
    `~/.claude/.credentials.json` (mode 600, straight to the file - the app never sees it). State from that file's
    presence/expiry/refresh token. The non-root image ships it (11-09): build-rootfs.sh stages claude-login's `dist/`
    (`CLAUDE_LOGIN_DIR`, default `~/Projects/claude-login`), install-powos-android.sh puts it in `/usr/bin/claude-login`
    (bun runs it; no node in the image) and installs Claude Code itself into `/root/.local/bin`. A login that ends
    without a line of its own shows its stderr's last line ("the sign-in stopped: ...").
- **Detection**: `powos manager --auth` says `relogin` (new word; `signin` stays "no login at all, direct"), a chat
  turn emits `{"kind": "relogin"}` (status 4), a failed turn asks again, the app re-asks every 10 min, and a terminal
  whose output says claude's `run /login` / `Invalid API key` / 401 (`shell/ui/claudesignin.tsx` `LOGIN_PROMPT`).
- **Where the user sees it**: the AI page (the sheet instead of the chat), the terminal tile (a sheet at its foot),
  Settings > AI ("Claude sign-in needed · log in"), and a notification "Claude sign-in needed - powback" (tap: the AI
  page). One state for all (`Chat.signin`, `ClaudeSignIn.kt`).
- **Flow**: Login -> the code box shows at once and the link opens in the phone's browser (Android `ACTION_VIEW`);
  sign in on claude.com (PowOS never sees the password) -> paste the `code#state` (or the Paste button) -> Sign in ->
  "Signed in to Claude - powback" live, or the authority's/claude-login's error in its words with Login again. One
  held process (`--fleet-login login`) carries the two steps: its first line the URL, stdin the code, last line done.
- **Tests**: `test/tier1/test-fleet-login.py` (fake authority + fake claude-login: both states, both backends, the
  manager words, no secret printed), JVM `ClaudeSignInTest`, gate scene `ai-signin` (`shell/dev/ai-signin-check.js`).

## Next

- Stream a turn into the chat as it happens across sessions: the manager's long-running mode (repl, with the live
  inbox) behind the chat instead of a process per turn, so agent mail arrives in the conversation too.
- Markdown in the chat (code blocks, lists), and voice input (the launcher's speech) in the chat field.
- `powos android` for more of the phone: calendar and contacts (the PowOS app's providers), location, the camera,
  intents (`powos android share <file>`); and the launcher's state (pages, tiles, the drawer) to read and arrange.
- First-run setup of Claude on the phone from the app (install + endpoint), instead of by hand.
