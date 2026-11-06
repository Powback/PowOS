#!/usr/bin/env bash
# perf-scenarios.sh shade-scroll seeds its own test notifications (the phone's shade had 2, too few to scroll) and
# removes them again. Hermetic: the ss_seed / ss_unseed block is cut out of the script and run with stubbed sh_ /
# hcall (a fake notification list holding two of the user's own notifications, one of them also com.android.shell).
# Asserts: SS_N posts, each a messaging-style (own row) with a powos-ss-<i> tag; the clean-up dismisses exactly
# those keys and never the user's; the EXIT trap carries the clean-up while seeded and is handed back after.
set -u
here=$(cd "$(dirname "$0")" && pwd)
S=$here/../../tools/phone/verify/perf-scenarios.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

sed -n '/^SS_N=/,/^sc_shade_scroll() {/p' "$S" | sed '$d' >"$tmp/block.sh"
grep -q '^ss_seed()' "$tmp/block.sh" && grep -q '^ss_unseed()' "$tmp/block.sh" || fail "no ss_seed/ss_unseed block in perf-scenarios.sh"

cat >"$tmp/run.sh" <<'EOF'
LIST=$TMPD/list; POSTS=$TMPD/posts; DISMISSED=$TMPD/dismissed
printf '%s\n' '0|com.whatsapp|1|null|10200' '0|com.android.shell|7|user-own|2000' >"$LIST"
: >"$POSTS"; : >"$DISMISSED"
sleep() { :; }
log() { echo "LOG $*"; }
note() { echo "NOTE $*"; }
e2e_abort() { :; }
sh_() {
  echo "$*" >>"$POSTS"
  local tag; tag=$(sed -nE 's/.* (powos-ss-[0-9]+) .*/\1/p' <<<"$*")
  [ -n "$tag" ] && echo "0|com.android.shell|${tag#powos-ss-}|$tag|2000" >>"$LIST"
}
hcall() {
  case $1 in
    notifications.list)
      node -e 'const fs=require("fs");const l={available:true,items:fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).map(key=>({key}))};console.log(String(('"$3"')(l)))' "$LIST" ;;
    notifications.dismiss)
      local k; k=$(node -e 'console.log(JSON.parse(process.argv[1])[0])' "$2")
      echo "$k" >>"$DISMISSED"; grep -vxF "$k" "$LIST" >"$LIST.n"; mv "$LIST.n" "$LIST"; echo ok ;;
  esac
}
SS_N=5
. "$TMPD/block.sh"
ss_seed
trap -p EXIT | grep -q ss_unseed || { echo "TRAP-MISSING"; exit 1; }
ss_unseed
trap -p EXIT | grep -q ss_unseed && { echo "TRAP-LEFT"; exit 1; }
echo DONE
EOF
out=$(TMPD=$tmp bash "$tmp/run.sh" 2>&1) || fail "run: $out"
grep -q '^DONE' <<<"$out" || fail "no DONE: $out"
[ "$(grep -c 'cmd notification post -S messaging' "$tmp/posts")" = 5 ] || fail "want 5 messaging posts: $(cat "$tmp/posts")"
for i in 1 2 3 4 5; do grep -q " powos-ss-$i " "$tmp/posts" || fail "no post tagged powos-ss-$i"; done
[ "$(wc -l <"$tmp/dismissed" | tr -d ' ')" = 5 ] || fail "want 5 dismissals: $(cat "$tmp/dismissed")"
grep -v '|powos-ss-' "$tmp/dismissed" && fail "dismissed a notification that isn't the check's"
[ "$(cat "$tmp/list")" = "$(printf '%s\n' '0|com.whatsapp|1|null|10200' '0|com.android.shell|7|user-own|2000')" ] || fail "the user's notifications changed: $(cat "$tmp/list")"
grep -q 'posted 5 test notifications (powos-ss-\*), 5 in' <<<"$out" || fail "seed log: $out"
grep -q 'test notifications removed' <<<"$out" || fail "unseed log: $out"
echo "PASS perf shade-scroll seeds 5 test notifications and removes only those"
