# desktop-windows.sh: the windows-over-the-home check (board task powos-home-as-the-desktop-linux-android-apps-as).
# Run as root on the phone, only while the user has the PowOS desktop (the Plasma session) open - it skips otherwise:
#   tools/phone/adb.sh push tools/phone/record/desktop-windows.sh /data/local/tmp/ &&
#   tools/phone/adb.sh shell su -c "sh /data/local/tmp/desktop-windows.sh"   (after AWAKE_ONLY=1 tools/phone/idle.sh --wait 120 MAX)
# Opens Konsole and Settings as an Android window (powos-android-app), screencaps every display before / with them /
# after Konsole closes (desk-<n>-<display>.png in /data/local/tmp), warns on a real touch. The Settings window stays.
top=$(dumpsys activity activities | grep -m1 topResumedActivity)
echo "$top"
case "$top" in *com.powos.app*) ;; *) echo "SKIP: PowOS isn't in front"; exit 4;; esac
case "$top" in *HomeShell*|*ShellActivity*|*LockActivity*|*Switcher*) echo "SKIP: not the desktop"; exit 4;; esac
irq() { awk '/touch-0/{s+=$2+$3+$4+$5+$6+$7+$8+$9} END{print s}' /proc/interrupts; }
I0=$(irq)
DS=$(dumpsys SurfaceFlinger --display-id | sed -n 's/^Display \([0-9]*\).*/\1/p')
shot() { for D in $DS; do screencap -d $D -p /data/local/tmp/desk-$1-$D.png; done; }
shot 0
sh /data/powos/powos-run.sh 'setsid konsole >/dev/null 2>&1 & setsid powos-android-app com.android.settings Settings >/dev/null 2>&1 &'
sleep 8
shot 1
[ "$(irq)" != "$I0" ] && echo "WARN: the user touched during the check"
sh /data/powos/powos-run.sh 'pkill -u powos -x konsole'
sleep 2
shot 2
chmod 644 /data/local/tmp/desk-*.png
echo "displays $DS done"
