---
name: powos-comms
description: Use when working on PowOS inter-agent comms - `powos comms` (send/watch/inbox/read/notify), the comms MCP tools, the manager's inbox injection (manager.py --once-inbox / live), powos-agentsd and the agents module's message feed, or the phone's agent-mail notifications. The model, the truncation pitfalls, deploy and tests.
---

# PowOS comms: how it works and what bites

## Model
- Daemonless spool: `$COMMS_ROOT` (default `${XDG_STATE_HOME:-~/.local/state}/powos/comms`), one inbox per role:
  `agents/<role>/inbox/<ts>-<priority>-<id>.json` = `{id, from, to, kind, priority, ts, iso, body[, result]}`,
  written tmp + rename (atomic), FIFO by filename. Same code for MCP (stdio JSON-RPC, no argv) and CLI (any argv).
- `_deliver()` also: on a phone (`POWOS_PLATFORM=phone` or /etc/powos/platform) touches
  `$XDG_RUNTIME_DIR/agent-wake/<role>-<ms>` (the app runs the manager's `--once-inbox` turn), and drops a
  `message` record in the Agents queue (`POWOS_AGENTS_QUEUE` / /dev/shm/powos-agents-$USER) for powos-agentsd.
- notify (`notify_user`, `powos comms notify`) -> user inbox + `$XDG_RUNTIME_DIR/agent-mail/*.json`
  `{id, from, text, priority, time}` -> AgentMail.kt posts the notification; `{"op":"read","ids":[..]}` marks read.
- Manager: `take_inbox()` drains its inbox into turn texts
  `[inbox message from agent 'X' (P)]: <body>\n\nHandle this: ...`; live mode polls it 1 s, `--once-inbox` joins all
  with `\n\n`; `--json-events` emits `{"kind":"inbox","text":...}` which PowosAiChat shows as a note.

## CLI facts
- `watch` and `inbox` (without `--peek`) CONSUME the messages; a crash or a cut-off output after the read loses them.
  Use `--peek` to look; consume with `--json` into a file you keep (handbook, Comms).
- `--json` (inbox/watch): one JSON object per message per line, the exact stored body. Text form: header
  `• [prio] from X (kind) at ISO [id ID]`, then every body line indented 4 spaces (strip 4 to recover).
- `send <to> -` / `notify -`: body from stdin; only ONE trailing newline is dropped. `send <to> -- -text`: a body
  starting with `-` (the app's inline reply uses `--`).

## The 10 truncation/corruption points fixed (b1329eb) - don't reintroduce
1. comms-mcp `_agents_note` body[:400]  2. agentsd `clean(body, 280)` (one line)  3. agents module `cut(body, 280)`
4. shell .ag-msg nowrap/ellipsis with no tap-to-open  5. PowosAiChat.inboxLine first line .take(140)
6. AgentMail BigText > Android's 5 KiB MAX_CHARSEQUENCE_LENGTH silently dropped (now capped with "N more - tap")
7. locale-dependent stdio: ASCII locale crashed inbox/watch AFTER draining; latin-1 mis-decoded MCP input
8. `notify -` .strip()  9. `_fmt_msgs` indented only the first body line  10. reply starting with `-` = argparse error.
Display-only caps that are fine: manager `_tool_hint` (120), `_result_text` (160), `_result_out` (2000) - tool
output, not messages. agentsd still scrubs secret-shaped strings (deliberate).

## Deploy
- lib/ai -> phone: `targets/android/rooted/rooted.sh deploy --note "..."` (pushes comms-mcp.py, lib/ai/manager,
  lib/ai/agents, plus everything else rooted needs; powos-deploy.sh installs to /data/powos/root/usr/lib/powos/ai/).
  It calls a bare `adb`: put a shim first on PATH that execs tools/phone/adb.sh AND realpath's existing absolute
  args - adb.sh mounts dirname into a container and a `..` path ("rooted/../session/...") fails "cannot stat".
- The phone's manager runs one process per chat turn, so a deploy takes effect next turn (no restart).
- Agents module changes need an STDB module publish (not done by rooted.sh deploy).
- Verify with ONE batched adb call (md5sum the installed files). Never poll.

## Tests
python3 test/tier1/test-comms-fulltext.py   # 10 KB unicode/quotes/$/CRLF round-trip: CLI, MCP stdio, manager, phone files
python3 test/tier1/test-comms.py; python3 test/tier1/test-manager.py; python3 test/tier1/test-agents.py
(`just test` / run-all.sh needs bash 4: CI/Linux; the Mac's bash 3.2 can't run run-all.sh.)
Shell tsc: a fresh worktree has no shell/node_modules - the gate skips tsc; symlink another worktree's
(`ln -s <other>/shell/node_modules shell/`; .gitignore's `node_modules` ignores the link, so the tree stays clean).
