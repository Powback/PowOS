#!/bin/bash
# The warm CDP runner (unit units/mac/cdp-warm-mac.json): ONE long-lived oven/bun container per Mac user,
# powos-cdp-warm-<user>, in powos-vadb's network, that tools/phone/cdp.sh `docker exec`s cdp.ts in instead of a fresh
# `docker run` per call. 2026-11-09 at Mac load ~25 the per-call container create+start cost 7-10 s, so checks doing
# 20-50 page evals hit their 300 s budgets (shade-scroll, needs-me-reply, glass-sync-accept).
#   sourced by cdp.sh: cdp_warm_run <port> <cdp.ts args...>   returns 75 when the warm path couldn't run (caller falls
#                                                            back to the per-call container), else cdp.ts's own rc
#   tools/phone/cdp-warm.sh status | stop
# - Concurrent callers: every call is its own `docker exec` (own bun process); a start race (two callers creating it)
#   is settled by docker's name conflict, the loser uses the winner's container.
# - Reconnect: the adb forward is still made by cdp.sh on every call and each bun connects afresh, so a new app pid or
#   forward is picked up as before. The container is labelled with the powos-vadb container id whose network it
#   shares; a recreated powos-vadb (new namespace) makes the next call replace it.
# - Idle: the container exits by itself (and --rm removes it) once no bun has run for CDP_WARM_IDLE_S (900 s): each
#   call touches $CDP_WARM_DIR/last, which it reads through its mount.
# - Fallback: a call whose `docker exec` never reached cdp.ts (no run marker written) returns 75 - docker's own
#   "No such container" is rc 1 like cdp.ts's "no page", so the marker, not the rc, tells them apart.
# Overrides (tests): CDP_DOCKER (docker client), CDP_WARM_DIR, CDP_WARM_NAME, CDP_NETNS (container whose network).
CDP_DOCKER=${CDP_DOCKER:-docker}
CDP_WARM_DIR=${CDP_WARM_DIR:-$HOME/.cache/powos-cdp}
CDP_WARM_NAME=${CDP_WARM_NAME:-powos-cdp-warm-${USER:-$(id -un)}}
CDP_NETNS=${CDP_NETNS:-powos-vadb}
CDP_WARM_IDLE_S=${CDP_WARM_IDLE_S:-900}

# The container's own loop: exit when no bun process is running and the last call is older than the idle limit.
# (/proc/*/exe, not cmdline: this script's own text says "bun".)
cdp_warm_loop='while sleep 20; do
  for p in /proc/[0-9]*; do [ "$(readlink $p/exe 2>/dev/null)" = /usr/local/bin/bun ] && continue 2; done
  last=$(stat -c %Y /s/last 2>/dev/null || echo 0)
  [ $(( $(date +%s) - last )) -gt "$IDLE" ] && exit 0
done'

# Make sure the container runs in the current powos-vadb namespace. rc 0 = ready. No forks but docker's own: at Mac
# load ~25 every fork costs 50-100 ms, so the parsing is bash builtins.
cdp_warm_ensure() {
  local want have out
  [ -d "$CDP_WARM_DIR" ] || mkdir -p "$CDP_WARM_DIR" 2>/dev/null || return 1
  : > "$CDP_WARM_DIR/last" 2>/dev/null || return 1
  # One inspect for both, a line each: "/<name>|<netns label>|<running>|<id>" (a missing container has no line).
  out=$("$CDP_DOCKER" inspect --format '{{.Name}}|{{if .Config.Labels}}{{index .Config.Labels "powos.cdp.netns"}}{{end}}|{{.State.Running}}|{{.Id}}' "$CDP_NETNS" "$CDP_WARM_NAME" 2>/dev/null)
  local line
  want= have=
  while IFS= read -r line; do
    case "$line" in
      "/$CDP_NETNS|"*) want=${line##*|} ;;
      "/$CDP_WARM_NAME|"*) have=${line#*|}; have=${have%|*} ;;
    esac
  done <<<"$out"
  [ -n "$want" ] || return 1
  [ "$have" = "$want|true" ] && return 0
  # Stale (other namespace) or stopped: replace it.
  [ -n "$have" ] && "$CDP_DOCKER" rm -f "$CDP_WARM_NAME" >/dev/null 2>&1
  "$CDP_DOCKER" run -d --rm --name "$CDP_WARM_NAME" --label powos.unit=cdp-warm-mac --label "powos.cdp.netns=$want" \
    --memory 1g --cpus 2 --network "container:$CDP_NETNS" -e "IDLE=$CDP_WARM_IDLE_S" -v "$CDP_WARM_DIR:/s" \
    oven/bun:1 sh -c "$cdp_warm_loop" >/dev/null 2>&1 && return 0
  # Lost a start race to another caller: use theirs once it runs (created-not-yet-started for a moment), if it is the
  # right one.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    have=$("$CDP_DOCKER" inspect --format '{{index .Config.Labels "powos.cdp.netns"}}|{{.State.Running}}' "$CDP_WARM_NAME" 2>/dev/null)
    [ "$have" = "$want|true" ] && return 0
    [ -n "$have" ] || return 1
    sleep 0.5
  done
  return 1
}

cdp_warm_run() {
  local port=$1 src dst script mark rc
  shift
  [ "${CDP_WARM:-1}" = 0 ] && return 75
  cdp_warm_ensure || return 75
  # The caller's own cdp.ts (worktrees differ), copied into the shared dir under a name from its path, refreshed when
  # the source is newer: no per-worktree mounts, no hashing fork per call.
  src=${CDP_TS:-${BASH_SOURCE[0]%/*}/cdp.ts}
  script=cdp-${src//[^A-Za-z0-9]/_}.ts
  dst=$CDP_WARM_DIR/$script
  if [ ! -s "$dst" ] || [ "$src" -nt "$dst" ]; then
    cp -p "$src" "$dst.$$" && mv -f "$dst.$$" "$dst" || return 75
  fi
  mark=run.$$.$RANDOM
  "$CDP_DOCKER" exec -i -e CDP_TIMEOUT_S -e "CDP_PORT=$port" "$CDP_WARM_NAME" \
    sh -c 'touch "/s/$1"; s=$2; shift 2; exec bun "/s/$s" "$@"' sh "$mark" "$script" "$@"
  rc=$?
  if [ -e "$CDP_WARM_DIR/$mark" ]; then
    rm -f "$CDP_WARM_DIR/$mark"
    return $rc
  fi
  return 75
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-status}" in
    status) "$CDP_DOCKER" inspect --format '{{.Name}} running={{.State.Running}} netns={{index .Config.Labels "powos.cdp.netns"}} started={{.State.StartedAt}}' "$CDP_WARM_NAME" 2>/dev/null || echo "$CDP_WARM_NAME: not running" ;;
    stop) "$CDP_DOCKER" rm -f "$CDP_WARM_NAME" >/dev/null 2>&1; rm -f "$CDP_WARM_DIR"/cdp-*.ts* "$CDP_WARM_DIR"/run.*; echo stopped ;;
    *) echo "usage: cdp-warm.sh status | stop" >&2; exit 2 ;;
  esac
fi
