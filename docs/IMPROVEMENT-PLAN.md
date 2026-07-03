# PowOS Improvement Plan

Based on architecture review with Gemini AI. Prioritized by impact and complexity.

## Phase 1: Quick Wins (Naming & Safety) ✅ COMPLETED

### 1.1 Rename Commands for Clarity ✅
- [x] Rename `powos state` → `powos backup`
  - [x] Update `lib/sync.sh` - rename `cmd_sync` to `cmd_remote`
  - [x] Update `bin/powos` - change dispatch from `state` to `remote`
  - [x] Update usage docs in `bin/powos`
  - [x] Update `CLAUDE.md` documentation
- [x] Rename internal commands:
  - [x] `powos backup status` - show remote sync status
  - [x] `powos backup push` - push to git remote
  - [x] `powos backup pull` - pull from git remote
  - [x] `powos backup setup` - configure remote
- [x] Keep `powos sync` for RAM→USB (it's clear enough)

### 1.2 Add Lock File Safety ✅
- [x] Create lock mechanism in `lib/sync.sh`
  - [x] `sync_lock_acquire()` - create `/run/powos/sync.lock`
  - [x] `sync_lock_release()` - remove lock file
  - [x] `sync_lock_check_stale()` - check if lock exists (stale)
- [x] Add lock to critical operations:
  - [x] `powos backup push`
  - [x] `powos backup pull`
- [x] Check for stale lock on boot
  - [x] Add to `systemd/powos-init`
  - [x] Warn user if previous sync was interrupted
  - [x] Offer recovery options

### 1.3 Update Documentation ✅
- [x] Update `CLAUDE.md` with new command names
- [x] Add troubleshooting section for interrupted syncs

## Phase 2: Git Safety (Staging & Validation)

### 2.1 Staged Git Pulls
- [ ] Create staging directory: `/var/lib/powos/.git-staging/`
- [ ] Modify `sync_pull()` in `lib/sync.sh`:
  - [ ] Clone/pull to staging first
  - [ ] Validate staged changes (syntax check configs)
  - [ ] Only apply if validation passes
  - [ ] Keep backup of previous state
- [ ] Add rollback command:
  - [ ] `powos backup rollback` - restore previous state

### 2.2 Conflict Detection
- [ ] Before pull, check for uncommitted local changes
- [ ] Before pull, check for diverged branches
- [ ] Provide clear options:
  - [ ] `--merge` - try to merge (default)
  - [ ] `--theirs` - discard local, use remote
  - [ ] `--stash` - stash local, pull, re-apply
- [ ] Add `powos backup conflicts` to show pending conflicts

### 2.3 Git Repo Health Check
- [ ] Add `powos backup doctor` command:
  - [ ] Check `.git` integrity
  - [ ] Check for uncommitted changes
  - [ ] Check for untracked files
  - [ ] Check remote connectivity
  - [ ] Suggest fixes

## Phase 3: Performance Optimization

### 3.1 Lazy Commits for pinstall
- [ ] Change `pinstall` behavior:
  - [ ] Record package to `containers/distrobox.ini` immediately
  - [ ] Queue git commit (don't block)
  - [ ] Batch commits on timer (every 5 min) or on `powos sync`
- [ ] Add `POWOS_PINSTALL_COMMIT_MODE` config:
  - [ ] `immediate` - current behavior (default for safety)
  - [ ] `batched` - queue and batch
  - [ ] `manual` - never auto-commit

### 3.2 Incremental RAM→USB Sync
- [ ] Ensure `powos sync` uses rsync with:
  - [ ] `--checksum` or `--times` for change detection
  - [ ] `--delete` for removed files
  - [ ] `--partial` for resumable transfers
- [ ] Add progress indicator for large syncs
- [ ] Add `--dry-run` option to preview changes

## Phase 4: Binary File Handling

### 4.1 Improve .gitignore
- [ ] Add comprehensive exclusions:
  ```
  # Large/binary files
  *.iso
  *.img
  *.vmdk
  *.qcow2
  node_modules/
  __pycache__/
  .cache/

  # Browser profiles (large, constantly changing)
  .mozilla/
  .config/chromium/
  .config/google-chrome/

  # Build artifacts
  target/
  dist/
  build/
  ```

### 4.2 Hybrid Sync Option (Future)
- [ ] Research Syncthing integration for heavy directories
- [ ] Consider separate sync mechanism for `~/Documents`, etc.
- [ ] Add config option: `POWOS_SYNC_HEAVY_DIRS=syncthing`

## Phase 5: Filesystem Safety

### 5.1 Recommend btrfs
- [ ] Update `build/install-to-usb.sh`:
  - [ ] Default to btrfs for data partition
  - [ ] Enable compression (zstd)
  - [ ] Document benefits (CoW, snapshots)
- [ ] Add btrfs snapshot before risky operations:
  - [ ] `powos backup pull` - snapshot before
  - [ ] `powos update` - snapshot before

### 5.2 Atomic Sync Operations
- [ ] For `powos sync` (RAM→USB):
  - [ ] Write to temp directory first
  - [ ] Rename/move atomically
  - [ ] Or use rsync's default temp-file behavior
- [ ] For git operations:
  - [ ] Already somewhat atomic, but add verification

## Phase 6: UX Improvements

### 6.1 First-Run Setup Wizard
- [ ] On first boot, prompt user:
  - [ ] "Set up remote backup? (recommended)"
  - [ ] Guide through SSH key setup
  - [ ] Guide through `powos backup setup`
- [ ] Add `powos setup` command for guided setup

### 6.2 Status Dashboard
- [ ] Improve `powos status` to show:
  - [ ] Remote sync status (ahead/behind)
  - [ ] Last sync time
  - [ ] Pending local changes
  - [ ] Disk usage on USB

### 6.3 Notifications
- [ ] Warn on shutdown if unsynced changes exist
- [ ] Warn if remote is significantly behind
- [ ] Desktop notification for sync failures

## Phase 7: Testing

### 7.1 Add Integration Tests
- [ ] Test interrupted sync recovery
- [ ] Test conflict resolution paths
- [ ] Test multi-machine sync scenario
- [ ] Test USB unplug during operations

### 7.2 Add Stress Tests
- [ ] Large file sync performance
- [ ] Many small files sync performance
- [ ] Git repo with 1000+ commits

## Implementation Order

```
Week 1: Phase 1 (Quick Wins)
├── 1.1 Rename commands
├── 1.2 Lock file safety
└── 1.3 Documentation

Week 2: Phase 2 (Git Safety)
├── 2.1 Staged pulls
├── 2.2 Conflict detection
└── 2.3 Health check

Week 3: Phase 3 + 4 (Performance)
├── 3.1 Lazy commits
├── 3.2 Incremental sync
└── 4.1 Gitignore improvements

Week 4: Phase 5 + 6 (Polish)
├── 5.1 btrfs recommendations
├── 6.1 Setup wizard
└── 6.2 Status dashboard

Ongoing: Phase 7 (Testing)
```

## Success Metrics

- [ ] Zero data loss from interrupted syncs
- [ ] < 2 second overhead for pinstall
- [ ] Clear error messages for all failure modes
- [ ] User can recover from any error state
- [ ] Documentation covers all edge cases

## Questions to Resolve

1. Should `powos backup` require explicit setup, or auto-init local git?
2. Should we support multiple remotes (backup + collaboration)?
3. Should AI sessions sync by default or stay local?
4. How to handle secrets that accidentally get committed?

---

## Current Status

**Started**: 2024-12-14
**Last Updated**: 2024-12-14

### Completed
- [x] Initial sync system (`lib/sync.sh`)
- [x] State commands (`powos state` → renamed to `powos backup`)
- [x] Machine branch support
- [x] Export/import functionality
- [x] Test suite (32 tests)
- [x] Architecture documentation
- [x] **Phase 1: Quick Wins** - Command renaming, lock file safety, documentation

### In Progress
- [ ] Phase 2: Git Safety (Staging & Validation)

### Blocked
- None

### Notes
- Gemini review completed, feedback incorporated into this plan
- All existing tests passing (113/114)
- Phase 1 completed: `powos state` renamed to `powos backup`, lock file safety added
