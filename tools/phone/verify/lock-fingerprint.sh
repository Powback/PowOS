#!/bin/bash
# lanes: phone
# lock-fingerprint.sh (Mac side, board "Fingerprint unlocks straight from the lock face"): the path a fingerprint unlock
# takes out of the PowOS lock face. A real finger can't be injected, so the keyguard is dismissed the way the keyguard's
# own biometric unlock ends - from outside the face (`wm dismiss-keyguard`; this phone has no PIN, a PIN pad that comes up
# is left alone) - and the face must go by itself (LockFace.kt: USER_PRESENT), with no swipe on it. In a free window:
#   1. the screen off and on: the face (PowosLockActivity) in front, the keyguard locked;
#   2. the lock page's sensor read (lock.sensor over read-only CDP, informational): kind, enrolled, spot, and the spot
#      the page draws (an in-display one: it must be drawn, and in the hint);
#   3. `wm dismiss-keyguard`: within 4 s the face is gone and the keyguard unlocked; logcat PowosUnlock shows
#      "broadcast USER_PRESENT" then "face gone" and no "dismiss requested" (nothing went through the face's swipe).
# PASS / FAIL; SKIP when the face never came up (a PIN-less phone with the lock screen off).
set -u
cd "$(dirname "$0")/../../.." || exit 1
A=tools/phone/adb.sh
. tools/phone/verify/window-lock.sh
window_lock lock-fingerprint 60 || exit 3
focus() { "$A" shell "dumpsys window | grep -m1 mCurrentFocus" </dev/null | tr -d '\r'; }
locked() { "$A" shell "dumpsys window policy | grep -m1 -E 'isKeyguardShowing|showing='" </dev/null | tr -d '\r'; }
lockface() { "$A" shell "dumpsys activity activities | grep -c 'PowosLockActivity'" </dev/null | tr -d '\r'; }

# 1. Locked, the face up.
"$A" shell "echo \$(( \$(date +%s) + 8 )) > /data/local/tmp/powos-selfinput; input keyevent KEYCODE_SLEEP; sleep 2; input keyevent KEYCODE_WAKEUP" </dev/null; sleep 2.5
echo "focus: $(focus) | $(locked)"
case "$(focus)" in *PowosLock*) ;; *) echo "SKIP: the lock face isn't in front after the screen went off and on ($(focus))"; exit 0 ;; esac

# 2. The sensor as the page has it (informational, but an in-display spot must be drawn).
sensor=$(tools/phone/cdp.sh eval lock 'new Promise((ok)=>{const H=window.__powosHost;const r=H.resolve;const id=987101;const t=setTimeout(()=>{H.resolve=r;ok("timeout")},5000);H.resolve=(i,v)=>{if(i===id){clearTimeout(t);H.resolve=r;const fp=document.querySelector(".lock-fp")?.getBoundingClientRect();ok(JSON.stringify({sensor:v,drawn:fp?[Math.round(fp.left+fp.width/2),Math.round(fp.top+fp.height/2),Math.round(fp.width/2)]:null,hint:document.querySelector(".lock-hint")?.textContent}))}else r(i,v)};window.PowosHost.postMessage(JSON.stringify([id,"lock.sensor","[]"]))})' 2>&1 | tail -1)
sensor=$(python3 -c 'import json,sys; s=sys.argv[1]; v=json.loads(s) if s.startswith("\"") else s; print(v)' "$sensor" 2>/dev/null || echo "$sensor")
echo "sensor: $sensor"
fails=()
python3 - "$sensor" <<'PY' || fails+=("an in-display sensor's spot isn't drawn on the face")
import json, sys
try: v = json.loads(sys.argv[1])
except Exception: print("INFO: no lock.sensor answer (older APK?)"); sys.exit(0)
s = v.get("sensor") or {}
print(f"INFO: kind {s.get('kind')}, enrolled {s.get('enrolled')}, spot {s.get('spot')}, drawn {v.get('drawn')}, hint \"{v.get('hint')}\"")
sys.exit(1 if s.get("kind") == "udfps" and s.get("enrolled") and not v.get("drawn") else 0)
PY

# 3. The keyguard dismissed from outside the face: the face must follow.
"$A" logcat -c </dev/null 2>/dev/null
"$A" shell "wm dismiss-keyguard" </dev/null
gone=""
for _ in 1 2 3 4 5 6 7 8; do sleep 0.5; [ "$(lockface)" = 0 ] && { gone=1; break; }; done
log=$("$A" logcat -d -s PowosUnlock </dev/null 2>/dev/null | tr -d '\r')
echo "$log" | sed 's/^/  /' | tail -12
echo "after dismiss: focus $(focus) | $(locked)"
if [ -z "$gone" ]; then
  case "$(locked)" in *true*) fails+=("the keyguard stayed locked after wm dismiss-keyguard (a PIN pad? never entered) - the face's exit untested") ;;
    *) fails+=("the keyguard was dismissed but the PowOS lock face stayed up") ;; esac
fi
echo "$log" | grep -q "broadcast USER_PRESENT" || fails+=("no USER_PRESENT reached the face")
echo "$log" | grep -q "dismiss requested" && fails+=("the face asked a dismiss itself - the check didn't test the outside path")
if [ ${#fails[@]} -gt 0 ]; then printf 'FAIL: %s\n' "${fails[@]}"; exit 1; fi
echo "PASS: the keyguard dismissed from outside the face (as its fingerprint unlock does) took the face with it (USER_PRESENT, face gone)"
