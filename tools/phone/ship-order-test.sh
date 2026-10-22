#!/bin/bash
# Hermetic test of ship-apk.sh's install order and push.sh's phone-is-newer check: a throwaway repo (this tree's
# ship-apk.sh + shell/push.sh, stubs for the gate, the build, idle, bindings, docker and adb) and a fake phone (a
# folder as the app's data dir). Nothing reaches the real phone, docker or ~/.cache.
#   tools/phone/ship-order-test.sh        exit 0 = all pass
set -uo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/ship-order-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
export HOME=$T/home PHONE=$T/phone LOG=$T/log GIT_CONFIG_GLOBAL=$T/gitconfig
mkdir -p "$HOME/.cache" "$PHONE/files/shell" "$PHONE/tmp" "$T/bin"
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main
ts() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
export -f ts
# --- stubs on PATH: docker (install, the overrides pull, push.sh's re-exec) and adb (the fake phone) ---
cat > "$T/bin/adb" <<'EOF'
#!/bin/bash
case "$1" in
  connect|-s) exit 0 ;;
  push) shift; [ "$1" = -q ] && shift; cp "$1" "${2/\/data\/local\/tmp/$PHONE/tmp}"; exit ;;
  shell|exec-out) shift; c="$*" ;;
  *) exit 0 ;;
esac
case "$c" in *powos-run.sh*) exit 0 ;; "run-as com.powos.app true") exit 0 ;; esac
c=${c//\/data\/local\/tmp/$PHONE/tmp}; c=${c/run-as com.powos.app /}
case "$c" in *"mv -f shell-staging"*) echo "PUSH $(ts)" >> "$LOG" ;; esac
cd "$PHONE" && sh -c "$c"
EOF
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
all="$*"
vol() { local want=$1 prev=""; shift; for a in "$@"; do [ "$prev" = -v ] && [ "${a##*:}" = "$want" ] && echo "${a%:*}"; prev=$a; done; }
case "$all" in
  *install-app.sh*) echo "INSTALL $(ts)" >> "$LOG"; exit 0 ;;
  *SCHEMAS=*) ov=$(vol /ov "$@"); cp -R "$PHONE/files/shell" "$ov/"; cat "$PHONE/files/shell-commits.txt" > "$ov/commits.txt" 2>/dev/null; exit 0 ;;
  *POWOS_GATE_DONE=1*)
    sh=$(vol /shell "$@"); pc=""; prev=""; rest=(); seen=""
    for a in "$@"; do
      [ -n "$seen" ] && rest+=("$a")
      [ "$prev" = -e ] && case "$a" in POWOS_PUSH_COMMITS=*) pc=${a#POWOS_PUSH_COMMITS=} ;; esac
      [ "$a" = _ ] && seen=1; prev=$a
    done
    cd "$sh" && POWOS_GATE_DONE=1 POWOS_PUSH_COMMITS="$pc" exec bash push.sh "${rest[@]}" ;;
esac
exit 0
EOF
chmod +x "$T/bin/"*; export PATH="$T/bin:$PATH"
# --- the repo: origin (bare), the shipper's clone A, another agent's clone B ---
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null; cd "$T/seed"; git checkout -q -b worktree-powos-multiplatform
mkdir -p tools/phone shell/dev shell/ui targets/android
cp "$src/tools/phone/ship-apk.sh" tools/phone/; cp "$src/shell/push.sh" shell/
cat > shell/dev/gate.sh <<'EOF'
#!/bin/bash
# fake gate: logs, takes GATE_SLEEP seconds (a loaded Mac), fails on a file containing BROKEN
echo "GATE $(ts) $*" >> "$LOG"; sleep "${GATE_SLEEP:-0}"
for f in "$@"; do case "$f" in --*) ;; *) grep -q BROKEN "$f" 2>/dev/null && { echo "FAIL home: $f broken"; exit 1; } ;; esac; done
echo "ok all pages"
EOF
cat > targets/android/build-app.sh <<'EOF'
#!/bin/bash
# fake build: meanwhile another agent lands a shell commit on origin (the 23:09 case)
echo "BUILD $(ts)" >> "$LOG"; [ -n "${DURING_BUILD:-}" ] && bash -c "$DURING_BUILD" >/dev/null 2>&1; echo "BUILD SUCCESSFUL"
EOF
printf '#!/bin/bash\necho "screen=Asleep"\n' > tools/phone/idle.sh
printf '#!/bin/bash\n[ "${1:-}" = --remote-cmd ] && echo true; exit 0\n' > tools/phone/bindings-check.sh
printf '#!/bin/bash\necho "12-31 00:00:00"\n' > tools/phone/adb.sh
echo 'export const ai = "old"' > shell/ui/ai.tsx; echo 'export const x = 1' > shell/ui/other.tsx
chmod +x shell/dev/gate.sh shell/push.sh targets/android/*.sh tools/phone/*.sh
git add -A; git commit -qm base; git push -q origin worktree-powos-multiplatform 2>/dev/null
git clone -q -b worktree-powos-multiplatform "$T/origin.git" "$T/A" 2>/dev/null
git clone -q -b worktree-powos-multiplatform "$T/origin.git" "$T/B" 2>/dev/null
landB() { (cd "$T/B" && git pull -q --rebase 2>/dev/null; echo "$1" > shell/ui/ai.tsx && git commit -qam "$2" && git push -q origin HEAD:worktree-powos-multiplatform 2>/dev/null; git rev-parse HEAD); }
fails=0
ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fails=$((fails+1)); }
ship() { (cd "$T/A" && git pull -q --ff-only 2>/dev/null; SHIP_APK_CURRENT=1 bash tools/phone/ship-apk.sh --silent --now) > "$T/ship.out" 2>&1; }

# 1. A commit lands during the build: gated before the install, pushed right after it without a second gate.
: > "$LOG"
export GATE_SLEEP=2 DURING_BUILD="cd $T/B && echo 'export const ai = \"new\"' > shell/ui/ai.tsx && git commit -qam newer && git push -q origin HEAD:worktree-powos-multiplatform"
ship; rc=$?
i=$(grep -n '^INSTALL' "$LOG" | cut -d: -f1); p=$(grep -n '^PUSH' "$LOG" | tail -1 | cut -d: -f1)
pg=$(grep -n '^GATE .* ui/ai.tsx' "$LOG" | head -1 | cut -d: -f1)
[ $rc -eq 0 ] && [ -n "$i" ] && [ -n "$pg" ] && [ "$pg" -lt "$i" ] && ok "pre-gate ran before the install" || { bad "pre-gate before install (rc $rc)"; cat "$LOG" "$T/ship.out"; }
[ -z "$(sed -n "$((i+1)),\$p" "$LOG" | grep '^GATE')" ] && ok "no gate between install and re-push" || { bad "a gate ran after the install"; cat "$LOG"; }
gap=$(awk '/^INSTALL/{i=$2} /^PUSH/{p=$2} END{printf "%.1f", p-i}' "$LOG")
awk -v g="$gap" 'BEGIN{exit !(g < 2)}' && ok "old-shell window ${gap}s (gate takes ${GATE_SLEEP}s)" || bad "old-shell window ${gap}s"
grep -q '"new"' "$PHONE/files/shell/ui/ai.tsx" 2>/dev/null && ok "phone has origin's newer ai.tsx" || bad "newer ai.tsx not on the phone"
grep -q "^ui/ai.tsx $(cd "$T/B" && git rev-parse HEAD)$" "$PHONE/files/shell-commits.txt" 2>/dev/null && ok "phone records ai.tsx's commit" || { bad "commit record"; cat "$PHONE/files/shell-commits.txt"; }

# 2. The newer set doesn't load: no install, and why.
: > "$LOG"; rm -f "$HOME/.cache/powos-installed-commit"; export GATE_SLEEP=0
export DURING_BUILD="cd $T/B && git pull -q --rebase && echo BROKEN > shell/ui/ai.tsx && git commit -qam broken && git push -q origin HEAD:worktree-powos-multiplatform"
ship; rc=$?
[ $rc -eq 3 ] && ! grep -q '^INSTALL' "$LOG" && grep -q "REFUSED - not installing" "$T/ship.out" && ok "failed pre-gate refuses the install" || { bad "failed pre-gate (rc $rc)"; cat "$LOG" "$T/ship.out"; }
unset DURING_BUILD
landB 'export const ai = "fixed"' fix >/dev/null

# 3. The phone's copy is from a commit the pusher's base lacks.
(cd "$T/A" && git pull -q --ff-only 2>/dev/null); base=$(cd "$T/A" && git rev-parse HEAD)
C=$(landB 'export const ai = "C"' C)
(cd "$T/B/shell" && ./push.sh --vpn --silent ui/ai.tsx) >/dev/null 2>&1   # B pushes C's ai.tsx
D=$(landB 'export const ai = "fixed"' "revert C")   # origin's ai.tsx is A's again: the origin check alone passes A
out=$(cd "$T/A/shell" && ./push.sh --vpn --silent ui/ai.tsx 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "ui/ai.tsx on the phone is from ${C:0:9} (newer than your base): rebase first" && ok "older base refused" || { bad "older base not refused (rc $rc)"; echo "$out"; }
grep -q '"C"' "$PHONE/files/shell/ui/ai.tsx" && ok "phone kept the newer copy" || bad "phone's copy overwritten"
out=$(cd "$T/A/shell" && ./push.sh --vpn --silent --force ui/ai.tsx 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "pushing anyway (--force)" && ok "--force pushes anyway" || { bad "--force (rc $rc)"; echo "$out"; }
(cd "$T/B/shell" && ./push.sh --vpn --silent ui/ai.tsx) >/dev/null 2>&1   # record: D (B's HEAD has it)
(cd "$T/A" && git pull -q --ff-only 2>/dev/null)
out=$(cd "$T/A/shell" && ./push.sh --vpn --silent ui/ai.tsx 2>&1); rc=$?
[ $rc -eq 0 ] && ok "rebased base pushes" || { bad "rebased push refused (rc $rc)"; echo "$out"; }

# 4. A stamp is only for exactly its file set and tree.
st=$(cd "$T/A/shell" && ./push.sh --pre-gate ui/ai.tsx 2>&1 | sed -n 's/^pre-gated //p')
out=$(cd "$T/A/shell" && ./push.sh --vpn --pre-gated="$st" --silent ui/ai.tsx ui/other.tsx 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "isn't a gate result for exactly these files" && ok "stamp for another file set refused" || { bad "stamp mismatch (rc $rc)"; echo "$out"; }
: > "$LOG"
out=$(cd "$T/A/shell" && ./push.sh --vpn --pre-gated="$st" --silent ui/ai.tsx 2>&1); rc=$?
[ $rc -eq 0 ] && ! grep -q '^GATE' "$LOG" && ok "matching stamp pushes ungated" || { bad "matching stamp (rc $rc)"; echo "$out"; }
[ $fails -eq 0 ] && echo "all pass" || echo "$fails failed"
exit $fails
