# PowOS

## PowOS fleet integration (2026-10-26)

The operational contract is documented in `PowOS/docs/PLATFORM.md` (relative to `~/Projects`). PowOS is the
owner's cross-device runtime and management layer; PowStation is the shared server deployment, and PowAuth
manages accounts for exposed services. Keep native apps and GPU Quadlets in their existing runtimes.

Use the shared `PowStation/bin/pow-compose` wrapper for Compose operations. From `~/Projects`:

```sh
PowStation/bin/pow-compose fleet --manifest PowOS/config/platform-fleet.json --json
PowStation/bin/pow-compose --project-directory <project-dir> -f <project-dir>/docker-compose.yml check
```

The eight adopted projects declare `x-pow.schema: powos.platform/v1`, service policy in top-level
`x-pow.services`, and one storage declaration per persistent mount in `x-pow.datasets`. Every service carries
`io.powos.unit`; `pow-compose units` exports records and `pow-compose register` installs them through the
existing PowOS unit registry. `powos platform` exposes the same adapter. Compose policy is validated before
starts; direct `docker compose` bypasses this preflight. Preserve project names and existing volumes.

Existing Traefik and autosleep labels remain the enforcement mechanisms. Keep one lifecycle controller per
workload. Games/media stay awake until their activity and wake integrations exist. Never freeze infrastructure,
state stores, active jobs or agent fleets just because CPU is low. Host placement metadata does not migrate data.

Public browser routes use PowAuth (`authelia@docker`, backed by `powauth:latest`). When a route also sleeps,
auth must precede `autosleep@file`. Preserve existing native/API authentication and explicit route exceptions;
never add a blanket bypass. Service accounts do not grant fleet administration. No new public route was added.

Storage classifications do not create quotas or backups. No automatic cleanup or data migration is enabled.
PowCache contains durable media, scenes and backups as well as caches; never clear the whole share. PowStorage
is not approved for Mac mounts/exports. PowCDN publication remains planned: no CDN controller/backend is running
as a result of this integration. Do not advertise draft CDN labels or commands as implemented.

Changes require project `check`, the fleet check, and regeneration of that project's unit files under
`PowOS/units/powstation/`. Existing containers receive label changes on their normal deployment, not by bulk
restarting the infrastructure. Keep boot/runtime/trust/recovery prerequisites local so PowOS can start offline.

Source: `lib/apps/powos-platform`; CLI: `bin/pow-compose` and `powos platform`; adopted fleet:
`config/platform-fleet.json`. The Android deployment stages the adapter and wrapper with the `platform-adapter`
unit; the Containerfile already copies bin/ and lib/. Tests: `test/tier1/test-platform.py`.


PowOS is a layered-persistence Linux distro (Bazzite-based), originally x86-only and now being extended to
phone (Android, OnePlus Open), web and other platforms. This file is a short index: what PowOS is, the rules
every agent must follow regardless of area, and pointers to the full reference. Full detail moved to `docs/`
verbatim (friction f100 — this file used to be ~15k tokens of mostly x86 reference, loaded on every call of
every agent, including phone/web work that never touches it).

## Quick start (x86)

```bash
docker compose up               # test in Docker — KDE desktop at http://localhost:6091/vnc.html (pw: powos)
podman build -t localhost/powos . && ./build/build-iso.sh    # canonical install: build the Anaconda GUI ISO
```

Full CLI reference: `docs/CLI.md`. Full x86 architecture (layers, boot, RAM/CacheFS, Windows dual-boot/VM,
games storage, directory layout, rollback, dev workflow, troubleshooting, Tier1/Tier2 testing, feature
status): `docs/REFERENCE-X86.md`.

## Agents: where the current (phone/multiplatform) work actually lives (f116)

This checkout can be on `master`, behind the integration branch the phone/multiplatform agents actually work
from: `origin/worktree-powos-multiplatform`. `docs/AGENT-HANDBOOK.md`, `tools/agents/*` (friction, the work
board, worktrees, land.sh) and most of the active skills only exist THERE — `git show`-ing one of those paths
from a stale `master` checkout 404s, not because it was deleted. Get your own worktree on that branch with
`tools/agents/worktree.sh new <name>` (the script itself lives on that branch; fetch/run it from there, or use
an existing worktree under `.claude/worktrees/`), then read `docs/AGENT-HANDBOOK.md` for the rest.

## Hard rules (read before working)

## Testing — nothing to remember

`just test` (= `bash test/tier1/run-all.sh`) **auto-discovers** every
`test/tier1/test-*.{sh,py}`. CI runs that same script. Drop a test file in and
it runs. There is no list to update, anywhere.

**`run-all.sh` needs bash 4+** (`declare -A`, `mapfile`) — the Mac's `/bin/bash` is 3.2 (Apple ships the last
GPLv2 release) and has neither, failing with `declare: -A: invalid option` before a single test runs (friction
f84). On the Mac, run it in the container instead: `just test-container` (`docker compose --profile test run
--rm test-runner`) — CI (Ubuntu) and the phone both already have bash 4+, so this only bites on the Mac. Or,
from any worktree, `tools/agents/tier1.sh [test-name...]` — a small cached `powos-tier1:latest` image (not
the full OS image `test-container` builds), mounting the docker socket only for the tests that need it.

**Do not reintroduce a hand-written list of tests.** The old CI enumerated
them, drifted, and ran 10 of 31 suites — which is how `powos sync` shipped
silently running the cloud backup instead of the sync.

Known-flaky/known-broken suites are quarantined **inside `run-all.sh`** with a
written reason. They still run and report, they just don't gate. That list is
debt, not a parking spot.

Invariants that used to be prose rules here are now assertions — if you break
one, a test says so, with the reason, at the point of breakage:

| Invariant | Enforced by |
|---|---|
| No function defined in two libs sourced into the same shell | `test-lib-collisions.sh` |
| Shared constants resolve the same in either source order | `test-lib-collisions.sh` |
| Every verb `powos mods help` documents actually dispatches | `test-mods-core.sh` |
| Every verb an agent needs is discoverable in help | `test-mods-core.sh` |
| Every verb `powos game` documents resolves to a real function | `test-game-facade.sh` |
| One canonical game id across manifest / harness / `powos games` | `test-mods-harness.sh` |
| Every `HACK:` marker in the tree has a row in the HACK registry | `test-hack-registry.sh` |
| Everything a deploy script installs on a host is claimed by a unit in `units/<host>/` | `test-units-registry.py` |

## Workarounds: `HACK:` markers and the registry

Mark every workaround `HACK:` at the spot, with why and the real fix. **Every `HACK:` is also listed in the
registry, `docs/REMOTE-POWOS.md` §4, in the same commit that adds, moves or removes it** (`test-hack-registry.sh`
fails otherwise). Cross-device channels (adb, ssh, root between hosts) and their replacement: `docs/REMOTE-POWOS.md`.

## Host installs: units, and dependencies inside apps/containers

Nothing is installed or left running on a host without a **unit** (`powos units`, `lib/apps/powos-units`): a
manifest with owner, purpose, files/packages/processes, limits and how to remove it. **Prefer dependencies INSIDE an
app or a container** (`backend.container.image`, `powos containers run`) over host installs. A host install needs its
unit in `units/<host>/` in the same commit (`test-units-registry.py` fails a deploy script that installs anything no
unit claims); `powos units check` flags what was installed by hand, `powos units remove <id> --dry-run` shows the way
out. Details: `config/ai/context/capabilities.md` (Units).

## Shared checkouts: commit only your own paths (agents: READ THIS)

Several agents often work in one checkout/worktree at once, sharing ONE git index. A whole-index commit ships
someone else's half-done work under your message (it happened: 05761a3).

- NEVER `git commit -a`, never a bare `git commit` after someone else may have staged, never `git add -A` / `git add .`.
- Commit ONLY your paths: `git commit -m "..." -- <your files>` (pathspec commits ignore other staged entries), or a
  private index: `GIT_INDEX_FILE=$(mktemp) git read-tree HEAD && git add <files> && git commit`.
- Check `git diff --cached --stat` shows only your files before committing.
- Never reset/checkout/stash files you didn't change: others' uncommitted work lives in the same tree.
- `powos self push -m "msg" -- <paths>` commits only those; without paths it refuses when others' changes are staged.

## CI & GitHub API etiquette (agents: READ THIS)

The GitHub REST API allows **5,000 requests/hour shared across every agent and
tool on this account** — it has been exhausted by run-polling before. Rules:

- **NEVER `gh run watch`** — it polls every ~3s (~1,200 req/h per watcher).
- Don't poll `gh run list`/`gh run view` in loops. Check once, then wait
  minutes (ScheduleWakeup or a long sleep), not seconds.
- **"Did the build publish?" doesn't need the REST API at all.** The registry
  API is separate and effectively unmetered:
  ```bash
  skopeo inspect --creds "Powback:$(gh auth token)" \
      docker://ghcr.io/powback/powos:nvidia-open | jq -r '.Digest, .Created'
  ```
  New digest/timestamp = build landed. Prefer this for completion checks.
- Reserve `gh run view --log-failed` for diagnosing a KNOWN failure, not for
  discovering whether one happened.
- `gh api rate_limit` is free (doesn't count) — check it if unsure.

## Docs index

- `docs/CLI.md` — full `powos` CLI command reference (every subcommand, with examples)
- `docs/REFERENCE-X86.md` — x86/Bazzite architecture: layered persistence, boot sequence, kernel args, USB
  layout, directory structure, RAM boot/CacheFS/mobile mode internals, Windows dual-boot/VM/GPU-hotswap, games
  storage, rollback/protection/RAM tables, dev workflow, container notes, troubleshooting, Tier1/Tier2 testing,
  feature status, credentials
- `docs/AGENT-HANDBOOK.md` — agent process: expert routing, efficiency, the work board, friction, retro,
  shipping, reaching the phone (on the integration branch — see above)
- `docs/BUILD-GUIDE.md`, `docs/BOOT-ARCHITECTURE.md`, `docs/WINDOWS.md`, `docs/HIBERNATION.md`,
  `docs/REMOTE-POWOS.md` (the HACK registry, §4) — deep dives referenced above and by the hard rules
- everything else (design specs, feasibility notes, per-feature plans): `ls docs/`
