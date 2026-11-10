#!/system/bin/sh
# app-frida.sh - the App API's on-demand IN-APP HOOK helper. For apps the owner ENABLED that pin TLS or sign their
# requests, the pure-proxy path can't read the traffic; instead an in-app hook reads the request the way the app
# ITSELF builds it, so we reuse the app's own auth/headers and never re-implement auth or run a second client.
# Owner's phone, owner's enabled app, owner's account. Unit: units/phone-android/app-frida.json.
#
# Run by the Mac wrapper `rooted.sh app-frida <cmd>` (pushed + run as root on the Android side via Magisk), with the
# owner present. Lifecycle (default STOPPED - it only runs inside an explicit, bounded capture window):
#   install [BIN]   stage the hook-server binary (0700, root-only) at /data/local/tmp/frida-server. BIN is the
#                   matching-arch binary the Mac wrapper pushes; keeps the staged copy if already present and no BIN
#                   is given. Does NOT start it.
#   start PKG       start the hook helper for ONE package the owner enabled in the App API, for this capture window.
#                   REFUSES any package that is not an enabled App API app (allowlist = the apps the owner picked).
#                   Records the single target package so the capture layer attaches to that package only.
#   stop            stop the helper and clear the capture window. Also runs on idle / capture end.
#   status          is it running, and for which package.
#   remove          stop it and delete the staged binary. Keeps nothing. --dry-run says what it would do.
#   Every verb takes --help. install refuses a binary whose --version is not the pinned FRIDA_VERSION.
#
# Scope: attaches ONLY to the one enabled package, only while started; no other app is touched. SELinux is never
# touched (a root process under Magisk, no policy change). Non-root parity: the in-app hook needs root; a non-rooted
# device uses the notification-stream read path instead (no hook, no CA) - see docs/APP-API.md.
set -u

R=/data/powos/root
AA=/data/powos/app-api
BIN=/data/local/tmp/frida-server
PID=$AA/frida.pid
TARGET=$AA/capture-target            # the single package this window is allowed to hook
LOG=$AA/frida.log
# The pinned hook-server version (same as the PowStation frida tooling, powstation-frida/deploy/frida-server.sh). The
# client side that attaches must speak the same version; install refuses any other binary.
FRIDA_VERSION=16.6.6

die() { echo "app-frida: $*" >&2; exit 1; }

# Is PKG an app the owner ENABLED in the App API (a spec with enabled:true whose android.package == PKG)? The
# allowlist IS the set of apps the owner picked in the UI; nothing else may be hooked. Read-only, as the powos user.
enabled_app() {
  pkg=$1
  chroot "$R" /usr/bin/env -i PATH=/usr/bin:/usr/sbin HOME=/home/powos \
    /usr/bin/python3 - "$pkg" <<'PY' 2>/dev/null
import glob, json, os, sys
pkg = sys.argv[1]
state = os.path.expanduser("~/.local/state/powos/app-api/specs")
for p in glob.glob(os.path.join(state, "*.appcap.json")):
    try:
        s = json.load(open(p))
    except Exception:
        continue
    if not s.get("enabled"):
        continue
    if str(((s.get("android") or {}).get("package")) or "") == pkg:
        print("ok"); sys.exit(0)
sys.exit(1)
PY
}

running() { p=$(cat "$PID" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

install() {
  [ "$(id -u)" = 0 ] || die "install needs root"
  ( umask 077; mkdir -p "$AA" ); chmod 700 "$AA"
  src=${1:-}
  if [ -n "$src" ]; then
    [ -s "$src" ] || die "no such binary: $src"
    cp "$src" "$BIN" || die "cannot stage the binary"
  fi
  [ -s "$BIN" ] || die "no hook-server binary staged. Push one: rooted.sh app-frida install <frida-server-$FRIDA_VERSION-android-arm64>"
  chmod 700 "$BIN"; chown 0:0 "$BIN" 2>/dev/null
  # Version check: `frida-server --version` prints the version and exits (it does not start the server).
  v=$("$BIN" --version 2>/dev/null | tr -d '\r' | head -n 1)
  if [ "$v" != "$FRIDA_VERSION" ]; then
    rm -f "$BIN"
    die "REFUSED: staged binary reports version '${v:-none}', pinned is $FRIDA_VERSION (wrong version/arch); removed it"
  fi
  echo "app-frida: staged $BIN (frida-server $v, 0700, root-only), STOPPED. Starts only inside a capture window."
}

start() {
  [ "$(id -u)" = 0 ] || die "start needs root"
  pkg=${1:-}; [ -n "$pkg" ] || die "start PKG (the enabled app to hook)"
  [ -s "$BIN" ] || die "not installed (run: rooted.sh app-frida install <binary>)"
  [ "$(enabled_app "$pkg")" = ok ] || die "REFUSED: '$pkg' is not an enabled App API app. Enable it in the App API UI first - only apps the owner picked can be hooked."
  if running; then
    echo "app-frida: already running (pid $(cat "$PID")) for $(cat "$TARGET" 2>/dev/null)"; return
  fi
  echo "$pkg" > "$TARGET"; chmod 600 "$TARGET"
  # STOPPED-by-default daemon, started only here; the capture layer attaches it to exactly $TARGET.
  "$BIN" >"$LOG" 2>&1 &
  echo $! > "$PID"; chmod 600 "$PID"
  echo "app-frida: started for $pkg only (pid $(cat "$PID")). Capture window OPEN - stop it when done:"
  echo "app-frida:   rooted.sh app-frida stop"
}

stop() {
  p=$(cat "$PID" 2>/dev/null)
  [ -n "$p" ] && kill "$p" 2>/dev/null
  rm -f "$PID" "$TARGET"
  echo "app-frida: stopped. Capture window CLOSED; no package is hooked."
}

status() {
  [ -s "$BIN" ] && echo "app-frida: binary staged ($BIN)" || echo "app-frida: not installed"
  if running; then echo "app-frida: RUNNING (pid $(cat "$PID")) for package $(cat "$TARGET" 2>/dev/null)"
  else echo "app-frida: stopped (resting state)"; fi
}

remove() {
  stop >/dev/null 2>&1
  rm -f "$BIN"
  echo "app-frida: stopped + deleted the staged binary. Kept nothing."
}

usage_of() {
  case "$1" in
    install) echo "usage: app-frida.sh install [BIN]   stage frida-server $FRIDA_VERSION (version-checked), STOPPED" ;;
    start) echo "usage: app-frida.sh start PKG   start for ONE enabled App API package (a capture window)" ;;
    stop) echo "usage: app-frida.sh stop   stop it and close the capture window" ;;
    status) echo "usage: app-frida.sh status   staged? running, and for which package?" ;;
    remove) echo "usage: app-frida.sh remove [--dry-run]   stop it and delete the staged binary; --dry-run changes nothing" ;;
    *) echo "usage: app-frida.sh [install [BIN]|start PKG|stop|status|remove [--dry-run]]   (VERB --help for one verb)" ;;
  esac
}

# Every verb answers --help/-h without doing anything; unknown options are refused, never passed to an action.
verb=${1:-status}; [ $# -gt 0 ] && shift
for a in "$@"; do case "$a" in -h|--help|help) usage_of "$verb"; exit 0 ;; -*) [ "$verb" = remove ] && [ "$a" = --dry-run ] || { usage_of "$verb" >&2; exit 2; } ;; esac; done
case "$verb" in
  -h|--help|help) usage_of ""; exit 0 ;;
  install) [ $# -le 1 ] || { usage_of install >&2; exit 2; }; install "${1:-}" ;;
  start) [ $# -le 1 ] || { usage_of start >&2; exit 2; }; start "${1:-}" ;;
  stop|status) [ $# = 0 ] || { usage_of "$verb" >&2; exit 2; }; "$verb" ;;
  remove)
    if [ "${1:-}" = --dry-run ]; then
      [ -s "$BIN" ] && echo "app-frida: (dry run) would stop it and delete $BIN" || echo "app-frida: (dry run) no binary at $BIN"
      echo "app-frida: (dry run) nothing changed"
    else
      [ $# = 0 ] || { usage_of remove >&2; exit 2; }; remove
    fi ;;
  *) usage_of "" >&2; exit 2 ;;
esac
