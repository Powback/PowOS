#!/usr/bin/env bash
# build/iterate.sh — TIER 1: build the image and prove it, nothing else.
#
# This is the edit->verify loop. No raw disk image, no QEMU, no USB. It ends
# with a container image at HEAD whose in-image tests have passed, which is the
# only thing most changes need.
#
# It replaces /var/tmp/build-deck-local.sh. Same base image, same build args,
# same test list, same verification that the built image is stamped at HEAD.
# What it does not do is redo work whose inputs have not moved:
#
#   * `.snapshot/` is `git archive HEAD` — deterministic per commit, so it is
#     re-extracted only when HEAD changes.
#   * The KDE builder is looked for in the LOCAL image store before the network.
#     The old script ran `gh auth token | podman login ghcr.io` and then
#     `podman pull` on every build, including builds where the image was already
#     sitting in local storage.
#   * build/vendor-bazzite.sh does a `git fetch` against GitHub every run to
#     populate a directory that no COPY in the Containerfile reads any more.
#     Skipped — with a grep that fails the build loudly if that ever stops
#     being true, because "the vendor step is dead" is exactly the kind of fact
#     that quietly stops holding.
#
# Usage:
#   build/iterate.sh                 # deck variant, with tests
#   build/iterate.sh --variant main
#   build/iterate.sh --no-tests      # build only (media.sh uses this internally)
#   build/iterate.sh --allow-dirty   # do not warn about uncommitted context edits
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/cycle-lib.sh"
cd "$REPO" || exit 1
export PATH="$HOME/.local/bin:$PATH"

VARIANT=deck; RUN_TESTS=1; ALLOW_DIRTY=0
while [[ $# -gt 0 ]]; do case "$1" in
    --variant) VARIANT="$2"; shift 2 ;;
    --no-tests) RUN_TESTS=0; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) die "unknown option: $1" ;;
esac; done

case "$VARIANT" in
    deck)        BASE=ghcr.io/ublue-os/bazzite-deck:stable ;;
    main)        BASE=ghcr.io/ublue-os/bazzite:stable ;;
    nvidia-open) BASE=ghcr.io/ublue-os/bazzite-nvidia-open:stable ;;
    *) die "unknown variant: $VARIANT (deck|main|nvidia-open)" ;;
esac
TAG="ghcr.io/powback/powos:$VARIANT"
SHA=$(head_commit)

POWOS_TIER="iterate/$VARIANT"
refuse_if_cycle_running
echo "=== iterate: $VARIANT at ${SHA:0:8} ==="

# ── dirty tree ────────────────────────────────────────────────────
# bin/ lib/ config/ systemd/ are COPYed from the build CONTEXT, so uncommitted
# edits DO land in the image — while /usr/lib/powos/.powos-src-commit still says
# HEAD, because that comes from `git archive HEAD`. The image is then stamped
# with a commit that cannot reproduce it. Fine to iterate on; burn.sh refuses.
DIRTY=clean
if dirt=$(tree_is_dirty); then DIRTY=dirty; fi
if [[ $ALLOW_DIRTY -eq 0 && "$DIRTY" == dirty ]]; then
    loud "UNCOMMITTED CHANGES IN THE BUILD CONTEXT" \
         "" \
         "These files are copied into the image, but .powos-src-commit will" \
         "still read ${SHA:0:8}. The image will not be reproducible from that" \
         "commit. build/burn.sh will refuse to write a stick from it." \
         "" \
         "$(printf '%s' "$dirt" | head -6 | tr '\n' ' ')"
fi

# ── vendored bazzite tree ─────────────────────────────────────────
stage "vendor check"
if grep -qE '^\s*COPY\s+(--[^ ]+\s+)*bazzite/' Containerfile; then
    say "Containerfile COPYs bazzite/ — vendoring (network)"
    ./build/vendor-bazzite.sh 2>&1 | tail -2 || die "vendor-bazzite"
else
    ok "no COPY reads bazzite/ — skipping the vendor fetch"
fi

# ── source snapshot ───────────────────────────────────────────────
stage "source snapshot"
if [[ -f .snapshot/.commit ]] && [[ "$(cat .snapshot/.commit)" == "$SHA" ]]; then
    ok "snapshot already at ${SHA:0:8}"
else
    rm -rf .snapshot && mkdir -p .snapshot
    git archive HEAD | tar -x -C .snapshot || die "git archive"
    printf '%s\n' "$SHA" > .snapshot/.commit
    ok "extracted ${SHA:0:8}"
fi

# ── KDE builder ───────────────────────────────────────────────────
# Content-addressed on sources/kde. Compiling plasma-desktop is ~30 min and its
# inputs change maybe monthly, so this must never be rebuilt speculatively.
stage "resolve KDE builder"
KEY=$( { echo "$BASE"; find sources/kde -type f ! -path '*/upstream/*' -print0 \
         | sort -z | xargs -0 sha256sum; } | sha256sum | cut -c1-16 )
KDEREF="ghcr.io/powback/powos-kde:$VARIANT-$KEY"
say "key=$KEY"
if S podman image exists "$KDEREF" 2>/dev/null; then
    ok "KDE builder cache HIT (local store — no registry round trip)"
elif { gh auth token 2>/dev/null | S podman login ghcr.io -u Powback --password-stdin >/dev/null 2>&1
       S podman pull -q "$KDEREF" >/dev/null 2>&1; }; then
    ok "KDE builder cache HIT (pulled)"
else
    loud "KDE BUILDER CACHE MISS — building plasma-desktop from source" \
         "This is a ~30 minute step. It happens when sources/kde changed or" \
         "the base image moved. ref: $KDEREF"
    S podman build --target kde-builder-local --build-arg BASE_IMAGE="$BASE" \
        -f Containerfile -t "$KDEREF" . || die "kde builder build"
fi

# ── the base prefix (cached across commits) ───────────────────────
# Everything in the Containerfile that depends only on the base image lives in
# the `powos-base` stage. It is built ONCE per (base image, base-stage text,
# dracut config) and tagged by a hash of exactly those three things, so an edit
# to a shell script cannot invalidate it and an edit to the base stage cannot
# fail to.
#
# The key is derived from the STAGE TEXT, not the whole Containerfile: hashing
# the file would rebuild six minutes of dnf5/dracut/localedef every time someone
# fixed a comment in the payload half.
stage "resolve base prefix"
S podman image exists "$BASE" 2>/dev/null || S podman pull -q "$BASE" >/dev/null 2>&1 \
    || die "cannot obtain base image $BASE"
BASE_ID=$(image_digest "$BASE")
BASE_SECTION=$(awk '/^FROM \$\{BASE_IMAGE\} AS powos-base$/,/^FROM \$\{POWOS_BASE\}$/' Containerfile)
[[ -n "$BASE_SECTION" ]] || die "cannot locate the powos-base stage in Containerfile"
BASEKEY=$( { printf '%s\n%s\n' "$BASE_ID" "$BASE_SECTION"
             cat config/dracut.conf.d/95-powos-deck-slim.conf 2>/dev/null; } \
           | sha256sum | cut -c1-16 )
BASEREF="localhost/powos-base:$VARIANT-$BASEKEY"
if S podman image exists "$BASEREF" 2>/dev/null; then
    ok "base prefix cache HIT ($BASEKEY)"
else
    loud "BASE PREFIX CACHE MISS — rebuilding the base-only layers" \
         "Base image, base-stage instructions or the dracut config changed." \
         "This is the slow path (dnf5, dracut, ~700 localedef deletions) and" \
         "costs several minutes. Every commit after this one reuses it." \
         "ref: $BASEREF"
    S podman build --layers --target powos-base \
        --build-arg BASE_IMAGE="$BASE" \
        -f Containerfile -t "$BASEREF" . || die "base prefix build"
fi

# ── the payload (one commit) ──────────────────────────────────────
# --layers=false ON PURPOSE, and it is the single largest speedup here.
#
# `podman commit` costs ~27s on this image no matter what the layer contains,
# because overlay.mountopt sets metacopy=on, which turns off native overlay diff
# and falls back to walking the whole ~11 GB tree. With --layers the payload
# half committed sixteen times per edit; without it, once. Nothing is lost:
# every instruction in the payload stage is invalidated by every commit anyway,
# so there was never a cache hit to give up.
stage "podman build (payload)"
S podman build --layers=false \
    --build-arg BASE_IMAGE="$BASE" \
    --build-arg KDE_BUILDER="$KDEREF" \
    --build-arg POWOS_BASE="$BASEREF" \
    --build-arg POWOS_SRC_COMMIT="$SHA" \
    -f Containerfile -t "$TAG" -t "localhost/powos-ci-$VARIANT" . \
    || die "image build"

# ── the image says what it is ─────────────────────────────────────
# Read out of the image. The version of this check that grepped the build log
# reported success for a failed build, and the stick went out with the old
# image; prepare.sh has carried the artifact-reading form ever since.
stage "verify stamp"
built=$(image_baked_commit "$TAG")
[[ "$built" == "$SHA" ]] || die "built image is stamped ${built:-none}, HEAD is ${SHA:0:8}"
ok "image is stamped ${built:0:8}"

# ── in-image tests ────────────────────────────────────────────────
if [[ $RUN_TESTS -eq 1 ]]; then
    stage "in-image tier1 tests"
    S podman run --rm -v "$PWD:/powos:rw" -e POWOS_ROOT=/powos \
        --entrypoint /bin/bash "localhost/powos-ci-$VARIANT" -c '
        set -e
        for t in test-hardware-detect test-pinstall test-overlay test-sync \
                 test-ai-agent test-firstboot-offline test-image-invariants; do
            bash "/powos/test/tier1/$t.sh"
        done' 2>&1 | grep -aE '✗|FAIL|Results:'
    rc=${PIPESTATUS[0]}
    [[ $rc -eq 0 ]] || die "in-image tests failed (rc=$rc)"
    ok "in-image tests passed"
fi

# ── record, for media.sh's raw cache ──────────────────────────────
# A HINT, not a permission slip. media.sh compares it, and then still re-reads
# the commit baked inside the raw before trusting it.
# A HINT, and a precise one. media.sh uses it to decide whether rebuilding is
# redundant, so it has to record everything that makes an image trustworthy:
# which digest, which commit, whether the tree was clean when it was built (a
# dirty build is stamped with a commit it does not match), and whether the
# in-image tests actually ran and passed for THIS digest.
#
# This matters more than it looks: a podman image ID changes on every rebuild
# even when nothing changed, because the fixup layer writes files with
# build-time timestamps. Without this record, media.sh would rebuild, get a new
# digest, and miss the raw cache every single time — which is exactly what it
# did on its first run.
DIGEST=$(image_digest "$TAG")
[[ $RUN_TESTS -eq 1 ]] && TESTED=tested || TESTED=untested
printf '%s\t%s\t%s\t%s\t%s\n' "$DIGEST" "$SHA" "$(date -u +%FT%TZ)" "$DIRTY" "$TESTED" \
    > "$CACHE/image-$VARIANT"
say "image id ${DIGEST#sha256:}" | cut -c1-60

timings "iterate/$VARIANT"
echo
echo "=== ITERATE OK — $VARIANT at ${SHA:0:8} built and tested ==="
