# PowOS CLI Reference

Moved out of CLAUDE.md (friction f100) to keep the root file a short index. Verbatim, nothing changed.

## CLI Commands

### Status & Info
```bash
powos status          # Full status (layers, RAM, USB, protection)
powos health          # System health check with issues/warnings
powos health --ai     # Talk to health AI agent for troubleshooting
powos layers          # Detailed layer stack with sizes
powos layers status   # Same as above
powos hardware        # Show detected hardware
powos version         # Show version and active layers
```

### Sync (RAM ↔ USB)

**Real-world scenario:** Your USB runs on Machine A, you unplug and use on Machine B, then return to Machine A. Both machines have changes in RAM - conflict!

```bash
powos sync                    # Show sync status (bare = status)
powos sync now                # Sync RAM ↔ USB now (detects conflicts)
powos sync status             # Show sync status & conflicts
powos sync resolve            # Interactive conflict resolution
powos sync resolve --ai       # AI analyzes conflicts & recommends action
powos sync --keep-ram         # Force RAM changes to USB (your work wins)
powos sync --keep-usb         # Reload from USB (USB wins, reboot needed)
powos sync --merge            # Attempt basic merge (may need manual intervention)
powos sync diff               # Show differences between RAM and USB
```

**How conflict detection works:**
- USB has a `.powos-sync` marker tracking which machine last wrote to it
- If you're on Machine A but USB was last written by Machine B → CONFLICT
- Choose to keep your RAM changes, USB changes, or merge manually
- Use `--ai` to discuss the conflict with the health agent before deciding

### Flush & Safety
```bash
powos flush           # Force flush RAM changes to USB now (no conflict check)
powos safe            # Check if safe to unplug USB
```

### Mobile Mode (RAM-Only)

Copy selected OS packages to a RAM tmpfs, then bind-mount the populated directories
over their USB-backed paths. **No reboot required** — paths are served from RAM
immediately after `sudo powos mobile enable` completes.

> **How it works:** overlayfs `mount -o remount,lowerdir=…` is rejected by the kernel
> (EINVAL) — you cannot add lowerdirs to a live overlayfs. Instead, mobile mode:
> 1. Creates a tmpfs at `/run/powos/mobile-ram` (sized to fit selected packages + 20%)
> 2. Copies selected RPM-category files from the current merged FS into the tmpfs
> 3. Bind-mounts each populated safe directory (`/usr`, `/opt`, `/libexec`) from the
>    tmpfs over the corresponding system path — those paths are now served from RAM
>
> `/etc` and `/var` are intentionally excluded (live auth/service config — risky to bind).
>
> **After reboot:** the tmpfs and binds live in `/run` and are lost. `powos mobile status`
> detects the stale state automatically. Re-run `sudo powos mobile enable` to re-activate.
>
> **Writes to bound paths** while mobile is active go to the RAM tmpfs only; they are
> not persisted to the overlayfs upper layer or USB.

```bash
sudo powos mobile enable         # Enable mobile mode (live bind mounts, no reboot)
powos mobile                     # Show mobile-mode status (bare = status)
sudo powos mobile -c             # Interactive menu to customize categories first
powos mobile status              # Show active binds / stale-state detection
sudo powos mobile disable        # Unmount binds + free tmpfs, return to USB-backed

# Category management (non-interactive, for scripts/LLMs)
powos mobile categories          # List all categories with sizes
powos mobile exclude Games       # Exclude a category
powos mobile include Games       # Include a category
powos mobile include-all         # Reset to include everything
powos mobile exclude-all         # Start fresh, include nothing
```

**How it works:**
- Categories detected from package manager (rpm groups)
- Selected categories copied to a tmpfs in RAM (`/run/powos/mobile-ram`)
- Populated safe dirs bind-mounted from tmpfs over USB-backed paths — live, no reboot
- USB data partition can be unplugged for bound paths (`/usr`, `/opt`, `/libexec`)
- `/etc` and `/var` remain USB-backed; user data still uses default USB bind-mount

### Backup (USB → Cloud)

Optional cloud backup of your USB state to a git repository:

```bash
powos backup status           # Show backup status (ahead/behind)
powos backup push             # Push USB state to cloud
powos backup push -m "msg"    # Push with custom commit message
powos backup pull             # Pull from cloud (merge strategy)
powos backup pull --theirs    # Pull and discard local changes
powos backup setup <url>      # Configure cloud backup repository
powos backup ignore           # Edit .syncignore in editor
powos backup ignore "pattern" # Add pattern to .syncignore
powos backup refresh          # Regenerate ignore rules
powos backup export [file]    # Export state to tarball
powos backup import <file>    # Import state from tarball
powos backup machine init     # Create machine-specific branch
```

**What gets backed up:**
- `projects/` - Your development projects
- `sources/` - Overlay source code
- `containers/distrobox.ini` - Container definitions
- `config/` - PowOS configuration

**Configuring what NOT to backup:**

Edit `.syncignore` in your state repo (`/var/lib/powos/git/.syncignore`):

```bash
powos backup ignore             # Opens in editor
powos backup ignore "big-data/" # Quick add a pattern
```

**Default exclusions** (in `.syncignore`):
- `node_modules/`, `vendor/`, `.venv/` - Package managers
- `dist/`, `build/`, `target/` - Build artifacts
- `.env`, `secrets/`, `*.key` - Secrets
- `.next/`, `.nuxt/`, `.cache/` - Framework caches
- `*.iso`, `*.img`, `*.vmdk` - Large binaries
- `.mozilla/`, `.config/chromium/` - Browser profiles

### Updates
```bash
powos update              # Check for available updates
powos update os           # Update Bazzite base OS
powos update powos        # Update PowOS scripts
powos update packages     # Update installed packages
powos update overlays     # Rebuild overlays with latest upstream
powos update apply        # Apply all updates (os + packages)
```

### Layer Management
```bash
powos layers sync           # Force sync RAM → custom layer
powos layers clear custom   # Clear custom layer entirely
powos layers clear updates  # Clear updates layer entirely
```

### Rollback
```bash
powos rollback              # Show rollback options
powos rollback custom       # Skip custom layer on next boot
powos rollback updates      # Skip updates layer on next boot
powos rollback all          # Boot with base only
powos rollback reset        # Clear all rollback flags
```

**Note:** rollback sets kernel args via `grubby`; grubby failures are reported loudly. `/run/powos/rollback-kargs` is informational only — nothing reads it at boot, so it is NOT a fallback. After reboot, verify with `grep powos /proc/cmdline`.

### OS in RAM (`powos ramboot`) — ⚠️ Installed opt-in is EXPERIMENTAL

The **USB live** model already runs the whole OS from RAM automatically
(`rd.powos.ramboot=1`, engaged by the dracut module when a `POWOS-DATA`
partition is present). On an **installed** bootc/composefs system, OS-in-RAM is
a deliberate, composefs-safe **copy-to-tmpfs** opt-in behind a *different* karg
(`rd.powos.ramboot.installed=1`) — because overlaying a composefs root on itself
loops the boot (that incident is why the two are now separate). The CLI never
sets the USB auto karg on an installed system.

```bash
powos ramboot status                 # mode, RAM-vs-OS fit, self-heal counter
sudo powos ramboot enable            # installed only; auto-sizes the tmpfs
sudo powos ramboot enable --ram 20G  # explicit tmpfs size
sudo powos ramboot enable --dry-run  # show the plan, change nothing
sudo powos ramboot disable           # remove the installed opt-in kargs
sudo powos ramboot reset             # clear the self-heal counter after a fix
```

`enable` refuses on the USB model ("already runs from RAM") and refuses unless
the OS fits: `MemTotal > OS_estimate(du -sx /usr /etc) + 4 GiB`; default `--ram`
= `min(OS + 4 GiB, MemTotal − 4 GiB)`. Kargs go through `rpm-ostree kargs`
(preferred) or `bootc kargs` (fallback). Self-heal: after **3** failed boots the
initramfs auto-skips ramboot (counter at `<esp>/powos/ramboot-attempts`); the
5-second boot menu also offers the previous entry. `reset` clears the counter.
Full contract + rationale: `docs/BOOT-ARCHITECTURE.md`.

### Package Installation
```bash
powos install PKG...              # Install to custom layer
powos install -c NAME PKG...      # Install to container NAME
powos install -c NAME -e PKG...   # Install + export GUI apps to host
```

### Install to Disk (dual-boot)

**CANONICAL (hardware-validated): the Anaconda GUI installer ISO.** Build it with
`./build/build-iso.sh` (→ `build/output/bootiso/install.iso`), flash, boot, and
Anaconda picks the disk + installs PowOS with its own confirmations. After
reboot, `powos backup pull` restores config. This is the supported install path.

> ⚠️ **Everything below is the LEGACY / experimental custom install machinery**
> (`powos install` / `powos-install-wizard` / `install-system`, the lean
> `POWOS_INSTALLER` raw variant, and the live-USB first-boot self-completion). It
> is superseded by the Anaconda ISO — blind TUI, GPU stalls, slow boot. Kept in
> the tree and documented for reference, but NOT the way to install. The services
> stay in the image but the Anaconda ISO never triggers `powos.install`, so they
> don't run.

The (legacy) raw live USB is a **single live image with a 5-second visible boot
menu**: "PowOS Live" (default, runs from RAM), "Install PowOS to disk", "Recovery
— Safe mode", "Recovery — AI Debug". Choosing Install boots live and launches the
**guided installer wizard** — nothing is wiped without an explicit target +
confirmation.

**Guided wizard** (`powos install` / `powos-install-wizard`, TUI or GUI): walks
disk → mode → partition sizes → GPU flavor → hostname/user/password (hashed) →
SSH → RAM boot → AI credentials → restore-from-backup URL, shows a review, then
drives `powos install-system` with the mapped flags and writes
`/etc/powos/install.conf`. `powos-firstboot.service` applies the rest on first
boot (hostname, user, ssh, `powos ramboot enable`, AI creds, `powos backup pull`)
then deletes the config and self-disables. The raw installer is still available:

```bash
sudo powos install                        # Guided wizard (default install flow)
sudo powos install-system                 # Raw interactive installer
sudo powos install-system --dry-run       # Show the plan, change nothing
sudo powos install-system --alongside     # Dual-boot: install into free space, keep Windows
sudo powos install-system --whole-disk    # Erase target disk (must type disk model to confirm)
sudo powos install-system --shared-gb 200 # Shared NTFS data partition (labeled POWOS-GAMES)
```

Reservations (games + Windows tail) are **default-on, auto-sized** from the disk
so a fresh install never needs a reformat to add games/Windows later.

**Flashing the raw + first-boot self-completion:** the built image (`bib` →
`powos.raw`) ships as a **plain bootable OS** — POWOS-DATA and the boot-menu
entries are NOT baked in (baking needs loop devices that fail unreliably in CI /
Docker). Flash `powos.raw` to a USB with any tool (Balena Etcher / Rufus / dd);
on the **first boot from the real device**, `powos-firstboot-disk.service` runs
`install-to-usb.sh --self-complete`: it resolves the boot disk (verified via the
`/boot/efi` source, never guessed), and — only if `POWOS-DATA` is absent —
creates it filling the **whole device** (repairs the GPT to the real end so a
30 GB raw on a 4 TB stick uses all 4 TB) plus the Install/Recovery boot entries.
Add-only (existing partitions untouched), marker-gated (`/var/lib/powos/
firstboot-disk-done`, runs once), and can't brick boot. Real hardware has
working partition scanning; the build stays simple and small.

**Boot-menu mechanism:** the "Install PowOS" and "Recovery" entries are Boot
Loader Spec entries (`loader/entries/powos-*.conf`) added by `install-to-usb.sh`
— copies of the live entry plus a kernel arg (`powos.install=1`, or
`powos.mode=safe|aidebug` for recovery, both forcing `rd.powos.ramboot=0`).
`powos-installer.service` (`ConditionKernelCommandLine=powos.install`) launches
the wizard on tty1; `powos-safemode.service` (`powos.mode`) runs recovery.

**Dual-boot notes automated by the installer:** sets RTC to local time (matches
Windows), reminds to disable Windows Fast Startup/hibernation, recommends the
UEFI boot menu (atomic Bazzite's GRUB won't auto-list Windows), and advises
keeping Steam Proton prefixes on native FS while sharing only assets on NTFS.

> ⚠️ **Status:** whole-disk uses `bootc install to-disk`; the dual-boot
> "alongside" path (partition free space + reuse Windows ESP via
> `bootc install to-filesystem`) is **EXPERIMENTAL** — see `TODO(hw)` markers
> in `lib/install-system.sh`. Validate on a VM / spare disk before trusting it.

### Recovery & Boot Debugging (`powos doctor`, Safe mode)

A bad boot is **survivable and diagnosable**, not a brick (this is the direct
answer to the composefs boot-loop incident):

- **Self-heal:** RAM boot can never loop — after 3 failed attempts the initramfs
  auto-reverts to a normal disk boot (see the ramboot section).
- **Always-visible 5s boot menu:** pick the previous bootc deployment any time.
- **Recovery boot entries:** *Safe mode* (recovery menu) and *AI Debug* (runs
  `powos doctor --ai` on tty1) — both boot with RAM boot off.
- **`powos doctor`** — the AI-native boot debugger:

```bash
powos doctor                 # collect a diagnostic bundle → /var/log/powos/
powos doctor --ai            # + have the health agent diagnose it
sudo powos doctor --target auto --ai   # from the Live USB: mount a broken
                                       # install READ-ONLY and diagnose ITS logs
powos doctor --offline       # save the bundle, no network/AI (re-run later)
```

`doctor` gathers the current + previous boot journal, failed units, dmesg,
`/run/powos` state and the self-heal counter. AI credentials resolve
try-all-with-fallback (the target install → this system → cloud backup →
prompt); the secret is passed via env, never argv, never printed. Details:
`docs/BOOT-ARCHITECTURE.md`.

### Windows: dual-boot, reciprocal VM, GPU hotswap
```bash
powos boot windows          # one-shot reboot into bare-metal Windows, back after
powos vm windows [--gpu]    # run the installed Windows as a KVM guest (no reboot)
powos gpu status            # where the dGPU is (host vs vfio/VM) + readiness
powos gpu to-vm | to-host   # hotswap the dGPU between Linux (CUDA) and a VM
```
**Anti-cheat reality (see `docs/DUAL-BOOT-VM.md`):** kernel anti-cheats
(EAC/BattlEye/Vanguard — e.g. Arc Raiders) **block VMs** → those games need
**bare-metal Windows** (`powos boot windows`, a reboot). Non-anti-cheat games run
**native on Linux/Proton** (no VM). The VM is for productivity + non-AC
Windows-only titles. `--gpu` hotswaps the dGPU in for the session and reclaims it
on exit (keeps CUDA on the host otherwise).

> ⚠️ **Status / testability:** GPU hotswap + passthrough is **hardware-only** —
> it can't be exercised in Docker/CI (no GPU, vfio, IOMMU, or Windows image). The
> harness covers PowOS boot (`test/e2e`) + command/PCI-detection logic
> (`test/tier1/test-gpu.sh`). Hard prereqs: IOMMU on; **desktop on the iGPU**
> (else releasing the dGPU freezes the session — `powos gpu to-vm` refuses while
> the GPU is in use). Keep a TTY/SSH the first time.

### Games Storage (powos games) — shared NTFS partition, both OSes

> **Three namespaces, one rule each — singular/plural is meaningful:**
>
> | Command | Scope | Owns |
> |---|---|---|
> | `powos game <name> <verb>` | ONE game | Facade (`lib/game.sh`) — dispatches to mods subsystems. Owns no state. |
> | `powos games` | The COLLECTION | Bare = list your games. `games sync` = saves between devices. |
> | `powos games storage <verb>` | The DISK | POWOS-GAMES partition: create/mount/resize/steam-setup (`lib/games.sh`). |
> | `powos mods <verb> <game>` | Mod tooling | The actual implementation — Nexus/Vortex/Wabbajack/ASI/prefixes. |
>
> `powos game` is a **facade**: `powos game gtav mod install 123` and
> `powos mods install gtav 123` do the same work. Two spellings, one
> implementation — the facade must never grow its own state.
>
> New feature routing test: *partitions or mounts a disk?* → `games storage`.
> *Puts files into a game or a prefix?* → `mods` (then expose it on the facade).
>
> The storage verbs still work bare (`powos games create --size 512`) for
> existing scripts, but `storage` is the documented spelling.

POWOS-GAMES is a first-class partition: NTFS, labeled `POWOS-GAMES`,
deliberately visible to Windows. Every other PowOS partition is hidden from
Windows via GPT type GUIDs (Linux-filesystem type = no drive letter = no
"format this disk?" prompts) — see the exposure contract in `docs/WINDOWS.md`.
Created at USB flash time (`install-to-usb.sh --games-gb N`), by the disk
installer (`--shared-gb`, now labeled POWOS-GAMES), or later on any existing
system via the CLI. Machine-local: each machine creates its own on its own
PowOS-owned disk.

```bash
powos games status                    # partition, mount, Steam wiring state
powos games create --size N [--disk D] [--dry-run] [--yes]  # create POWOS-GAMES
powos games mount                     # mount at /var/mnt/games (ntfs3)
powos games steam-setup               # Steam library on the shared partition
powos games resize                    # grow/shrink POWOS-GAMES partition (ntfsresize + parted)
```

**Steam wiring (`steam-setup`):** mounts POWOS-GAMES at `/var/mnt/games` via
ntfs3 (uid/gid, windows_names), creates `SteamLibrary/steamapps`, keeps
`compatdata`/`shadercache` on native btrfs via symlinks (Proton prefixes break
on NTFS), adds the library to `libraryfolders.vdf` when Steam is closed, and
drops `GAMES-README.txt` at the partition root telling the Windows side to add
`<letter>:\SteamLibrary` as a Windows Steam library. One installed game serves
both OSes.

> ⚠️ **Safety/status:** nothing touches a disk except a user-run command
> against a device the user names, behind plan display + confirmations +
> `--dry-run`. Implemented, not yet hardware-validated.

### Bare-Metal Windows on USB (powos windows) — 🚧 EXPERIMENTAL, needs hardware validation

Full design: `docs/WINDOWS.md`. Windows lives in ONE file
(`<POWOS-GAMES>/PowOS-Windows/windows.vhdx`, thin/dynamic) — NO real partitions
for Windows, ever. It bare-metal boots via Windows native VHD boot (bootmgr on
the SHARED PowOS ESP, backed up before install), and the same file also runs as
a KVM guest. The user supplies their own ISO + license.

```bash
powos windows status              # image, hibernation state, boot entry, snapshots
powos windows create [--size N] [--fixed-vhd]   # create the thin image file (no partitioning)
powos windows install --iso PATH  # Windows Setup in QEMU into the file (real ESP rides along) 🚧
powos windows finalize            # raw→VHDX convert + verify ESP boot files + host firmware entry
powos windows                     # guarded switch: flush + stop layer-sync → guards →
                                  #   unmount POWOS-GAMES → BootNext → hibernate PowOS
                                  #   (Windows COLD-BOOTS; --reboot fallback until hibernation ships) 🚧
powos windows snapshot|snapshots|rollback   # whole-file zstd copy on POWOS-DATA (refuses if image open)
powos windows vm                  # boot the SAME image as a KVM guest (VM-hibernation OK) 🚧
```

**Metal Windows always COLD-BOOTS** — `winresume` can't read a `hiberfil.sys`
inside a VHD, so bare-metal session resume is impossible (accepted: you quit the
game to switch). PowOS's own session survives via PowOS-side S4 hibernation.
Windows session resume exists only in `vm` mode. Costs of native-VHD boot: a
dynamic image expands toward its full `--size` on first metal boot, and in-place
feature updates are blocked (`--fixed-vhd` is the escape hatch; see WINDOWS.md).

> 🚧 **Status:** the switch and `install` are EXPERIMENTAL — implemented, not
> yet hardware-validated. The hibernation half is blocked on
> `docs/HIBERNATION.md`; until it ships, `powos windows --reboot` is the
> fallback. Same safety posture as `powos games`: named device, plan,
> confirmations, `--dry-run`.

### Container Management
```bash
powos containers run --rm --memory 64m --cpus 0.5 --pids-limit 64 IMG CMD  # hard limits (phone too)
powos containers ps | exec | limits | check   # limits in use, exec inside them, what the kernel enforces
powos containers autosleep status | wake NAME  # idle ones pause (phone: 5 min default), wake on a connection
powos containers list             # List all containers
powos containers create NAME IMG  # Create new container
powos containers enter NAME       # Enter container shell
powos containers remove NAME      # Remove container
powos containers export NAME APP  # Export GUI app to host menu
powos containers assemble         # Create from distrobox.ini
powos containers prune            # Clean up unused images
```

### Build from Dockerfile
```bash
powos build                       # Build from ./Dockerfile
powos build -f FILE               # Build from specific file
powos build -t TAG                # Build with tag
powos build -t myapp:v1 ./dir     # Full example
```

### Development (powos dev)
```bash
powos dev list                    # List all projects
powos dev new NAME                # Create new project from scratch

# AI Project Creator - generates full project from description
powos dev new --ai mytool                              # Interactive mode
powos dev new --ai "CLI that converts JSON to YAML" jsonyaml
powos dev new --ai "async web scraper with Redis queue" scraper

# Docker projects (AI-powered)
powos dev new --docker myapi
powos dev new --docker --desc "REST API with Redis" myapi

# Fork existing repos
powos dev fork kde:dolphin
powos dev fork https://github.com/user/repo
powos dev fork --docker URL       # Fork and auto-dockerize

powos dev build NAME              # Build project
powos dev enable NAME             # Install to system as overlay
powos dev disable NAME            # Remove from system
powos dev update NAME             # Pull upstream changes (forks only)
```

### AI Agent System (powos ai)

The AI agent system provides configurable AI assistance with multiple clients, agent personalities, and specialized flavors.

```bash
# Basic prompts
powos ai "help me set up this project"
powos ai --agent coder "review this function"
powos ai --agent health "is my system healthy?"

# Agent flavors (specialized modes)
powos ai --agent health:sync "help with this conflict"
powos ai --agent health:layers "layer corruption issue"
powos ai --agent containerizer:python "containerize this flask app"
powos ai --agent containerizer:node "dockerize my next.js app"
powos ai --agent coder:review "check this code for issues"

# Agent aliases (multiple names for same agent)
powos ai --agent docker "containerize this"     # → containerizer
powos ai --agent pod "help with containers"     # → containerizer

# Client selection
powos ai --client claude "explain this"    # Default
powos ai --client gemini "analyze this"
powos ai --client ollama "local inference"

# Interactive mode
powos ai -i                               # Start chat session
powos ai -i --agent coder                 # Chat with specific agent

# Session management
powos ai session new myproject            # Create named session
powos ai -s myproject "hello"             # Use session
powos ai -s myproject "continue..."       # Session maintains context
powos ai --continue "what next?"          # Continue last conversation
powos ai sessions                         # List all sessions
powos ai session export myproject md      # Export as markdown

# Output formats
powos ai --json "hello"                   # Full JSON with session_id
powos ai --verbose "create a todo"        # Verbose with tool use

# List agents with their flavors
powos ai agents
```

**Available Agents & Flavors:**

| Agent | Description | Flavors |
|-------|-------------|---------|
| `assistant` | General purpose (default) | - |
| `coder` | Coding assistance | `:review` - Code review specialist |
| `devops` | System admin, containers | - |
| `health` | PowOS diagnostics | `:sync` - RAM↔USB conflicts, `:layers` - Layer issues |
| `creator` | Project generator | - |
| `containerizer` | Container config generator | `:python`, `:node` |

**Aliases:** `docker`, `pod`, `container` → `containerizer`

**Keeping agents current (single source of truth):** the system-facing agents
(`assistant`, `health`, `devops`) inject `config/ai/context/capabilities.md`
plus live `powos help` at call time via `AGENT_CONTEXT_CMD`. Edit that ONE doc
when features change — do not re-describe features in individual agent prompts,
which drift. Ships to `/etc/powos/ai/context/capabilities.md`.

**`!cmd` — agent instructions are GENERATED from `--help`, not hand-written.**
In any `AGENT_SYSTEM_PROMPT` (or `FLAVOR_PROMPT`), a line whose first character
is `!` is replaced at load time by that command's stdout:

```bash
AGENT_SYSTEM_PROMPT="You are the PowOS modding agent.

!powos mods help
"
```

The agent then reads the REAL, CURRENT help text, so prompt and CLI cannot
drift. **Corollary — this is the rule, not a nicety: if a command's `--help`
can't explain a feature, that is a HELP BUG to fix at the source. Never restate
command documentation as prose in an agent.conf.** (The hardcoded CLI listing
this replaced in `modder/agent.conf` had already gone stale — it was missing
`verify`, `bisect`, `deploy`, `adopt`, `snapshot` and `export`/`import`.)

Division of labour:
- `AGENT_SYSTEM_PROMPT` — judgment (routing, policy, failure diagnosis) plus
  `!cmd` for the CLI contract.
- `AGENT_CONTEXT_CMD` — live STATE only (what's installed, what's
  authenticated, what's detected). Never duplicate help here; that pays for the
  same tokens twice and drifts twice as fast.

**Consequence: an undocumented command no longer exists.** Once instructions
are generated from `--help`, a working-but-undocumented verb is invisible to
the agent. `test/tier1/test-mods-core.sh` enforces the contract in BOTH
directions — every help-documented verb must dispatch, and every verb an agent
needs must appear in help. Both failure modes were real here: `snapshot` was
documented but never wired, and `info` / `files` / `changelog` /
`download-link` / `install-file` / `check` / `doctor` / `loadouts` all worked
but were missing from help. When you add a verb, add it to help in the same
commit or the agent will never use it.

Mechanics: `_ai_expand_prompt_cmds` in `lib/ai/agent.sh`, run at the end of
`_ai_load_agent` so it covers flavor prompts too. Each command is capped at
`AI_PROMPT_CMD_TIMEOUT` (default 10s) so a wedged command can't hang agent
startup; failures report inline (`[cmd — unavailable (exit N)]`) rather than
silently yielding an empty section, which would give the agent amnesia about a
whole subsystem. ANSI escapes are stripped (PowOS colorizes unconditionally). A
`!` that isn't the first character of a line is ordinary text. Tested in
`test/tier1/test-ai-agent.sh`.

**Agent Config Structure:**
```
config/ai/agents/
├── health/
│   ├── agent.conf        # Main agent config
│   ├── sync.conf         # :sync flavor
│   └── layers.conf       # :layers flavor
├── containerizer/
│   ├── agent.conf
│   ├── python.conf
│   └── node.conf
├── coder/
│   ├── agent.conf
│   └── review.conf
└── ...
```

**Library Usage (in scripts):**
```bash
source /usr/lib/powos/ai/agent.sh

# Basic calls
ai_call "what should I do?"
ai_call --agent devops "diagnose this"
ai_call --agent health:sync "help with conflict"

# Interactive with context
ai_interactive --agent health --context "$system_state"
```

**Creating Custom Agents:**

1. Create agent directory and config:
```bash
mkdir -p config/ai/agents/myagent

# config/ai/agents/myagent/agent.conf
AGENT_NAME="myagent"
AGENT_DESCRIPTION="My custom agent"
AGENT_CLIENT="claude"  # or gemini, ollama
AGENT_ALIASES="myalias otheralias"  # Optional aliases
AGENT_SYSTEM_PROMPT="You are a specialist in..."
```

2. Add flavors (optional) - any .conf file except agent.conf:
```bash
# config/ai/agents/myagent/specialized.conf
FLAVOR_NAME="specialized"
FLAVOR_DESCRIPTION="Specialized mode for X"
FLAVOR_PROMPT="## Specialized Mode

Focus on X, Y, Z..."
```

3. Use it:
```bash
powos ai --agent myagent "help me"
powos ai --agent myagent:specialized "detailed help"
```

## Example Output

**powos status:**
```
PowOS Status
════════════════════════════════════════

Active Layers
  Stack:      custom,updates,base
              ├─ ● custom (your packages & configs)
              ├─ ● updates (OS updates)
              └─ ● base (Bazzite)

RAM Overlay
  Mode:       ● Running from RAM
  Allocated:  8G
  Used:       1.2G (changes since boot)

User Data (/home)
  Mode:       ● USB bind-mount (direct)
  CacheFS:    disabled (set POWOS_CACHEFS_ENABLED=true in /etc/powos/config)

USB Drive
  Status:     ● Connected
  Last Sync:  30s ago

Unplug Safety
  ⚠ OS PROTECTED, HOME REQUIRES USB
    OS runs from RAM (safe to unplug for OS)
    /home is USB-mounted (enable CacheFS for full unplug resilience)
```

**powos layers:**
```
Layer Stack
════════════════════════════════════════

  Writes → [RAM Upper] → sync → [Custom Layer] → USB

  Lower layers (read-only at runtime):
    ● custom    - Your packages, configs, customizations
                  Size: 2.1G
    ● updates   - OS updates
                  Size: 156M
    ● base      - Bazzite OS image

  RAM Upper (writes since boot):
    Files changed: 47
    Size: 89M
```

