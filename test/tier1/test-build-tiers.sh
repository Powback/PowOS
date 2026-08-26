#!/usr/bin/env bash
# Behavioural tests for the three build tiers.
#
# These drive the actual decision code with real inputs and read the answer
# back. They do not grep the tier scripts for the presence of a guard, because
# a guard that is present and never reached is exactly the bug this repo keeps
# shipping: TESTS_RC=1 was printed by build-deck-local.sh on every failing test
# run and checked by nobody.
# NO pipefail — deliberately, and for the reason run-all.sh spells out at
# length: these assertions are `... | grep -q ...`, and grep -q exits on its
# first match, which SIGPIPEs the writer and makes the pipeline return 141.
# This test lost an hour to exactly that: "COPY --from=staging is not in the
# payload stage" was reported for a Containerfile that plainly had it, because
# the sed feeding the grep was killed by the successful match.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
check(){ if ( eval "$2" ) >/dev/null 2>&1; then echo "  ok   - $1"; PASS=$((PASS+1));
         else echo "  FAIL - $1"; FAIL=$((FAIL+1)); fi }
GD="bash $ROOT/build/gate-decision.sh"
dec(){ $GD "$@" | sed -n 's/^DECISION=//p'; }

echo "== boot-gate decision =="
# The default must be to RUN. Every branch that skips has to be reached
# deliberately; anything unrecognised falls through to booting the thing.
check "no gate record at all -> run" \
      '[ "$('"$GD"' --mode auto --rawkey K1)" ] && [ "$(bash '"$ROOT"'/build/gate-decision.sh --mode auto --rawkey K1 | sed -n "s/^DECISION=//p")" = run ]'
check "boot-path files changed -> run" \
      '[ "$(bash '"$ROOT"'/build/gate-decision.sh --mode auto --rawkey K1 --gated-key K0 --gated-commit deadbeef --changed "systemd/powos-firstboot.service" | sed -n "s/^DECISION=//p")" = run ]'
check "nothing on the boot path changed -> skip-inferred" \
      '[ "$(bash '"$ROOT"'/build/gate-decision.sh --mode auto --rawkey K1 --gated-key K0 --gated-commit deadbeef --changed "" | sed -n "s/^DECISION=//p")" = skip-inferred ]'
check "the SAME raw was already gated -> skip-same-artifact (not an inference)" \
      '[ "$(bash '"$ROOT"'/build/gate-decision.sh --mode auto --rawkey K1 --gated-key K1 --gated-commit deadbeef --changed "systemd/x.service" | sed -n "s/^DECISION=//p")" = skip-same-artifact ]'
check "--gate always overrides a matching key" \
      '[ "$(bash '"$ROOT"'/build/gate-decision.sh --mode always --rawkey K1 --gated-key K1 --gated-commit deadbeef | sed -n "s/^DECISION=//p")" = run ]'
check "--gate never is a distinct, nameable decision" \
      '[ "$(bash '"$ROOT"'/build/gate-decision.sh --mode never --rawkey K1 --gated-key K1 | sed -n "s/^DECISION=//p")" = skip-disabled ]'
ws=$(bash "$ROOT/build/gate-decision.sh" --mode auto --rawkey K1 --gated-key K0 \
        --gated-commit deadbeef --changed "$(printf ' \n\t ')" | sed -n 's/^DECISION=//p')
if [ "$ws" = skip-inferred ]; then echo "  ok   - whitespace-only change list is not mistaken for a change"; PASS=$((PASS+1));
else echo "  FAIL - whitespace-only change list treated as a change (got $ws)"; FAIL=$((FAIL+1)); fi
check "every skip decision carries a reason a human can read" \
      'for m in "--mode never --rawkey K1" "--mode auto --rawkey K1 --gated-key K1"; do
         bash '"$ROOT"'/build/gate-decision.sh $m | grep -q "^WHY=." || exit 1
       done'

echo
echo "== offline variant store completeness =="
# A manifest is a few hundred bytes and resolves fine while the gigabytes of
# layers it names are absent. `skopeo inspect --raw` cannot tell those apart;
# this must.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkstore(){
    local d="$T/$1"; mkdir -p "$d/blobs/sha256"
    local cfg lay man
    printf '{"architecture":"amd64","os":"linux"}' > "$d/blobs/sha256/cfg"
    printf 'layerbytes-layerbytes' > "$d/blobs/sha256/lay"
    cfg=$(stat -c %s "$d/blobs/sha256/cfg"); lay=$(stat -c %s "$d/blobs/sha256/lay")
    cat > "$d/blobs/sha256/man" <<EOF
{"schemaVersion":2,"config":{"digest":"sha256:cfg","size":$cfg},
 "layers":[{"digest":"sha256:lay","size":$lay}]}
EOF
    man=$(stat -c %s "$d/blobs/sha256/man")
    cat > "$d/index.json" <<EOF
{"schemaVersion":2,"manifests":[{"digest":"sha256:man","size":$man,
 "annotations":{"org.opencontainers.image.ref.name":"deck"}}]}
EOF
    printf '{"imageLayoutVersion":"1.0.0"}' > "$d/oci-layout"
    echo "$d"
}
GOOD=$(mkstore good)
check "a complete store passes" \
      'bash '"$ROOT"'/build/verify-variant-store.sh "'"$GOOD"'" deck'
check "an expected variant that is not in the index fails" \
      '! bash '"$ROOT"'/build/verify-variant-store.sh "'"$GOOD"'" deck main'
MISS=$(mkstore missing); rm -f "$MISS/blobs/sha256/lay"
check "a store missing a LAYER blob fails (skopeo inspect would not notice)" \
      '! bash '"$ROOT"'/build/verify-variant-store.sh "'"$MISS"'" deck'
TRUNC=$(mkstore trunc); printf 'short' > "$TRUNC/blobs/sha256/lay"
check "a store with a TRUNCATED layer blob fails" \
      '! bash '"$ROOT"'/build/verify-variant-store.sh "'"$TRUNC"'" deck'
NOCFG=$(mkstore nocfg); rm -f "$NOCFG/blobs/sha256/cfg"
check "a store missing the CONFIG blob fails" \
      '! bash '"$ROOT"'/build/verify-variant-store.sh "'"$NOCFG"'" deck'

echo
echo "== Containerfile stage split =="
# The speed of the iterate tier rests entirely on the powos-base stage not
# depending on anything PowOS ships. If a COPY of a PowOS file lands in that
# stage, two things break at once and neither is loud: the base cache starts
# missing on every commit, and any step in that stage that reads the copied
# path sees the BASE IMAGE's version of it instead.
#
# Derived from the instruction stream rather than searched for as a phrase.
check "the Containerfile still has both stages" \
      'grep -q "^FROM \${BASE_IMAGE} AS powos-base$" '"$ROOT"'/Containerfile &&
       grep -q "^FROM \${POWOS_BASE}$" '"$ROOT"'/Containerfile'
check "powos-base COPYs nothing from the context but the dracut config" \
      'bad=$(awk "/^FROM .\\\$\\{BASE_IMAGE\\} AS powos-base\$/,/^FROM .\\\$\\{POWOS_BASE\\}\$/" '"$ROOT"'/Containerfile \
              | grep -E "^COPY " | grep -v -- "--from=" | grep -v "config/dracut.conf.d/")
       [ -z "$bad" ]'
if sed -n "/^FROM ..POWOS_BASE.\$/,\$p" "$ROOT/Containerfile" | grep -q "^COPY --from=staging / /$"; then
  echo "  ok   - the payload stage is where the staging tree lands"; PASS=$((PASS+1));
else echo "  FAIL - COPY --from=staging is not in the payload stage"; FAIL=$((FAIL+1)); fi
check "the source snapshot is the LAST copy in the staging stage" \
      'l=$(awk "/^FROM scratch AS staging$/,/^FROM \\\$\{BASE_IMAGE\} AS kde-builder-local\$/" '"$ROOT"'/Containerfile \
            | grep -E "^COPY " | tail -1)
       printf "%s" "$l" | grep -q "^COPY .snapshot/"'
check "the deck initramfs is regenerated before the firmware trim" \
      'i=$(grep -n "dracut --force --no-hostonly" '"$ROOT"'/Containerfile | head -1 | cut -d: -f1)
       f=$(grep -n "firmware trim removed" '"$ROOT"'/Containerfile | head -1 | cut -d: -f1)
       [ -n "$i" ] && [ -n "$f" ] && [ "$i" -lt "$f" ]'

echo
echo "== mutual exclusion =="
# The first version of this guard was `pgrep -f` over other processes' command
# lines, which refused to run because the shell LAUNCHING the tier had the
# script names in its own argv. A guard that fires on a mention rather than an
# execution is worse than no guard: it is a stoppage nobody can explain.
LOCKPROBE='cd "'"$ROOT"'"; . build/cycle-lib.sh; acquire_lock'
check "a shell that merely mentions /var/tmp/boot-gate.sh is not a running cycle" \
      'bash -c "cd \"'"$ROOT"'\"; . build/cycle-lib.sh; refuse_if_cycle_running" \
         </dev/null 2>&1 | grep -q FATAL && exit 1 || exit 0'
check "the lock excludes an UNRELATED process" \
      'bash -c "$LOCKPROBE; env -u POWOS_TIER_LOCK bash -c \"$LOCKPROBE\" >/dev/null 2>&1 && echo GOT || echo REFUSED" \
         2>/dev/null | grep -q REFUSED'
check "a CHILD tier re-enters its parent's lock instead of deadlocking on it" \
      'bash -c "$LOCKPROBE; bash -c \"$LOCKPROBE; echo REENTERED\"" 2>/dev/null | grep -q REENTERED'
check "the lock is released when the holder exits" \
      'bash -c "$LOCKPROBE" >/dev/null 2>&1
       bash -c "$LOCKPROBE" >/dev/null 2>&1'

echo
echo "== tier entry points exist and are self-describing =="
for s in iterate media burn boot-gate raw-stamp raw-bootcheck gate-decision verify-variant-store; do
    check "build/$s.sh is executable and parses" \
          '[ -x '"$ROOT"'/build/'"$s"'.sh ] && bash -n '"$ROOT"'/build/'"$s"'.sh'
done

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
