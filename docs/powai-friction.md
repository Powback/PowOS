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

- [x] **`powos ai sessions` fails for a normal user:** `mkdir: cannot create directory
  '/var/lib/powos/state/ai': Permission denied`. The AI state dir isn't user-writable.
  Same root cause family as the root-owned-tree item. — fixed: AI_STATE_DIR moved to
  XDG state home (~/.local/state/powos/ai) with runtime fallback in _session_init.

- [ ] **modder agent claimed Nexus API was "permission-gated" and punted** despite the
  key existing. Two layers: (a) instruction — now told to use the key when present
  (agent.conf); (b) product — non-interactive agents can't make tool calls without
  `--yolo` because of the permission model. (b) still open.

- [x] **`powos self test` aborts on an already-unlocked bootc deployment.** Its
  `self_usr_ro` writability probe runs as the calling (non-root) user, so on a
  deployment already in bootc `development`/unlocked state it still sees `/usr` as
  read-only (root-writable, user not), then calls `bootc usr-overlay` which errors
  "Deployment is already in unlocked state: development" and the whole test bails —
  nothing applied. 2026-07-16 addendum: merged sysexts make /usr ro even for root.
  — fixed: self_test now calls sysext_unmerge_if_needed (shared helper in
  lib/common.sh) BEFORE probing /usr writability, matching update-self's ordering.
  cmd_install's apply-live path also uses the same helper.

- [x] **jackify-engine hangs indefinitely when CWD contains a slow/dead network
  mount.** The Wabbajack engine (`lib/mods/modlist.sh`) walks its working directory
  on startup; with CWD = the user's HOME containing a CIFS `~/NAS` automount, a
  single `list-modlists` wedged 12+ min in uninterruptible IO (kernel stack:
  `cifs_readdir → SMB2_query_directory → wait_for_response`). FIXED in the wrapper
  (run the engine from a guaranteed-local CWD + a `timeout` bound on the gallery
  call), so this is closed on the PowOS side.

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

- [x] **Agent can't finish `overlay enable` / `update self` — sudo needs a
  terminal** — FIXED locally 2026-07-16: scoped NOPASSWD rule at
  /etc/sudoers.d/powos-dev. Now shipped in the repo as an opt-in:
  `powos setup dev-sudoers` installs the scoped rules (rpm-ostree, powos
  update self/overlay, systemd-sysext, bootc usr-overlay, cp/mv/chmod/mkdir
  into /usr, systemctl daemon-reload). visudo-checked before install.

- [x] **`overlay-manager.sh` defaults `POWOS_ROOT=$HOME/powos`, which doesn't
  exist on this box** — FIXED: defaults to the repo the script lives in, else
  /var/lib/powos/src. Original: — running the documented `bash lib/overlay-manager.sh
  build powstream` from /var/lib/powos/src looks for sources in
  /home/powos/powos/sources and fails. Had to prefix
  `POWOS_ROOT=/var/lib/powos/src`. Default should be the repo the script
  lives in (`$(dirname $BASH_SOURCE)/..`).

- [x] **powstream overlay run-sheet says `powos dev enable powstream`, but
  `powos dev` only knows fork projects** — FIXED: new `powos overlay
  build|enable|disable|list|status|clean` front door delegates to
  overlay-manager.sh. Original: — the working command is
  `overlay-manager.sh enable powstream` (or wire overlays into a
  `powos overlay <build|enable|…>` front door and update the docs).

- [x] **`bootc usr-overlay` silently unmerges ALL systemd-sysext extensions**
  — FIXED: `update self` now unmerges sysexts before installing (they're a
  read-only overlay on /usr), auto-engages bootc usr-overlay when /usr is ro,
  and re-merges extensions at the end. Also: `--pull` refuses to run as root
  (git-as-root .git pollution) and git reads use GIT_OPTIONAL_LOCKS=0.
  Original:
  — 2026-07-16: after `update self` enabled the writable /usr overlay, the
  powstream AND plasma-desktop sysexts vanished from /usr until a manual
  `systemd-sysext refresh`. `powos update self` / `self test` should run
  `systemd-sysext refresh` after enabling usr-overlay (and overlay-manager
  enable/disable should warn when a usr-overlay is active).

- [x] **Sysext extensions with /var-born SELinux labels black-screened the
  greeter after reboot** — 2026-07-16: overlayfs surfaces the extension dir's
  label as the merged /usr/<dir> label; the powstream extension carried
  container_file_t (built via container, cp -a preserved it), so /usr/lib
  went container_file_t → confined domains (unix_chkpwd, xdm_t, auditd)
  couldn't read /usr/lib/passwd (altfiles NSS) → PAM "user not known" for
  plasmalogin → user@967 dead → startplasma waited forever, black screen.
  FIXED: overlay-manager now relabels extension trees to match the real /usr
  (chcon --reference) after build and before enable. Recovered live by
  relabeling + sysext refresh + clean greeter cycle.

- [x] **traefik quadlet in /etc/containers/systemd/users/ ran under EVERY
  user manager** — including the plasmalogin greeter (which then owned host
  :80 and spammed failed podman pulls on every greeter start). FIXED: moved
  to users/1000/ (source + live), traefik now runs under the powos manager.

## PowStream "connect" friction (2026-07-16) — hours lost, real asks below

- [x] **Stream hung at "Negotiating" — host missing `libnice-gstreamer1`**
  (the GStreamer libnice/ICE plugin). webrtcbin couldn't link rtph264pay →
  "Your GStreamer installation is missing a plug-in", so no video track ever
  formed. nvh264enc/webrtcbin/srtp/dtls were present; only `nicesink`/`nicesrc`
  were absent. Fixed live (dropped libgstnice.so into the usr-overlay + sysext
  refresh) and staged persistently via rpm-ostree. The portal/token was a red
  herring — it worked and saved ~/.config/powstream/portal-restore-token.

### What PowOS should change so this is trivial next time
- [x] **Bake the PowStream runtime deps into the base image** — at minimum
  `libnice-gstreamer1` (+ verify nvh264enc/webrtcbin/srtp/dtls). PowStream is a
  first-party feature; its server should never fail on a missing distro plugin.
  — fixed: libnice-gstreamer1 added to Containerfile dnf install layer.
- [x] **`powos install` must apply-live under an active usr-overlay/sysext** —
  `rpm-ostree apply-live` failed EROFS because bootc usr-overlay + merged
  sysext sit on /usr read-only. Need: unmerge sysext → apply-live → re-merge,
  wrapped in `powos install --live`.
  — fixed: cmd_install now brackets apply-live with sysext_unmerge/remerge_if_needed
  (shared helper in lib/common.sh).
- [x] **First-class `powos stream` command** — start server+sidecar, ensure the
  screencast restore-token exists (bootstrap the one-time approval, or use a
  dialog-free capture path), print URL + creds. No hand-starting binaries.
  — fixed: `powos stream` (lib/stream.sh) wraps the user units with
  status/start/stop/restart/logs/setup subcommands.
- [x] **Dialog-free capture for headless/remote** — the KDE screencast portal
  renders its consent dialog only on the physical monitor (invisible to a
  remote user). Either pre-seed the restore token at setup, or capture via
  zkde_screencast/NvFBC so a remote box needs zero local clicks ever.
  — fixed: `powos stream setup` pre-seeds the portal restore token by running
  the PowStream server's portal handshake once on the local console; future
  captures (including remote) reuse the saved token silently.
- [x] **Broaden the scoped dev sudoers** to cover `rpm-ostree`/`powos install`
  and `systemctl --user` service ops — kept hitting the password wall mid-task.
  — fixed: `powos setup dev-sudoers` installs scoped NOPASSWD rules at
  /etc/sudoers.d/powos-dev (rpm-ostree, powos update self, sysext, bootc).
- [ ] **overlays should declare package deps** (or `powos overlay` pulls a
  feature's rpm deps) so shipping the powstream sysext also ensures libnice etc.
