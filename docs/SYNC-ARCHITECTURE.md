# PowOS Sync Architecture

## The Problem

After building PowOS to ISO, burning to USB, and booting on a machine, we have:

```
┌─────────────────────────────────────────────────────────────────┐
│                    USB Boot Environment                          │
├─────────────────────────────────────────────────────────────────┤
│  Local State (in RAM or persistent partition)                    │
│  ├── /var/lib/powos/sources/     User's overlay sources         │
│  ├── /var/lib/powos/projects/    User's dev projects            │
│  ├── /var/lib/powos/containers/  Distrobox definitions          │
│  ├── /var/lib/powos/git/         Local git state repo           │
│  └── /var/lib/powos/extensions/  Built overlays                 │
│                                                                  │
│  System Code (read-only from ISO)                                │
│  ├── /usr/lib/powos/            Core scripts                    │
│  ├── /etc/powos/                System config                   │
│  └── /usr/bin/powos             Main binary                     │
└─────────────────────────────────────────────────────────────────┘
```

**Key Questions:**

1. When user runs `pinstall neovim`, where does that state persist?
2. How does user sync state to a remote (for backup/multi-machine)?
3. How does user get upstream PowOS updates?
4. What happens if USB dies? Can state be recovered?

## Edge Cases Analysis

### Case 1: Fresh USB Boot (No Remote)

```
User boots USB → powos-hydrate runs → No POWOS_GIT_REPO configured
                                       ↓
                               Local git init
                                       ↓
                       User makes changes (pinstall, dev new)
                                       ↓
                           Committed to LOCAL git only
                                       ↓
                      ⚠️ USB dies = ALL STATE LOST
```

**Risk**: High. No backup.
**Mitigation**: Prompt user to configure remote or auto-backup to cloud.

### Case 2: Configured Remote, Single Machine

```
User configures: POWOS_GIT_REPO=github.com/user/powos-state

Boot → powos-hydrate → Clone/pull from remote
                           ↓
         User makes changes (pinstall neovim)
                           ↓
              Committed to LOCAL git
                           ↓
              ⚠️ NOT automatically pushed!
                           ↓
         User must run: powos sync push (MISSING!)
```

**Gap**: No `powos sync push` command exists.

### Case 3: Multiple Machines, Same Remote

```
Machine A: pinstall neovim → commit → (no push)
Machine B: pinstall tmux → commit → (no push)

Machine A pushes first → remote has neovim
Machine B tries to push → CONFLICT!

Options:
  a) Merge (both changes preserved)
  b) Rebase (B's changes on top of A's)
  c) Force push (dangerous, loses A's changes)
  d) Machine-specific branches
```

**Solution**: Branch strategy per machine with shared base.

### Case 4: Upstream System Updates

```
PowOS v1.0 → User deploys to USB
                   ↓
PowOS v1.1 released (lib/ai/agent.sh updated)
                   ↓
User has their own changes in /var/lib/powos/
                   ↓
        How do they get v1.1?
```

**Key Insight**: Separate concerns:
- **System repo** = PowOS upstream (lib/, bin/, systemd/)
- **State repo** = User's config (sources/, projects/, containers/)

ISO build bakes system code in. User state lives in separate repo.

### Case 5: Project Development Workflow

```
User creates: powos dev new myapp
                   ↓
         /var/lib/powos/projects/myapp/
                   ↓
         Development, testing, iteration
                   ↓
         Committed to state repo
                   ↓
         Push to remote for backup
```

**This works IF sync push exists.**

### Case 6: AI Sessions and State

```
User runs: powos ai -i --session myproject
                   ↓
         /var/lib/powos/state/ai/sessions/
                   ↓
         Conversation history saved
                   ↓
         Should this sync to remote?

Options:
  a) Yes, sync sessions (privacy concern)
  b) No, local only (lost on USB death)
  c) Optional, user configures
```

**Recommendation**: Sessions are local-only by default, user can opt-in.

## Architecture Design

### Two-Repo Strategy

```
┌─────────────────────────────────────────────────────────────────┐
│  UPSTREAM: github.com/powos/powos (or your fork)                │
│  ├── lib/           System scripts                              │
│  ├── bin/           Commands                                    │
│  ├── systemd/       Services                                    │
│  ├── config/        Templates                                   │
│  └── Containerfile  OS definition                               │
│                                                                  │
│  Release cycle: Build ISO from this repo                        │
│  Updates: User rebuilds/upgrades ISO                            │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  USER STATE: github.com/user/powos-state                        │
│  ├── sources/       Custom overlay sources                      │
│  ├── projects/      Development projects                        │
│  ├── containers/    distrobox.ini                               │
│  ├── config/        User configuration                          │
│  └── machines/      Machine-specific state (optional)           │
│      ├── desktop-a/                                             │
│      └── laptop-b/                                              │
│                                                                  │
│  Sync cycle: Push/pull on every boot and on-demand              │
└─────────────────────────────────────────────────────────────────┘
```

### Branch Strategy for Multi-Machine

```
main (shared base)
├── packages list (from pinstall)
├── common config
└── shared projects

machine/desktop-a
├── inherits from main
├── machine-specific config
└── desktop-specific packages

machine/laptop-b
├── inherits from main
├── laptop-specific config
└── laptop-specific packages
```

**Sync flow:**
1. Pull main
2. Rebase machine branch onto main
3. Make changes
4. Push machine branch
5. Optionally merge to main for sharing

### Sync Commands Needed

```bash
# Status - see what's changed
powos sync status
# Output: 3 local commits, 2 remote commits, diverged from main

# Push - send changes to remote
powos sync push
# Options: --force, --branch=<name>

# Pull - get changes from remote
powos sync pull
# Options: --merge, --rebase, --theirs, --ours

# Setup - configure remote
powos sync setup <remote-url>
# Creates ~/.config/powos/sync.conf
# Sets POWOS_GIT_REPO

# Export - create tarball backup
powos sync export
# Creates powos-state-YYYY-MM-DD.tar.gz

# Import - restore from tarball
powos sync import <tarball>

# Machine - manage machine-specific branch
powos sync machine init   # Create branch for this machine
powos sync machine share  # Merge current to main
powos sync machine pull   # Pull shared changes from main
```

### Auto-Sync Triggers

```
┌──────────────────────────────────────────────────────────────┐
│  Trigger               │  Action                             │
├──────────────────────────────────────────────────────────────┤
│  Boot (hydration)      │  Pull from remote                   │
│  pinstall              │  Commit + (optional) push           │
│  powos dev new         │  Commit                             │
│  powos dev build       │  Commit                             │
│  Shutdown              │  Push if auto-sync enabled          │
│  Timer (hourly)        │  Push if configured                 │
└──────────────────────────────────────────────────────────────┘
```

## Configuration

### /etc/powos/sync.conf

```bash
# Remote repository for user state
POWOS_SYNC_REMOTE="git@github.com:user/powos-state.git"

# Branch strategy: single, machine, or manual
POWOS_SYNC_STRATEGY="machine"

# Auto-push on changes
POWOS_SYNC_AUTO_PUSH=false

# Auto-pull on boot
POWOS_SYNC_AUTO_PULL=true

# What to sync
POWOS_SYNC_SOURCES=true
POWOS_SYNC_PROJECTS=true
POWOS_SYNC_CONTAINERS=true
POWOS_SYNC_CONFIG=true
POWOS_SYNC_SESSIONS=false  # AI sessions, privacy-sensitive

# Machine identifier (auto-detected from hostname if empty)
POWOS_MACHINE_ID=""
```

## Implementation Files

```
lib/
├── sync.sh           # Main sync library
│   ├── sync_status()
│   ├── sync_push()
│   ├── sync_pull()
│   ├── sync_setup()
│   ├── sync_export()
│   └── sync_import()
└── machine.sh        # Machine management
    ├── machine_init()
    ├── machine_id()
    └── machine_branch()

config/
└── sync.conf.template

bin/
└── powos sync        # CLI command (add to powos dispatcher)

systemd/
├── powos-sync-pull.service   # Pull on boot
└── powos-sync-push.timer     # Optional periodic push
```

## Conflict Resolution

When local and remote diverge:

```
┌─────────────────────────────────────────────────────────────────┐
│  Scenario                    │  Default Action                  │
├─────────────────────────────────────────────────────────────────┤
│  Local ahead, remote same    │  Push                            │
│  Remote ahead, local same    │  Pull (fast-forward)             │
│  Both have changes           │  Prompt user OR auto-merge       │
│  Merge conflict              │  Keep both, manual resolve later │
│  Binary files differ         │  Keep local, backup remote       │
└─────────────────────────────────────────────────────────────────┘
```

### Auto-Merge Strategy

For most PowOS state files, we can auto-merge:

- `distrobox.ini` - Append packages, dedup
- `sources/` - Keep both versions
- `projects/` - Keep both, rename on conflict
- `config/` - 3-way merge, prefer local

## Security Considerations

1. **SSH keys** - User must have SSH key for git push
2. **Secrets** - Never sync `.env` files, API keys
3. **Sessions** - AI conversation history may contain sensitive data
4. **.gitignore** - Must exclude:
   ```
   **/.env
   **/secrets/
   state/ai/sessions/  # Unless opted in
   *.key
   *.pem
   ```

## Recovery Scenarios

### USB Dies - Has Remote

```bash
# New USB, fresh PowOS
# Configure sync
powos sync setup git@github.com:user/powos-state.git

# Hydrate from remote
powos-hydrate

# All state restored!
```

### USB Dies - No Remote (data loss)

```
⚠️ State is gone. This is why we prompt for remote setup.
```

### Machine-Specific Config Lost

```bash
# If machine branch existed on remote
powos sync machine init
git checkout machine/$(hostname)
# Machine config restored
```

## Summary

**Current state:**
- ✅ `powos-hydrate` pulls from remote
- ❌ No push mechanism
- ❌ No multi-machine support
- ❌ No conflict resolution
- ❌ No sync status command

**To implement:**
1. `lib/sync.sh` - Core sync functions
2. `powos sync` CLI - User-facing commands
3. `config/sync.conf.template` - Configuration
4. Update `pinstall` to optionally auto-push
5. Machine branch management
6. Systemd services for auto-sync
