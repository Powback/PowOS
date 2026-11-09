#!/bin/bash
# lanes: phone
# progress-notify.sh [OUT]: (Mac side; queue it: queue.sh add --close steam-first-launch-no-visible-progress-gaming-pa
# tools/phone/verify/progress-notify.sh) a long Linux job's progress is ONE Android notification with a progress bar
# that updates and goes when the job ends (Powback/PowOS#11; 803798f2 + 8856cc05: engine Progress.java, the session's
# powos-progress writing run/progress-<id>.state). A simulated job, never a real download: in the session as its user,
#   1. the app serves it ("progress" in run/android-request.verbs) and /usr/bin/powos-progress is installed - else SKIP
#      (not deployed yet);
#   2. `powos-progress <id> 1 4 <title>` -> one com.powos.app notification on channel powos-progress with that title,
#      ongoing, progress 25 of 100;
#   3. `<id> 3 4 <title>` -> the SAME notification (one per job) at 75; `<id> 0 0 <title>` -> indeterminate;
#   4. `<id> done` -> the notification gone and the state file consumed.
# Always: the job ended (`powos-progress <id> done`) so nothing stays in the shade.
# Exit: 0 PASS; 1 FAIL; 3 not woken / not now; 5 SKIP/can't run (ENV).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/progress-notify-$(date +%m%d-%H%M)}; mkdir -p "$OUT"; R=$OUT/log.txt
L=$HOME/.cache/powos-verify.lock
N=$(date +%s)$RANDOM; ID=powos-check-$N; TITLE="PowOS progress check $N"
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
# A script run as the session user (its run dir), through user.sh. Never sudo in it.
us() { printf 'export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/powos-app}\n%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
log() { echo "$*" | tee -a "$R"; }
fail() { log "FAIL: $*"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { log "PASS: $*"; }
# rec: the dumpsys notification record of our job (one block per NotificationRecord), "" when none.
rec() { sh_ "dumpsys notification --noredact" | awk -v t="$TITLE" '
  /NotificationRecord\(/ { if (b != "" && index(b, t)) { print b; n++ } b = "" }
  { b = b $0 "\n" }
  END { if (b != "" && index(b, t)) print b }'; }
val() { grep -m1 -oE "$1=[A-Za-z]+ \([^)]*\)" | sed -E 's/.*\((.*)\)/\1/'; }
# wait_rec <want progress> <s>: the record once android.progress says <want> (or "ind": indeterminate), else the last one.
wait_rec() { local i r=""; for i in $(seq 1 "$2"); do sleep 1; r=$(rec)
  case $1 in ind) [ "$(printf '%s' "$r" | val android.progressIndeterminate)" = true ] && break ;;
             *) [ "$(printf '%s' "$r" | val android.progress)" = "$1" ] && break ;; esac; done; printf '%s' "$r"; }

. "$here/window-lock.sh"
window_lock progress-notify.sh 120
STARTED=0
restore() { [ $STARTED = 1 ] && us "powos-progress $ID done >/dev/null 2>&1; true" >/dev/null; echo "restored; artefacts $OUT"; }
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { log "the screen is $s - not woken (rule); nothing done"; exit 3; }

# 1. Deployed?
env=$(us 'command -v powos-progress || echo none; grep -qx progress "$XDG_RUNTIME_DIR/android-request.verbs" 2>/dev/null && echo verbs=yes || echo verbs=no')
log "session: $(echo "$env" | tr '\n' ' ')"
grep -q '^/.*powos-progress$' <<<"$env" || { log "SKIP: powos-progress isn't installed in the session (core package older than 803798f2)"; exit 5; }
grep -q 'verbs=yes' <<<"$env" || { log "SKIP: the installed APK doesn't serve progress (no \"progress\" in android-request.verbs: older than 803798f2)"; exit 5; }
[ -z "$(rec)" ] || fail "a notification titled '$TITLE' is there before the job started"

# 2. The job starts: one notification at 25 %.
STARTED=1
us "powos-progress $ID 1 4 '$TITLE'" >/dev/null
r=$(wait_rec 25 6); printf '%s\n' "$r" > "$OUT/rec-25.txt"
[ -n "$r" ] || fail "no notification for job $ID 6 s after powos-progress $ID 1 4 (run dir: $(us "ls \$XDG_RUNTIME_DIR | grep progress- | tr '\n' ' '"))"
n=$(grep -c 'NotificationRecord(' <<<"$r"); [ "$n" = 1 ] || fail "$n notifications for one job"
grep -q 'pkg=com.powos.app' <<<"$r" || fail "not posted by com.powos.app: $(grep -m1 'NotificationRecord(' <<<"$r" | cut -c1-160)"
grep -q "powos-progress" <<<"$r" || fail "not on the powos-progress channel"
p=$(printf '%s' "$r" | val android.progress); m=$(printf '%s' "$r" | val android.progressMax)
[ "$p/$m" = 25/100 ] || fail "progress $p/$m, want 25/100"
key=$(grep -m1 -oE 'key=[^ )]+' <<<"$r")
"$T/shot.sh" "$OUT/posted.png" >/dev/null 2>&1
pass "job $ID shows as one com.powos.app progress notification at 25/100 ('$TITLE', $key)"

# 3. Updates: the same notification at 75, then indeterminate.
us "powos-progress $ID 3 4 '$TITLE'" >/dev/null
r=$(wait_rec 75 6); printf '%s\n' "$r" > "$OUT/rec-75.txt"
p=$(printf '%s' "$r" | val android.progress); [ "$p" = 75 ] || fail "after 3/4 the notification says ${p:-nothing} (want 75)"
[ "$(grep -c 'NotificationRecord(' <<<"$r")" = 1 ] || fail "the update posted a second notification"
[ "$(grep -m1 -oE 'key=[^ )]+' <<<"$r")" = "$key" ] || fail "the update is another notification ($(grep -m1 -oE 'key=[^ )]+' <<<"$r"), was $key)"
us "powos-progress $ID 0 0 '$TITLE'" >/dev/null
r=$(wait_rec ind 6); printf '%s\n' "$r" > "$OUT/rec-ind.txt"
[ "$(printf '%s' "$r" | val android.progressIndeterminate)" = true ] || fail "total 0 isn't shown as indeterminate"
pass "updates move the same notification (75/100, then indeterminate)"

# 4. Done: it goes.
us "powos-progress $ID done" >/dev/null
for _ in 1 2 3 4 5 6; do sleep 1; [ -z "$(rec)" ] && break; done
[ -z "$(rec)" ] || fail "the notification stays 6 s after powos-progress $ID done"
left=$(us "ls \$XDG_RUNTIME_DIR/progress-$ID.state 2>/dev/null")
[ -z "$left" ] || fail "the app left run/progress-$ID.state behind"
STARTED=0
pass "done: the notification is gone and the state file consumed"
echo "all passed; artefacts: $OUT"
