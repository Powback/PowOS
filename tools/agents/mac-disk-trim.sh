#!/bin/bash
# tools/agents/mac-disk-trim.sh [--dry-run] (Mac): hand space freed inside the Colima VM back to macOS, and once a week
# remove long-dead loose containers. Run every 20 min by the launchd agent com.powos.mac-disk-trim (unit
# units/mac/mac-disk-trim-mac.json, installed by mac-disk-trim-deploy.sh); replaces the manager's crontab lines.
#
# Why: Colima's VM disk is a sparse file on the Mac's data volume. Space freed inside the VM (a removed container, a
# deleted layer) stays allocated on the Mac until the VM's filesystem is trimmed, so the Mac ran down to 2 GB free
# (10-2x) with the VM holding tens of GB of freed blocks. fstrim returns them.
#
#   every pass       `colima ssh -- sudo fstrim /mnt/lima-colima` (--dry-run: fstrim -n, nothing discarded)
#   weekly (7 days)  `docker rm` of stopped containers that are ALL of: exited/created, finished more than 7 days ago,
#                    NOT part of a compose project (autosleep's hibernate tier stops compose containers and wakes
#                    them by starting them again - removing one would break its wake), NOT labelled powos.autosleep.
#                    `docker rm` without -v: their volumes stay.
# NEVER: the Docker build cache (`docker builder prune`, `system prune`), images, volumes, or any file. The user needs
# the build cache and build images for dev (17:4x decision: the 27 + 17 GB build images stay).
#
# State + log: ~/.cache/powos-mac-disk-trim/ (trim.log, last-prune).
set -u
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
S=$HOME/.cache/powos-mac-disk-trim
PRUNE_EVERY_S=${PRUNE_EVERY_S:-604800}
DEAD_FOR_S=${DEAD_FOR_S:-604800}
mkdir -p "$S"
log() { echo "$(date '+%F %T') $*" >> "$S/trim.log"; [ $DRY = 1 ] && echo "$*"; return 0; }
cap() { perl -e 'alarm shift; exec @ARGV' "$@"; }
free_gb() { df -g /System/Volumes/Data | awk 'NR==2 {print $4}'; }

before=$(free_gb)
colima status >/dev/null 2>&1 || { log "colima not running: nothing to trim"; exit 0; }

# ── weekly: long-dead loose containers ─────────────────────────────────────────────────────────────────────────────
now=$(date +%s); last=$(cat "$S/last-prune" 2>/dev/null || echo 0)
if [ $DRY = 1 ] || [ $((now - last)) -ge "$PRUNE_EVERY_S" ]; then
  ids=$(cap 60 docker ps -aq --filter status=exited --filter status=created 2>/dev/null)
  rm_ids=()
  for id in $ids; do
    # one line: name|compose project|autosleep label|finished|created
    row=$(cap 30 docker inspect -f '{{.Name}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "powos.autosleep"}}|{{.State.FinishedAt}}|{{.Created}}' "$id" 2>/dev/null) || { log "skip $id: docker inspect cannot read it"; continue; }
    IFS='|' read -r name proj sleep fin created <<< "$row"
    [ -z "$proj" ] && [ -z "$sleep" ] || { log "keep ${name#/}: compose=${proj:--} autosleep=${sleep:--}"; continue; }
    t=$fin; case "$t" in 0001-*|"") t=$created ;; esac
    ts=$(python3 -c 'import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1][:19]).replace(tzinfo=datetime.timezone.utc).timestamp()))' "$t" 2>/dev/null) || continue
    if [ $((now - ts)) -lt "$DEAD_FOR_S" ]; then log "keep ${name#/}: stopped < $((DEAD_FOR_S / 86400)) days"; continue; fi
    rm_ids+=("$id"); log "$([ $DRY = 1 ] && echo 'dry-run: would remove' || echo remove) ${name#/} ($id, stopped since $t)"
  done
  if [ $DRY = 0 ]; then
    [ ${#rm_ids[@]} -gt 0 ] && cap 120 docker rm "${rm_ids[@]}" >/dev/null 2>&1
    echo "$now" > "$S/last-prune"
  fi
fi

# ── every pass: trim the VM's filesystem so the sparse disk shrinks on the Mac ─────────────────────────────────────
if [ $DRY = 1 ]; then out=$(cap 300 colima ssh -- sudo fstrim -nv /mnt/lima-colima 2>&1); else out=$(cap 300 colima ssh -- sudo fstrim -v /mnt/lima-colima 2>&1); fi
log "fstrim$([ $DRY = 1 ] && echo ' (dry-run)'): ${out:-no output} | Mac free ${before} -> $(free_gb) GB"
# keep the log short
tail -500 "$S/trim.log" > "$S/trim.log.tmp" 2>/dev/null && mv "$S/trim.log.tmp" "$S/trim.log"
exit 0
