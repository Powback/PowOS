#!/bin/bash
# The phone's quiet "update applied" notification, after anything lands on it (an APK, a shell push, an app, the
# system module, the rootfs or a package): one plain line for the user - what changed for them ("Switcher now follows
# your finger"), never a commit or a file. Silent, shade only (comms' low priority), in the PowOS AI feed too. Notes
# fold into one notification - within 2 minutes of each other, or while the last one is unread (up to 30 minutes) -
# that lists the changes one per line, newest first: "Update installed · 3 changes" and up to 4, then "and N more".
#   targets/android/tools/deploy-note.sh "<what changed, for the user>"
#   targets/android/tools/deploy-note.sh --silent "<what landed>"   a change the user can't see (refactor, lint,
#                                    tooling): no notification, only a line in comms' quiet log (`powos comms quiet`)
# Runs `powos comms notify --from deploy --priority low --batch deploy` inside PowOS (one su call). Through $ADB like
# apps/install.sh: ADB="docker exec powos-vadb adb" (the VPN), or plain adb. Best effort: a phone that can't be reached
# doesn't fail the deploy that called it.
set -uo pipefail
silent=""
[ "${1:-}" = --silent ] && { silent=1; shift; }
note=${1:-}
[ -n "${note// }" ] || [ -n "$silent" ] || { echo "deploy-note.sh: a note is required: what changed, for the user" >&2; exit 2; }
[ -n "${note// }" ] || note="a silent update"
ADB=${ADB:-adb}
# Base64 through the quoting layers (adb shell -> su -c -> powos-run.sh -> bash -lc); comms reads it from stdin.
b=$(printf '%s' "$note" | base64 | tr -d '\n')
$ADB shell "su -c \"sh /data/powos/powos-run.sh 'echo $b | base64 -d | powos comms notify --from deploy ${silent:+--silent} --priority low --batch deploy -'\"" >/dev/null ||
  echo "deploy-note.sh: the phone wasn't told (\"$note\")" >&2
exit 0
