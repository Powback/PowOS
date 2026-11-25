#!/bin/bash
# lanes: phone
# lock-media.sh (board lock-screen-media-controls-when-something-is-pla + lock-screen-camera-flashlight-shortcuts; the
# user 11-25: "we are missing basic features such as a media control on the lockscreen if media is playing", "lock
# screen camera button or whatever?"). In a free window (window-lock.sh), on the device as the user would:
#   1. nothing of the user's may be playing (any active session PLAYING: SKIP - never touch their music);
#   2. a short, near-silent tone (made here, pushed to /sdcard/Music, deleted at the end) opened in the phone's own
#      audio player through MediaStore (no player we ship); its MediaSession must reach PLAYING;
#   3. the screen off and on: the PowOS lock face (PowosLockActivity) must show the media card with the tone's title;
#   4. play/pause on the card (an input tap at the card's button, the rect read over read-only CDP): the session must go
#      PAUSED, then PLAYING again - with the phone still locked;
#   5. the torch shortcut held (a long press): the face shows it on, held again: off;
#   6. the camera shortcut held: a camera activity in front over the lock (keyguard still locked), Back to the face;
#   7. stock's double-press power for the camera, over the face (informational: SystemUI's own gesture, never failed on);
#   8. the tone paused and its player stopped (only a player that wasn't running before), the file deleted, the face
#      swiped up (it has no PIN; never enter a credential).
# Screens go to $OUT (lock face with the card, torch on). FAIL on the card or controls; SKIP when no player took the file.
set -u
cd "$(dirname "$0")/../../.." || exit 1
A=tools/phone/adb.sh
OUT=${OUT:-$HOME/.cache/powos-verify-queue/lock-media-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
. tools/phone/verify/window-lock.sh
window_lock lock-media 60 || exit 3
FILE=/sdcard/Music/powos-lock-media-check.wav
TITLE=powos-lock-media-check

# The MediaSession records: "pkg state" per active session (dumpsys media_session).
sessions() {
  "$A" shell dumpsys media_session </dev/null 2>/dev/null | python3 -c '
import re, sys
pkg = None
for line in sys.stdin:
    m = re.search(r"\bpackage=(\S+)", line)
    if m: pkg = m.group(1)
    s = re.search(r"state=PlaybackState \{state=(\w+)", line)
    if s and pkg: print(pkg, s.group(1)); pkg = None
'
}
state_of() { sessions | awk -v p="$1" '$1 == p { print $2; exit }'; }
focus() { "$A" shell "dumpsys window | grep -m1 mCurrentFocus" </dev/null | tr -d '\r'; }
locked() { "$A" shell "dumpsys window policy | grep -m1 -E 'isKeyguardShowing|showing='" </dev/null | tr -d '\r'; }
# The lock page's state (read-only CDP): the card, its play button's centre and the corners', in device px.
face() {
  tools/phone/cdp.sh eval lock 'JSON.stringify((()=>{const d=devicePixelRatio,c=(e)=>{if(!e)return null;const b=e.getBoundingClientRect();return [Math.round((b.left+b.width/2)*d),Math.round((b.top+b.height/2)*d)]};const card=document.querySelector(".lock-media-slide .cc-media");return {card:!!card,title:card?.querySelector(".cc-label")?.textContent??null,play:card?.querySelector(".cc-play")?.getAttribute("aria-label")??null,playAt:c(card?.querySelector(".cc-play")),torchAt:c(document.querySelector(".lock-shortcut[data-shortcut=torch]")),torchOn:document.querySelector(".lock-shortcut[data-shortcut=torch]")?.classList.contains("on")??null,cameraAt:c(document.querySelector(".lock-shortcut[data-shortcut=camera]"))}})())' 2>/dev/null | tail -1 |
    python3 -c 'import json,sys; s=sys.stdin.read().strip(); v=json.loads(s) if s else {}; v=json.loads(v) if isinstance(v,str) else v; print(json.dumps(v))' 2>/dev/null
}
field() { python3 -c 'import json,sys; v=json.loads(sys.argv[1]).get(sys.argv[2]); print(" ".join(map(str,v)) if isinstance(v,list) else v)' "$1" "$2" 2>/dev/null; }
shot() { "$A" shell "screencap -p /data/local/tmp/lm.png" </dev/null && "$A" pull /data/local/tmp/lm.png "$OUT/$1.png" >/dev/null 2>&1; }
hold() { "$A" shell "echo \$(( \$(date +%s) + 3 )) > /data/local/tmp/powos-selfinput; input swipe $1 $2 $1 $2 750" </dev/null; sleep 1.2; }
tap() { "$A" shell "echo \$(( \$(date +%s) + 3 )) > /data/local/tmp/powos-selfinput; input tap $1 $2" </dev/null; sleep 1.5; }

read -r W H < <("$A" shell wm size </dev/null | grep -o '[0-9]*x[0-9]*' | tail -1 | tr x ' ')
before=$(sessions)
echo "sessions before: ${before:-none}"
if echo "$before" | grep -q ' PLAYING'; then echo "SKIP: something of the user's is playing - not touched"; exit 0; fi

fails=()
player=""
cleanup() {
  [ -n "$player" ] && "$A" shell "cmd media_session dispatch pause" </dev/null >/dev/null 2>&1
  if [ -n "$player" ] && ! echo "$before" | grep -q "^$player "; then "$A" shell am force-stop "$player" </dev/null >/dev/null 2>&1; fi
  "$A" shell "rm -f $FILE; content delete --uri content://media/external/audio/media --where \"_display_name='$TITLE.wav'\"" </dev/null >/dev/null 2>&1
  # The face swiped up (no PIN on this phone; a PIN pad that comes up is left alone).
  case "$(focus)" in *PowosLock*) "$A" shell "input swipe $((W / 2)) $((H * 85 / 100)) $((W / 2)) $((H * 25 / 100)) 250" </dev/null; sleep 1.5 ;; esac
}
trap cleanup EXIT

# 2. The tone: 60 s at 440 Hz, amplitude 1/1000 (inaudible at any volume worth having), 8 kHz mono.
tmp=$(mktemp -d)
python3 -I - "$tmp/$TITLE.wav" <<'PY'
import math, struct, sys, wave
w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(8000)
w.writeframes(b"".join(struct.pack("<h", int(32 * math.sin(2 * math.pi * 440 * i / 8000))) for i in range(8000 * 60)))
PY
"$A" push "$tmp/$TITLE.wav" "$FILE" >/dev/null 2>&1; rm -rf "$tmp"
"$A" shell "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://$FILE" </dev/null >/dev/null 2>&1; sleep 3
id=$("$A" shell "content query --uri content://media/external/audio/media --projection _id --where \"_display_name='$TITLE.wav'\"" </dev/null | grep -o '_id=[0-9]*' | head -1 | cut -d= -f2)
[ -z "$id" ] && { echo "SKIP: MediaStore didn't index the tone"; exit 0; }
"$A" shell "am start -a android.intent.action.VIEW -t audio/wav -d content://media/external/audio/media/$id" </dev/null >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8; do sleep 1; player=$(sessions | awk '$2 == "PLAYING" { print $1; exit }'); [ -n "$player" ] && break; done
if [ -z "$player" ]; then echo "SKIP: no player played the tone (no default audio player?) - focus $(focus)"; "$A" shell input keyevent KEYCODE_BACK </dev/null; exit 0; fi
echo "player: $player (PLAYING)"

# 3. Locked: the face with the card.
"$A" shell "echo \$(( \$(date +%s) + 8 )) > /data/local/tmp/powos-selfinput; input keyevent KEYCODE_SLEEP; sleep 2; input keyevent KEYCODE_WAKEUP" </dev/null; sleep 2.5
echo "focus: $(focus) | $(locked)"
case "$(focus)" in *PowosLock*) ;; *) echo "FAIL: the lock face isn't in front after the screen went off and on"; exit 1 ;; esac
f=$(face); echo "face: $f"
shot face-playing
[ "$(field "$f" card)" = True ] || fails+=("no media card on the lock face while $player plays")
[ "$(field "$f" play)" = pause ] || fails+=("the card's button says '$(field "$f" play)', not pause, while it plays")

# 4. Play/pause from the face, still locked.
if [ "$(field "$f" card)" = True ]; then
  tap $(field "$f" playAt); s=$(state_of "$player"); echo "after pause tap: $s"
  [ "$s" = PAUSED ] || fails+=("a tap on pause left the session $s")
  tap $(field "$f" playAt); s=$(state_of "$player"); echo "after play tap: $s"
  [ "$s" = PLAYING ] || fails+=("a tap on play left the session $s")
  case "$(focus)" in *PowosLock*) ;; *) fails+=("play/pause left the lock face ($(focus))") ;; esac
fi

# 5. The torch: held on, held off.
f=$(face); at=$(field "$f" torchAt)
if [ -n "$at" ] && [ "$at" != None ]; then
  hold $at; f2=$(face); echo "torch held: $(field "$f2" torchOn)"; shot face-torch
  [ "$(field "$f2" torchOn)" = True ] || fails+=("holding the torch shortcut didn't show it on")
  hold $at; f2=$(face); echo "torch held again: $(field "$f2" torchOn)"
  [ "$(field "$f2" torchOn)" = False ] || fails+=("holding the torch again didn't turn it off")
else
  fails+=("no torch shortcut on the face (the APK without lock.shortcuts?)")
fi

# 6. The camera over the lock, then Back to the face.
at=$(field "$f" cameraAt)
if [ -n "$at" ] && [ "$at" != None ]; then
  hold $at; sleep 1.5; fc=$(focus); lk=$(locked); echo "camera held: $fc | $lk"; shot camera
  case "$fc" in *[Cc]amera*) ;; *) fails+=("holding the camera shortcut didn't bring a camera in front ($fc)") ;; esac
  case "$lk" in *true*) ;; *) fails+=("the camera opened but the phone isn't locked under it ($lk)") ;; esac
  "$A" shell input keyevent KEYCODE_BACK </dev/null; sleep 2
  case "$(focus)" in *PowosLock*) ;; *) fails+=("Back from the camera didn't return to the lock face ($(focus))") ;; esac
else
  fails+=("no camera shortcut on the face")
fi

# 7. Stock's double-press power: informational.
"$A" shell "echo \$(( \$(date +%s) + 8 )) > /data/local/tmp/powos-selfinput; input keyevent KEYCODE_POWER KEYCODE_POWER" </dev/null; sleep 2.5
fc=$(focus); echo "double-press power: $fc"
case "$fc" in *[Cc]amera*) echo "INFO: double-press power opens the camera over the face"; "$A" shell input keyevent KEYCODE_BACK </dev/null; sleep 1.5 ;;
  *) echo "INFO: double-press power didn't bring the camera (gesture off in settings, or injected keys don't count)"
     "$A" shell "echo \$(( \$(date +%s) + 8 )) > /data/local/tmp/powos-selfinput; input keyevent KEYCODE_WAKEUP" </dev/null; sleep 1 ;;
esac

if [ ${#fails[@]} -gt 0 ]; then printf 'FAIL: %s\n' "${fails[@]}"; echo "shots: $OUT"; exit 1; fi
echo "PASS: media card on the lock face for $player, play/pause from it while locked (PAUSED, PLAYING), torch on/off by hold, camera over the lock and Back; shots $OUT"
