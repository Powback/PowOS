# PowOS Capabilities (AI context — single source of truth)

This file is injected into PowOS AI agents at call time (via AGENT_CONTEXT_CMD)
alongside live `powos help`. **Edit this one file to keep every agent current** —
do not duplicate this into individual agent prompts. Keep entries short and mark
status honestly so agents don't over-promise.

Status legend: ✅ stable · ⚠️ experimental/partial · 🚧 WIP · ❌ not implemented

## Core model
- Runs live from USB into a RAM overlay; OS in RAM, USB optional at runtime.
- Layered persistence: RAM upper → custom → updates → base (Bazzite). ✅
- Independent rollback per layer: `powos rollback {custom|updates|all|reset}`. ✅
  (grubby failures are reported loudly; `/run/powos/rollback-kargs` is
  informational only — verify after reboot via `grep powos /proc/cmdline`.)
- Layer sync RAM→USB every 60s (`powos sync`, `powos flush`). ✅

## Install to disk & dual-boot (NEW)
- The USB boots a menu: **"PowOS Live"** (default, RAM) and **"Install PowOS to disk"**. ✅ menu wiring / ⚠️ install paths need hardware validation
- `powos install-system` — interactive installer. Picks target disk (never wipes
  blindly), detects Windows, defaults to **dual-boot into free space**. ⚠️
  - `--dry-run` shows the plan, changes nothing. `--alongside` / `--whole-disk`
    (whole-disk requires typing the disk model). `--shared-gb N` = shared NTFS.
  - Whole-disk uses `bootc install to-disk` ✅-ish; **alongside is experimental** ⚠️.
- Dual-boot guidance the installer automates / should advise:
  - Disable Windows Fast Startup + hibernation (`powercfg.exe /hibernate off`).
  - Set RTC to local time to match Windows. Suspend BitLocker before repartitioning.
  - Use the UEFI boot menu (F-key) to pick OS — atomic Bazzite's GRUB won't auto-list Windows.
  - Share only large Steam *assets* on NTFS; keep Proton compatdata/prefixes on native FS.
- Reciprocal VMs (`powos vm`): boot the *other* installed OS as a VM off the same
  physical partition, no reboot. `powos vm status`, `sudo powos vm windows`
  (KVM/OVMF, AHCI passthrough), `--dry-run/--ram/--cpus/--gpu`. ⚠️ launch config
  generated + safety-gated (refuses mounted disks); real boot/GPU passthrough
  needs hardware validation. Reverse direction (Windows→PowOS guest) = manual,
  see docs/DUAL-BOOT-VM.md. Gaming in a guest needs GPU passthrough (2 GPUs + IOMMU).
- PowOS cannot build/bundle Windows or a live Windows; Windows comes from normal MS install.

## Games partition & bare-metal Windows (NEW)
- `powos games {status|create|mount|steam-setup|resize}` — first-class shared NTFS
  partition, label POWOS-GAMES, deliberately visible to Windows (all other PowOS
  partitions hidden via Linux GPT type GUIDs — no drive letter, no format prompts).
  Created at USB flash (`install-to-usb.sh --games-gb N`), by the installer
  (`--shared-gb`, now labeled POWOS-GAMES), or later via
  `powos games create --size N [--disk D] [--dry-run] [--yes]`. `steam-setup`
  mounts at /var/mnt/games (ntfs3, uid/gid, windows_names), creates
  SteamLibrary/steamapps, keeps Proton compatdata/shadercache on native btrfs via
  symlinks (prefixes break on NTFS), registers in libraryfolders.vdf (Steam must
  be closed), drops GAMES-README.txt for the Windows side. One installed game
  serves both OSes. `resize` is a stub. ⚠️ implemented CLI, hardware validation
  pending.
- `powos windows {status|create [--size N] [--fixed-vhd]|fetch-iso [--slim] [--hash]|
  slim <iso>|install [--iso PATH] [--fetch] [--slim]|finalize|snapshot|snapshots|
  rollback|vm}`, plus `--backend vhd|partition` (default vhd). DEFAULT BACKEND:
  Windows lives in ONE FILE (`<POWOS-GAMES>/PowOS-Windows/windows.vhdx`,
  thin/dynamic), no partition of its own. ALT BACKEND (`WINDOWS_BACKEND=partition`
  in /etc/powos/windows.conf, or `--backend partition`): a dedicated WIN-ESP +
  POWOS-WIN carved from the burn-time `--windows-gb` unallocated tail, giving
  Windows plain metal + REAL hibernation (both backends keep every Linux partition
  invisible to Windows via GPT type GUIDs). `fetch-iso` downloads the OFFICIAL MS
  ISO (verified, never a prebuilt third-party image) and `--slim` debloats it
  natively (wimlib, tiny11-style) — install `--fetch` chains this. Install is
  zero-touch (autounattend: keyless edition-select, TPM/SB bypass, OOBE skipped)
  and preloads Steam pointed at the shared POWOS-GAMES library. User supplies ISO
  + license; PowOS ships no MS bits. Bare-metal boots via native VHD
  boot (bootmgr on the SHARED PowOS ESP, backed up before install); the same file
  also boots as a KVM guest (`vm`, implemented — VM-hibernation is the supported
  resume path). Bare `powos windows` = the guarded switch: flush + stop layer-sync
  → guards → unmount POWOS-GAMES → BootNext → hibernate PowOS (`--reboot` fallback
  until hibernation ships). **Metal Windows always COLD-BOOTS** (winresume can't
  read a hiberfil inside a VHD — no bare-metal session resume; PowOS's own session
  survives via S4). Snapshots = whole-file zstd copy on POWOS-DATA (NOT ntfsclone).
  Native-VHD costs: dynamic image expands toward full --size on first metal boot,
  and in-place feature updates are blocked. 🚧 implemented CLI, hardware validation
  pending — do NOT present the switch or install as proven; see docs/WINDOWS.md.
- Machine-local model: the USB is also an installer and gets unplugged after
  installing to a desktop/laptop/Steam Deck SSD — so the POWOS-GAMES partition (and
  the windows.vhdx file on it) is per-machine, created on that machine's own
  PowOS-owned disk. Installed systems receive these commands via normal bootc
  updates and run create once (no reflash).
- Safety: nothing touches a disk except a user-run command against a device the
  user names, behind plan display + confirmations + `--dry-run`.

## Runtime updates (edit source → update running system)
- Source is bundled at `/var/lib/powos/src` (no `.git` — excluded from image).
- `powos update self` — deploy bin/lib/config/systemd from source into the live
  system; persists via layer sync. ✅
- `powos update self --from /path` — deploy from a mounted checkout. ✅
- `powos update self --pull` — pulls if src has `.git`; otherwise attaches git
  to the bundled src in place (once), falling back to a one-shot clone when src
  isn't writable. Private repo needs git creds on the machine. ✅ (creds-dependent)
- `powos update {os|packages|overlays|apply}` — base OS / packages / overlays.
- `powos reload` — the easy button: auto-finds your source checkout (~/PowOS etc.),
  remembers it, and hot-applies live (no reboot). `--pull` (git pull first),
  `--build` (full local image build + switch), `--where`. Just `powos reload`.
- `powos upgrade` — smart base update: `bootc upgrade` then the LIGHTEST restart —
  soft-reboot if the staged kernel is unchanged (~seconds, warm), full reboot if it
  changed, nothing if already current. `--check|--now|--soft|--reboot`. Soft-reboot
  into a staged bootc deployment is ⚠️ frontier (opt-in).
- `powos build image [variant] [--switch|--push]` — build the OS image LOCALLY (no
  GitHub), optionally rebase this machine onto it. Self-hosted counterpart to CI. ✅

## PowOS self-development loop (for AI agents)
The full round-trip an agent can drive to fix / improve PowOS itself:

1. **Edit** — `/var/lib/powos/src` is a git checkout of `Powback/PowOS`
   after the first `powos self pull`. Origin is SSH (`git@github.com:Powback/PowOS.git`),
   push key at `~/.ssh/id_ed25519`. Agent edits files there directly.
2. **Test transiently** — `powos self test`
   Applies the /var/lib/powos/src edits to the RUNNING system via a
   `bootc usr-overlay` (writable overlay on top of the composefs `/usr`).
   Auto-reverts on next reboot. Agent can verify behavior immediately
   without committing.
3. **Commit + push** — `powos self push -m "<msg>"`
   `git add -A && git commit && git push origin master`. Uses the
   configured identity (`git config user.name/email`) and SSH key.
   If push errors with permission-denied, the SSH pubkey at
   ~/.ssh/id_ed25519.pub isn't added to the GitHub account yet — ask
   the user to add it at https://github.com/settings/ssh/new.
4. **CI runs** — Powback/PowOS's build-test-publish.yml runs lint +
   Containerfile build + E2E tests + publishes to
   `ghcr.io/powback/powos:nvidia-open`. Takes ~5-6 min. Agent can watch
   via `gh run watch` if `gh` is installed AND authed (currently only I
   have gh auth locally, not the box — install & auth if the agent
   needs it: `dnf install gh; gh auth login`).
5. **Deploy** — `powos upgrade --now` (or `sudo bootc upgrade`
   directly, then reboot). Pulls the new channel-tagged image and
   applies via `soft-reboot` if kernel is unchanged, full reboot
   otherwise.

Rules for agents driving this loop:
- **Shared checkouts: commit only your own paths.** Several agents often share one tree and one git index. Never
  `git commit -a`, never a bare `git commit` after someone else may have staged, never `git add -A` / `git add .`.
  Commit by pathspec (`git commit -m "..." -- <your files>`, which ignores other staged entries) or with a private
  index (`GIT_INDEX_FILE=$(mktemp) git read-tree HEAD && git add <files> && git commit`); check
  `git diff --cached --stat` first. Never reset/checkout/stash files you didn't change. `powos self push` takes
  `-- <paths>` for this and refuses a whole-tree commit when others' changes are already staged.
- **NEVER `git push --force`** unless a) an isolated branch, b) the user
  explicitly asks, c) confirms twice. Master is atomic-published — a
  force push replaces the running channel for every user.
- **NEVER skip hooks** (`--no-verify`) unless the user asked and knows why.
- **Commit messages** should be actual descriptions. Two blank lines
  between subject and body, subject <70 chars.
- **`powos self test` first, then push.** Don't commit changes that
  haven't been transiently applied and observed to work.

Key facts an agent should CHECK before starting:
- `git -C /var/lib/powos/src remote -v` → confirm SSH origin.
- `git -C /var/lib/powos/src config user.email` → confirm identity is set.
- `ssh -T git@github.com` → confirm push auth (returns "You've
  successfully authenticated..." on success).
- `powos ai install claude` if the agent needs Claude Code itself
  (installed at `~/.local/bin/claude`; auth already in `~/.claude.json`).

## Other subsystems
- Settings (`powos config [name] [value]` / `--json`): one front door for system
  toggles AND value settings — ssh, driver (stable/testing channel), auto-update
  (background staging via rpm-ostreed, never auto-reboots), ramsize (kernel arg,
  reboot), sync-interval (layer-sync daemon, applied live), nvidia-persistence,
  cachefs, **claude-endpoint / claude-token**. Each shows WHEN it applies
  (now/reboot). Registry-based: adding a setting is one line + get/set(/validate)
  pair in lib/config.sh. Intended substrate for a future installer/GUI. ✅
  - `claude-endpoint` is the ONE place the Anthropic authority URL lives
    (`/etc/powos/ai/endpoint.conf`). lib/ai/agent.sh reads it at call time, so
    `powos ai`, the manager and the desktop widget agree no matter what
    environment they were launched from — the widget inherits plasmashell's env
    from session start, which is why an env-only setup broke it whenever the
    endpoint moved. An explicitly-exported env var still wins, so per-shell
    overrides and containers (which point at the authority on their own network)
    are unaffected. Changing it takes effect for new agents immediately;
    already-running GUI apps need Plasma restarted.
- Uninstall (`powos remove [--dry] <thing...>`): mirror of the install router —
  probes flatpak / powos-sandbox (rpm+pip) / brew / host rpm-ostree layer and
  removes from every backend the thing is found in. Honest about host-layer
  config residue in /etc,/var. ✅
- Persistent **manager** (`powos ai manager`, aliases jarvis/boss): the standing PowOS
  orchestrator — a long-lived streaming `claude` session (backend for the coming desktop
  widget). Keeps context across turns, has **per-directory memory** (resumes the session
  keyed by cwd), and receives comms mail **live** (injected as a turn — no polling). It is
  the default escalation target: specialist agents report UP to it. `--safe` keeps
  permission prompts. `powos ai --continue` now also resumes raw `claude` CLI sessions in
  the current dir. ✅ (Phase 1; widget is Phase 2)
- Inter-agent comms (`powos comms` + a `comms` MCP auto-wired into every `powos ai`
  agent): a daemonless **mailbox** so agents talk to each other. Each agent runs as a
  role (health/coder/devops/...); mail addressed to a role lands in that role's durable
  inbox (spool under XDG state) and is read by whoever next runs as that role — or by a
  live agent of that role parked on it. As an agent you have MCP tools: `send_message`
  (to a role), `escalate` (to your parent, default `user`), `notify_user`, `read_inbox`
  (drains), and **`wait_for_message`** (BLOCKS until mail arrives — yield while idle
  instead of polling; you can also Monitor the inbox path). Humans/scripts use
  `powos comms send|watch|inbox|agents|notify`. ✅ (opt out: `POWOS_COMMS_ENABLED=0`)
- Mobile mode `powos mobile` — copy OS to RAM so USB can unplug. 🚧 live remount not done; reboot needed.
- Cloud backup `powos backup {status|push|pull|setup}` — git-based USB state backup. ✅ CLI exists.
- Sync conflicts `powos sync {status|resolve|--keep-ram|--keep-usb|--merge}` — detection ✅, `--merge` basic ⚠️.
- CacheFS (lazy user-data FUSE) — ❌ incomplete: write-back to USB NOT implemented (written data is lost); must remain disabled (`POWOS_CACHEFS_ENABLED`).
- Containers `powos containers …` (Podman/Distrobox), install/export GUI apps. ✅ `powos containers run` with
  `--memory/--cpus/--pids-limit` enforced everywhere, the phone included (no pasta/bridge networking there yet). ✅
- Desktop widgets (KDE plasmoids in `desktop/plasmoid/`, shipped to
  `/usr/share/plasma/plasmoids/`) — add from "Add Widgets" or the System Tray: ✅
  - `com.powos.manager` — **two-pane chat with the PowOS manager**: left sidebar of
    your projects (`~/Projects/*`, ● = live thread) + agent roster (unread badges),
    right pane a live chat. Picking a project switches to that project's manager
    thread (per-dir memory). Each turn runs `powos ai manager --json-events --once`,
    rendered as bubbles + tool panels (⚙ tool_use, ↳ tool_result, ✉ inbox).
  - `com.powos.containers` — start/stop/restart podman containers, grouped by
    compose stack; expand a container for Logs / **Processes** (podman top) / Details.
  - `com.powos.monitor` — CPU (aggregate + per-core bars), GPU, net, disk;
    worst-offenders strips **grouped by owning container** (host vs container).
  - `com.powos.updates` (tray) — version + changelog, bootc update available
    (skopeo digest compare), one-click upgrade/rollback, and **apply local
    `/var/lib/powos/src` changes** (`powos update self`).
  - `com.powos.camera` (tray) — shows when the camera is in use AND **names the
    app(s)** holding `/dev/video*` (which KDE's stock indicator can't).
- Dev / modding — TWO paths, pick by whether you want it committed:
  - **Runtime, per-machine** (`powos dev`): `new`/`fork`/`build`/`enable`/`disable`/
    `update`, `--ai` gen, plus native app override — `override <app>` seeds a
    COMPLETE sysext shadow of a base app (edit → `enable` auto-builds → `disable`
    restores base), `overrides` lists them, `override --diff <n>` shows what changed.
    Projects live in /var/lib/powos/projects — **NOT committable**. Override of a
    base app is ⚠️ untested overlay-on-overlay (TODO(hw)).
  - **Committable, baked into every build** (`sources/<name>/`): edit upstream
    source, save a `.patch` under `sources/<name>/patches/<app>/` — upstream is
    gitignored, patches are committed (Fedora-style); the image build applies them.
    `powos dev patch <name> [desc]` generates the patch from a fork straight into
    `sources/…` (KDE → `sources/kde/patches/<app>/`). **Use THIS, not `dev`, for
    permanent/version-controlled mods** (e.g. patch Dolphin).
  - KDE start menu (Kickoff) is Plasma, not a standalone app → config/widget, not override.
- Overlays (systemd-sysext) via `powos dev` / `overlay-manager.sh`; extension-release
  uses `ID=_any` so it merges on any host (Bazzite included). ✅
- Hibernation / session-resume (hop to Windows for anti-cheat games, resume the
  Linux session on return) — ❌ SPEC ONLY, not built, blocked on persistence
  validation. See docs/HIBERNATION.md. `powos boot windows` (UEFI BootNext,
  one-shot reboot to Windows) IS built. ✅

## PowOS on a phone (Android)

You may be running on a phone: `/etc/powos/platform` reads `phone` and the session exports `POWOS_PLATFORM=phone`.
Device in use: OnePlus Open (foldable, SM8550, Adreno 740), Android 16 / OxygenOS, unlocked + Magisk. Source:
`targets/android/` (README.md there), the web shell `shell/`, design `docs/NATIVE-SYSTEM-UI.md`.

### Architecture
- **Rooted mode (this phone)** ✅: PowOS's own Arch Linux ARM system in `/data/powos/root`, run on Android's kernel.
  Not a VM, kexec or dual-boot: `powos-start.sh` (Magisk boot service) mounts it, and the PowOS app starts the
  desktop with `su -c sh /data/powos/powos-session.sh …`, which pivots into its own mount namespace. The desktop runs
  as user `powos` (real sudo). KWin uses its Anland backend: the app owns the screen surface, touch, keys and audio,
  and relays them to KWin over an abstract socket. GPU: Mesa Turnip on KGSL.
  Session lifetime: the relay (display daemon) lives in the app's process, so every app restart or APK install
  restarts the whole desktop (~9 s to KWin, then Plasma). KWin gets the screen size from the daemon at startup; a
  daemon without `--screen` made it wait for the desktop to be opened (Plasma then started in front of the user).
- **No-root mode** ⚠️ (Galaxy S25 Ultra, 2026-10-13): the same desktop inside the app through Andromarchy's engine
  (patched loader, fakechroot, fakeroot). Not this phone's setup.
- **Android stays in charge** of the kernel, display, notifications and Android apps. The PowOS app `com.powos.app`
  (Omalauncher + the Andromarchy engine) is the home app. As a privileged system app (Magisk module) it also holds
  the recents role.
- **The web shell** (`shell/`, Preact + TypeScript, hot-reloaded in WebViews) draws every PowOS screen on Android:
  home (`index.html`), notification shade + control center (`?mode=shade`), lock face (`?mode=lock`), switcher
  (`?mode=switcher`), assistant (`?mode=assist`). Kotlin hosts are thin (`targets/android/app/.../shell/`).
- **Steam:** FEX (`FEXBash`) + `steam` are installed in the rootfs. ⚠️ Not validated as a daily path.

### Components & paths
| What | Where |
|---|---|
| Linux root | `/data/powos/root` (`/` inside the session); scripts `/data/powos/{powos-start,powos-session,powos-run}.sh` |
| Run a command in the session (from Android root) | `su -c "sh /data/powos/powos-run.sh '<cmd>'"` |
| App ↔ PowOS shared dir | app `files/run` = `/run/powos-app` (XDG_RUNTIME_DIR): `agent-mail/`, `agent-wake/`, `powos-ai-shared/` |
| Launcher widgets / styles | `~/.config/omalauncher/{widgets,style}` (OWL; edits show on home) |
| Shell overrides (hot reload) | app `files/shell/` (wins over the APK's copy until reset) |
| Displays | `0` = active panel (cover 1116×2484 folded / inner 2268×2440 open); `cmd device_state print-state`: 0 = folded |
| Hosted Android widgets | private virtual displays `powos-appwidget-N` (not the screen; don't capture them) |
| Root | Magisk (`su`); SELinux enforcing |
| App data backups | full: `/data/powos/backup/app-data-<time>.tar`; hourly layout + store: `/data/powos/root/var/backups/powos-app/light-<time>.tar` - `su -c "sh /data/powos/powos-appdata.sh list\|backup\|restore <tar>"` (`docs/APP-DATA-BACKUP.md`) |
| adb | phone-local `127.0.0.1:5555` (rooted.sh wifi); LAN `192.168.50.239:5555`; VPN `10.13.13.7:5555`. On the phone itself `emulator-5554` is this same phone's adbd auto-detected on port 5555 (a bare `adb shell` then fails, "more than one device"): always pass `-s 127.0.0.1:5555`. An AVD only on the Mac |

### Shipping a change (edit → test → ship → roll back)
| Layer | Edit | Ship | Roll back |
|---|---|---|---|
| Web shell UI | `shell/**` | `shell/push.sh --note "<what changed>" <files>` (`--vpn` first over the VPN; `ANDROID_SERIAL` picks the phone): gated first (below), then every open page reloads | `shell/push.sh --reset [files]`; automatic when a page fails to boot within 2 min of the push |
| OWL widgets | `targets/android/app/app/src/main/assets/widgets/*.owl` | APK; or write the live copy `files/widgets/<name>.owl` (that copy then counts as the user's and isn't updated by later APKs) | restore the previous file |
| App (Kotlin) | `targets/android/app/**` | `bash targets/android/build-app.sh` → `~/Projects/android-app-dev/output/powos.apk` (also on android.pow) → `targets/android/install-app.sh <apk> --note "<what changed>"` | install the previous APK |
| System slots (priv-app, recents, overlays) | `targets/android/system-module/` | `build-module.sh --priv-app --slot recents` → `rooted.sh module <zip> --note "<what changed>"` + reboot | `touch /data/adb/modules/powos-system/disable` + reboot |
| Rooted scripts | `targets/android/rooted/*` | `targets/android/rooted/rooted.sh deploy --note "<what changed>"` | redeploy the previous version |
| KWin / packages | `targets/android/pkgs/` | `build-pkgs.sh` (ccache) → rootfs | previous package |
| Rootfs | `build-rootfs.sh` → `out/powos-rootfs.tar.gz` | `rooted.sh install --note "<what changed>"` (replaces `/data/powos/root`) | reinstall the old tarball |
| PowOS layer (`lib/`, `bin/`, `config/`) | repo | copy into `/data/powos/root/usr/lib/powos/…` (or `/etc/powos/…`) as root, then `targets/android/tools/deploy-note.sh "<what changed>"` | copy back the old file |
Built centrally and shipped whole. Never `pacman -Syu` on the phone.
**Never `pm uninstall-system-updates com.powos.app` (nor `pm clear`, nor a downgrade) without the backup step: it
deletes the app's whole data dir** - home layout, hosted widgets, installed PowOS app UIs, chat, mail, the shell's
store (lost for good on 2026-10-20). Re-basing on the system copy is only `su -c "sh /data/powos/powos-appdata.sh
rebase <apk>"` (backup, refuses without one, restore after); afterwards check PowOS still has Magisk Superuser (the
user re-grants it). `docs/APP-DATA-BACKUP.md`; `test/tier1/test-appdata-guard.sh` enforces it.
Every ship to the phone carries `--note`: one plain line of what changed for the user ("Switcher now follows your finger", never a hash or a file) - the phone's quiet "update applied" notification, deploys within 2 min folded into one (`powos comms notify --from deploy --priority low --batch deploy`).

### Shell errors reach the manager (nothing only in logcat)
- **Before a push**: `shell/push.sh` runs `shell/dev/gate.sh` - tsc, then every page (home, lock, shade, assist, aod,
  recents) booted in a headless Chromium against the mock bridge, as the phone serves it (committed shell + the phone's
  overrides + the pushed files). Any uncaught error, failed module load, missing export, import-cycle error or a page
  not ready in 8 s refuses the push with the error; `--force` overrides. `apps/install.sh` gates an app's UI modules
  the same way. Run it alone: `shell/dev/gate.sh [--tree] [files]`.
- **On the phone**: every page's uncaught errors, rejections, module-load failures and "never became ready" go to the
  manager's inbox (`--from shell --priority high`: page, file:line, APK version, override files and when they were
  pushed, the last push), once per error per 10 min, and to a log: `powos shell errors [N]` (phone),
  `shell/push.sh --errors` (Mac). A page that fails to boot within 2 min of a push has the push rolled back by the app
  (previous overrides restored, else the APK's files) and the manager gets "rolled back <files> because <error>".
  `powos shell help` has the details.
- **Testing it: never break a live page (home, lock, shade).** Break the test-only page `shell/test/gate-test.tsx`
  (`?mode=gate-test`, loaded off screen by the app when that file is pushed) and push with `--test`; its reports go
  only to the test's role (`--test=ROLE`, default the scratch role `shelltest`) as "[test]", never to the manager.

### `powos` on the phone
- Works: `status` (Phone: mode, kernel, battery, network), `android {apps,open,running,notifications,notify,screenshot}`,
  `ai …`, `manager`, `comms …`, `shell errors`, `doctor`, `help`. `podman`, `distrobox`, `flatpak` and `tmux` are installed.
  ⚠️ Containers aren't validated on the phone.
- Doesn't apply (no bootc, rpm-ostree or grubby; no USB/RAM layers): `upgrade`, `base`, `driver`, `rollback`,
  `ramboot`, `sync`/`flush`/`safe`, `install-system`, `boot`, `games storage`, `windows`, `gpu`, `cuda`.
  `powos help` still lists them: it isn't filtered by platform yet.

### AI hooks on the phone
- PowOS AI chat (`PowosAiActivity`, the home's AI page, the assistant overlay) → `powos manager --once-stdin --json-events`,
  one turn at a time. ✅ Mail to `manager` wakes it between turns (verified 2026-10-19) (comms writes `agent-wake/manager-*`; the app runs
  `powos manager --once-inbox`).
- Assistant: long-press power = PowOS's VoiceInteractionService. The overlay sends the screen's text (AssistStructure,
  naming the app under it) plus a screenshot; the user can crop to the part they mean. Shares land in
  `/run/powos-app/powos-ai-shared/` (a crop is the user's selection, not a capture bug).
- `notify_user` / `powos comms notify` → an Android notification (`agent-mail/`). An inline reply goes to the
  sender's inbox.
- Share sheet (`ACTION_SEND`) and `ACTION_ASSIST` open PowOS AI.
- Agents view (docs/AGENTS-VIEW-DESIGN.md, Phase 1): every claude in PowOS reports through async hooks in
  `~powos/.claude/settings.json` (`/usr/lib/powos/ai/agents/powos-agent-hook` → `powos-agentsd` → `/run/powos-app/agents/`);
  the Mac's sessions are mirrored in (`agents/mirror/mac.json`; an adb HACK - every cross-device channel and its
  replacement, the remote PowOS design: `docs/REMOTE-POWOS.md`). Shown as home's Agents widget, PowOS AI's page →
  Agents, and an ongoing notification while one works. Asks (PermissionRequest) can be allowed/denied from the phone;
  unanswered after 60 s, Claude asks at its terminal.
- Compute mesh (moving containers between PowOS hosts, resource sharing): design only, ❌ not implemented - `docs/POWOS-COMPUTE-MESH.md`.
- Claude: `ANTHROPIC_BASE_URL=http://claude-auth.pow`, the fleet's OAuth proxy. Never log in or refresh a token on
  the phone.

### PowOS apps on the phone (system tier, SpacetimeDB, runtime switch)
Design and measurements: `docs/POWOS-APPS-FEASIBILITY.md` (§5.6 runtime, §8 the prototype on the phone).
- **System tier** ✅ (2026-10-19): `powos-start.sh` (boot, and every session start) runs `powos-supervisor` once per
  boot as root in PowOS's own persistent mount namespace, outside the desktop session (which an APK install restarts).
  It runs every manifest in `/usr/lib/powos/apps/services/` through `powos-runtime`, restarts crashes with backoff
  and keeps budgets without cgroups (RSS over `memMB` → restart, 3× in 5 min → held; CPU over `cpuPct` for a minute
  → nice 19; rlimits/nice/ionice at start). `powos app services` = its status (`/run/powos-system/status.json`),
  logs `/var/log/powos/<id>.log`. Off: `rooted.sh system off` (`/data/powos/system-tier.off`), on: `rooted.sh system on`.
- **SpacetimeDB 2.12.0** (package `spacetimedb`: built from the local SpacetimeDB fork, `~/Projects/SpacetimeDB` branch `powos/v2.12` = v2.12.0 + three idle-wakeup commits, pinned by hash -
  idle server ~9 wakeups/s instead of 161, ~0 per loaded database instead of ~145; `spacetimedb-bin` = the unpatched
  official binaries; `spacetime` CLI on PATH) as
  `dev.powos.spacetimedb`: `127.0.0.1:3410`, data/keys `/var/lib/powos/stdb` (owned by powos). The port is locked to
  the PowOS app's uid (= powos) and root by iptables chain `powos-local` (`xt_owner`); every other Android app gets
  a reset. Idle unload: no client for 5 min and RSS > 60 MB (the bare server is ~51 MB) → a ~150 ms restart that drops every loaded database
  (a memory policy; the patched server costs ~nothing idle).
- **Runtime switch**: `powos config app-runtime native|sandbox|container` (default), `powos app runtime <id> <mode>`
  (per app). native = plain process; sandbox = bubblewrap (user/pid/uts/cgroup ns - never `--unshare-ipc`/`--unshare-all`,
  this kernel has no SysV IPC), read-only system, private /tmp, only the data dir writable, seccomp denylist (no
  Landlock: not in this kernel); container = podman via `powos containers run` with the budget as hard limits (phone:
  Android's v1 memcg/cpuctl + v2 pids, `docs/PHONE-KERNEL-CONTAINERS.md` §12). Flipping restarts the
  service in seconds; same command, data dir, port and uid. `powos app check` shows what this kernel supports.
- **Apps**: `powos app install|publish|ui|list|remove` (Mac side: `apps/build.sh <app>` then
  `ADB="docker exec powos-vadb adb" apps/install.sh <app> [install|publish|ui] --note "<what changed>"`). The registry is the
  `powos-registry` database (owner = powos's CLI identity). Installed UIs: `~/.local/share/powos/apps/<id>/<ver>/` =
  the app's `files/apps` (bound by `powos-session.sh`), served to the shell at `https://shell.powos/_app/<id>/`.
  Prototype: `apps/counter` (Rust module `powos-counter` + island widget `widgets/count.js`).
- **Making apps** ✅ (2026-10-20, `powos app help` is the contract): `powos app new <name> [--name ..] [--template
  spacetimedb-astro|widget|module-only]` scaffolds `~/Projects/<name>` (Rust module `module/src/lib.rs`, Preact page
  `ui/pages/main.tsx`, widget `ui/widgets/main.tsx`, hooks `ui/lib/app.ts` = the spacetimedb-astro template's
  useTable/useReducer/useStatus on the shell's host); `powos app install <dir>` builds and installs; `powos app dev
  <dir>` hot-reloads every save (UI: the open page and widgets re-import in place, no shell reload; module: republished,
  clients stay connected). The **module builds on the app builder** (`powos app builder user@host`, on the phone the Mac
  `macback@192.168.50.99`: source over ssh into a `powos-app-builder` container with the shared cargo cache, wasm back;
  ~3-4 s warm) - never Rust on the phone's battery; the UI bundles locally with bun (~50 ms), bindings with the local
  `spacetime generate`. An app with a page is a launcher app (`p:<id>`: drawer, search, recent strip) and opens full
  screen inside home's page (`shell/ui/appscreen.tsx`); its widgets are in home's edit sheet → PowOS apps. Example:
  `~/Projects/shopping` on the phone (`local.shopping`, a shared shopping list + widget).
- **Apps on the network** ✅ (2026-10-20, `host.net`, the PowOS app's `ShellNet.kt` - no process of the app's own):
  an app declares what it may reach in powos-app.json `"net": ["lan", "discovery.meethue.com"]` (exact hosts, or
  `"lan"` = any private address / `*.local`); nothing declared, nothing reachable. `host.net.fetch(app, url, {method,
  headers, body, capture})`, `host.net.useEvents(app, url, headers, onEvent)` (server-sent events: one connection per
  app + URL for the whole shell, closed 5 s after home/the page is hidden or the screen goes off), `host.net.mdns(app,
  "_hue._tcp")`, `hasSecret`, `forget`. A LAN device's self-signed certificate is pinned on first use per app +
  host:port (a changed one fails until `forget`); public hosts use the system CAs. Secrets stay in the PowOS app's
  private storage per app: `capture: {secret, path}` takes one out of a response, `${secret:name}` in a header sends it
  - the page never sees it. Example: `~/Projects/lights` (`local.lights`, Philips Hue: rooms, brightness, scenes).
- Remove an app: `powos app remove <id> [--data]`. Remove everything: `rooted.sh system off`, then delete
  `/var/lib/powos/stdb`.

### The pet - the agents' face on home (`local.pet`, apps/pet + shell/ui/pet.tsx)
- A small creature floating over home and the PowOS AI page (draggable; its place is kept). Its look comes from live
  data only: working (an agent is working - the agents' spool), looking at the user (an agent needs them, an approval
  ask, a work-board task `waiting`, unread agent mail), worried (a shell error, a deploy note saying something failed
  or was rolled back), sleepy (23-7, or home untouched 3 min), hungry (battery < 20% and not charging), a jump when a
  task gets done. Still at rest: one short CSS animation per state change, no timers while hidden.
- **Speak to the user through it:** `powos pet say "<text>" [--mood M] [--from ROLE]` - one short plain line in its
  speech bubble (3-6 s, batched with others arriving together, a tap opens them all). Use it for "done, try it" and
  "I need you" moments; it doesn't replace `notify_user` (deploy notes and agent mail already show in the bubble too,
  alongside their notification). `powos pet mood <M> [--for S]`, `feed`, `name`, `status`, `log`, `hush`; `powos pet
  help`. Moods: idle, happy, working, looking, worried, sleepy, hungry.
- The user taps it to talk (the phone's recognizer -> the manager, as PowOS AI's chat sends; the answer streams into
  its bubble); a long press opens PowOS AI. Removing the app (`powos app remove local.pet`) removes the pet.

### Smart glasses (Even Realities G2 / G1) - docs/GLASSES.md
- The PowOS app drives the glasses over raw BLE (no Even app): `targets/android/app/.../glasses/` (G2: app-layer auth,
  heartbeat, teleprompter text, input, mic; G1: Nordic UART, text, 1-bit bitmaps, wear/battery events).
- Pairing is on the phone: control center -> glasses tile -> pair (Android's companion dialogs, one per arm); then they
  reconnect by themselves (Android's background connect + companion presence; no polling).
- Their screen is a shell page, `shell/glasses/` (mode `glasses`, loaded off screen while connected): the HUD
  (`glasses/hud.tsx`: time, newest notification, PowOS AI's last reply; tap = next view, double tap = ask PowOS AI
  by voice on the G2, scroll = through it), or a PowOS app's manifest `"glasses": {"entry": ...}` picked on the phone's
  glasses screen. Hot-reloaded as any shell file (`shell/push.sh`).
- The G2 gets TEXT (its teleprompter - the confirmed path); pictures to the G2 are an unverified guess, behind the
  `g2Raster` option. The G1 gets 1-bit pictures.
- `powos glasses [status|show TEXT|clear|connect|disconnect|mic on|off]` from PowOS (through the app's run dir).
- Bridge: `powos.glasses.*` + events `glasses.state|input|transcript|audio|message` (shell/types.ts).

### Status
- ✅ On hardware (OnePlus Open, 2026-10-19):
  - rooted desktop, PowOS as home + priv-app + recents provider
  - gesture nav (swipe home), PowOS shade (left pull) + control center (right pull: phone's own tile order, root
    toggles, sliders, media, edit mode, hosted 3rd-party tiles)
  - lock face (one swipe, no PIN), assistant overlay
  - OWL widgets; Linux sessions in the AI page
- ⚠️ Built, partly tested:
  - hosted Android app widgets (sizing, theming, resize, scroll in progress)
  - switcher / quick switch; the inner-display layouts
- 🚧 Planned:
  - AOD/screen-off slot (reverted: laggy)
  - Android↔PowOS bridge (calendar etc.); fold-aware Plasma layouts
  - emulator target; PowOS Web; linux-wasm research

### Rules for agents on the phone
- Reversible PowOS work is autonomous (standing permission from the user, 2026-10-19): build, install and ship - the APK,
  the system module, rootfs/deploy changes, services, apps, hooks - then report to `manager`. Keep a rollback for each
  (module disable / service off / remove the app); if the home screen breaks, roll back first, then report.
- Confirm first (via `manager`): anything irreversible or that can lose data (deleting volumes or user data, wipes,
  flashing kernel/boot, force-pushing master) and externally visible behaviour (the Discord bot, exposed ports, auth).
- Deferred by the user for now: the /dev/fuse rule, moving memory/cpu to cgroup v2. (The containers kernel is flashed
  and phone containers run with hard limits since 2026-10-20.)
- Never type into existing tmux sessions, on the phone or on the Mac: they are live Claude sessions. Open a fresh shell.
- Don't inject touches/keys while the user is using the phone: `dumpsys power | grep lastUserActivityTime` must
  show more than 120000 ms ago.
- Never weaken SELinux (no setenforce, no broad allow rules). Don't route around a denial; tell the user.
- Mark every workaround `HACK:` with why and the real fix, and add it to the HACK registry (`docs/REMOTE-POWOS.md` §4)
  in the same commit (`test/tier1/test-hack-registry.sh` checks). Never print secrets or tokens.
- Nothing goes on a host without a unit (`powos units`, below): every package, file, watcher or daemon you install has
  a manifest with owner, purpose, limits and removal, and dependencies go INSIDE an app or a container, not the host.
- Recovery if the phone UI breaks: disable the Magisk module (above) and reboot.

## Units: what is installed and running, on every host (`powos units`)
The rule: nothing is installed or left running host-wide without an overview or a limit. A **unit** is anything that
installs files or runs processes on a host - a PowOS app, a container, a system component, a package dependency, a
watcher/daemon. Each has a manifest (`/etc/powos/units.d/<id>.json`; the phone's Android side `/data/powos/units.d`,
the Magisk module's own `powos-units/`; the Mac `~/.config/powos/units.d`; a user's own installs
`~/.config/powos/units.d`): id, owner (`app:<id>` | `agent:<role>` | `user` | `system:<installer>`), purpose, host,
what it installs (`packages`, `files`, `edits` = shared files it changes, never deleted), what it runs (`processes`:
`match` regex | `pidfile` + `tree` | `cgroup` | `container` | `systemd`), `limits` (memory, cpus, pids - or
`unbounded` with the reason), `autosleep` (powos-sleep-common's key), and `remove` (stop, commands, keep).
- `powos units` - this host's units: running / asleep / stopped / installed, owner, memory, CPU, limits; orphans
  (found with no clear owner) marked for the user. `show <id>`, `check` (drift: packages, files, processes and
  Docker containers no unit claims; a unit's process outside its cgroup), `remove <id> [--dry-run] [--yes]` (the plan
  first), `register`, `unregister`, `enforce` (each running unit with limits into a cgroup of its own - the
  containers' hybrid cgroups on the phone, cgroup v2 elsewhere; macOS has none), `baseline` (adopt a host's
  pre-existing base once), `publish` (to the PowOS AI page's "installed & running" section, per host).
- The install paths register by themselves: `powos app install` (the app; `remove` unregisters), `powos containers run`
  (`container.<name>`, its cgroup and limits; `rm` / `--rm` unregister), the rooted deploy (`units/phone/`,
  `units/phone-android/`), the system module (`units/system-module/`). A native/sandbox service is put in its unit's
  cgroup by powos-runtime before it execs (limits: its manifest's, else twice its budget's memMB) - nothing long-running
  is unbounded. On the phone: `sh /data/powos/powos-units.sh ...` for Android's side.
- **Dependencies belong inside an app or a container, not on the host.** Need a tool or a library? Put it in the
  app's container image (`backend.container.image`) or `powos containers run` it. A host install is the exception: it
  needs a unit in `units/<host>/` in the same commit (`test/tier1/test-units-registry.py` fails a deploy script that
  installs anything no unit claims), and `powos units check` shows anything installed by hand.
- What was removed or registered on a host, and how to undo it: `docs/UNITS-LOG.md` (one row per action). GPU
  benchmarks on the phone belong in a container, not host packages: `powos-gpu-bench build|vk|gl` (unit `gpu-bench`;
  not run yet - see the log).

## Game modding (`powos mods`)
- **Native v2 mod manager (primary path — see docs/MODDING-V2.md).** Per-game
  install rules live in `config/mods/games.d/<game>.conf` (cyberpunk2077,
  gtav, gtav-legacy, rdr2, skyrimse). Mods stage to `~/.local/state/powos/mods`
  and deploy over the game dir via a rootless overlayfs mount; a Steam
  `powos-game-shim %command%` ensures the overlay before launch. Verbs:
  - `install <game> <mod-id…>` (numeric Nexus id / `nxm://` / local file) —
    auto-installs required frameworks, then the mods. RAGE games (GTAV/RDR2)
    auto-route through the ASI backend (`powos mods asi …`).
  - `list <game>` · `enable/disable <game> <mod>` · `deploy/undeploy <game>` ·
    `status [game]` · `verify <game>` · `snapshot`/`rollback <game>` ·
    `adopt <game>` (absorb a manually-modded game dir) · `doctor`.
  - **`export <game> [--out FILE]` / `import <file> [--game G] [--dry-run]
    [--no-deploy]`** — share/back up a mod list. Export projects the manifest to
    a machine-independent list (Nexus ids + priority + enabled, local paths/
    hashes stripped); import re-installs via the normal path and replays the
    enabled state. `--dry-run` prints the plan and installs nothing. ✅
- **`powos game <name> <verb>`** — game-centric facade over everything below.
  `powos game` / `powos games` lists your games; `powos game gtav status`,
  `powos game cyberpunk mod install 1234`, `powos game bf3 play`. Names accept
  any spelling the mod manager takes (canonical id, alias, Steam appid);
  `bf3`/`vu` routes to Venice Unleashed. It dispatches to `powos mods <verb>
  <game>`, which keeps working identically — prefer whichever reads better.
  Namespace rule: `game` = one game · `games` = the collection ·
  `games storage` = the POWOS-GAMES disk partition · `mods` = the tooling. ✅
- **Venice Unleashed (`powos mods vu`)** — Battlefield 3 community client +
  VEXT modding framework. A whole third-party CLIENT, not a Nexus mod, so it
  never routes through NMA/Vortex. Runs under GE-Proton in its own prefix
  (same mechanism as MO2 — no Bottles). `vu install [--gamepath DIR]` ·
  `activate [--token T]` · `play` · `branch prod|dev` · `status` ·
  `server init|start|status` · `uninstall [--purge]`.
  **Mods (`vu mod`)** — VU mods are always server-side (a server loads them,
  clients auto-download on join), so the verb is just `vu mod`, no client/server
  split. `vu mod install <source> [name...]` where source is `gh:owner/repo`,
  a github URL, a local dir/zip (the Discord/forum escape hatch), or `vumm:<name>`
  (bf3reality-account-gated — even realitymod 403s anonymously, and vumm has no
  search/list). A mod is identified by a `mod.json` Name, not guessed; a repo
  shipping several mods is never installed wholesale — with no name and no TTY it
  lists them and refuses (pass the name(s) or `--all`). `vu mod list` ·
  `enable|disable|remove <name>` (ModList.txt wiring) · `update [name|--all]`
  (re-fetch GitHub mods).
  **The one gotcha:** VU's WebUI needs a NATIVE `d3dcompiler_47` in the prefix
  on EVERY branch, not just dev. Wine's built-in stub renders a blank/black UI
  with no error, which reads as "VU is broken on Linux" — it isn't, and hasn't
  been since 2022. `vu install` installs it; `vu status` reports if a prefix
  reset lost it. Server ports: 7948/udp harmony, 25200/udp frostbite,
  47200/tcp rcon. 🚧 Implemented, hardware validation pending (needs BF3 files
  and an EA account that owns the game).
- Legacy escape hatches (Nexus Mods App GUI / Vortex / Wabbajack) remain for
  FOMOD wizards and games without a `games.d` config — details below.
- Install mod managers on-demand: `powos mods install nexus-mods-app`
  (AppImage, native Linux, Nexus's own — replaces old Vortex which was
  Windows-only). Also `install vortex` (documents the Proton wrapper path,
  doesn't auto-install). `mods installed` lists installed managers.
- One-shot game modding prep: `powos mods setup <game>` — installs
  protontricks, runs winetricks packages (`vcrun2022`, `d3dcompiler_47`)
  into the game's Proton prefix, sets `WINEDLLOVERRIDES="winmm=n,b;version=n,b" %command%`
  in Steam's per-user launch options. Requires Steam CLOSED for the config
  edit. Short names: cyberpunk, skyrimse, skyrim-ae, fallout4, starfield,
  witcher3, bg3 — plus any numeric appid. ✅
- **Nexus Mods App CLI** (undocumented but exists): `powos mods` wraps
  the AppImage's own `as-main` subcommands. Auth persists in the app's
  data model — a GUI login is visible to all subsequent CLI calls, no
  re-auth needed.
  - `powos mods auth [api-key]`: key = save API key; no arg = OAuth login.
  - `powos mods logout` / `games` / `tools <game>` / `run-tool <game> <tool>`.
  - `powos mods install-collection <slug>`: installs a whole Nexus
    collection headlessly. Slug is from the URL
    `nexusmods.com/<game>/collections/<slug>`. **NMA GUI must be closed.**
  - `powos mods install-mod <game> <mod-id> [file-id]`: constructs a
    `nxm://` URL and uses `protocol-invoke` — works whether the GUI is
    running or not (running instance receives it). Game accepts either a
    short name (cyberpunk, skyrimse, bg3, …) or a Nexus URL slug.
  - `powos mods raw <args>`: forward to `NexusModsApp as-main` for
    subcommands PowOS hasn't wrapped (heartbeat, extract-archive,
    datamodel, etc.).
- Workflow for AI-driven collection install:
  1. Ensure NMA installed: `powos mods install nexus-mods-app`.
  2. Ensure game modding-prep done: `powos mods setup <game>` (once per
     game). Requires Steam closed. On success, WINEDLLOVERRIDES is set.
  3. Ensure NMA GUI is closed for `as-main` commands.
  4. `powos mods install-collection <slug>` — hands-off collection install.
  5. Relaunch Steam and the game; mods are deployed by NMA.
- Cyberpunk specifics: mod framework stack is CET + RED4ext + REDscript.
  The `setup` command installs the winetricks packages CET needs;
  RED4ext/REDscript are managed by NMA once auth is in place.
- Steam Workshop is deliberately separate — it's built into Steam
  itself, no PowOS wrapper needed. `powos mods` covers off-Workshop
  modding (Nexus + REDmod tooling).

## GPU / base image
- **Default base is now the OPEN NVIDIA driver** (`bazzite-nvidia-open:stable`).
  Closed proprietary (`bazzite-nvidia`) is selectable; AMD/Intel = `bazzite`.
  Override at build: `POWOS_BASE_IMAGE` / `--build-arg BASE_IMAGE`.
- One x86-64 USB, GPU variant auto-select at boot: `lib/boot/variant-select.sh`
  picks `nvidia-open` (default for NVIDIA) vs `nvidia` (closed) vs `main` (AMD/Intel),
  override via `rd.powos.variant=nvidia-open|nvidia|main|auto`. Install inherits the
  booted variant. ⚠️ selection engine done + unit-tested; multi-variant build,
  USB layout, dracut selection, and boot menu are wired (docs/MULTI-VARIANT-USB.md)
  — hardware validation pending.
  x86-64 images only (the phone has its own ARM rootfs: see "PowOS on a phone"). Open needs Turing/GTX-16+; older NVIDIA
  (Maxwell/Pascal) needs closed.
- Driver stack is fixed by the image; hardware profiles tune settings but can't
  swap nvidia↔amd at boot.
- **Runtime base swap** (`powos base`): `list`, `current`, `switch <name>` (persistent
  default, reboot to apply), `add <bootc-image> [name]` (builds through PowOS's
  Containerfile so the new base keeps the RAM-boot module, extracts to
  layers/base-<name>/), `remove`. Same-family swaps work (nvidia open/closed, amd,
  newer/older bazzite/ublue); non-bootc distro is NOT a drop-in. ⚠️ boot-critical,
  needs VM validation. Each base is several GB.
- CUDA (`powos cuda enable|enter|run|status|disable`): base has the NVIDIA driver
  (CUDA *runtime* works). Full toolkit (nvcc/cuDNN) is NOT baked in — it lives in
  the `powos-cuda` distrobox (GPU passed through, nvcc exported to host). Image is
  CUDA 12.8 cuDNN — **≥12.8 is REQUIRED to compile for RTX 50-series (sm_120)**;
  12.4 silently can't target Blackwell. `powos-python` has passthrough but no toolkit.
- Driver channel (`powos driver status|stable|testing`): rebases the installed
  system between published image tags (:nvidia-open ↔ :nvidia-open-testing) for
  tested vs newest drivers. Derives the repo from the booted image (fork-agnostic).
  Reboot to apply; old deployment = rollback. Counterpart to `powos base` (USB layers).
- Private image pulls (`powos registry login [host]`): writes /etc/ostree/auth.json
  so bootc can pull private bases; reuses your `gh` token for ghcr.io.
- GPU hotswap (`powos gpu status|to-vm|to-host`): dynamically bind the dGPU
  between the host (nvidia → CUDA/native games) and vfio-pci (VM passthrough),
  so it's NOT permanently dedicated to vfio and CUDA keeps working. `vm windows
  --gpu` auto-does to-vm → launch → to-host. ⚠️ Hard prereqs: IOMMU on; the
  DESKTOP must run on the OTHER GPU (iGPU) or releasing the dGPU freezes the
  session (to-vm refuses while in use). Pure logic unit-tested; real bind/unbind
  needs hardware. Whole IOMMU-group slot (GPU + HDMI-audio) moves together.
- Anti-cheat reality (IMPORTANT, don't over-promise): kernel anti-cheats
  (EAC/BattlEye/Vanguard — e.g. Arc Raiders) BLOCK VMs and may flag them, so
  anti-cheat games CANNOT run in `vm windows` — they need BARE-METAL Windows
  (`powos boot windows`, a reboot). Non-anti-cheat games should run NATIVE on
  Linux (Steam/Proton) — no VM. The Windows VM is for productivity + non-AC
  Windows-only titles. "Both OSes native at once, no VM" is physically impossible.
- Overview (`powos overview [--json]`): one-glance panel — layer model
  (bootc-deployment vs USB overlay-stack), base image + channel, GPU/CUDA,
  deployment/rollback count, active services, containers, disk, safety posture.
  Read-only + non-root, so desktop widgets can poll `--json`.
- Services (`powos services [--json]`): running podman/distrobox containers
  (image, status, ports, gpu-access, dev-vs-service), container-backed systemd
  units (flags stale/failed), and GPU users (vram/util + compute processes).
  The "what are my gsplat/TTS/STT/dev boxes doing + who's on the GPU" panel.
- Install router (`powos install <thing>`): ONE front door — probes flatpak/rpm/
  brew, reports "found in N sources", installs the MOST CONTAINED by default:
  flatpak (sandbox + portals prompt) → powos-sandbox container (own home, can't
  see real $HOME — supply-chain containment) → brew only by explicit opt-in
  (unsandboxed, warns) → host rpm-ostree layer last, always asks. `-m` forces a
  backend; `-m pip` installs inside the sandbox; `--dry` reports only;
  `sandbox-share <dir>` = explicit containment grant. Honesty: flatpak portals
  give real runtime prompts; containers give denial-by-default (no per-syscall
  prompts on Linux) — the sandbox simply cannot see your files.

## Key paths
- `/usr/lib/powos/` scripts · `/etc/powos/` config · `/run/powos/` runtime state
- `/var/lib/powos/{src,projects,sources,extensions}` · USB label `POWOS-DATA`
