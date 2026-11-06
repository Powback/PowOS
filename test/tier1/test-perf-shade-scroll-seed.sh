#!/usr/bin/env bash
# perf-scenarios.sh shade-scroll seeds its own test notifications (the phone's shade had 2, too few to scroll),
# silently, and removes them again. Hermetic: the ss_* block is cut out of the script and run with stubbed sh_ /
# hcall / ash (a fake list holding the user's own notifications, one of them a real Plasma mirror). Asserts: SS_N
# urgency-0 notify files (the silent plasma-quiet-v1 channel), two per app, renamed in at mode 644; the clean-up closes
# exactly our ids and never the user's; the EXIT trap carries the clean-up while seeded and is handed back after;
# a channel above LOW is a SKIP with nothing posted.
set -u
here=$(cd "$(dirname "$0")" && pwd)
S=$here/../../tools/phone/verify/perf-scenarios.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

sed -n '/^SS_N=/,/^sc_shade_scroll() {/p' "$S" | sed '$d' >"$tmp/block.sh"
grep -q '^ss_seed()' "$tmp/block.sh" && grep -q '^ss_unseed()' "$tmp/block.sh" || fail "no ss_seed/ss_unseed block in perf-scenarios.sh"

cat >"$tmp/run.sh" <<'RUN'
LIST=$TMPD/list; DISMISSED=$TMPD/dismissed; WROTE=$TMPD/wrote
printf '%s\n' '0|com.whatsapp|1|null|10200' '0|com.powos.app|7|plasma|10359' '0|com.powos.app|2000000003|other|10359' >"$LIST"
: >"$DISMISSED"; : >"$WROTE"
sleep() { :; }
log() { echo "LOG $*"; }
note() { echo "NOTE $*"; }
fail() { echo "FAIL $*"; }
e2e_abort() { :; }
e2e_skip() { echo "SKIP $*"; exit 3; }
sh_() { case $* in "dumpsys notification") echo "    NotificationChannel{mId='plasma-quiet-v1', mName=Plasma notifications (low), mImportance=$IMP, mLockscreenVisibility=-1000}" ;; esac; }
# The app's FileObserver: renamed-in *.json files applied (notify -> listed, close -> gone), then deleted.
ash() {
  bash -s
  local f op
  for f in "$SS_RUN"/*.json; do
    [ -e "$f" ] || continue
    [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = 644 ] || echo "MODE $f"
    op=$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1]));if(j.op==="notify"&&j.urgency!==0)throw "loud";console.log(j.op+" "+j.id+" "+(j.app||"").replace(/ /g,"_"))' "$f") || echo "BADFILE $f"
    echo "$op" >>"$WROTE"
    set -- $op
    case $1 in
      notify) echo "0|com.powos.app|$2|plasma|10359" >>"$LIST" ;;
      close) echo "$2" >>"$DISMISSED"; grep -vxF "0|com.powos.app|$2|plasma|10359" "$LIST" >"$LIST.n"; mv "$LIST.n" "$LIST" ;;
    esac
    rm -f "$f"
  done
  ls -A "$SS_RUN" | grep -q . && echo "LEFTOVER"
}
hcall() {
  case $1 in
    notifications.list)
      node -e 'const fs=require("fs");const l={available:true,items:fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).map(key=>({key}))};console.log(String(('"$3"')(l)))' "$LIST" ;;
  esac
}
SS_N=5
. "$TMPD/block.sh"
SS_RUN=$TMPD/out; mkdir -p "$SS_RUN"
ss_seed
trap -p EXIT | grep -q ss_unseed || { echo "TRAP-MISSING"; exit 1; }
ss_unseed
trap -p EXIT | grep -q ss_unseed && { echo "TRAP-LEFT"; exit 1; }
echo DONE
RUN
out=$(TMPD=$tmp IMP=2 bash "$tmp/run.sh" 2>&1) || fail "run: $out"
grep -q '^DONE' <<<"$out" || fail "no DONE: $out"
grep -q 'MODE\|BADFILE\|LEFTOVER\|^FAIL' <<<"$out" && fail "files: $out"
[ "$(grep -c '^notify ' "$tmp/wrote")" = 5 ] || fail "want 5 silent notify files: $(cat "$tmp/wrote")"
[ "$(grep '^notify ' "$tmp/wrote" | awk '{print $3}' | sort | uniq -c | awk '{print $1}' | tr '\n' ' ')" = "2 2 1 " ] || fail "want two per app: $(cat "$tmp/wrote")"
[ "$(sort "$tmp/dismissed" | tr '\n' ' ')" = "2000000001 2000000002 2000000003 2000000004 2000000005 " ] || fail "want our 5 ids closed: $(cat "$tmp/dismissed")"
[ "$(cat "$tmp/list")" = "$(printf '%s\n' '0|com.whatsapp|1|null|10200' '0|com.powos.app|7|plasma|10359' '0|com.powos.app|2000000003|other|10359')" ] || fail "the user's notifications changed: $(cat "$tmp/list")"
grep -q 'posted 5 silent test notifications (plasma-quiet-v1, importance 2), 5 in' <<<"$out" || fail "seed log: $out"
grep -q 'test notifications removed' <<<"$out" || fail "unseed log: $out"
# A channel that could sound (the user raised it, or it's missing): SKIP, nothing posted.
rm -rf "$tmp/out"; : >"$tmp/wrote"
out=$(TMPD=$tmp IMP=3 bash "$tmp/run.sh" 2>&1); rc=$?
[ $rc = 3 ] && grep -q "SKIP shade-scroll: no silent channel.*importance '3'" <<<"$out" || fail "importance 3 should SKIP (rc $rc): $out"
[ -s "$tmp/wrote" ] && fail "posted on a loud channel: $(cat "$tmp/wrote")"
echo "PASS perf shade-scroll seeds 5 silent test notifications (LOW channel, two per app) and removes only those; SKIP on a loud channel"
