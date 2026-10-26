# owed.sh <lightsX> <lightsY>: (on the phone, Android root) the batch of owed screen checks in one window - home's
# merged tiles, the Lights popup (held press, read only), the control center and PowOS AI's page (frost v2). Injected
# input only; aborts (exit 3) on any real touch. Transient UI closed first; every opened surface closed again (Back);
# home returned to its first page. Screencaps: /data/local/tmp/cv/owed-<step>-<fold>.png. Changes no setting.
D=/data/local/tmp/cv; mkdir -p $D
LX=${1:-0}; LY=${2:-0}
irq() { awk '/touch-0/{for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i; else break} END{print s}' /proc/interrupts; }
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "ABORT: real touch at $1"; input keyevent 4; exit 3; }; }
case $(dumpsys device_state | grep -m1 mCommittedState) in *CLOSED*) FOLD=folded ;; *) FOLD=unfolded ;; esac
# The ON display (cover folded, inner unfolded) - never a fixed id: the other one is OFF and captures black.
DID=$(dumpsys display | grep -E "^  DisplayDeviceInfo" | sed -nE 's/.*uniqueId="local:([0-9]+)",.* state ON,.*/\1/p' | head -1)
[ -n "$DID" ] || { echo "ABORT: no display is on"; exit 3; }
set -- $(dumpsys display | grep -m1 -A0 "mOverrideDisplayInfo=DisplayInfo{\"Built-in Screen\", displayId 0" | sed -nE 's/.* real ([0-9]+) x ([0-9]+),.*/\1 \2/p')
W=${1:-1116}; H=${2:-2484}
echo "fold=$FOLD display=${W}x${H}"
shot() { screencap -d $DID -p $D/owed-$1-$FOLD.png; echo "shot $1"; }
x() { echo $(( W * $1 / 1000 )); }; y() { echo $(( H * $1 / 1000 )); }
# Transient UI away: the system shade collapsed, then home in front (no Back: it could act inside a user app).
cmd statusbar collapse; sleep 0.3
am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; sleep 1.2; chk close
shot home
# Lights: a held press on the room's name (not the slider), read the popup, Back.
if [ "$LX" -gt 0 ]; then input swipe $LX $LY $LX $LY 900; sleep 1.5; chk lights; shot lights; input keyevent 4; sleep 0.8; fi
# The control center: pull down on the status bar's right half; Back.
input swipe $(x 800) 8 $(x 800) $(y 600) 350; sleep 1.5; chk cc; shot cc; input keyevent 4; sleep 0.8
# PowOS AI's page: swipe right from home's first page (from x 31%, clear of the edge gesture); back to page one.
input swipe $(x 310) $(y 560) $(x 950) $(y 560) 350; sleep 1.5; chk ai; shot ai
input swipe $(x 900) $(y 560) $(x 180) $(y 560) 300; sleep 1; chk back; shot end
echo done
