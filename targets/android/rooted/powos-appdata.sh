#!/system/bin/sh
# powos-appdata.sh - the PowOS app's own data (/data/data/com.powos.app), kept safe across anything that can wipe it.
# Run as root on the phone (installed at /data/powos/powos-appdata.sh by powos-deploy.sh).
#
# Why: `pm uninstall-system-updates com.powos.app` (re-basing the app on its /system/priv-app copy, e.g. so PM grants
# a privileged permission the new system copy declares) does not just drop the /data APK - Android wipes the app's
# data dir with it. On 2026-10-20 a one-shot runner did exactly that at night and took the home layout, the hosted
# Android widgets, the installed PowOS app UIs (files/apps), PowOS AI's chat, agent mail, WebView localStorage and the
# shell's store (files/shell-data), with no copy anywhere. Rule: never uninstall-system-updates (nor downgrade, nor
# clear the app's data) except through `rebase` below, which backs up first, refuses without a good backup, and puts
# the data back after the reinstall.
#
#   powos-appdata.sh backup [tag]   the whole data dir -> /data/powos/backup/app-data-<time>[-tag].tar (prints the path).
#                                   Left out: cache/, code_cache/, WebView's caches, files/run (the runtime dir: sockets,
#                                   logs; the app makes it anew) and files/tmp. Owners and SELinux labels are kept.
#   powos-appdata.sh restore <tar>  the app stopped; what's now at each path <tar> holds moved aside (to
#                                   /data/powos/backup/replaced-<time>/, never deleted), <tar> put back, owner = the app's
#                                   uid now, labels by restorecon (checked against the data dir's own label). Works for
#                                   a full and a light backup (a light one replaces only its own paths).
#   powos-appdata.sh rebase <apk>   backup -> pm uninstall-system-updates -> pm install -r -g <apk> -> restore. REFUSES
#                                   (exit 3, nothing touched) when the backup fails or doesn't hold the layout. The one
#                                   sanctioned way to re-base the app on its system copy.
#   powos-appdata.sh light          the small, precious part (shared_prefs: home layout, widget bindings, pins; files/:
#                                   shell-data, powos-ai, widgets, widget-state, style) -> /data/powos/root/var/backups/
#                                   powos-app/light-<time>.tar, only when something changed since the last one.
#   powos-appdata.sh watch          `light` once an hour (awake time), for good; one instance (started by powos-start.sh
#                                   at boot). A wipe loses at most an hour of layout/store changes, not everything.
#   powos-appdata.sh list           the backups there are, newest first.
# Kept: the 5 newest full backups, the 48 newest light ones (older ones of this script's own go; nothing else does).
set -u
PKG=com.powos.app
D=/data/data/$PKG
B=/data/powos/backup
LB=/data/powos/root/var/backups/powos-app
LOG=/data/powos/appdata.log
KEEP_FULL=5 KEEP_LIGHT=48
# Android's own tools, by path: Magisk runs boot scripts (service.d -> powos-start.sh -> watch) in its busybox ash in
# standalone mode, where a bare `tar` is busybox's applet - no --selinux, so every light backup failed ("light backup
# failed", 2026-10-20 17:49). Functions win over applets; a full path is never an applet.
tar() { /system/bin/toybox tar "$@"; }
stat() { /system/bin/toybox stat "$@"; }
restorecon() { /system/bin/restorecon "$@"; }
chcon() { /system/bin/chcon "$@"; }

log() { echo "$(date '+%F %T') $*" >> "$LOG"; echo "$*" >&2; }
die() { log "powos-appdata: $*"; exit "${2:-1}"; }
stamp() { date +%Y%m%d-%H%M%S; }
# Newest first, all but the $2 newest of the files matching $1 go.
prune() { ls -1t $1 2>/dev/null | tail -n +$(($2 + 1)) | while read -r f; do rm -f "$f"; done; }

backup() {
  [ -d "$D" ] || die "no $D (is $PKG installed?)"
  mkdir -p "$B" && chmod 700 "$B" || die "can't make $B"
  out=$B/app-data-$(stamp)${1:+-$1}.tar
  # Top-level entries by name (no "." - toybox doesn't filter command-line args, so cache/ is left out by not naming
  # it); the WebView's caches by name anywhere below.
  set --
  for e in "$D"/* "$D"/.[!.]*; do
    [ -e "$e" ] || continue
    case ${e##*/} in cache|code_cache) continue ;; esac
    set -- "$@" "${e##*/}"
  done
  [ $# -gt 0 ] || die "$D is empty: nothing to back up"
  if ! tar -cf "$out.part" -C "$D" --numeric-owner --selinux \
      --exclude=files/run --exclude=files/tmp --exclude=no_backup/.webview \
      --exclude=Cache --exclude='Code Cache' --exclude=GPUCache --exclude=CacheStorage --exclude=ScriptCache \
      --exclude=DawnGraphiteCache --exclude=DawnWebGPUCache --exclude='BrowserMetrics*' "$@" 2>> "$LOG"; then
    rm -f "$out.part"; die "backup failed (tar, see $LOG)"
  fi
  mv "$out.part" "$out" && chmod 600 "$out"
  log "backup: $out ($(($(stat -c %s "$out") / 1024)) KB)"
  prune "$B/app-data-*.tar" $KEEP_FULL
  echo "$out"
}

# A backup that would actually bring the user's things back: readable, and holding the home layout.
check() {
  tar -tf "$1" > /dev/null 2>&1 || return 1
  tar -tf "$1" 2>/dev/null | grep -q '^\(\./\)\?shared_prefs/widget_grid\.xml$'
}

# The paths a backup holds at its top: every entry whose parent isn't in it (a full backup: shared_prefs, files, ...;
# a light one: shared_prefs, files/shell-data, ...). Only those are replaced by a restore.
roots() {
  tar -tf "$1" | sed 's|^\./||; s|/$||' | grep . |
    awk '{ a[$0] = 1; l[NR] = $0 } END { for (i = 1; i <= NR; i++) { p = l[i]; sub(/\/[^\/]*$/, "", p); if (p == l[i] || !(p in a)) print l[i] } }'
}

restore() {
  t=$1
  [ -f "$t" ] || die "no backup $t"
  tar -tf "$t" > /dev/null 2>&1 || die "$t isn't a readable tar"
  [ -d "$D" ] || die "no $D (install $PKG first, then restore)"
  am force-stop $PKG
  U=$(stat -c %u "$D") CTX=$(stat -c %C "$D")
  aside=$B/replaced-$(stamp)
  mkdir -p "$aside" && chmod 700 "$aside" || die "can't make $aside"
  # What's there now at each path the backup holds (a fresh install's defaults) moves aside, not away: `restore` can
  # be undone by moving it back. Everything else in the data dir stays as it is.
  roots "$t" > "$aside/.roots"
  while read -r r; do
    [ -e "$D/$r" ] || continue
    mkdir -p "$aside/$(dirname "$r")" && mv "$D/$r" "$aside/$r" || die "can't move $r aside (to $aside)"
  done < "$aside/.roots"
  tar -xf "$t" -C "$D" --numeric-owner --selinux 2>> "$LOG" || die "extracting $t failed (what was there is in $aside)"
  # Owner: the app's uid now (the same after an uninstall-system-updates; a full reinstall may have given a new one).
  # Labels: Android's own (restorecon knows the app's seinfo + MCS categories), then checked against the data dir's
  # label, which installd made - anything still different gets that one.
  while read -r r; do
    [ -e "$D/$r" ] || continue
    chown -R "$U:$U" "$D/$r"
    d=${r%%/*}; [ "$d" = "$r" ] || chown "$U:$U" "$D/$d"
    restorecon -RF "$D/$r" 2>> "$LOG"
    [ "$(stat -c %C "$D/$r")" = "$CTX" ] || { log "restore: $r labelled $(stat -c %C "$D/$r"), set to $CTX"; chcon -R "$CTX" "$D/$r"; }
  done < "$aside/.roots"
  log "restore: $t -> $D (uid $U, $CTX); the replaced contents are in $aside"
}

light() {
  [ -d "$D" ] || return 0
  [ -d /data/powos/root/var ] || return 0
  mkdir -p "$LB" && chmod 700 "$LB" || die "can't make $LB"
  set --
  for e in shared_prefs files/shell-data files/powos-ai files/widgets files/widget-state files/style; do
    [ -e "$D/$e" ] && set -- "$@" "$e"
  done
  [ $# -gt 0 ] || return 0
  last=$(ls -1t "$LB"/light-*.tar 2>/dev/null | head -1)
  if [ -n "$last" ]; then
    changed=$(cd "$D" && find "$@" -newer "$last" 2>/dev/null | head -1)
    [ -n "$changed" ] || return 0
  fi
  out=$LB/light-$(stamp).tar
  tar -cf "$out.part" -C "$D" --numeric-owner --selinux "$@" 2>> "$LOG" || { rm -f "$out.part"; die "light backup failed"; }
  mv "$out.part" "$out" && chmod 600 "$out"
  prune "$LB/light-*.tar" $KEEP_LIGHT
  echo "$out"
}

# Never exits on a failed backup: `light` runs in a subshell (its die ends only that), the failure is logged, the next
# try is the next hour; after 2 failures in a row the manager hears about it (once per streak), and again on recovery.
watch() {
  pidf=/data/powos/appdata-watch.pid
  old=$(cat "$pidf" 2>/dev/null)
  [ -n "$old" ] && grep -q powos-appdata "/proc/$old/cmdline" 2>/dev/null && exit 0
  echo $$ > "$pidf"
  fails=0
  while :; do
    if (light > /dev/null); then
      [ $fails -ge 2 ] && tell "the hourly app-data backup works again (after $fails failed tries)" low
      fails=0
    else
      fails=$((fails + 1))
      log "watch: light backup failed ($fails in a row); retrying in an hour"
      [ $fails -eq 2 ] && tell "the hourly backup of the PowOS app's home layout + store failed twice in a row (/data/powos/appdata.log on the phone); a data wipe now would lose more than an hour" high
    fi
    sleep 3600
  done
}

# Mail to the manager (powos comms, inside the PowOS session); best effort, never blocks the watcher for long.
tell() {
  timeout 60 sh /data/powos/powos-run.sh "powos comms send manager 'powos-appdata: $1' --from appdata --priority ${2:-normal}" \
    >> "$LOG" 2>&1 < /dev/null || log "watch: couldn't reach the manager ($1)"
}

rebase() {
  apk=${1:-}
  [ -f "$apk" ] || die "rebase: no apk '$apk' (the APK to reinstall after the system copy is active)" 2
  t=$(backup rebase) || die "rebase REFUSED: the backup failed - not touching $PKG" 3
  check "$t" || die "rebase REFUSED: $t doesn't hold the home layout (shared_prefs/widget_grid.xml) - not touching $PKG" 3
  U=$(stat -c %u "$D")
  log "rebase: backed up to $t; pm uninstall-system-updates $PKG"
  pm uninstall-system-updates $PKG >> "$LOG" 2>&1 || log "rebase: uninstall-system-updates failed (data may still be wiped)"
  sleep 5
  pm install -r -g "$apk" >> "$LOG" 2>&1 || log "rebase: reinstalling $apk failed; the system copy stays active"
  restore "$t"
  # Android also forgets the app's root grant when its updates go (Magisk drops the uid's policy; the next su asks,
  # and an unanswered prompt with the screen off is a lasting deny). Not re-granted here - the user decides: told.
  if [ "$(stat -c %u "$D")" != "$U" ] || ! magisk --sqlite "SELECT policy FROM policies WHERE uid=$U" 2>/dev/null | grep -q 'policy=2'; then
    log "rebase: PowOS may have lost its Superuser grant - Magisk > Superuser > PowOS: allow"
    cmd notification post -S bigtext -t "PowOS needs Superuser again" powos-appdata \
      "The app was re-based on its system copy. If PowOS's desktop doesn't start: Magisk > Superuser > PowOS > allow." \
      > /dev/null 2>&1
  fi
  am start -a android.intent.action.MAIN -c android.intent.category.HOME > /dev/null 2>&1
  log "rebase: done ($t restored)"
}

case ${1:-} in
  backup) shift; backup "${1:-}" ;;
  restore) shift; restore "${1:?usage: powos-appdata.sh restore <tar>}" ;;
  rebase) shift; rebase "${1:-}" ;;
  light) light ;;
  watch) watch ;;
  check) shift; check "${1:?usage: powos-appdata.sh check <tar>}" && echo ok ;;
  roots) shift; roots "${1:?usage: powos-appdata.sh roots <tar>}" ;;
  list) ls -lt "$B"/app-data-*.tar "$LB"/light-*.tar 2>/dev/null ;;
  *) sed -n '2,30p' "$0" >&2; exit 2 ;;
esac
