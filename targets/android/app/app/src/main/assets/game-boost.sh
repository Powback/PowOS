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
# 1.79-2.05 / 1.59-1.71 GHz on gold/prime) owns that policy's max: the boost lifts it once at the start (a stale
# request goes, freqs_unstale) and never again (it did, every second, and horae wrote its cap back - the "set back by
# someone else" fights), then only holds the min up to the controller's cap. While it
# holds under such a controller the vendor classes the front app as a game (vendor_game_class), so the controller's
# own game table applies; normal PowOS use stays on its default table.
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
BOOST_MIN_ALL=${BOOST_MIN_ALL:-0}
SETTINGS=${GAME_BOOST_SETTINGS:-settings}
# The vendor's game class (Settings.Global; GameBoost.VENDOR_GAME_KEY, read by targets/android/oplus-hook): the boosted
# game's app id while the boost holds under a vendor thermal controller, deleted on every restore.
VENDOR_GAME_KEY=powos_game_front
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
  # The lowest policy (the little cluster): where the holder itself runs, off the game's cores.
  LITTLE=$(for p in $P/policy*; do echo "$(cat $p/cpuinfo_max_freq) ${p##*/}"; done | sort -n | head -n 1 | cut -d' ' -f2)
  LITTLE_MASK=$(mask $(cpus_of "$LITTLE"))
  # Each policy's hw max and boost min, once: constants, and the holder re-reads the limits every second.
  for p in $BOOSTED; do read -r hw < $P/$p/cpuinfo_max_freq; eval HW_$p=$hw LO_$p=$(boost_min $p); done
  # The skin sensor the vendor's thermal controller gears on (OxygenOS: skin-msm-therm), for the cap lines' context.
  SKIN=; for z in ${GAME_BOOST_THERMAL:-/sys/class/thermal}/thermal_zone*; do
    { read -r ty < $z/type; } 2>/dev/null && [ "$ty" = skin-msm-therm ] && SKIN=$z/temp && break; done
  return 0
}
skin() { [ -n "$SKIN" ] && { read -r c < $SKIN; } 2>/dev/null && echo ", skin $((c / 1000)).$((c / 100 % 10)) C"; }
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
  echo "$t ${g:-/} $m" >> "$S/tids"; KNOWN="$KNOWN $t"
  echo $t > $CG/tasks 2>/dev/null
  [ -n "$REST_MASK" ] && taskset -p $REST_MASK $t > /dev/null 2>&1
}
# Threads' cpu time (utime + stime ticks), "tid pid ticks" - the comm may hold spaces: fields after the last ") ".
ticks() {
  for p in $PIDS; do for f in /proc/$p/task/[0-9]*; do
    { read -r s < $f/stat; } 2>/dev/null || continue; r=${s##*) }; set -- $r; echo "${f##*/} $p $(( ${12} + ${13} ))"
  done; done
}

# The userspace thermal controller writing the cpufreq limits, if any: OxygenOS' horae (found by its program name), or
# a process (not this one) holding a policy's scaling_max_freq open FOR WRITING. Not a reader: oiface (OnePlus' game
# daemon) holds every policy's scaling_min/max_freq open read-only and its main thread is named "horaeCb" - the comm
# match this had until 11-12 took it for horae (measured 11-12: oiface pid 6394, comm horaeCb, all its cpufreq fds
# lr-x; horae pid 6382 holds none, it writes and closes). Looked up once per hold (a /proc fd scan).
thermal_owner() {
  pidof horae > /dev/null 2>&1 && { echo horae; return; }
  for d in /proc/[0-9]*; do
    [ "${d#/proc/}" = $$ ] && continue
    ls -l $d/fd 2>/dev/null | grep -Eq "^l.w.* -> .*cpufreq/policy[0-9]+/scaling_max_freq" || continue
    cat $d/comm 2>/dev/null; return
  done
}

# HACK: the vendor's thermal table is picked per front Android package and the PowOS app is "common_config" (appType -1,
# caps from gear 3), while a game (appType 4 -> category_4 of sys_thermal_control_config*.xml) keeps full clocks to gear
# 5. com.oplus.battery's appType comes from DeepThinker, else OifaceManager.getInstalledGameList(), and a positive
# answer is cached until the package is uninstalled - so registering com.powos.app as a game (Game Space / oiface)
# would keep every later PowOS use on the game table. Instead this marks the game in front in Settings.Global and the
# PowOS Vector module (oplus-hook, scope com.oplus.battery) answers appType 4 for com.powos.app only while it is set.
# Real fix: a vendor API that classes a running game per window/process (or the Linux game as its own Android task
# whose package the vendor knows as a game), then drop the marker and the hook.
vendor_game_class() {
  if [ -n "$1" ]; then
    $SETTINGS put global $VENDOR_GAME_KEY "$1" > /dev/null 2>&1 && date +%s > "$S/vendor_game" && log "vendor game class on: $1"
  elif [ -n "$($SETTINGS get global $VENDOR_GAME_KEY 2>/dev/null | grep -v '^null$')" ]; then
    $SETTINGS delete global $VENDOR_GAME_KEY > /dev/null 2>&1; log "vendor game class off"
  fi
}

freqs_save() {
  [ -s "$S/freqs" ] && return   # a killed holder's: those are the originals, not what it set
  for p in $BOOSTED; do echo "$p $(cat $P/$p/scaling_min_freq) $(cat $P/$p/scaling_max_freq)"; done > "$S/freqs"
}
# Under a thermal controller: its max request is lifted to the hw max ONCE, at the hold's start, then never again. The
# sysfs scaling_max_freq is one request shared by every writer, and reading it gives the effective max - so a value
# read and written back later (a restore of a cap seen at save time, a killed holder's leftovers) became a request of
# its own that no controller lifts again: 11-12 the OnePlus sat at gold/prime 1.65/1.36 GHz (vendor cpu level 5 on
# those two, the little cluster uncapped - no level of the vendor table) from the 11-10 boot on at skin 26 C, through
# every boosted launch, because the boost "kept" it as the controller's. A live gear cap is re-applied by the
# controller itself (11-06: horae set a lifted max back within a second) and from then on stands; a stale one is gone.
# HACK: a blind one-shot lift because the controller's live gear isn't readable here (horae has no query; its gear is
# com.oplus.battery's). Real fix: read the controller's current cpu level (or have it publish one) and lift only when
# that level is uncapped.
freqs_unstale() {
  for p in $BOOSTED; do
    eval hw=\$HW_$p; read -r cap < $P/$p/scaling_max_freq
    [ "$cap" = "$hw" ] && continue
    echo $hw > $P/$p/scaling_max_freq; read -r now < $P/$p/scaling_max_freq
    log "$p: max $cap lifted to hw $hw once (now $now) - $THERMAL re-applies a live gear cap, which then stands"
  done
}

# Lift - max first, the min then fits under it - and re-assert each second.
# HACK: raw cpufreq sysfs writes, re-asserted every second, where no thermal controller owns the limits. On OxygenOS
# the owner is horae (thermal_owner): it applies com.oplus.battery's skin-temperature gear through the app's thermal
# category, and the PowOS app is "common_config" (appType -1) - a game package (e.g. com.tencent.tmgp.sgame's section)
# gets no cpu cap until gear 10, the default table caps from gear 3. Real fix: have the vendor class the game as a game
# (its Game Space / app category, or a section for the game in its thermal profile) so its own table lifts the cap.
freqs_lift() {
  # Shell builtins only (read, eval, test): this runs every second for the whole game, and each fork costs ~1 ms of a
  # core on the phone - the holder was 6-13 % of a core in play (11-06 live capture), mostly cat/grep forks.
  for p in $BOOSTED; do
    eval hw=\$HW_$p lo=\$LO_$p
    read -r cap < $P/$p/scaling_max_freq; read -r min < $P/$p/scaling_min_freq
    if [ -n "$THERMAL" ]; then
      # The thermal controller's cap stands; the min goes up to it (never past: a min above the max is refused).
      [ "$lo" -gt "$cap" ] && lo=$cap
      eval was=\${CAP_$p:-}
      [ "$was" != "$cap" ] && eval CAP_$p=$cap && if [ "$cap" = "$hw" ]; then log "$p: no thermal cap (hw $hw) under $THERMAL$(skin)"
        else log "$p: thermal cap $cap of hw $hw by $THERMAL$(skin) - kept"; fi
      # Heat is what moves the controller's gear: only the main thread's policy (the prime core) holds its min up;
      # the other big clusters (render/dxvk/workers, none pegged) clock on demand - their threads' uclamp.min 75 asks
      # schedutil for the clock while they run - instead of idling at the capped top voltage (BOOST_MIN_ALL=1: all).
      [ "$p" != "$TOP" ] && [ "$BOOST_MIN_ALL" != 1 ] && continue
      [ "$min" -lt "$lo" ] && echo $lo > $P/$p/scaling_min_freq
      continue
    fi
    if [ "$cap" != "$hw" ]; then
      [ "$LIFTED" = 1 ] && FIGHTS=$((FIGHTS + 1)) && log "$p: max set back to $cap by someone else: $hw again"
      echo $hw > $P/$p/scaling_max_freq
    fi
    [ "$min" -lt "$lo" ] && echo $lo > $P/$p/scaling_min_freq
  done
  LIFTED=1
}

restore_all() {
  if [ -s "$S/freqs" ]; then
    # Min first (the saved min is below the lifted max), then the saved max.
    # Under a thermal controller its max is live (it may be lower now): only the min goes back, never above that max.
    th=$(cat "$S/thermal" 2>/dev/null)
    while read -r p lo hi; do
      # A saved min pinned to a capped max (min == max < hw) is a snapshot of an earlier boost's min clamped under that
      # cap (the leftovers 11-12 found: policy3 1651200 1651200, policy7 1363200 1363200 - every restore put the
      # gold/prime clusters back at a fixed clock), not anyone's request: the policy's floor instead.
      [ "$lo" = "$hi" ] && [ "$hi" -lt "$(cat $P/$p/cpuinfo_max_freq)" ] && lo=$(cat $P/$p/cpuinfo_min_freq)
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
  vendor_game_class ""
  rm -f "$S/vendor_game" "$S/freqs" "$S/tids" "$S/ticks" "$S/main" "$S/app" "$S/holder.pid" "$S/thermal"
}

# The placement holds: the main thread's affinity still the prime core alone (a builtin read of its status, no fork).
# The kernel rewrites a thread's mask behind our back when its cpuset's cpus change (a cpu paused / brought back, or
# the cpuset rewritten): 11-06 14:25 live play had the game's main thread on cpu4 with Cpus_allowed 0-7. Then every
# known thread gets its mask again (the reset hits them all); the forks only on a reset.
allowed() { a=; while read -r k v; do [ "$k" = Cpus_allowed_list: ] && a=$v && break; done < /proc/$1/status; echo "$a"; } 2>/dev/null
placed() {
  m=; { read -r m < "$S/main"; } 2>/dev/null; [ -n "$m" ] && [ -d /proc/$m ] || return 0
  a=$(allowed $m); [ -z "$a" ] || [ "$a" = "$PRIME" ] && return 0
  RESETS=$((RESETS + 1))
  log "$APP: main thread $m on cpus $a (its mask was reset): cpu$PRIME again, the other threads back off it"
  [ -n "$REST_MASK" ] && for t in $KNOWN; do [ "$t" != "$m" ] && taskset -p $REST_MASK $t > /dev/null 2>&1; done
  taskset -p $PRIME_MASK $m > /dev/null 2>&1
}

hold() {
  APP=$1 LEASE=$2
  echo $$ > "$S/holder.pid"; echo "$APP" > "$S/app"; : > "$S/tids"
  trap 'log "$APP: restore asked"; restore_all; exit 0' TERM INT HUP
  topology || { log "$APP: no cpufreq policies"; restore_all; exit 1; }
  # The controller first, then the originals: a holder killed in between (the /proc scan takes a while) left saved
  # freqs without the controller, and the next restore wrote its capped max back as a request of its own.
  THERMAL=${GAME_BOOST_OWNER-$(thermal_owner)}; echo "$THERMAL" > "$S/thermal"
  freqs_save
  # The holder itself on the little cores: its 1 s loop never shares the prime / gold cores with the game (11-06 14:25
  # live capture: an unpinned sh at 10.5 % on cpu7).
  [ -n "$LITTLE_MASK" ] && taskset -p $LITTLE_MASK $$ > /dev/null 2>&1
  [ -n "$THERMAL" ] && freqs_unstale
  [ -n "$THERMAL" ] && vendor_game_class "$APP"
  mkdir -p $CG && echo $BOOST_UCLAMP > $CG/cpu.uclamp.min 2>/dev/null
  log "$APP: boost (policies $(echo $BOOSTED | tr '\n' ' '), prime cpu$PRIME, rest mask ${REST_MASK:-none}, uclamp.min $(cat $CG/cpu.uclamp.min 2>/dev/null), thermal controller ${THERMAL:-none}$([ -n "$THERMAL" ] && [ "$BOOST_MIN_ALL" != 1 ] && echo ": min held on $TOP only"), holder on mask ${LITTLE_MASK:-?})"
  LIFTED=0 FIGHTS=0 RESETS=0 i=0 seen=0 why= PIDS= KNOWN=
  while :; do
    now=$(date +%s); at=$(stat -c %Y "$LEASE" 2>/dev/null || echo 0)
    [ $((now - at)) -gt $LEASE_S ] && { why="the app's lease is $((now - at)) s old (the game left the front, or the app died)"; break; }
    freqs_lift
    if [ $((i % 5)) = 0 ]; then
      # The full scan (every process's environ: ~1000 on the phone) until the game is seen, then every 30 s for its new
      # processes; in between the known ones, as long as one lives (a test, no fork).
      live=; for p in $PIDS; do [ -d /proc/$p ] && live="$live $p"; done
      if [ $seen = 0 ] || [ -z "$live" ] || [ $((i % 30)) = 0 ]; then PIDS=$(game_pids | sort -u | tr '\n' ' '); else PIDS=$live; fi
      if [ -z "$PIDS" ]; then
        [ $seen = 1 ] && { why="the game's processes are gone"; break; }
      else
        seen=1
        ticks > "$S/ticks.new"
        for p in $PIDS; do for f in /proc/$p/task/[0-9]*; do t=${f##*/}
          case "$KNOWN " in *" $t "*) ;; *) adopt $t $p ;; esac
        done; done
        # The frame loop: the thread that used the most cpu since the last look; on the prime core (the one before back
        # on the rest) - moved only when the pinned one used under half of it, so two busy threads don't swap each time.
        # Both deltas over the same 5 s (the pinned one's too: it was compared by its lifetime total, which kept the
        # first pick - e.g. a loading thread at launch - on the prime core for good).
        { read -r old < "$S/main"; } 2>/dev/null || old=
        hot=$(awk -v o="$old" 'NR == FNR { a[$1] = $3; next } { d = $3 - (($1 in a) ? a[$1] : $3); if ($1 == o) od = d; if (d > b) { b = d; t = $1 } } END { print t, b + 0, od + 0 }' \
          "$S/ticks" "$S/ticks.new" 2>/dev/null)
        [ -f "$S/ticks" ] || hot=
        mv -f "$S/ticks.new" "$S/ticks"
        set -- $hot; ht=$1 hd=${2:-0} od=${3:-0}
        placed
        if [ -n "$ht" ] && [ "$hd" -gt 0 ] && [ "$ht" != "$old" ]; then
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
  log "$APP: restore - $why (HAL fights: $FIGHTS, placement resets: $RESETS)"
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
    m=$(cat "$S/main" 2>/dev/null)
    alive "$h" && echo "holder $h app $(cat "$S/app" 2>/dev/null) main $m threads $({ wc -l < "$S/tids"; } 2>/dev/null)" || echo "holder none"
    # Where the main thread may run and last ran (stat field 39): the placement check (prime = the highest policy's last cpu).
    [ -n "$m" ] && [ -d /proc/$m ] && echo "main $m allowed $(allowed $m) last cpu $(s=$(cat /proc/$m/stat); set -- ${s##*) }; echo ${37})"
    for p in $P/policy*; do echo "policy ${p##*/} min $(cat $p/scaling_min_freq) max $(cat $p/scaling_max_freq) hw $(cat $p/cpuinfo_max_freq) cur $(cat $p/scaling_cur_freq)"; done
    [ -s "$S/thermal" ] && echo "thermal $(cat "$S/thermal")"
    echo "vendor_game $($SETTINGS get global $VENDOR_GAME_KEY 2>/dev/null) since $(cat "$S/vendor_game" 2>/dev/null || echo -)"
    echo "uclamp.min $(cat $CG/cpu.uclamp.min 2>/dev/null || echo none) tasks $({ wc -l < $CG/tasks; } 2>/dev/null || echo 0)"
    [ -s "$S/freqs" ] && echo "saved $(tr '\n' ';' < "$S/freqs")"
    tail -n 5 "$S/log" 2>/dev/null ;;
  *) echo "usage: $0 engage <app id> <lease file> | restore | status"; exit 2 ;;
esac
