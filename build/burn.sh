#!/usr/bin/env bash
# build/burn.sh — TIER 3: write the verified raw to the stick and prove what
# landed there.
#
# WHAT THIS DELIBERATELY DOES NOT DO ANY MORE
#
# The script this replaces (/var/tmp/burn-prepared.sh) began by REBUILDING THE
# WHOLE IMAGE — about two minutes — immediately after prepare.sh had built and
# verified that same image. That was not thoughtless: an earlier version grepped
# a build log that turned out to be STALE, reported success for a failed build,
# and the stick went out carrying the old image. Rebuilding into a fresh log was
# the fix, and it worked.
#
# It is still the wrong fix, because it answers the question indirectly. The
# guarantee wanted is "the bytes about to be written correspond to a verified
# build at HEAD". That is now established by interrogating the artifacts:
#
#   * the tagged image is RUN and `/usr/lib/powos/.powos-src-commit` read out of
#     it — the image says what it is, no log involved
#   * the raw is loop-mounted and the commit baked into its ostree deployment is
#     read back and compared to HEAD (build/raw-stamp.sh)
#   * the raw passes the static boot check
#   * a boot-gate result is on record for this exact raw
#
# Every one of those is strictly stronger than "a fresh log said DONE", and none
# of them costs two minutes. The redundant work is gone; the guarantee is not.
#
# The fifteen post-write checks are unchanged in what they assert. They are
# consolidated into fewer privileged round trips, and joined by a sixteenth that
# is new: the offline variant store is checked for COMPLETENESS rather than mere
# presence (build/verify-variant-store.sh).
#
# Usage:
#   build/burn.sh                    # write /dev/sda after checking everything
#   build/burn.sh --device /dev/sdX --serial XXXX
#   build/burn.sh --verify-only      # run the post-write checks, write nothing
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/cycle-lib.sh"
cd "$REPO" || exit 1
POWOS_TIER="burn"

DEV=/dev/sda; EXPECT_SERIAL=AAAABBBB0007; VARIANT=deck
VERIFY_ONLY=0; ALLOW_DIRTY=0; ALLOW_UNGATED=0
while [[ $# -gt 0 ]]; do case "$1" in
    --device) DEV="$2"; shift 2 ;;
    --serial) EXPECT_SERIAL="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --allow-ungated) ALLOW_UNGATED=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) die "unknown option: $1" ;;
esac; done

TAG="ghcr.io/powback/powos:$VARIANT"
RAW="$REPO/build/output/powos.raw"
SHA=$(head_commit)
refuse_if_cycle_running

# ── the device is the one we think it is ──────────────────────────
stage "target device"
got=$(lsblk -dno SERIAL "$DEV" 2>/dev/null | tr -d ' ')
[[ "$got" == "$EXPECT_SERIAL" ]] || die "$DEV serial '$got' != '$EXPECT_SERIAL' — refusing to write"
ok "$DEV serial $got"

if [[ $VERIFY_ONLY -eq 0 ]]; then
    # ── the tree is reproducible ──────────────────────────────────
    # bin/ lib/ config/ systemd/ are COPYed from the working tree, so an
    # uncommitted edit is IN the image while .powos-src-commit still says HEAD.
    # A stick nobody can rebuild is a stick nobody can debug.
    if dirt=$(tree_is_dirty); then
        if [[ $ALLOW_DIRTY -eq 1 ]]; then
            loud "WRITING FROM A DIRTY TREE (--allow-dirty)" \
                 "The stick will be stamped ${SHA:0:8} and will NOT match it." \
                 "$(printf '%s' "$dirt" | head -4 | tr '\n' ' ')"
        else
            die "uncommitted changes in the build context — the stick would be stamped
${SHA:0:8} without matching it. Commit them, or pass --allow-dirty:
$dirt"
        fi
    fi

    # ── the artifacts say what they are ───────────────────────────
    stage "verify artifacts (no rebuild)"
    built=$(image_baked_commit "$TAG")
    [[ "$built" == "$SHA" ]] \
        || die "image $TAG is stamped ${built:-none}, HEAD is ${SHA:0:8} — run build/media.sh"
    ok "image is stamped ${built:0:8} (read out of the image, not a log)"

    [[ -f "$RAW" ]] || die "no raw at $RAW — run build/media.sh"
    unset commit live_marker containers_fstab
    eval "$(bash build/raw-stamp.sh "$RAW")"
    [[ "${commit:-}" == "$SHA" ]] \
        || die "powos.raw is baked at ${commit:0:8}, HEAD is ${SHA:0:8} — run build/media.sh"
    ok "raw is baked at ${commit:0:8} (read out of the ostree deployment inside it)"

    bash build/raw-bootcheck.sh "$RAW" || die "the raw failed its static boot check"

    rawkey=$(cut -f1 "$CACHE/raw.key" 2>/dev/null)
    gatekey=$(cut -f1 "$CACHE/gate" 2>/dev/null)
    gatewhen=$(cut -f3 "$CACHE/gate" 2>/dev/null)
    if [[ -n "$rawkey" && "$rawkey" == "$gatekey" ]]; then
        ok "a boot gate passed for this exact raw at $gatewhen"
    elif [[ $ALLOW_UNGATED -eq 1 ]]; then
        loud "WRITING A RAW WITH NO GATE RESULT (--allow-ungated)" \
             "raw key ${rawkey:-none}; last gated key ${gatekey:-none}." \
             "Nothing has booted these bytes."
    else
        die "no boot-gate result on record for this raw (key ${rawkey:-none} vs gated ${gatekey:-none}).
Run build/media.sh, or pass --allow-ungated if you accept that."
    fi

    # ── the store is complete ─────────────────────────────────────
    stage "verify offline variant store (source side)"
    bash build/verify-variant-store.sh build/output/variants deck main nvidia-open \
        || die "the variant store is incomplete — the medium would carry a half-copied variant"

    # ── write ─────────────────────────────────────────────────────
    stage "write"
    S umount "$DEV"?* 2>/dev/null
    printf 'YES\n' | S env POWOS_OVERRIDE_REMOVABLE=1 \
        ./build/install-to-usb.sh --with-variants build/output/variants "$DEV" \
        > /var/tmp/burn-write.log 2>&1
    rc=$?
    [[ $rc -eq 0 ]] || { tail -15 /var/tmp/burn-write.log; die "write failed (rc=$rc)"; }
    sync; S partprobe "$DEV"; sleep 3
    ok "written"
fi

# ── the fifteen checks, plus one ──────────────────────────────────
# Same assertions as burn-prepared.sh. What changed is the plumbing: one
# privileged shell doing three mounts, instead of forty separate `sudo -S`
# invocations each paying a PAM round trip. Nothing here was dropped, and
# nothing was made cheaper by asking a weaker question.
stage "verify the stick"
RESULT=$(S bash -s -- "$DEV" <<'CHECKS'
set -u
DEV="$1"; P=0; F=0
ok(){  echo "  ok   - $1"; P=$((P+1)); }
bad(){ echo "  FAIL - $1"; F=$((F+1)); }
M=$(mktemp -d)

B=$(lsblk -nro NAME,LABEL "$DEV" | awk '$2=="boot"{print "/dev/"$1}')
if [ -n "$B" ] && mount -o ro "$B" "$M" 2>/dev/null; then
  E="$M/loader/entries"
  for e in powos-install powos-safe powos-aidebug; do
    [ -f "$E/$e.conf" ] && ok "entry: $e" || bad "entry missing: $e"
  done
  # Capture first: under pipefail, grep -q exiting early kills the producers and
  # returns 141, which this negative check would read as 'no serial console' —
  # a silent PASS for the exact thing it exists to catch.
  _opts=$(grep -h '^options' $E/*.conf 2>/dev/null | tr ' ' '\n')
  if grep -q '^console=ttyS' <<< "$_opts"; then
    bad "serial console still present"
  else ok "no serial console on any entry"; fi
  n=$(grep -lc 'plymouth.enable=0' $E/*.conf 2>/dev/null | wc -l)
  t=$(ls $E/*.conf 2>/dev/null | wc -l)
  [ "$n" = "$t" ] && ok "plymouth disabled on all $t entries (boot stays visible)" \
                  || bad "plymouth.enable=0 on only $n of $t"
  tmo=$(grep -m1 '^set timeout=' "$M/grub2/grub.cfg" 2>/dev/null | cut -d= -f2 | tr -d ' ')
  [ "$tmo" = "10" ] && ok "menu timeout ${tmo}s" || bad "timeout=$tmo"
  umount "$M"
else bad "mount boot partition"; fi

R=$(lsblk -nro NAME,LABEL "$DEV" | awk '$2=="root"{print "/dev/"$1}')
if [ -n "$R" ] && mount -o ro "$R" "$M" 2>/dev/null; then
  d=$(ls -d $M/root/ostree/deploy/*/deploy/*.[0-9] 2>/dev/null | wc -l)
  [ "$d" = "1" ] && ok "exactly one deployment (no self-redeploy)" \
                 || bad "$d deployments on a fresh stick"
  if ls -l $M/root/ostree/deploy/*/deploy/*.0/etc/systemd/system/bazzite-hardware-setup.service 2>/dev/null | grep -q '/dev/null'; then
    ok "bazzite-hardware-setup masked on the medium"
  else bad "hardware-setup NOT masked — stick will redeploy itself"; fi
  umount "$M"
else bad "mount root partition"; fi

D=$(lsblk -nro NAME,LABEL "$DEV" | awk '$2=="POWOS-DATA"{print "/dev/"$1}')
if [ -n "$D" ] && mount -o ro "$D" "$M" 2>/dev/null; then
  tags=$(python3 -c '
import json,sys
t=[(m.get("annotations") or {}).get("org.opencontainers.image.ref.name")
   for m in json.load(open(sys.argv[1]))["manifests"]]
print(",".join(x for x in t if x))' "$M/@powos/variants/index.json" 2>/dev/null)
  case "$tags" in
    *deck*) case "$tags" in *main*) case "$tags" in *nvidia-open*)
        ok "offline store: $tags" ;; *) bad "store: $tags" ;; esac ;; *) bad "store: $tags" ;; esac ;;
    *) bad "store: $tags" ;;
  esac
  # Every variant must be CURRENT and COMPLETE, not merely named in the index.
  # Only 'deck' is built locally; a stale or half-copied main installs an old
  # PowOS on any non-Deck machine without saying so.
  for v in main nvidia-open deck; do
    skopeo inspect --raw "oci:$M/@powos/variants:$v" >/dev/null 2>&1 \
      && ok "variant $v is in the store" || bad "variant $v missing from the store"
  done
  echo "STORE_DIR=$M/@powos/variants"
  umount "$M"
fi
rmdir "$M" 2>/dev/null
echo "COUNT $P $F"
CHECKS
)
echo "$RESULT" | grep -vE '^(COUNT|STORE_DIR)'
P=$(echo "$RESULT" | awk '/^COUNT/{print $2}'); F=$(echo "$RESULT" | awk '/^COUNT/{print $3}')

# The stick itself, not the artifacts it was supposed to come from.
#
# The unset is load-bearing: raw-stamp was already eval'd above for the RAW. If
# this one fails to mount or read, its variables simply do not get reassigned,
# and every check below would silently re-examine the raw's values and pass.
unset commit live_marker containers_fstab
eval "$(bash build/raw-stamp.sh "$DEV")"
[[ -n "${commit:-}" ]] || { echo "  FAIL - could not read a stamp from $DEV at all"; }
if [[ "${commit:-}" == "$SHA" ]]; then echo "  ok   - stick is baked at ${SHA:0:8}"; P=$((P+1))
else echo "  FAIL - stick is baked at ${commit:0:8}, HEAD is ${SHA:0:8}"; F=$((F+1)); fi
if [[ "${live_marker:-}" == yes ]]; then echo "  ok   - live-medium marker present"; P=$((P+1))
else echo "  FAIL - live-medium marker MISSING (boot entries will not refresh)"; F=$((F+1)); fi
if [[ "${containers_fstab:-}" == yes ]]; then echo "  ok   - container storage mounts from POWOS-DATA"; P=$((P+1))
else echo "  FAIL - no /var/lib/containers fstab entry (install will run out of space)"; F=$((F+1)); fi

# NEW, and the reason it is here: `skopeo inspect --raw` reads a manifest and
# stops. A manifest resolves perfectly while the gigabytes of layers it names
# are half-written. On a stick that is the difference between an offline install
# and a failed one.
stage "verify the store ON THE STICK is complete"
SD=$(S mktemp -d)
DP=$(S lsblk -nro NAME,LABEL "$DEV" | awk '$2=="POWOS-DATA"{print "/dev/"$1}')
if [[ -n "$DP" ]] && S mount -o ro "$DP" "$SD" 2>/dev/null; then
    if bash build/verify-variant-store.sh "$SD/@powos/variants" deck main nvidia-open; then
        echo "  ok   - every blob of every variant is present on the stick"; P=$((P+1))
    else
        echo "  FAIL - the variant store on the stick is incomplete"; F=$((F+1))
    fi
    S umount "$SD"
else
    echo "  FAIL - could not mount POWOS-DATA to verify the store"; F=$((F+1))
fi
S rmdir "$SD" 2>/dev/null

echo
echo "== $P passed, $F failed =="
timings "burn"
[[ ${F:-1} -eq 0 ]] && echo "=== STICK READY at ${SHA:0:8} ===" \
                    || { echo "=== FAILURES ==="; exit 1; }
