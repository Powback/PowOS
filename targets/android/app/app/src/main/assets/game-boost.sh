#!/system/bin/sh
# game-boost.sh (phone, Android's side, as root - the PowOS app runs it through its root shell; GameBoost.kt): the
# CPU boost while a game window is the one the user plays (board broforce-games-black-noise-flicker-artifacts-ove,
# docs/research/broforce-fps.md). Generic for every game: the app says WHICH game is in front (its app id: steam_app_<id>
# or a Game desktop id), this finds its processes and threads.
#   sh game-boost.sh engage <app id> <lease file>   boost that game (a holder loop of its own, setsid) until the lease
#                                                  goes stale, the game exits or `restore` - one game at a time
#   sh game-boost.sh restore                       everything back as it was (also after a holder killed with -9)
#   sh game-boost.sh status                        one line per fact (tools/phone/verify/game-boost.sh reads it)
#
# What the boost is (Broforce measured CPU-bound: its main thread 95 % of one core, on gold/prime cores the vendor's
# performance HAL capped to 1.92 / 1.71 GHz of 2.80 / 3.19, migrating across cpu3-7, uclamp.min 0):
#   clocks   every cpufreq policy but the lowest (the little cluster): scaling_max_freq = its hw max, scaling_min_freq
#            = the highest available step <= BOOST_MIN_PCT (80) % of it; originals saved first, put back on restore
#   uclamp   the game's threads in /dev/cpuctl/powos-game with cpu.uclamp.min BOOST_UCLAMP (75 % = 768 of 1024): a
#            TOP-LEVEL group, since a child's uclamp.min is capped by its parent's (Android's /dev/cpuctl/powos has 0)
#   affinity the hottest thread of the game (its frame loop) on the highest-capacity core (cpu7, the X3 prime), every
#            other thread of the game on the other big cores (cpu3-6); each thread's own mask and cpu group saved
# Thermal limits stay as they are: thermal-engine's caps are cpufreq QoS requests of their own, which a sysfs
# scaling_max_freq never overrides (the effective max is the lowest request), and no cooling device is touched. A
# userspace thermal controller that writes scaling_min/max_freq itself (OxygenOS: horae, holding them open, applies
# com.oplus.battery's ThermalController gear - skin temperature -> a cpu level from
# /odm/etc/temperature_profile/sys_thermal_control_config*.xml; measured 11-03: gear 3-8 at 35-39 C put
# 1.79-2.05 / 1.59-1.71 GHz on gold/prime) owns that policy's max: the boost never raises it (it did, every second,
# and horae wrote its cap back - the "set back by someone else" fights), only holds the min up to its cap.
#
# A crash-safe lease: the app touches <lease file> every second while the game is in front; the holder restores
# everything when it is older than LEASE_S (the app died, froze or was killed), when the game's processes are gone, or
# on SIGTERM (restore). A holder killed outright leaves its saved state behind, which the next engage/restore applies.
S=${GAME_BOOST_STATE:-/data/powos/state/game-boost}
CPUCTL=${GAME_BOOST_CPUCTL:-/dev/cpuctl}
CG=$CPUCTL/powos-game
P=${GAME_BOOST_CPUFREQ:-/sys/devices/system/cpu/cpufreq}
LEASE_S=${LEASE_S:-4}
BOOST_MIN_PCT=${BOOST_MIN_PCT:-80}
BOOST_UCLAMP=${BOOST_UCLAMP:-75}
mkdir -p "$S"

log() {
  [ -f "$S/log" ] && [ "$(stat -c %s "$S/log" 2>/dev/null || echo 0)" -gt 65536 ] && mv -f "$S/log" "$S/log.1"
  echo "$(date '+%F %T') $*" >> "$S/log"
}
alive() { [ -n "$1" ] && [ -d "/proc/$1" ] && grep -q 'game-boost' "/proc/$1/cmdline" 2>/dev/null; }

# The boosted policies: every one but the lowest-capacity (by hw max). The prime core: the last cpu of the highest one.
policies() {
  for p in $P/policy*; do echo "$(cat $p/cpuinfo_max_freq) ${p##*/}"; done | sort -n | sed 1d | cut -d' ' -f2
}
mask() { m=0; for c in "$@"; do m=$((m | (1 << c))); done; printf '%x' $m; }
cpus_of() { cat $P/$1/related_cpus; }
topology() {
  BOOSTED=$(policies)
  TOP=$(echo "$BOOSTED" | tail -n 1)
  [ -n "$TOP" ] || return 1
  PRIME=$(cpus_of "$TOP" | tr ' ' '\n' | grep . | tail -n 1)
  rest=$(for p in $BOOSTED; do cpus_of $p; done | tr ' ' '\n' | grep . | grep -vx "$PRIME")
  PRIME_MASK=$(mask $PRIME)
  REST_MASK=$([ -n "$rest" ] && mask $rest)
}
# The highest available step <= pct % of the policy's hw max (its own steps: a write between steps rounds anyway).
boost_min() {
  hw=$(cat $P/$1/cpuinfo_max_freq); want=$((hw * BOOST_MIN_PCT / 100)); best=$(cat $P/$1/cpuinfo_min_freq)
  for f in $(cat $P/$1/scaling_available_frequencies 2>/dev/null); do [ "$f" -le "$want" ] && [ "$f" -gt "$best" ] && best=$f; done
  echo $best
}

# The game's processes: a Steam game's carry SteamAppId / SteamGameId = <id> in their environment (Steam sets it for
# everything it starts for the game: the reaper, Proton, wineserver, FEX, the game); any other game's are the ones
# whose name is its desktop file's Exec program (or the app id's last part). Never the compositor, X or Steam itself.
game_pids() {
  case "$APP" in
    steam_app_*)
      n=${APP#steam_app_}
      grep -lzx -e "SteamAppId=$n" -e "SteamGameId=$n" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3 ;;
    *)
      exe=
      for d in /data/powos/root/usr/share/applications /data/powos/root/home/powos/.local/share/applications \
        /data/powos/root/var/lib/flatpak/exports/share/applications; do
        [ -f "$d/$APP.desktop" ] && exe=$(sed -n 's/^Exec=//p' "$d/$APP.desktop" | head -n 1 | awk '{print $1}') && break
      done
      exe=${exe##*/}; [ -n "$exe" ] || exe=${APP##*.}
      want=$(echo "$exe" | cut -c1-15)
      for d in /proc/[0-9]*; do [ "$(cat $d/comm 2>/dev/null)" = "$want" ] && echo ${d#/proc/}; done ;;
  esac | while read -r p; do
    case "$(cat /proc/$p/comm 2>/dev/null)" in kwin_wayland|Xwayland|steam|steamwebhelper|"") ;; *) echo $p ;; esac
  done
}

# A thread joins the boost: its cpu group and mask saved (tid group mask), then the game group and the big cores.
adopt() {
  t=$1; f=/proc/$2/task/$t
  g=$(sed -n 's/^[0-9]*:cpu:\(.*\)$/\1/p' $f/cgroup 2>/dev/null); m=$(taskset -p $t 2>/dev/null | awk '{print $NF}')
  [ -n "$m" ] || return
  echo "$t ${g:-/} $m" >> "$S/tids"
  echo $t > $CG/tasks 2>/dev/null
  [ -n "$REST_MASK" ] && taskset -p $REST_MASK $t > /dev/null 2>&1
}
# Threads' cpu time (utime + stime ticks), "tid pid ticks" - the comm may hold spaces: fields after the last ") ".
ticks() {
  for p in $PIDS; do for f in /proc/$p/task/[0-9]*; do
    s=$(cat $f/stat 2>/dev/null) || continue; r=${s##*) }; set -- $r; echo "${f##*/} $p $(( ${12} + ${13} ))"
  done; done
}

# The userspace thermal controller writing the cpufreq limits, if any: the comm of a process (not this one) holding
# a policy's scaling_max_freq open, when it is a thermal daemon (horae = OxygenOS' skin-temperature controller,
# thermal*). Looked up once per hold (a /proc fd scan).
thermal_owner() {
  for d in /proc/[0-9]*; do
    [ "${d#/proc/}" = $$ ] && continue
    ls -l $d/fd 2>/dev/null | grep -q "cpufreq/policy[0-9]*/scaling_max_freq" || continue
    c=$(cat $d/comm 2>/dev/null)
    case "$c" in horae*|thermal*) echo "$c"; return ;; esac
  done
}

freqs_save() {
  [ -s "$S/freqs" ] && return   # a killed holder's: those are the originals, not what it set
  for p in $BOOSTED; do echo "$p $(cat $P/$p/scaling_min_freq) $(cat $P/$p/scaling_max_freq)"; done > "$S/freqs"
}
# Lift - max first, the min then fits under it - and re-assert each second.
# HACK: raw cpufreq sysfs writes, re-asserted every second, where no thermal controller owns the limits. On OxygenOS
# the owner is horae (thermal_owner): it applies com.oplus.battery's skin-temperature gear through the app's thermal
# category, and the PowOS app is "common_config" (appType -1) - a game package (e.g. com.tencent.tmgp.sgame's section)
# gets no cpu cap until gear 10, the default table caps from gear 3. Real fix: have the vendor class the game as a game
# (its Game Space / app category, or a section for the game in its thermal profile) so its own table lifts the cap.
freqs_lift() {
  for p in $BOOSTED; do
    hw=$(cat $P/$p/cpuinfo_max_freq); lo=$(boost_min $p)
    if [ -n "$THERMAL" ]; then
      # The thermal controller's cap stands; the min goes up to it (never past: a min above the max is refused).
      cap=$(cat $P/$p/scaling_max_freq); [ "$lo" -gt "$cap" ] && lo=$cap
      eval was=\${CAP_$p:-}
      [ "$was" != "$cap" ] && eval CAP_$p=$cap && log "$p: thermal cap $cap of hw $hw by $THERMAL - kept"
      [ "$(cat $P/$p/scaling_min_freq)" -lt "$lo" ] && echo $lo > $P/$p/scaling_min_freq
      continue
    fi
    if [ "$(cat $P/$p/scaling_max_freq)" != "$hw" ]; then
      [ "$LIFTED" = 1 ] && FIGHTS=$((FIGHTS + 1)) && log "$p: max set back to $(cat $P/$p/scaling_max_freq) by someone else: $hw again"
      echo $hw > $P/$p/scaling_max_freq
    fi
    [ "$(cat $P/$p/scaling_min_freq)" -lt "$lo" ] && echo $lo > $P/$p/scaling_min_freq
  done
  LIFTED=1
}

restore_all() {
  if [ -s "$S/freqs" ]; then
    # Min first (the saved min is below the lifted max), then the saved max.
    # Under a thermal controller its max is live (it may be lower now): only the min goes back, never above that max.
    th=$(cat "$S/thermal" 2>/dev/null)
    while read -r p lo hi; do
      if [ -n "$th" ]; then cap=$(cat $P/$p/scaling_max_freq); [ "$lo" -gt "$cap" ] && lo=$cap; echo $lo > $P/$p/scaling_min_freq
      else echo $lo > $P/$p/scaling_min_freq; echo $hi > $P/$p/scaling_max_freq; fi
    done < "$S/freqs"
    log "clocks restored: $(tr '\n' ';' < "$S/freqs")"
  fi
  if [ -s "$S/tids" ]; then
    n=0
    while read -r t g m; do
      [ -d /proc/$t ] || continue
      d=$CPUCTL${g%/}; echo $t > $d/tasks 2>/dev/null || echo $t > $CPUCTL/tasks 2>/dev/null
      taskset -p $m $t > /dev/null 2>&1; n=$((n + 1))
    done < "$S/tids"
    log "threads restored: $n"
  fi
  # Anything that joined the group without a row (a thread the game made since: it inherits the group) to the root.
  [ -f $CG/tasks ] && for t in $(cat $CG/tasks); do echo $t > $CPUCTL/tasks 2>/dev/null; done
  rmdir $CG 2>/dev/null
  rm -f "$S/freqs" "$S/tids" "$S/ticks" "$S/main" "$S/app" "$S/holder.pid" "$S/thermal"
}

hold() {
  APP=$1 LEASE=$2
  echo $$ > "$S/holder.pid"; echo "$APP" > "$S/app"; : > "$S/tids"
  trap 'log "$APP: restore asked"; restore_all; exit 0' TERM INT HUP
  topology || { log "$APP: no cpufreq policies"; restore_all; exit 1; }
  freqs_save
  THERMAL=$(thermal_owner); echo "$THERMAL" > "$S/thermal"
  mkdir -p $CG && echo $BOOST_UCLAMP > $CG/cpu.uclamp.min 2>/dev/null
  log "$APP: boost (policies $(echo $BOOSTED | tr '\n' ' '), prime cpu$PRIME, rest mask ${REST_MASK:-none}, uclamp.min $(cat $CG/cpu.uclamp.min 2>/dev/null), thermal controller ${THERMAL:-none})"
  LIFTED=0 FIGHTS=0 i=0 seen=0 why=
  while :; do
    now=$(date +%s); at=$(stat -c %Y "$LEASE" 2>/dev/null || echo 0)
    [ $((now - at)) -gt $LEASE_S ] && { why="the app's lease is $((now - at)) s old (the game left the front, or the app died)"; break; }
    freqs_lift
    if [ $((i % 5)) = 0 ]; then
      PIDS=$(game_pids | sort -u | tr '\n' ' ')
      if [ -z "$PIDS" ]; then
        [ $seen = 1 ] && { why="the game's processes are gone"; break; }
      else
        seen=1
        ticks > "$S/ticks.new"
        for p in $PIDS; do for f in /proc/$p/task/[0-9]*; do t=${f##*/}
          grep -q "^$t " "$S/tids" || adopt $t $p
        done; done
        # The frame loop: the thread that used the most cpu since the last look; on the prime core (the one before back
        # on the rest) - moved only when the pinned one used under half of it, so two busy threads don't swap each time.
        hot=$(awk 'NR == FNR { a[$1] = $3; next } { d = $3 - (($1 in a) ? a[$1] : $3); if (d > b) { b = d; t = $1 } } END { print t, b + 0 }' \
          "$S/ticks" "$S/ticks.new" 2>/dev/null)
        [ -f "$S/ticks" ] || hot=
        mv -f "$S/ticks.new" "$S/ticks"
        set -- $hot; ht=$1 hd=${2:-0}; old=$(cat "$S/main" 2>/dev/null)
        if [ -n "$ht" ] && [ "$hd" -gt 0 ] && [ "$ht" != "$old" ]; then
          od=$(awk -v t="$old" '$1 == t { print $3 }' "$S/ticks"); od=${od:-0}
          if [ -z "$old" ] || [ ! -d /proc/$old ] || [ $((od * 2)) -lt "$hd" ] 2>/dev/null; then
            [ -n "$old" ] && [ -n "$REST_MASK" ] && taskset -p $REST_MASK $old > /dev/null 2>&1
            taskset -p $PRIME_MASK $ht > /dev/null 2>&1 && echo $ht > "$S/main"
            log "$APP: main thread $ht ($(cat /proc/$ht/comm 2>/dev/null), $hd ticks / 5 s) on cpu$PRIME"
          fi
        fi
      fi
    fi
    i=$((i + 1)); sleep 1
  done
  log "$APP: restore - $why (HAL fights: $FIGHTS)"
  restore_all
}

case "$1" in
  engage)
    [ -n "$2" ] && [ -n "$3" ] || { echo "usage: $0 engage <app id> <lease file>"; exit 2; }
    h=$(cat "$S/holder.pid" 2>/dev/null)
    if alive "$h"; then
      [ "$(cat "$S/app" 2>/dev/null)" = "$2" ] && { echo "engaged $2 (holder $h)"; exit 0; }
      kill -TERM $h; i=0; while alive "$h" && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
    fi
    alive "$h" && kill -KILL $h
    restore_all   # a dead holder's leftovers (no-op when the holder restored)
    setsid sh "$0" hold "$2" "$3" < /dev/null > /dev/null 2>> "$S/log" &
    echo "engaging $2" ;;
  hold) hold "$2" "$3" ;;
  restore)
    h=$(cat "$S/holder.pid" 2>/dev/null)
    if alive "$h"; then
      kill -TERM $h; i=0; while alive "$h" && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
      alive "$h" && { kill -KILL $h; log "holder $h didn't stop: killed"; }
    fi
    restore_all; echo restored ;;
  status)
    h=$(cat "$S/holder.pid" 2>/dev/null)
    alive "$h" && echo "holder $h app $(cat "$S/app" 2>/dev/null) main $(cat "$S/main" 2>/dev/null) threads $({ wc -l < "$S/tids"; } 2>/dev/null)" || echo "holder none"
    for p in $P/policy*; do echo "policy ${p##*/} min $(cat $p/scaling_min_freq) max $(cat $p/scaling_max_freq) hw $(cat $p/cpuinfo_max_freq) cur $(cat $p/scaling_cur_freq)"; done
    [ -s "$S/thermal" ] && echo "thermal $(cat "$S/thermal")"
    echo "uclamp.min $(cat $CG/cpu.uclamp.min 2>/dev/null || echo none) tasks $({ wc -l < $CG/tasks; } 2>/dev/null || echo 0)"
    [ -s "$S/freqs" ] && echo "saved $(tr '\n' ';' < "$S/freqs")"
    tail -n 5 "$S/log" 2>/dev/null ;;
  *) echo "usage: $0 engage <app id> <lease file> | restore | status"; exit 2 ;;
esac
