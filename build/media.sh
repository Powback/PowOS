#!/usr/bin/env bash
# build/media.sh — TIER 2: turn the built image into a bootable raw disk, and
# prove it boots. Only worth running when you actually want media.
#
# Two things here are load-bearing and are NOT speed features:
#
#   1. The raw cache is keyed on the IMAGE ID, but a cache hit is never trusted
#      on the strength of the key alone. The recorded key is a hint that lets us
#      SKIP a 21-minute rebuild; the artifact is then opened and the commit baked
#      inside it is read back and compared to HEAD. A note saying "prepared at X"
#      has already once been true while the raw next to it was a build behind,
#      and the stick shipped. Notes are hints; artifacts are evidence.
#
#   2. The QEMU boot gate is conditional, never silent. An initramfs regenerated
#      without ostree support boots nothing while passing every metadata check
#      there is, and that is what put an unbootable stick in someone's hand. If
#      this script decides not to boot the image, it says so in a box you cannot
#      scroll past, and it names the commit whose gate result it is relying on.
#
# Usage:
#   build/media.sh                    # image, cached raw, gate if needed
#   build/media.sh --gate always      # always boot it
#   build/media.sh --gate never       # refuse to boot it (loudly; records nothing)
#   build/media.sh --force-raw        # rebuild the raw even on a cache hit
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/cycle-lib.sh"
cd "$REPO" || exit 1
POWOS_TIER="media"

VARIANT=deck; GATE=auto; FORCE_RAW=0; SKIP_IMAGE=0
while [[ $# -gt 0 ]]; do case "$1" in
    --variant) VARIANT="$2"; shift 2 ;;
    --gate) GATE="$2"; shift 2 ;;
    --force-raw) FORCE_RAW=1; shift ;;
    --skip-image) SKIP_IMAGE=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) die "unknown option: $1" ;;
esac; done
case "$GATE" in auto|always|never) ;; *) die "--gate must be auto|always|never" ;; esac

TAG="ghcr.io/powback/powos:$VARIANT"
BIB=quay.io/centos-bootc/bootc-image-builder:latest
RAW="$REPO/build/output/powos.raw"
SHA=$(head_commit)
refuse_if_cycle_running

# ── the image, at HEAD, tested ────────────────────────────────────
# Rebuilding an image that is already the right image is the same mistake the
# burn tier was making, one tier up — and here it is worse than wasted time.
#
# A podman image ID changes on EVERY rebuild even when nothing changed: the
# payload layer's tar carries build-time timestamps for the files the fixup RUN
# writes. Since the raw cache is keyed on that ID, an unconditional rebuild
# meant the raw cache could never hit. It didn't, on the first run of this
# script — a 200 s rebuild of a disk image that was already correct.
#
# So: skip the rebuild only when all four of these hold, each read back rather
# than assumed.
stage "image (tier 1)"
rebuild=1
if [[ $SKIP_IMAGE -eq 1 ]]; then
    rebuild=0; say "--skip-image: using whatever $TAG currently is"
elif [[ -f "$CACHE/image-$VARIANT" ]]; then
    IFS=$'\t' read -r r_digest r_commit r_when r_clean r_tested < "$CACHE/image-$VARIANT"
    cur=$(image_digest "$TAG")
    baked=$(image_baked_commit "$TAG")
    why=""
    # An older record has three fields, not five. Checked FIRST and on its own,
    # because falling through to the later branches reads r_clean="" and reports
    # "recorded build was from a dirty tree" — which sends you to look at git
    # instead of at the record.
    if   [[ -z "${r_clean:-}" || -z "${r_tested:-}" ]]; then why="image record predates provenance tracking"
    elif [[ -z "$cur" ]];            then why="no local image $TAG"
    elif [[ "$cur" != "$r_digest" ]];then why="image changed since it was recorded"
    elif [[ "$baked" != "$SHA" ]];   then why="image is stamped ${baked:-none}, HEAD is ${SHA:0:8}"
    elif [[ "$r_clean" != clean ]];  then why="recorded build was from a dirty tree"
    elif [[ "$r_tested" != tested ]];then why="recorded build was not tested"
    elif tree_is_dirty >/dev/null;   then why="working tree is dirty"
    fi
    if [[ -n "$why" ]]; then
        say "$why — rebuilding"
    else
        rebuild=0
        ok "image is already ${SHA:0:8}, built clean and tested at $r_when — not rebuilding"
    fi
fi
[[ $rebuild -eq 1 ]] && { bash build/iterate.sh --variant "$VARIANT" || die "iterate failed"; }
IMG_ID=$(image_digest "$TAG")
[[ -n "$IMG_ID" ]] || die "no local image $TAG — run build/iterate.sh"
built=$(image_baked_commit "$TAG")
[[ "$built" == "$SHA" ]] || die "image $TAG is stamped ${built:-none}, HEAD is ${SHA:0:8}"

# ── offline variant store ─────────────────────────────────────────
# skopeo copy is incremental over a content-addressed layout: blobs already in
# the destination are skipped by digest. Refreshing all three is therefore cheap
# when nothing moved, and skipping the two remote ones is how a medium once
# shipped a four-day-old 'main' that installed an old PowOS on any non-Deck
# machine without saying so.
stage "offline variant store"
S skopeo copy "containers-storage:$TAG" "oci:build/output/variants:$VARIANT" >/dev/null 2>&1 \
    || die "variant store refresh for $VARIANT"
ok "refreshed $VARIANT from the local build"
for v in main nvidia-open; do
    [[ "$v" == "$VARIANT" ]] && continue
    if S skopeo copy "docker://ghcr.io/powback/powos:$v" "oci:build/output/variants:$v" >/dev/null 2>&1; then
        ok "refreshed $v from the registry"
    else
        loud "COULD NOT REFRESH VARIANT '$v'" \
             "The medium will carry whatever copy is already in the store." \
             "On a non-Deck machine that is the PowOS that gets installed."
    fi
done

# ── raw cache ─────────────────────────────────────────────────────
# The key covers everything bootc-image-builder's output is a function of: the
# image it is given and the builder itself. A commit alone is NOT a key — the
# same commit built with a different POWOS_EXTRAS, or on a refreshed base, is a
# different system on the disk.
stage "raw disk image"
BIB_ID=$(image_digest "$BIB")
[[ -n "$BIB_ID" ]] || { S podman pull -q "$BIB" >/dev/null 2>&1; BIB_ID=$(image_digest "$BIB"); }
RAWKEY=$(printf '%s\n%s\nraw btrfs\n' "$IMG_ID" "$BIB_ID" | sha256sum | cut -c1-16)
recorded=$(cut -f1 "$CACHE/raw.key" 2>/dev/null)

reuse=0
if [[ $FORCE_RAW -eq 0 && -f "$RAW" && "$recorded" == "$RAWKEY" ]]; then
    say "recorded key matches ($RAWKEY) — checking the artifact before believing it"
    got=$(bash build/raw-stamp.sh "$RAW" | sed -n 's/^commit=//p')
    if [[ "$got" == "$SHA" ]]; then
        reuse=1; ok "raw cache HIT — baked commit ${got:0:8} confirmed inside the image"
    else
        loud "RAW CACHE KEY MATCHED BUT THE ARTIFACT DISAGREED" \
             "key said this raw was current; the commit baked INSIDE it is" \
             "${got:-none} and HEAD is ${SHA:0:8}. Rebuilding." \
             "This is exactly the check that a 'prepared at <commit>' note" \
             "cannot make, and the reason the note alone is never enough."
    fi
fi

if [[ $reuse -eq 0 ]]; then
    say "building raw (this is the ~21 minute step)"
    rm -f "$CACHE/raw.key"
    rm -rf "build/output/$VARIANT"; mkdir -p "build/output/$VARIANT"
    S podman run --rm --privileged -v "$PWD/build/output/$VARIANT:/output" \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        "$BIB" --type raw --rootfs btrfs --local "$TAG" >/dev/null 2>&1 \
        || die "raw build"
    S chown -R "$(id -un):$(id -gn)" "build/output/$VARIANT"
    src=$(find "build/output/$VARIANT" -name '*.raw' | head -1)
    [[ -n "$src" ]] || die "no raw produced"
    cp --sparse=always "$src" "$RAW" || die "cp raw"
    got=$(bash build/raw-stamp.sh "$RAW" | sed -n 's/^commit=//p')
    [[ "$got" == "$SHA" ]] || die "fresh raw is baked at ${got:0:8}, expected ${SHA:0:8}"
    ok "raw built and verified at ${got:0:8}"
    printf '%s\t%s\t%s\n' "$RAWKEY" "$SHA" "$(date -u +%FT%TZ)" > "$CACHE/raw.key"
fi

# ── static bootability, ALWAYS ────────────────────────────────────
# Cheap, and it is the half of the gate that does not need a running kernel.
# Making the QEMU gate conditional without this would mean a skipped gate leaves
# the artifact completely unexamined.
stage "static boot check"
bash build/raw-bootcheck.sh "$RAW" || die "the raw failed its static boot check"

# ── the QEMU gate ─────────────────────────────────────────────────
# Anything that can change whether the machine boots. Deliberately broad: a unit
# that fails early, a tmpfiles rule that repoints display-manager, a preset that
# enables the wrong thing are all boot bugs, and all of them have happened here.
BOOT_PATHS=(
    Containerfile
    config/dracut.conf.d/ config/systemd-preset/ config/tmpfiles.d/
    systemd/
    bin/powos-initramfs-slim bin/powos-boot bin/powos-boot-entries
    bin/powos-safemode bin/powos-firstboot-apply bin/powos-firstboot-disk
    bin/powos-desktop-entrypoint
    lib/ramboot.sh lib/variants.sh lib/overlay.sh
    build/install-to-usb.sh build/bootc-config.toml
)
gate_rec_key=$(cut -f1 "$CACHE/gate" 2>/dev/null)
gate_rec_commit=$(cut -f2 "$CACHE/gate" 2>/dev/null)
gate_rec_when=$(cut -f3 "$CACHE/gate" 2>/dev/null)
changed=""
[[ -n "$gate_rec_commit" ]] && changed=$(git diff --name-only "$gate_rec_commit"..HEAD -- "${BOOT_PATHS[@]}" 2>/dev/null)
eval "$(bash build/gate-decision.sh --mode "$GATE" --rawkey "$RAWKEY" \
          --gated-key "$gate_rec_key" --gated-commit "$gate_rec_commit" \
          --changed "$changed")"

stage "boot gate"
case "$DECISION" in
  skip-disabled)
    loud "BOOT GATE DELIBERATELY DISABLED (--gate never)" \
         "Nothing has booted this image. The fault this gate exists to catch" \
         "— an initramfs that cannot switch root — passes every other check" \
         "in this pipeline and shipped on a stick once." \
         "" \
         "The static boot check above did run and did pass, which covers the" \
         "known form of that fault but not an unknown one." \
         "" \
         "No gate result is recorded, so the next run will not treat this" \
         "artifact as gated and build/burn.sh will refuse to write it."
    ;;
  skip-same-artifact)
    ok "$WHY (gated at ${gate_rec_when:-?})"
    ;;
  skip-inferred)
    loud "BOOT GATE SKIPPED — THIS IS A DECISION, NOT AN OVERSIGHT" \
         "" \
         "Last passing gate: ${gate_rec_commit:0:8} at ${gate_rec_when:-?}" \
         "Now building:      ${SHA:0:8}" \
         "" \
         "$WHY, so the bootability of this image is being INFERRED from that" \
         "run rather than observed. The boot path is the BOOT_PATHS list in" \
         "build/media.sh — if you changed something that can affect boot and" \
         "it is not in that list, this inference is wrong and the list is the" \
         "bug." \
         "" \
         "Force a real boot with:  build/media.sh --gate always"
    # Carry the ORIGINAL gated commit forward, never HEAD: the gate result
    # belongs to the run that actually booted something. Stamping HEAD here
    # would let a chain of inferences masquerade as a chain of gate passes.
    printf '%s\t%s\t%s\n' "$RAWKEY" "$gate_rec_commit" "$gate_rec_when" > "$CACHE/gate"
    ;;
  run)
    say "running the QEMU boot gate — $WHY"
    bash build/boot-gate.sh "$RAW" || die "boot gate failed — this image does not reach a desktop"
    printf '%s\t%s\t%s\n' "$RAWKEY" "$SHA" "$(date -u +%FT%TZ)" > "$CACHE/gate"
    ok "gate passed and recorded for key $RAWKEY"
    ;;
  *) die "gate-decision returned an unknown decision: ${DECISION:-none}" ;;
esac

timings "media/$VARIANT"
echo
echo "=== MEDIA READY — $VARIANT at ${SHA:0:8}, raw verified, key $RAWKEY ==="
