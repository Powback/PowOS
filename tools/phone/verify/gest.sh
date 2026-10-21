# gest.sh <A|B|C|D|R>: gesture journeys on the cover screen (runs ON the phone as Android root, pushed by journey.sh).
# Injected input only; aborts (exit 3) the moment a real touch IRQ moves. Output: /data/local/tmp/cv/<run>.mp4 + <run>-<step>.png
# A home from page 2 · B home from page 1 · C switcher from home + from an app · D home from the PowOS AI page · R back to page 1
RUN=$1; D=/data/local/tmp/cv; mkdir -p $D
irq() { awk '/touch-0/{s+=$2+$3+$4+$5+$6+$7+$8+$9} END{print s}' /proc/interrupts; }
I0=$(irq)
chk() { if [ "$(irq)" != "$I0" ]; then echo "ABORT: real touch at step $1"; pkill -INT screenrecord; exit 3; fi; }
shot() { screencap -d 4630946316123810436 -p $D/$RUN-$1.png; }
mon() { echo "monitors[$1]: $(dumpsys input | grep -c 'name=\[Gesture Monitor\] powos-gestures')  focus: $(dumpsys window | grep -m1 mCurrentFocus | sed 's/.*u0 //;s/}//')"; }
rec() { screenrecord --display-id 4630946316123810436 --bit-rate 40000000 --time-limit $2 $D/$1.mp4 & sleep 1.2; }
home_flick() { input swipe 558 2475 558 1300 140; }
hold_up() { input motionevent DOWN 558 2475; input motionevent MOVE 558 2380; input motionevent MOVE 558 2250; input motionevent MOVE 558 2100; input motionevent MOVE 558 1950; input motionevent MOVE 558 1850; sleep 1.0; input motionevent UP 558 1850; }
settings() { am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10200000 -n com.android.settings/.Settings >/dev/null; }
mon start
case $RUN in
A) # home from page 2
  rec A 16; chk 0
  input swipe 900 1300 150 1300 220; sleep 1.5; chk 1; shot page2; mon page2
  settings; sleep 2; chk 2; mon app
  home_flick; sleep 3; chk 3; shot end; mon home ;;
B) # home from PowOS AI page
  rec B 16; chk 0
  input swipe 150 1300 950 1300 220; sleep 1.5; chk 1; shot aipage; mon aipage
  settings; sleep 2; chk 2; mon app
  home_flick; sleep 3; chk 3; shot end; mon home ;;
C) # switcher from home, then from an app
  rec C 30; chk 0
  hold_up; sleep 2; chk 1; shot sw_home; mon switcher_from_home
  home_flick; sleep 2; chk 2; mon back_home
  settings; sleep 2; chk 3
  hold_up; sleep 2; chk 4; shot sw_app; mon switcher_from_app
  home_flick; sleep 2.5; chk 5; shot end; mon home ;;
D) # home from PowOS AI page (swipe right from page 1, away from the side-gesture edge)
  rec D 18; chk 0
  input swipe 350 1400 1060 1400 350; sleep 1.5; chk 1; shot aipage; mon aipage
  settings; sleep 2; chk 2; mon app
  home_flick; sleep 3; chk 3; shot end; mon home ;;
R) # restore: back to page 1 if on the AI page
  input swipe 1000 1400 200 1400 300; sleep 1; shot restored ;;
esac
wait
echo done $RUN
