#!/bin/sh
# phone-update.sh - updates an installed phone's PowOS image package by package (docs/PHONE-UPDATES.md), rooted or not:
# the [powos] repo in the PowApps store (http://android.pow/apk/repo: KWin, FEX, box64, ... and powos-core, PowOS's own
# code - targets/android/build-powos-core.sh). A new base image is only for fresh installs.
#
#   phone-update.sh            upgrade from [powos] (its own pacman config with only that repo: Arch's databases are
#                              never refreshed, so this can't make a partial upgrade), then powos-core when the repo's
#                              is newer or the image has none yet
#   phone-update.sh --check    what would change (a private copy of the databases; the real ones stay untouched)
#   phone-update.sh --system   the same with Arch Linux ARM's repos too: a full -Syu, [powos] first (the image's
#                              IgnorePkg keeps Plasma at our KWin's version)
#   phone-update.sh --session  the app's run (session start, Settings): as the default, never fails the caller
#   --force                    even while a game runs
#   --retry                    packages that failed before are tried now, not after their backoff (Settings' check)
# Lines "#step <what>", "#fail <package> <reason>" and "#done <ok|fail|busy|game>" are for the app (PowosUpdates.kt):
# its progress notification, and the failures it names in Settings > system updates.
# Phones without root (a split base image): packages whose pack the phone hasn't added are never upgraded here, and a
# package that fails is retried with backoff (30 min, doubling, at most a day) and named with pacman's reason in
# $POWOS_UPDATE_FAILURES (Settings reads it) - 11-25 S25: "it failed to install some linux updates", nothing more.
# Runs inside the image: pacman under the image's own loader, `sudo` = the non-root session's fake root.
set -u
# POWOS_UPDATE_CONF: another pacman config (a test repo); the default is the one the app writes.
C=${POWOS_UPDATE_CONF:-/etc/pacman.d/powos-repo.conf}
mode=apply session="" force="" retry=""
for a in "$@"; do
  case "$a" in
    --check) mode=check ;;
    --system) mode=system ;;
    --session) session=1 ;;
    --force) force=1 ;;
    --retry) retry=1 ;;
    *) echo "usage: phone-update.sh [--check|--system] [--session] [--force] [--retry]" >&2; exit 2 ;;
  esac
done
SUDO=""; [ "$(id -u)" = 0 ] || SUDO=sudo
done_() { echo "#done $1"; [ -n "$session" ] && exit 0; [ "$1" = ok ] && exit 0; exit 1; }

# One update at a time (session start and Settings can meet).
exec 9>"${TMPDIR:-/tmp}/powos-phone-update.lock"
if command -v flock >/dev/null 2>&1 && ! flock -n 9; then echo "phone-update: another update is running"; done_ busy; fi

# Never under a running game: its libraries would change beneath it.
game_running() { pgrep -f '/steamapps/common/|/usr/bin/powos-play|wine64-preloader|wine-preloader|proton waitforexitandrun' >/dev/null 2>&1; }
if [ -z "$force" ] && [ "$mode" != check ] && game_running; then echo "phone-update: a game is running - later"; done_ game; fi

# A pacman killed mid-run (the app's process ended with the session) leaves its lock, and every later run failed with
# "unable to lock database" (razr, 11-09: no update for a day). Ours is the only updater (the lock above), so a db.lck
# with no pacman running is stale.
LCK=${POWOS_PACMAN_LOCK:-/var/lib/pacman/db.lck}
if [ -e "$LCK" ] && ! pgrep -x pacman >/dev/null 2>&1; then
  echo "phone-update: removing a stale pacman lock"; $SUDO rm -f "$LCK"
fi

if [ ! -s "$C" ]; then
  # HACK: SigLevel TrustAll - the repo is unsigned (plain HTTP, LAN/VPN only); same as SessionService step 0b. Real fix:
  # sign the packages in build-pkgs.sh with a PowOS key and ship its public key in the rootfs keyring.
  $SUDO mkdir -p /etc/pacman.d
  printf '[options]\nArchitecture = auto\nDisableSandbox\nSigLevel = Optional TrustAll\n\n[powos]\nServer = http://android.pow/apk/repo\n' | $SUDO tee "$C" >/dev/null
fi
conf=$C
if [ "$mode" = system ]; then
  # /etc/pacman.conf with [powos] ahead of every repo (pacman takes a package from the first repo that has it).
  conf=${TMPDIR:-/tmp}/powos-full-pacman.conf
  awk -v c="$C" 'BEGIN { while ((getline l < c) > 0) if (l ~ /^\[powos\]/ || s) { s = 1; r = r l "\n" } }
    /^\[/ && $0 != "[options]" && !done { printf "%s\n", r; done = 1 } { print }' /etc/pacman.conf > "$conf"
fi

# Away from home on the WireGuard VPN the store's name may not resolve (the non-root image's resolv.conf is a fixed
# 8.8.8.8, Android's Private DNS, a tunnel without Pi-hole's DNS), while the hub itself answers: every peer routes
# 192.168.50.0/24, and Traefik admits the VPN's addresses to .pow names. pacman then downloads through curl with the
# name pinned to the hub's address (the Host header stays android.pow, which Traefik routes by). No public route (#2).
# HACK: a fixed hub address (PowosUpdates.kt UpdatePlan.HUB, the same). Real fix: the host directory's hub row
# (docs/REMOTE-POWOS.md §2) or the public release channel #2 plans for phones off the owner's VPN.
HUB=${POWOS_UPDATE_HUB:-192.168.50.100}
store_resolves() { getent hosts android.pow >/dev/null 2>&1; }
if ! store_resolves && command -v curl >/dev/null 2>&1 && grep -q '^Server = http://android.pow/' "$conf"; then
  echo "phone-update: android.pow doesn't resolve - the hub by address ($HUB)"
  pinned=${TMPDIR:-/tmp}/powos-pinned-pacman.conf
  awk -v x="XferCommand = /usr/bin/curl -fL -C - --connect-timeout 5 --retry 2 --resolve android.pow:80:$HUB -o %o %u" \
    '{ print } /^\[options\]/ { print x }' "$conf" > "$pinned"
  conf=$pinned
fi

if [ "$mode" = check ]; then
  t=$(mktemp -d "${TMPDIR:-/tmp}/powos-update-check.XXXXXX")
  ln -s /var/lib/pacman/local "$t/local"
  if $SUDO pacman --config "$conf" -Sy --dbpath "$t" --logfile /dev/null >/dev/null 2>&1; then
    pacman --config "$conf" -Qu --dbpath "$t" 2>/dev/null
    pacman -Q powos-core >/dev/null 2>&1 || pacman --config "$conf" -Si --dbpath "$t" powos-core 2>/dev/null |
      sed -n 's/^Version *: */powos-core (not installed) -> /p' | head -1
    rm -rf "$t"; done_ ok
  fi
  rm -rf "$t"; echo "phone-update: the repo isn't reachable (android.pow, or $HUB by address: home network or the PowOS VPN only)"; done_ fail
fi

# Failures, one line each: "<package>\t<tries>\t<next try, epoch s>\t<reason>" ("[powos]" for the repo's upgrade). The
# app reads it for Settings > system updates (PowosUpdates.failures); a success removes the package's line.
F=${POWOS_UPDATE_FAILURES:-/var/lib/powos/update-failures}
NOW=${POWOS_UPDATE_NOW:-$(date +%s)}
st_set() { # st_set <package> [<reason>]: no reason = it worked
  t=$(mktemp "${TMPDIR:-/tmp}/powos-update-failures.XXXXXX")
  [ -f "$F" ] && awk -F'\t' -v p="$1" '$1 != p' "$F" > "$t"
  if [ -n "${2:-}" ]; then
    k=$(( $(st_tries "$1") + 1 )); d=1800; i=1
    while [ $i -lt $k ] && [ $d -lt 86400 ]; do d=$((d * 2)); i=$((i + 1)); done
    [ $d -gt 86400 ] && d=86400
    printf '%s\t%s\t%s\t%s\n' "$1" "$k" "$((NOW + d))" "$2" >> "$t"
  fi
  { mkdir -p "$(dirname "$F")" 2>/dev/null && cat "$t" > "$F"; } 2>/dev/null || { $SUDO mkdir -p "$(dirname "$F")"; $SUDO cp "$t" "$F"; $SUDO chmod 644 "$F"; }
  rm -f "$t"
}
st_tries() { [ -f "$F" ] && awk -F'\t' -v p="$1" '$1 == p { print $2; f = 1 } END { if (!f) print 0 }' "$F" || echo 0; }
# waiting <package>: it failed and its backoff hasn't passed (--retry: never)
waiting() { [ -z "$retry" ] && [ -f "$F" ] && awk -F'\t' -v p="$1" -v now="$NOW" '$1 == p && $3 > now { f = 1 } END { exit !f }' "$F"; }
# why <pacman output file>: pacman's reason in a line - its first error, a dropped mirror version said plainly
why() {
  if grep -q "failed retrieving file\|returned error: 404" "$1"; then
    echo "the mirror no longer has this version"
  elif grep -q "target not found" "$1"; then echo "no repo here has it"
  elif grep -qi "not enough free disk space\|No space left" "$1"; then echo "not enough free space"
  elif grep -qi "could not resolve host\|Could not resolve\|connection timed out\|Failed to connect" "$1"; then echo "no connection to the package mirror"
  else
    r=$(grep -m1 '^error:' "$1" | sed 's/^error: *//'); [ -n "$r" ] || r=$(grep -v '^ *$' "$1" | tail -1)
    printf '%.160s\n' "${r:-pacman failed}"
  fi
}
fail() { echo "#fail $1 $2"; st_set "$1" "$2"; }
# run_pkg <log> <pacman args...>: pacman with its output both shown and kept
run_pkg() { o=$1; shift; "$@" > "$o" 2>&1; r=$?; cat "$o"; return $r; }
OUT=$(mktemp "${TMPDIR:-/tmp}/powos-update-out.XXXXXX")
B=${POWOS_BASE_SYNC:-/usr/lib/powos/phone-base-sync.py}

echo "#step packages"
ok=1
# Packages from a pack this phone hasn't added stay as they are (a split base only; nothing on a full rootfs).
ign=powos-core
if [ "$mode" != check ] && [ -f "$B" ]; then
  ours_all=" $(pacman --config "$conf" -Slq powos 2>/dev/null | tr '\n' ' ') "
  for p in $(python3 "$B" --away 2>/dev/null); do
    case "$ours_all" in *" $p "*) ign="$ign,$p" ;; esac
  done
  [ "$ign" != powos-core ] && echo "phone-update: not here (their pack isn't added): ${ign#powos-core,}"
fi
if run_pkg "$OUT" $SUDO pacman --config "$conf" -Syu --noconfirm --ignore "$ign"; then st_set "[powos]"
else ok=0; fail "[powos]" "$(why "$OUT")"; fi
# powos-core: the first time over the files the base image put there unowned (self_phone_apply, the session map),
# hence --overwrite; after that only when the repo's is newer (-S would also take an older one).
echo "#step powos"
have=$(pacman -Q powos-core 2>/dev/null | cut -d' ' -f2)
repo=$(pacman --config "$conf" -Si powos-core 2>/dev/null | sed -n 's/^Version *: *//p' | head -1)
if [ -n "$repo" ] && { [ -z "$have" ] || [ "$(vercmp "$repo" "$have")" -gt 0 ]; }; then
  if run_pkg "$OUT" $SUDO pacman --config "$conf" -S --noconfirm --overwrite '*' powos-core; then st_set powos-core
  else ok=0; fail powos-core "$(why "$OUT")"; fi
else
  echo "powos-core ${have:-not in the repo} is current"
fi
# The base: packages a newer base image has that this phone's doesn't (an image split before they joined the base left
# their files in a pack the phone never added - razr 11-10: no SpacetimeDB). phone-base-sync.py (from powos-core) names
# them; [powos] reinstalls its own (spacetimedb), Arch's are reinstalled at the version installed (never an upgrade
# without -Sy: the image's own sync databases), and one missing everywhere is left for its pack (Settings > Storage).
# One transaction per package: one that can't come no longer takes the rest down with it.
# Arch Linux ARM keeps no old versions: a base's exact version 404s within days (11-25: fzf 0.74.5-1 and gh 2.103.3-1
# of the 11-14 base already gone), and every session start failed the whole step on the S25. Then the mirror's current
# version, from a private copy of the databases, only when that transaction is that package alone (pacman pulls no
# other upgrade: what it links is satisfied by what's installed) - never a partial upgrade.
echo "#step base"
fresh=""
fresh_db() {
  [ -n "$fresh" ] && return 0
  fresh=$(mktemp -d "${TMPDIR:-/tmp}/powos-update-fresh.XXXXXX")
  ln -s /var/lib/pacman/local "$fresh/local"
  $SUDO pacman -Sy --dbpath "$fresh" --logfile /dev/null >/dev/null 2>&1
}
arch_take() { # arch_take <package>: at the installed version, else the mirror's when it needs nothing else
  run_pkg "$OUT" $SUDO pacman -S --noconfirm "$1" && return 0
  grep -q "failed retrieving file\|returned error: 404" "$OUT" || return 1
  fresh_db || return 1
  t=$(pacman -S --print --print-format %n --dbpath "$fresh" "$1" 2>/dev/null)
  if [ "$t" != "$1" ]; then
    printf 'the mirror no longer has its version and the current one needs other upgrades (%s) - add its pack in Settings > Storage\n' \
      "$(echo $t | tr ' ' ',')" > "$OUT"
    return 1
  fi
  echo "phone-update: $1: the installed version is gone from the mirror - the mirror's (nothing else changes)"
  run_pkg "$OUT" $SUDO pacman -S --noconfirm --dbpath "$fresh" "$1"
}
if [ "$mode" != check ] && [ -f "$B" ]; then
  ours="" arch=""
  for p in $(python3 "$B" 2>/dev/null); do
    if waiting "$p"; then echo "phone-update: $p failed before ($(awk -F'\t' -v p="$p" '$1 == p { print $4 }' "$F")) - tried again later"; continue; fi
    if pacman --config "$conf" -Si "$p" >/dev/null 2>&1; then ours="$ours $p"
    elif v=$(pacman -Si "$p" 2>/dev/null | sed -n 's/^Version *: *//p' | head -1) && [ -n "$v" ] &&
         [ "$v" = "$(pacman -Q "$p" 2>/dev/null | cut -d' ' -f2)" ]; then arch="$arch $p"
    else echo "phone-update: $p isn't in this image's base and no repo here has its version - add its pack (Settings > Storage)"
    fi
  done
  [ -z "$ours$arch" ] && echo "the base is complete"
  # Seen on the phone however the run started (the session's start runs it with no notification of its own).
  prog() { command -v powos-progress >/dev/null 2>&1 && powos-progress base-sync "$@" >/dev/null 2>&1; :; }
  set -- $ours $arch; total=$#; n=0; failed=""
  [ "$total" -gt 0 ] && { echo "phone-update: adding to the base:$ours$arch"; prog 0 "$total" "Adding to the Linux image:$ours$arch"; }
  for p in $ours; do
    if run_pkg "$OUT" $SUDO pacman --config "$conf" -S --noconfirm "$p"; then st_set "$p"; else ok=0; r=$(why "$OUT"); fail "$p" "$r"; failed="$failed, $p ($r)"; fi
    n=$((n + 1)); prog "$n" "$total" "Adding to the Linux image:$ours$arch"
  done
  for p in $arch; do
    if arch_take "$p"; then st_set "$p"; else ok=0; r=$(why "$OUT"); fail "$p" "$r"; failed="$failed, $p ($r)"; fi
    n=$((n + 1)); prog "$n" "$total" "Adding to the Linux image:$ours$arch"
  done
  # The app's own run says it in its notification (PowosUpdates); the session start's run has only this one.
  if [ "$total" -gt 0 ]; then
    if [ -z "$failed" ] || [ -z "$session" ]; then prog done
    else prog failed "Couldn't add ${failed#, } - tried again later; Settings > system updates"; fi
  fi
fi
[ -n "$fresh" ] && rm -rf "$fresh"
rm -f "$OUT"
[ $ok = 1 ] && done_ ok
done_ fail
