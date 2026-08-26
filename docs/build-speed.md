# Build speed: the three tiers, and where the time actually goes

The edit→verify loop was ~35 minutes. It is now **38 seconds**. Most of that
did not come from making anything faster — it came from finding out that the
build was priced per `podman commit`, and that nobody had ever measured one.

Every number here was measured on this box on 2026-08-26, warm cache, with a
one-line edit to a file under `bin/`. Numbers without a measurement behind them
are marked as such.

## The tiers

| | entry point | what it does | measured |
|---|---|---|---|
| **iterate** | `build/iterate.sh` | image + in-image tier-1 tests | **38 s** |
| **media** | `build/media.sh` | + offline variant store, raw disk, static boot check, conditional QEMU gate | **390 s** cold / **35 s** fully cached |
| **burn** | `build/burn.sh` | + write the stick and verify 16 things about it | ~75 s (see below) |

Most changes need only `iterate`. `media` is for when you want media; `burn` is
for when you want it on a stick.

```
build/iterate.sh                  # the loop
build/media.sh                    # when you want a disk image
build/media.sh --gate always      # when you want it booted no matter what
build/burn.sh                     # when you want it on the stick
```

## Before and after

| step | before | after | how |
|---|---|---|---|
| image + tests | **378 s** | **38 s** | base/payload stage split, one commit |
| variant store refresh | ~27 s | ~27 s | unchanged; skopeo is already incremental |
| raw disk image | 200 s | 200 s cold, **~10 s cached** | cache keyed on image ID, re-verified from inside the artifact |
| QEMU boot gate | 117 s, always | 117 s, **conditional and loud** | `build/gate-decision.sh` |
| burn | **434 s** | ~75 s | stopped rebuilding the image it had just built |

Two full `media.sh` runs, measured end to end:

```
cold (image rebuilt, raw rebuilt, gate run)     fully cached
  39 s  image (tier 1)                            1 s  image — not rebuilt
  27 s  offline variant store                    26 s  offline variant store
 201 s  raw disk image                            2 s  raw — cache hit, re-verified
   5 s  static boot check                         6 s  static boot check
 118 s  boot gate  (PASS: reaches sddm)           0 s  gate — same artifact
 390 s  TOTAL                                    35 s  TOTAL
```

The 26 s variant-store refresh is the largest remaining item in a cached run
and is genuine work: `skopeo copy` re-checks three OCI layouts against the
registry. Skipping it is how a medium once shipped a four-day-old `main` that
installed an old PowOS on any non-Deck machine without saying so.

The burn figure is **projected, not measured** — the target enclosure was
unplugged before it could be exercised, and `build/burn.sh` refused to run on a
device whose serial it could not read, which is the guard working. Its parts are
measured: 48 s of write from the real cycle below, ~15 s of artifact verification
timed directly, ~10 s of checks.

The brief that started this work estimated the image build at ~2 min and the raw
at ~21 min. Measured, they were 6m18s and 3m20s. Both estimates were wrong in
opposite directions, which is the entire argument for measuring first.

## The finding that mattered: commits, not layers

The obvious suspect was the layer count — 141 in the deck image, built with
`--layers`. It is not the layer count.

```
mount the 141-layer image and run a command      0.43 s
podman commit one layer onto it                 27.1 s   <-- regardless of content
podman commit one layer onto fedora:41           1.6 s
```

Twenty-seven seconds to commit a layer containing **nothing**. Four no-op `RUN`s:

```
--layers        111.6 s   (4 commits)
--layers=false   28.5 s   (1 commit)
```

The build is priced per commit. Not per instruction, not per byte written.

### Why a commit costs 27 s

```
$ podman info | grep -iE 'native overlay|metacopy|mountopt'
    overlay.mountopt: nodev,metacopy=on
    Native Overlay Diff: "false"
    Using metacopy: "true"
```

`metacopy=on` makes containers/storage fall back to the **naive diff**, which
computes a layer by walking the entire merged tree — ~11 GB here — on every
single commit. Confirmed by construction, on a throwaway graphroot:

```
$ podman --root /tmp/probe --storage-opt overlay.mountopt=nodev,metacopy=on info
    Native Overlay Diff: "false"
$ podman --root /tmp/probe --storage-opt overlay.mountopt=nodev info
    Native Overlay Diff: "true"
```

So there are two independent levers. This work pulled the first one.

## Lever 1 (pulled): commit once per edit

The Containerfile is split at `FROM ${POWOS_BASE}`:

* **`powos-base`** — everything that depends only on the base image: the dnf5
  stack, tmux plugins, the deck initramfs regeneration, and the icon/extras/
  brew/locale/firmware/doc trims. Built with `--layers`, tagged
  `localhost/powos-base:<variant>-<key>` where the key is a hash of the base
  image ID, the *text of that stage*, and the dracut config. Rebuilt only when
  one of those moves.
* **the payload stage** — `COPY --from=staging`, the KDE artifacts, and the
  fixup layer. Built with **`--layers=false`**, so it commits exactly once.

Turning caching off for the payload costs nothing: every instruction in it is
invalidated by every commit anyway, so there was never a cache hit to lose.

Post-invalidation commits per edit: **16 → 1**.

The reorder is **size-neutral**, measured in the built image rather than assumed:
`/usr/share/{doc,man,help}` are still absent, icons 165M, locale 7.5M, firmware
203M with no `nvidia/`, 27 wallpapers kept — every figure identical to
`docs/image-size.md`. The one thing worth checking was the doc/man trim now
running *before* the KDE artifacts land; the KDE builder ships no man pages, so
nothing survives that used to be removed.

Three supporting moves, each small:

* `.snapshot/` (a `git archive HEAD` extraction, different every commit) was the
  **third** of fifty-one COPYs in the staging stage, so it invalidated the
  forty-eight after it. It is now last.
* The build context was 490 MB, of which `extensions/` (355 MB) and `bazzite/`
  (128 MB) are read by no `COPY` in the Containerfile. Both are now in
  `.dockerignore`. Podman tars and hashes the context before the first
  instruction, so that was paid on every build including fully cached ones.
* `build/vendor-bazzite.sh` did a `git fetch` against GitHub on every build to
  populate a directory nothing copies. `iterate.sh` skips it — and greps the
  Containerfile for a `COPY bazzite/` so the day that stops being true, the
  build says so instead of silently missing files.

The deck initramfs regeneration moved into `powos-base`. It is the single most
expensive step in the file (a full dracut run, and in its old form **five**
separate `lsinitrd` invocations each decompressing a ~100 MB image to grep it —
now one). Its inputs are the base image and one dracut config; sitting after the
payload COPY meant a comment fix re-ran it. Its relative order is unchanged: it
still runs **before** the firmware trim, because dracut may pull firmware in.

## Lever 2 (NOT pulled): turn metacopy off

Worth ~27 s → ~1 s per commit, on every commit, in every tier. It was left alone
on purpose.

Overlay layers that were copied-up **with** metacopy are metadata-only files
carrying a `trusted.overlay.metacopy` xattr. Mounting them with `metacopy=off`
is not a supported transition; the kernel's behaviour with existing metacopy
upper files is undefined and the plausible outcome is files that read as empty.
That is a silent-wrong-content failure in an OS image — the worst class of bug
this repo has.

Doing it safely means a **fresh graphroot** and re-pulling the base images.
That is a deliberate, human-timed migration, not something a build script should
do to a store another process is using. It is written down here so it is a
decision someone makes, not a discovery someone re-makes.

## The raw cache, and why the note is never trusted

`build/media.sh` keys the raw on `sha256(image ID + bootc-image-builder ID)`.
The commit alone is **not** a key: the same commit built with a different
`POWOS_EXTRAS`, or on a refreshed base, is a different system on the disk.

A matching key never authorises reuse by itself. On a key hit the artifact is
loop-mounted and the commit baked into its ostree deployment is read back
(`build/raw-stamp.sh`) and compared to HEAD. Only both together are a hit.

This is not belt-and-braces. A `prepare` that rebuilt the image but not the raw
once wrote a "prepared at `<commit>`" note that was perfectly true, next to a raw
that was a build behind, and the stick shipped with every check reporting
success. **Notes are hints. Artifacts are evidence.** If the key and the artifact
ever disagree, `media.sh` says so in a box and rebuilds.

## The boot gate is conditional, never silent

The gate exists because an initramfs regenerated without ostree support boots
nothing while passing every metadata check there is — smaller image, matching
commit, all boot entries present — and that shipped on a stick.

The decision is a pure function in its own file, `build/gate-decision.sh`,
because it is the one part of the pipeline whose failure mode is silence.
`test/tier1/test-build-tiers.sh` drives every branch.

| situation | decision |
|---|---|
| `--gate always` | run |
| `--gate never` | `skip-disabled`, loud, **records nothing** |
| this exact raw already gated (key match) | `skip-same-artifact` — same bytes, not an inference |
| no gate result on record | run |
| a `BOOT_PATHS` file changed since the gated commit | run |
| otherwise | `skip-inferred`, **loud** |

Anything unrecognised runs the gate. `BOOT_PATHS` lives in `build/media.sh` and
is deliberately broad — a unit that fails early, a tmpfiles rule that repoints
`display-manager`, a preset that enables the wrong thing are all boot bugs and
all have happened here.

A skipped gate carries the **original** gated commit forward, never HEAD. Otherwise
a chain of inferences would launder itself into a chain of gate passes.

And a skip is never a completely unexamined artifact: `build/raw-bootcheck.sh`
runs on every fresh raw, always, in about 5 seconds. It loop-mounts the disk and
asserts every boot entry's kernel and initrd exist and are non-empty, that every
entry carries an `ostree=` argument, that there is exactly one deployment, and
that the initramfs contains `ostree-prepare-root`. That last line is the
regression that shipped, checked against the artifact rather than the build log.

## What the burn was actually doing

Reconstructed from log mtimes and the journal for the 15:49→15:58 cycle:

```
15:51:37 → 15:57:55   rebuild the image                    378 s
15:57:57 → 15:58:45   dd + partitions + variants + BLS      48 s
15:58:45 → 15:58:53   fifteen verification checks            8 s
```

**Eighty-seven percent of the burn was rebuilding an image `prepare.sh` had
built and verified eight minutes earlier.** That rebuild was not thoughtless: an
earlier version grepped a build log that turned out to be stale, called a failed
build a success, and wrote the old image to the stick. Rebuilding into a fresh
log fixed it.

It was still the wrong fix, because it answers the question indirectly. What is
wanted is "the bytes about to be written correspond to a verified build at HEAD",
and that is now established by interrogating the artifacts: the image is run and
its `.powos-src-commit` read out of it, the raw is loop-mounted and its baked
commit read back, the static boot check passes, and a gate result exists for that
exact raw key. Each is strictly stronger than a fresh log saying DONE, and
together they cost about 15 seconds.

Two things about the write itself, both measured, both against expectation:

* `dd` of the 28 GB raw takes **16.3 s at 1.8 GB/s**. The device is an NVMe
  behind a USB bridge, not a flash stick. There is nothing to optimise here.
* Copying the 33 GB offline variant store is inside the 48 s. It looked like the
  obvious target — an incremental rsync exploiting the content-addressed blob
  names, plus preserving `POWOS-DATA` across the `dd` by saving and restoring the
  tail partition entries with `sfdisk`. **That work was designed and then not
  done**, because measuring it first showed the whole write is 48 seconds. It
  would have been a substantial change to the most safety-critical script in the
  repo to save perhaps 20 s of a tier you run rarely.

## What is deliberately still slow

| | cost | why it stays |
|---|---|---|
| the QEMU boot gate | 117 s | it is the only thing that boots the image. It is skipped by rule, never made cheaper |
| the raw build, cold | 200 s | bootc-image-builder; cached on image ID, so it runs when the image really changed |
| `powos-base` rebuild | ~4½ min | dnf5, dracut, ~700 `localedef` deletions. Amortised across every commit that does not touch the base |
| the KDE builder | ~30 min | content-addressed on `sources/kde`; only ever built when those inputs move |
| writing the stick | 48 s | real device I/O of real bytes |
| one commit per iterate | 27 s | this is lever 2 above, and it is 71% of the 38 s |

## Traps

* **Do not put a `COPY` of a PowOS file into the `powos-base` stage.** Two things
  break at once and neither is loud: the base cache starts missing on every
  commit, and any step in that stage reading the copied path sees the *base
  image's* version. `test/tier1/test-build-tiers.sh` asserts this from the
  instruction stream.
* **Do not add `pipefail` to a test in this repo.** `... | grep -q ...` SIGPIPEs
  the writer on the first match and the pipeline returns 141. `run-all.sh`
  documents this at length; this file's own test lost time to it anyway, reporting
  "COPY --from=staging is not in the payload stage" for a Containerfile that
  plainly had it.
* **`eval "$(...)"` needs `%q`.** `build/gate-decision.sh` emitted
  `WHY=no boot-path file changed`, which assigned `WHY=no` and then tried to run
  `boot-path`. A correct gate decision surfaced three lines later as
  `WHY: unbound variable`.
* **`build-deck-local.sh` printed `TESTS_RC=1` and nothing checked it.** A red
  in-image test suite has been shipping. `build/iterate.sh` treats a test failure
  as fatal.
* **A dirty working tree produces an image nobody can rebuild.** `bin/`, `lib/`,
  `config/` and `systemd/` are copied from the build *context*, so uncommitted
  edits are in the image while `.powos-src-commit` still says HEAD. `iterate.sh`
  warns; `burn.sh` refuses without `--allow-dirty`.
