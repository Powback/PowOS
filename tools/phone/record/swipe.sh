# swipe.sh: run as root on the phone (run.sh pushes it): home -> PowOS AI's page -> Settings, then a recorded swipe
# home from the app and a second one on home, screencaps after each. Injected input only; aborts on a real touch IRQ.
# Output in /data/local/tmp/hg* (root's screenrecord can't write /sdcard). Display id: the cover screen.
irq() { awk '/touch-0/{s+=$2+$3+$4+$5+$6+$7+$8+$9} END{print s}' /proc/interrupts; }
I0=$(irq)
chk() { [ "$(irq)" != "$I0" ] && { echo "ABORT real touch at $1"; pkill -INT screenrecord; exit 3; }; }
D=4630946316123810436
am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1; sleep 1.5; chk 0
# to PowOS AI's page (a swipe right on home's first page)
input swipe 350 1400 1060 1400 350; sleep 1.5; chk 1
screencap -d $D -p /data/local/tmp/hg-ai.png
am start -W -n com.android.settings/.Settings >/dev/null 2>&1; sleep 2.5; chk 2
logcat -c
echo rec_start $(date +%s.%N)
screenrecord --display-id $D --bit-rate 40000000 --time-limit 9 /data/local/tmp/hg.mp4 &
R=$!
sleep 1.5
echo swipe1 $(date +%s.%N)
input swipe 558 2475 558 1300 140
sleep 2.5; chk 3
screencap -d $D -p /data/local/tmp/hg-after1.png
echo swipe2 $(date +%s.%N)
input swipe 558 2475 558 1300 140
sleep 2.5; chk 4
screencap -d $D -p /data/local/tmp/hg-after2.png
wait $R
logcat -d -v epoch > /data/local/tmp/hg.log
chmod 644 /data/local/tmp/hg*
