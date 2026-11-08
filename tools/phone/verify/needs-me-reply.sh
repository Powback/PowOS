#!/bin/bash
# lanes: phone
# needs-me-reply.sh: What needs me's inline reply, end to end on the phone (board task
# what-needs-me-discord-whatsapp-gmail-in-one-widg). The widget's reply field -> the notification's own RemoteInput reply
# action -> PendingIntent.send with the typed text -> the app that posted it receives the words.
#
# Never a real person: the notification comes from the check's OWN test sender (replycheck/, package
# dev.powos.replycheck, built here, installed for this run and uninstalled in the EXIT trap), posted with a name
# carrying this run's token ("Reply check rcNNNN"), and the only row the check opens and replies on is the one whose
# group is that name - no Discord, WhatsApp or Gmail notification is pressed, opened or read.
#
#   1. idle gate (e2e-lib useract: the user idle > 120 s, screen Awake), else SKIP (exit 3, re-queued);
#   2. the sender installed, POST_NOTIFICATIONS granted, its notification posted (am broadcast, shell-only receiver);
#   3. home's notification list has it from dev.powos.replycheck with a reply action (input: true);
#   4. What needs me may read dev.powos.replycheck for this run - in the page's memory only (apps/pages.ts installedApps,
#      the row's manifest with "notifications:dev.powos.replycheck" added; put back in the trap, never written to the
#      registry), as its manifest names Discord/WhatsApp/Gmail only;
#   5. the row found in the home widget (else the What needs me page opened by code), tapped open, the text put in its
#      reply field, send tapped (a click in the page: no touch on the screen) -> the row says "Sent" at once
#      (data-reply="sent", the optimistic state) and never "error";
#   6. the sender's files/last-reply reads "<token>\t<the text>" within 15 s: the words reached the app.
# PASS: exit 0; FAIL lines: exit 1; SKIP: exit 3. Budget: 300 s (watchdog).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
T=$here/..; A=$T/adb.sh
OUT=$(mktemp -d "${TMPDIR:-/tmp}/needs-me-reply.XXXX")
. "$here/e2e-lib.sh"
. "$here/ww-lib.sh"
PKG=dev.powos.replycheck
TOKEN=rc$(date +%s)
WHO="Reply check $TOKEN"
TEXT="needs-me check $TOKEN"
FAILS=0
log() { echo "$*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
pass() { echo "PASS $*"; }
# The whole check under 300 s: a stuck adb/CDP hop ends it as a FAIL, the trap still runs.
( sleep 290; echo "FAIL needs-me-reply: over its 300 s budget" >&2; kill -TERM $$ ) 2>/dev/null &
DOG=$!

SCOPED=; OPENED=; INSTALLED=
restore() {
  kill "$DOG" 2>/dev/null
  [ -n "$SCOPED" ] && ev 'importShim("./apps/pages.ts").then(P=>{const o=window.__nmReplyCheckRow;if(o)P.installedApps.value=P.installedApps.value.map(a=>a.id===o.id&&JSON.parse(a.manifest||"{}").permissions?.includes("notifications:'$PKG'")?o:a);delete window.__nmReplyCheckRow;return "ok"})' >/dev/null
  [ -n "$OPENED" ] && ev 'importShim("./apps/pages.ts").then(P=>{P.closeApp();return "ok"})' >/dev/null
  [ -n "$INSTALLED" ] && "$A" uninstall "$PKG" >/dev/null 2>&1
  rm -rf "$OUT"
}
trap restore EXIT
trap 'exit 1' TERM INT

# 1. The user idle (e2e-lib's rule): the check types into home's page.
e2e_touchwatch >/dev/null 2>&1
r=$(useract); idle=$(sed -nE 's/.*idle=(-?[0-9]+).*/\1/p' <<<"$r"); wake=$(sed -nE 's/.*wake=([^ ]*).*/\1/p' <<<"$r")
log "idle check: $r"
if [ "${wake:-?}" != Awake ] && [ "${wake:-?}" != "?" ]; then echo "SKIP: needs-me-reply: the screen is $wake"; exit 3; fi
if [ "${idle:--1}" -le "${E2E_IDLE_S:-120}" ]; then echo "SKIP: needs-me-reply: user active ${idle} s ago"; exit 3; fi

# 2. The test sender.
apk=$("$here/replycheck/build.sh") || { fail "the test sender didn't build (replycheck/build.sh)"; exit 1; }
"$A" install -r -t "$apk" >/dev/null 2>&1 || { fail "the test sender didn't install ($apk)"; exit 1; }
INSTALLED=1
# As root: OxygenOS (the 11-08 03:16 run) refuses `pm grant` from the shell user ("Neither user 2000 nor current process
# has android.permission.GRANT_RUNTIME_PERMISSIONS"), so the permission stayed off and Android dropped the post.
grant=$("$A" shell "su -c 'pm grant $PKG android.permission.POST_NOTIFICATIONS 2>&1'" </dev/null 2>&1 | tr -d '\r' | head -3)
# The app-op too, per uid as well as per package: POST_NOTIFICATION is a uid-mode op ("Uid mode: POST_NOTIFICATION:
# ignore" with the package mode allowed), and OxygenOS keeps its own switch for a fresh install beside the permission.
sh_ "appops set $PKG POST_NOTIFICATION allow; appops set --uid $PKG POST_NOTIFICATION allow" >/dev/null
sh_ "dumpsys package $PKG" | grep -qm1 'POST_NOTIFICATIONS: granted=true' || { fail "the test sender has no POST_NOTIFICATIONS after the root grant: ${grant:-no answer}"; exit 1; }
sh_ "rm -f /data/data/$PKG/files/last-reply"
# posted: how many of the sender's notifications Android's notification service holds now (its own record, before any
# listener or home's list: 0 = never posted, so the fault is the sender's start, not home).
posted() { sh_ "dumpsys notification --noredact" | grep -c "NotificationRecord(.* pkg=$PKG "; }
# -f 0x20: FLAG_INCLUDE_STOPPED_PACKAGES (a fresh install is stopped until something starts it).
bc=$("$A" shell am broadcast -f 0x20 -n "$PKG/.Post" -a "$PKG.POST" --es token "$TOKEN" 2>&1 | tr -d '\r' | tail -1)
n=0; for _ in $(seq 1 10); do n=$(posted); [ "${n:-0}" -gt 0 ] && break; sleep 0.5; done
if [ "${n:-0}" -eq 0 ]; then
  # HACK: a second post from root - OxygenOS's OplusAppStartupManager may refuse to start a fresh third-party app's
  # process for a shell broadcast (the 11-07 run: nothing posted, no reason logged). Real fix: none needed in PowOS
  # (the sender is the check's own test app); drop this once the diagnosis below shows which caller it lets through.
  log "not posted after the shell's broadcast ($bc); again as root"
  bc="$bc / root: $(sh_ "am broadcast -f 0x20 -n $PKG/.Post -a $PKG.POST --es token $TOKEN" | tail -1)"
  for _ in $(seq 1 10); do n=$(posted); [ "${n:-0}" -gt 0 ] && break; sleep 0.5; done
fi
# why: everything that says where the post stopped - for the FAIL line.
why() {
  echo "posted in Android: ${n:-0}; broadcast: ${bc:-no answer}; grant: ${grant:-ok};" \
    "permission: $(sh_ "dumpsys package $PKG" | grep -m1 -oE 'POST_NOTIFICATIONS: granted=[a-z]+')" \
    "app-op: $(sh_ "appops get $PKG POST_NOTIFICATION" | head -1);" \
    "process: $(sh_ "pidof $PKG" || true);" \
    "log: $(sh_ "logcat -d -t 600" | grep -E "PowosReplyCheck|$PKG" | grep -v adbd | tail -4 | cut -c1-200 | tr '\n' '~')"
}

# 3. Posted, from the sender, with a reply that takes text.
seen=
for _ in $(seq 1 20); do
  seen=$(ev 'importShim("./bridge.ts").then(({powos})=>powos.notifications.list()).then(l=>{const n=(l.items||[]).find(i=>i.pkg==="'$PKG'"&&i.title==="'"$WHO"'");return n?(n.actions||[]).some(a=>a.input)?"ok":"no reply action":(l.available?"none":"no notification access")})')
  [ "$seen" = ok ] && break; sleep 0.5
done
if [ "$seen" != ok ]; then
  # Home's list from the sender at all (another title = the check's match is wrong, not the post).
  mine=$(ev 'importShim("./bridge.ts").then(({powos})=>powos.notifications.list()).then(l=>JSON.stringify((l.items||[]).filter(i=>i.pkg==="'$PKG'").map(i=>({title:i.title,actions:i.actions}))))')
  fail "the test notification isn't in home's list from $PKG with a reply action: ${seen:-no answer} (home's from $PKG: ${mine:-none}; $(why))"; exit 1
fi
pass "posted \"$WHO\" from $PKG with a RemoteInput reply"

# 4. What needs me may read the sender, in the page's memory for this run.
r=$(ev 'importShim("./apps/pages.ts").then(P=>{const o=P.installedApps.value.find(a=>a.id==="local.needs-me");if(!o)return "not installed";const m=JSON.parse(o.manifest||"{}");window.__nmReplyCheckRow=o;m.permissions=[...(m.permissions||[]),"notifications:'$PKG'"];P.installedApps.value=P.installedApps.value.map(a=>a===o?{...o,manifest:JSON.stringify(m)}:a);return "ok"})')
[ "$r" = ok ] || { fail "What needs me: $r"; exit 1; }
SCOPED=1

# 5. The row (the widget on home, else the page), opened, typed into, sent.
ROW='(()=>{const k="'"$(tr '[:upper:]' '[:lower:]' <<<"$WHO")"'";const rs=[...document.querySelectorAll(".nm-row")].filter(r=>(r.dataset.group||"").endsWith(k));return rs[0]||null})()'
where=$(ev "(()=>{const r=$ROW;return r?(r.closest('.app-screen')?'page':'widget'):'none'})()")
for _ in $(seq 1 10); do [ "$where" != none ] && break; sleep 0.5; where=$(ev "(()=>{const r=$ROW;return r?(r.closest('.app-screen')?'page':'widget'):'none'})()"); done
if [ "$where" = none ]; then
  OPENED=1; ev 'importShim("./apps/pages.ts").then(P=>{P.openApp("local.needs-me");return "ok"})' >/dev/null
  for _ in $(seq 1 16); do sleep 0.5; where=$(ev "(()=>{const r=$ROW;return r?'page':'none'})()"); [ "$where" = page ] && break; done
fi
[ "$where" = none ] && { fail "no What needs me row for \"$WHO\" (widget or page)"; exit 1; }
log "row for \"$WHO\" in the $where"
r=$(ev "(async()=>{const sleep=ms=>new Promise(o=>setTimeout(o,ms));const row=()=>$ROW;
  row().querySelector('[role=button]').click();
  let f=null;for(let i=0;i<40&&!(f=row()?.querySelector('form textarea, form input'));i++)await sleep(50);
  if(!f)return 'FAIL no reply field after opening the row: '+(row()?.textContent||'').slice(0,80);
  Object.getOwnPropertyDescriptor(Object.getPrototypeOf(f),'value').set.call(f,'$TEXT');
  f.dispatchEvent(new Event('input',{bubbles:true}));await sleep(150);
  const s=row().querySelector('form [type=submit]');if(!s)return 'FAIL no send button in the reply field';
  s.click();
  let st='';for(let i=0;i<20;i++){st=row()?.dataset.reply||'';if(st)break;await sleep(25)}
  return st==='sent'?'ok':'FAIL the row is not Sent right after send: '+(st||'no state')+' '+(row()?.textContent||'').slice(0,80)})()")
case $r in ok) pass "typed into the $where's reply field and sent: the row says Sent at once" ;; *) fail "${r#FAIL }"; exit 1 ;; esac

# 6. The sender received the words.
got=
for _ in $(seq 1 30); do got=$(sh_ "cat /data/data/$PKG/files/last-reply 2>/dev/null"); [ -n "$got" ] && break; sleep 0.5; done
want=$(printf '%s\t%s' "$TOKEN" "$TEXT")
if [ "$got" = "$want" ]; then pass "the test sender received \"$TEXT\" through its RemoteInput"
else fail "the test sender received \"${got:-nothing}\", want \"$want\""; fi
st=$(ev "(()=>{const r=$ROW;return r?(r.dataset.reply||'gone'):'gone'})()")
[ "$st" = error ] && fail "the row rolled back to an error after the reply went: $(ev "(()=>{const r=$ROW;return r?r.textContent.slice(0,80):''})()")"
[ "$FAILS" -eq 0 ] && { echo "PASS needs-me-reply: inline reply from What needs me reached the app"; exit 0; }
exit 1
