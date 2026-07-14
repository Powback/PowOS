# powai friction log

Running list of issues where **powai** (the AI assistant) had to *work around* PowOS
instead of using it cleanly. Goal: powai can fix and ship PowOS end-to-end with zero
workarounds. Append every new workaround here; close items as they're fixed in source.

Format: `- [ ] <friction>` → `- [x] <friction> — fixed in <commit>`

## Open

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

- [ ] **`powos self test` aborts on an already-unlocked bootc deployment.** Its
  `self_usr_ro` writability probe runs as the calling (non-root) user, so on a
  deployment already in bootc `development`/unlocked state it still sees `/usr` as
  read-only (root-writable, user not), then calls `bootc usr-overlay` which errors
  "Deployment is already in unlocked state: development" and the whole test bails —
  nothing applied. Worked around 2026-07-07 by invoking the underlying apply
  directly: `sudo powos update self --from /var/lib/powos/src`. Fix: probe as root
  (or treat "already unlocked" as success, and re-check writability with sudo).

- [ ] **jackify-engine hangs indefinitely when CWD contains a slow/dead network
  mount.** The Wabbajack engine (`lib/mods/modlist.sh`) walks its working directory
  on startup; with CWD = the user's HOME containing a CIFS `~/NAS` automount, a
  single `list-modlists` wedged 12+ min in uninterruptible IO (kernel stack:
  `cifs_readdir → SMB2_query_directory → wait_for_response`). FIXED in the wrapper
  (run the engine from a guaranteed-local CWD + a `timeout` bound on the gallery
  call), so this is closed on the PowOS side — noted here as the diagnosis of a
  "took forever" class of hang that also bit the old Bottles/Vortex path.

## Fixed

- [x] **Root-owned source tree / `sudo` needed for self push.** Turned out the fix
  already ships: `/etc/tmpfiles.d/powos-self-src.conf` has a `Z` rule that recursively
  re-chowns `/var/lib/powos/src` to `powos:powos` on every boot. The tree only went
  root-owned MID-SESSION because `.git` was created by a `sudo powos self pull` (git
  as root makes root-owned files). Resolution: **never `sudo` `self pull`/`push`** —
  the powos user owns the tree and is git-authed as Powback with a credential helper,
  so they run clean and unprivileged; edit source files directly (no `sudo cp`). Only
  `self test` needs sudo (it writes the `/usr` overlay). A stray root-owned tree
  self-heals on reboot, or `sudo chown -R powos:powos /var/lib/powos/src`.
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

- [x] **`powos self test` aborted with "/usr still read-only after usr-overlay"**
  — `self_usr_ro()` wrote its probe file as the invoking user; root-owned /usr
  returns EACCES even on a writable overlay, misread as "read-only". Probe now
  runs via sudo — fixed in `cc9065e`.

- [ ] **`powos update self` self-corrupts the running `powos` process** — the
  bin/ deploy does a non-atomic `cp` over `/usr/bin/powos` while that very bash
  is executing it → bogus "syntax error near unexpected token" / "unexpected
  EOF" and a failed deploy (hit again 2026-07-11 during `self test`). A fix
  (copy-to-temp + `mv`) ALREADY EXISTS in the `powos-bundle-edits` stash in
  /var/lib/powos/src but never landed upstream — resolve the stash and ship it.

- [ ] **`self test`/`update self` doesn't deploy `desktop/autostart/` or
  `desktop/plasmoid/`** — the image build COPYs them but the live deploy skips
  them, so autostart/widget changes can't be tested transiently (had to sudo cp
  by hand for powos-panel-center). The same stash contains this deploy step too.

- [ ] **`powos self pull` first git-attach left 41 phantom mode-only diffs +
  a conflicted stash** — bundled src ships 755, repo has 644; every file shows
  modified until `git config core.fileMode false` (now set locally — consider
  setting it in the attach path). The stash `powos-bundle-edits` (real fixes:
  atomic bin deploy, plasmoid/autostart deploy, containers JSON, plasma-setup
  mask) conflicts with upstream and awaits manual resolution.

- [ ] **SSH origin push is dead on this box** — ~/.ssh/id_ed25519.pub is not
  added to the GitHub account (`Permission denied (publickey)`). Worked around
  by pushing to the https:// URL with gh's credential helper. Either add the
  pubkey at https://github.com/settings/ssh/new or flip origin to HTTPS.

- [x] **`powos dev patch` was broken for EVERY fork** — it copied `upstream/.`
  (including its `.git`) into the temp diff repo, so `git init` was a no-op and
  the base commit died with "nothing to commit", aborting under `set -e` before
  writing any patch. Fixed in this commit (`rm -rf "$tmp/.git"` before init).
  Couldn't hot-deploy the fix (`self test` unlock issue above) — generated the
  plasma-desktop patch by running the fixed logic by hand.

- [x] **`sources/kde/source.conf` claims "the image build applies every patch
  under patches/<app>/" but nothing in the Containerfile or CI builds
  sources/kde apps** — fixed: Containerfile now has a `kde-builder` stage
  (FROM the same base image, version-matched clone, applies patches, builds
  targets from per-app `build.conf`, ships listed artifacts). A patch that
  stops applying fails the image build loudly.

- [ ] **PowStream GTA test loop leaks host RAM via nvidia driver (~120GiB
  leaked, reboot-only reclaim)** — 2026-07-14: PowStream agents repeatedly
  launch GTA V Enhanced (Proton/DXVK, `POWSTREAM_*` env) and the sessions get
  SIGKILLed; the nvidia driver (610.43.02, RTX 5090) never returns the
  host-side buffer pages. Memory is invisible to ps/cgroups (direct driver
  allocs; DirectMap4k shattered to ~170GiB). Box was down to 37GiB available
  of 186GiB. Fix ideas: PowStream test harness must exit GTA cleanly
  (SIGTERM → wait → escalate, or Steam shutdown request) instead of
  `pkill -9`; consider a `powos` helper for clean game teardown; file/track
  upstream nvidia leak.
