# powai friction log

Running list of issues where **powai** (the AI assistant) had to *work around* PowOS
instead of using it cleanly. Goal: powai can fix and ship PowOS end-to-end with zero
workarounds. Append every new workaround here; close items as they're fixed in source.

Format: `- [ ] <friction>` → `- [x] <friction> — fixed in <commit>`

## Open

- [ ] **Root-owned source tree blocks direct edits.** `/var/lib/powos/src` is `root:root`,
  so powai's editor can't write files — every change must be staged elsewhere and
  `sudo cp`'d in. Proposal: seed the src checkout owned by the primary user (or a
  group they're in) in the image, keeping `self test`/`push` (which touch `/usr`)
  privileged. Low risk (it's a working copy); needs image-seeding change + testing.

- [ ] **`sudo` prompts for a password on every `powos self`/`setup` call.** Deliberately
  NOT auto-fixed: a blanket `NOPASSWD` for `powos self` is effectively user→root
  escalation (`self test` writes into `/usr`), and shipping that to every install
  weakens security for everyone. Needs an explicit product/security decision before
  any default change. Local opt-in only until then.

- [ ] **`powos ai --agent X --continue` continues the GLOBAL most-recent conversation,
  not agent X.** `--continue` → `client_continue` → `claude --print --continue`, which
  resumes whatever ran last in the cwd, then grafts X's system prompt on top. With
  `--yolo` this can run an unrelated in-context plan autonomously (it did, on
  2026-07-07: a "modder" call resumed the assistant session and pushed commit
  ad071a6). Partial mitigation shipped: a loud warning when `--agent` + `--continue`
  are combined. Real fix: resolve per-agent continuity via named sessions
  (`--session <name>`), or bind `--continue` to the agent.

- [ ] **`powos ai sessions` fails for a normal user:** `mkdir: cannot create directory
  '/var/lib/powos/state/ai': Permission denied`. The AI state dir isn't user-writable.
  Same root cause family as the root-owned-tree item.

- [ ] **modder agent claimed Nexus API was "permission-gated" and punted** despite the
  key existing. Two layers: (a) instruction — now told to use the key when present
  (agent.conf); (b) product — non-interactive agents can't make tool calls without
  `--yolo` because of the permission model. (b) still open.

## Fixed

- [x] **`powos self push` (git add -A) can ship unrelated working-tree edits.**
  On 2026-07-07 a push meant for the `install.sh` mods-hang fix also carried a
  pre-existing uncommitted `lib/mods/vortex.sh` change (per-user Bottles install)
  under a single-purpose commit message (fc2c095) — unreviewed. Mitigation: `self
  push` now prints the staged file list (`diff --cached --name-status`) before
  committing, so a stray file is visible, not silent. Reviewers should still eyeball
  it. (The vortex.sh change itself was valid and kept.)

- [x] **`powos ai` sessions never persisted on fresh installs** — `AI_STATE_DIR`
  defaulted to root-owned `/var/lib/powos/state/ai`, so a normal user's `mkdir`
  failed and every session (incl. `--session <name>`) was silently lost. Moved
  per-user AI state to the XDG state home (`~/.local/state/powos/ai`), which is
  always writable, plus a runtime fallback in `_session_init`. Fixed in the
  session-dir commit. (Also unblocks resumable named sessions — the proper
  alternative to the `--continue` footgun.)

- [x] **modder agent.conf broke on load** — backticks in the double-quoted
  `AGENT_SYSTEM_PROMPT` ran as command substitution at source time. Escaped —
  fixed in `dd3c75a`; regression test guarding all agent.conf added in `ad071a6`.
- [x] **`powos self push` died with "author identity unknown" / phantom exec-bit
  files / dubious ownership on fresh installs** — self-healed in `setup gh` and
  `self push` — fixed in `ad071a6` (+ idempotency follow-up).
