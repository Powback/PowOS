#!/usr/bin/env bash
# powos-shell against a nested KWin, headless - for a machine with no KVM to boot a VM on (the Mac). Runs INSIDE the
# bench container (dev/Containerfile); from the host:
#
#   docker build -t powos-shell-dev:f44 sources/powos-shell/dev
#   docker run -d --init --name powos-shell-dev -v "$PWD":/src:ro powos-shell-dev:f44 sleep infinity
#   docker exec powos-shell-dev bash /src/sources/powos-shell/dev/nested.sh start   # build, install, KWin, panel
#   docker exec powos-shell-dev bash /src/sources/powos-shell/dev/nested.sh shot /tmp/panel.png
#   docker exec powos-shell-dev bash /src/sources/powos-shell/dev/nested.sh run konsole   # a client in that KWin
#
# KWin runs windowed in Xvfb (:99, 1280x800); `shot` is that X screen. The panel is the real host: built and
# installed to /usr (so KWin's .desktop permission check for org_kde_plasma_window_management is the real one),
# serving /usr/share/powos/shell under ~/.config/powos/shell - save a file there and the panel reloads.
# Not tested here: a real session (plasmashell, logind seat, GPU) - that's the VM (test/tier2) or hardware.
set -euo pipefail
export XDG_RUNTIME_DIR=/tmp/xdg
export WAYLAND_DISPLAY=wayland-powos
export DISPLAY=:99
STATE=/tmp/nested
mkdir -p "$XDG_RUNTIME_DIR" "$STATE" && chmod 700 "$XDG_RUNTIME_DIR"
[ -f "$STATE/dbus.env" ] && . "$STATE/dbus.env" && export DBUS_SESSION_BUS_ADDRESS

# A Wayland Qt client in the nested KWin. As root in a container: Chromium's sandbox can't start (no user namespaces).
client_env() {
  export QT_QPA_PLATFORM=wayland QTWEBENGINE_DISABLE_SANDBOX=1 XDG_CURRENT_DESKTOP=KDE KDE_FULL_SESSION=true \
    QT_FORCE_STDERR_LOGGING=1
}

case "${1:-start}" in
  start)
    cmake -S /src/sources/powos-shell -B /build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DPOWOS_SHELL_WEB=/src/shell >/dev/null
    ninja -C /build >/dev/null && ninja -C /build install >/dev/null
    pgrep -x Xvfb >/dev/null || { setsid Xvfb :99 -screen 0 1280x800x24 >"$STATE/xvfb.log" 2>&1 & sleep 1; }
    if [ ! -f "$STATE/dbus.env" ]; then
      dbus-daemon --session --fork --print-address=1 | sed 's/^/DBUS_SESSION_BUS_ADDRESS=/' >"$STATE/dbus.env"
      . "$STATE/dbus.env" && export DBUS_SESSION_BUS_ADDRESS
    fi
    if ! pgrep -x kwin_wayland >/dev/null; then
      setsid kwin_wayland --x11-display :99 --no-lockscreen --width 1280 --height 800 --socket "$WAYLAND_DISPLAY" \
        >"$STATE/kwin.log" 2>&1 &
      for _ in $(seq 50); do [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break; sleep 0.2; done
    fi
    pkill -x powos-shell || true
    client_env
    QTWEBENGINE_REMOTE_DEBUGGING=9222 setsid powos-shell >"$STATE/shell.log" 2>&1 &
    echo "started: logs in $STATE (kwin.log, shell.log)"
    ;;
  run)
    shift
    client_env
    setsid "$@" >"$STATE/$(basename "$1").log" 2>&1 &
    ;;
  shot)
    xwd -root -silent -display :99 | magick xwd:- "${2:-/tmp/panel.png}"
    echo "${2:-/tmp/panel.png}"
    ;;
  stop)
    pkill -x powos-shell || true
    pkill -x kwin_wayland || true
    pkill -x Xvfb || true
    rm -f "$STATE/dbus.env"
    ;;
  *) sed -n '2,16p' "$0"; exit 2 ;;
esac
