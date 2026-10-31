#!/system/bin/sh
# powos-periodic.sh (phone, Android's side, as root; unit units/phone-android/powos-periodic.json): the phone's timers,
# one loop for all of them - PowOS on the phone has no systemd, so nothing else would run them on a clock:
#   every 10 min  the App API health check (unit app-api-health) as the powos user inside PowOS; the result's last
#                 lines in /data/powos/state/app-api-health.txt (the runtime down = exit 1, logged as DOWN)
#   every 15 min  both sides' units to the PowOS AI page (powos units publish: phone + phone-android), so a host's
#                 age there is never more than ~15 min unless publishing fails (the page then says "stale")
# Started at boot by powos-start.sh and (re)started by powos-deploy.sh; one at a time (its pidfile).
#   sh /data/powos/powos-periodic.sh run     the loop (what boot starts)
#   sh /data/powos/powos-periodic.sh once    one pass of everything now (publish: only the units, what a ship runs)
#   sh /data/powos/powos-periodic.sh stop    the running loop ended
R=/data/powos/root
P=/data/powos/powos-periodic.pid
L=/data/powos/state/periodic.log
mkdir -p /data/powos/state

log() { echo "$(date '+%F %T') $*" >> "$L"; }
health() {
  out=$(chroot $R /usr/bin/setpriv --reuid=powos --regid=powos --init-groups /usr/bin/env -i PATH=/usr/bin:/usr/sbin \
    HOME=/home/powos bash /usr/lib/powos/app-api/health-check.sh 2>&1); rc=$?
  { date '+%F %T'; echo "$out" | tail -12; } > /data/powos/state/app-api-health.txt
  [ $rc = 0 ] || log "app-api health: DOWN (rc $rc): $(echo "$out" | grep -m1 DOWN)"
}
publish() {
  chroot $R /usr/bin/env -i PATH=/usr/bin:/usr/sbin python3 /usr/lib/powos/apps/powos-units publish > /dev/null 2>&1 ||
    log "publish phone failed (rc $?)"
  sh /data/powos/powos-units.sh publish > /dev/null 2>&1 || log "publish phone-android failed (rc $?)"
}

case "${1:-run}" in
run)
  o=$(cat $P 2>/dev/null); [ -n "$o" ] && [ "$o" != $$ ] && kill -0 "$o" 2>/dev/null && { echo "running (pid $o)"; exit 0; }
  echo $$ > $P
  t=0
  while :; do
    [ $((t % 600)) = 0 ] && health
    [ $t -gt 0 ] && [ $((t % 900)) = 0 ] && publish
    # The log kept small: its last 200 lines.
    [ -f "$L" ] && [ "$(wc -l < "$L")" -gt 400 ] && { tail -200 "$L" > "$L.new" && mv "$L.new" "$L"; }
    sleep 300; t=$((t + 300))
  done ;;
once) health; publish ;;
publish) publish ;;
stop) o=$(cat $P 2>/dev/null); [ -n "$o" ] && kill "$o" 2>/dev/null; rm -f $P ;;
*) sed -n 2,12p "$0"; exit 2 ;;
esac
