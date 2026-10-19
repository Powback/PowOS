#!/bin/sh
# powos-vadb's health check (compose.yaml, every minute). Exit 0 = healthy, 1 = unhealthy.
#
# Unhealthy when:
#   - adb has no device (VPN down, phone off, adb authorization lost); or
#   - the agents mirror is stale: powos-rootsh's per-tag status (/state/status, written on the Mac) shows pushes being
#     tried and none landing for VADB_STALE_MIN minutes. "No pushes at all" is not stale: the Mac's powos-agentsd only
#     pushes on change and exits when its agents are idle.
#
# A stale mirror mails the phone's manager once per outage (`powos comms send manager ... --from vadb`), and once more
# when pushes land again. With adb down the mail can't go out; it is retried every check, and an outage that ended
# before any alert got through is reported once on recovery. Alerting costs one su, and only on those events.
set -u
S=/state/status
TAG=mirror
N=${VADB_STALE_MIN:-10}
now=$(date +%s)
num() { v=$(cat "$1" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
ago() { echo "$(( ($now - $1) / 60 )) min"; }

mail() { # mail <priority> <text>: to the phone's manager, as vadb. Plain text only (no quotes) by construction.
  [ "${VADB_ALERT:-1}" = 1 ] || { echo "vadb-health: (alerts off) $2"; return 0; }
  msg=$(printf '%s' "$2" | tr -d "'\"\\\\\`\$")
  timeout 30 adb -s "$ANDROID_SERIAL" shell -T \
    "su -c \"sh /data/powos/powos-run.sh 'powos comms send manager \\\"$msg\\\" --from vadb --priority $1'\"" \
    >/dev/null 2>&1
}

healthy=0
st=$(adb -s "$ANDROID_SERIAL" get-state 2>/dev/null || true)
if [ "$st" != device ]; then
  echo "vadb-health: $ANDROID_SERIAL ${st:-unreachable}"
  healthy=1
fi

ok=$(num "$S/$TAG.ok")
since=$(num "$S/$TAG.fail_since")
alerted=$(num "$S/$TAG.alerted")     # fail_since of the outage whose alert went out
reported=$(num "$S/$TAG.reported")   # fail_since of the outage whose recovery was reported

if [ "$since" -gt "$ok" ] && [ $((now - since)) -ge $((N * 60)) ]; then
  # Stale now.
  echo "vadb-health: $TAG stale: failing for $(ago "$since"), last success $([ "$ok" -gt 0 ] && ago "$ok" || echo never)"
  healthy=1
  if [ "$alerted" != "$since" ] && [ "$st" = device ]; then
    mail high "The Mac's agents mirror to the phone is stale: pushes have failed for $(ago "$since") (powos-vadb health check). The Agents view shows the Mac's agents as of the last push. Check: docker logs powos-vadb, and powos-rootsh status on the Mac." &&
      echo "$since" > "$S/$TAG.alerted"
  fi
elif [ "$since" -gt 0 ] && [ "$ok" -gt "$since" ] && [ $((ok - since)) -ge $((N * 60)) ] && [ "$reported" != "$since" ]; then
  # An outage long enough to count has ended: say so once.
  if [ "$alerted" = "$since" ]; then
    text="The Mac's agents mirror to the phone is back: pushes landing again after $(( (ok - since) / 60 )) min."
  else
    text="The Mac's agents mirror to the phone was stale for $(( (ok - since) / 60 )) min (the alert could not be delivered: adb was down). Pushes are landing again."
  fi
  if [ "$st" = device ]; then
    mail normal "$text" && echo "$since" > "$S/$TAG.reported"
  fi
fi
exit $healthy
