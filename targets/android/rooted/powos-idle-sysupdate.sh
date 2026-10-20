#!/system/bin/sh
# One-shot, armed by the PowOS manager (pushed to /data/local/tmp and started as root, in the background): re-base
# com.powos.app on its current /system/priv-app copy so PM grants the privileged permissions the new system copy
# declares (e.g. BIND_APPWIDGET), then reinstall the current /data update. Runs only when the user is away (screen
# off, no touch 10+ min, no call) and on AC or >30% battery; gives up after 12 h.
#
# The re-base itself is powos-appdata.sh rebase: `pm uninstall-system-updates` WIPES the app's data dir (2026-10-20:
# the home layout, widgets, installed apps, chat, mail - all gone), so it backs the data up first, refuses without a
# good backup, and restores it after the reinstall. This script refuses to arm without it. Never call
# `pm uninstall-system-updates` directly (docs/APP-DATA-BACKUP.md).
LOG=/data/local/tmp/powos-idle-sysupdate.log
SAVE=/data/local/tmp/powos-current.apk
APPDATA=/data/powos/powos-appdata.sh
[ -f "$APPDATA" ] || { echo "$(date) REFUSED: no $APPDATA (rooted.sh deploy) - would wipe the app's data unbacked" >> $LOG; exit 3; }
# The backup must work now, before waiting for idle (a broken one found at 4 am helps nobody).
t=$(sh "$APPDATA" backup armed) && sh "$APPDATA" check "$t" > /dev/null ||
  { echo "$(date) REFUSED: the app-data backup failed (see /data/powos/appdata.log)" >> $LOG; exit 3; }
cp "$(pm path com.powos.app | grep /data/app | head -1 | cut -d: -f2)" $SAVE || { echo "$(date) no /data apk, abort" >> $LOG; exit 1; }
echo "$(date) armed (backup $t), saved $(dumpsys package com.powos.app | grep -m1 versionCode)" >> $LOG
i=0
while [ $i -lt 720 ]; do
  i=$((i + 1)); sleep 60
  wake=$(dumpsys power | grep -o 'mWakefulness=[A-Za-z]*' | head -1)
  ago=$(dumpsys power | grep -o 'lastUserActivityTime=[0-9]* ([0-9]* ms ago)' | head -1 | sed 's/.*(\([0-9]*\) ms ago)/\1/')
  call=$(dumpsys telephony.registry | grep -o 'mCallState=[0-9]' | sort -u | tr '\n' ' ')
  lvl=$(dumpsys battery | grep -m1 ' level:' | tr -dc 0-9); ac=$(dumpsys battery | grep -c 'AC powered: true')
  case "$wake" in *Awake*) continue ;; esac
  [ -n "$ago" ] && [ "$ago" -gt 600000 ] || continue
  case "$call" in *=1*|*=2*) continue ;; esac
  [ "$ac" = 1 ] || [ "${lvl:-0}" -gt 30 ] || continue
  echo "$(date) idle ($wake, ${ago} ms, battery $lvl ac=$ac): rebasing" >> $LOG
  # Backup (fresh, at this moment) -> uninstall-system-updates -> reinstall $SAVE -> restore; refuses on a bad backup.
  sh "$APPDATA" rebase $SAVE >> $LOG 2>&1
  rc=$?
  dumpsys package com.powos.app | grep -E 'versionCode|BIND_APPWIDGET' >> $LOG
  sleep 45
  g=$(dumpsys package com.powos.app | grep -c 'BIND_APPWIDGET: granted=true')
  sh /data/powos/powos-run.sh "powos comms send manager 'sysupdate rebase finished (exit $rc), app data backed up and restored by powos-appdata.sh; BIND_APPWIDGET granted lines: $g. Log: $LOG' --from manager" >> $LOG 2>&1
  echo "$(date) done (exit $rc, granted lines: $g)" >> $LOG
  exit $rc
done
echo "$(date) gave up after 12 h" >> $LOG
