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
# Lines "#step <what>" and "#done <ok|fail|busy|game>" are for the app's progress notification (PowosUpdates.kt).
# Runs inside the image: pacman under the image's own loader, `sudo` = the non-root session's fake root.
set -u
# POWOS_UPDATE_CONF: another pacman config (a test repo); the default is the one the app writes.
C=${POWOS_UPDATE_CONF:-/etc/pacman.d/powos-repo.conf}
mode=apply session="" force=""
for a in "$@"; do
  case "$a" in
    --check) mode=check ;;
    --system) mode=system ;;
    --session) session=1 ;;
    --force) force=1 ;;
    *) echo "usage: phone-update.sh [--check|--system] [--session] [--force]" >&2; exit 2 ;;
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

echo "#step packages"
ok=1
$SUDO pacman --config "$conf" -Syu --noconfirm --ignore powos-core || ok=0
# powos-core: the first time over the files the base image put there unowned (self_phone_apply, the session map),
# hence --overwrite; after that only when the repo's is newer (-S would also take an older one).
echo "#step powos"
have=$(pacman -Q powos-core 2>/dev/null | cut -d' ' -f2)
repo=$(pacman --config "$conf" -Si powos-core 2>/dev/null | sed -n 's/^Version *: *//p' | head -1)
if [ -n "$repo" ] && { [ -z "$have" ] || [ "$(vercmp "$repo" "$have")" -gt 0 ]; }; then
  $SUDO pacman --config "$conf" -S --noconfirm --overwrite '*' powos-core || ok=0
else
  echo "powos-core ${have:-not in the repo} is current"
fi
[ $ok = 1 ] && done_ ok
done_ fail
