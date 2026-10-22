#!/usr/bin/env bash
# powos-shell on the phone's own Plasma session (KWin on the Anland backend, the "PowOS" activity) - the desktop
# shell's first test bed (docs/DESKTOP-SHELL.md). From the Mac, one phone call each:
#
#   sources/powos-shell/dev/phone.sh build        this tree's sources/powos-shell + shell/ -> built on the phone, installed
#                                                 to /usr/lib/powos/desktop-shell (units/phone/powos-desktop-shell.json)
#   sources/powos-shell/dev/phone.sh start|stop   the desktop home in the session (as powos), or gone: Plasma as before
#   sources/powos-shell/dev/phone.sh status       running?, RSS, CPU ticks, the log's tail
#   sources/powos-shell/dev/phone.sh page NAME    the home page as Chromium drew it (DevTools), over Android's still of
#                                                 the wallpaper -> /home/powos/design-qa/desktop-NAME.png (+ a copy here)
#   sources/powos-shell/dev/phone.sh cdp 'JS'     evaluate in the home page (read-only checks)
#   sources/powos-shell/dev/phone.sh render NAME WxH [DPR]   the home with real data off screen at a desktop's size
#   sources/powos-shell/dev/phone.sh theme        the phone home's picked theme -> the session's Omarchy current theme
#   sources/powos-shell/dev/phone.sh wallpaper    Android's wallpaper still -> the desktop home's own wallpaper
#   sources/powos-shell/dev/phone.sh shot NAME    KWin's whole output (spectacle); on the phone's Anland backend it
#                                                 comes back empty (2026-10-21) - use page, or Android's screencap
#
# The base it serves is the installed copy of shell/ (/usr/lib/powos/desktop-shell/share/shell); a file saved into
# ~/.config/powos/shell/ on the phone overrides it and hot-reloads. Never touches the Android app or its shell.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
adb="$repo/tools/phone/adb.sh"
cache="$HOME/.cache/powos-desktop"
mkdir -p "$cache"
P=/usr/lib/powos/desktop-shell
# The session's own Wayland socket (KWin's wayland-0 in the app's run dir, /run/powos-app).
RUN="WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland POWOS_SHELL_DIR=$P/share/shell"
# DevTools on the phone's loopback only, for cdp/page (read-only checks): a dev run's, not the product's.
DEV="QTWEBENGINE_REMOTE_DEBUGGING=127.0.0.1:9333"

as_user() { "$adb" shell "su -c \"sh /data/powos/powos-run.sh '$1'\""; }

case "${1:-}" in
  build)
    COPYFILE_DISABLE=1 tar -C "$repo" --exclude node_modules --exclude 'shell/dev/perf' -czf "$cache/src.tgz" sources/powos-shell shell
    "$adb" push "$cache/src.tgz" /data/local/tmp/powos-shell-src.tgz >/dev/null
    cat >"$cache/build.sh" <<EOF
set -e
S=/var/tmp/powos-shell-src B=/var/tmp/powos-shell-build
rm -rf \$S && mkdir -p \$S && tar -xzf /tmp/powos-shell-src.tgz -C \$S && rm -f /tmp/powos-shell-src.tgz
cmake -S \$S/sources/powos-shell -B \$B -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=$P \
  -DPOWOS_SHELL_WEB=\$S/shell -DPOWOS_SHELL_WEB_DEST=share/shell -DPOWOS_SHELL_AUTOSTART=/etc/xdg/autostart >/dev/null
ninja -C \$B 2>&1 | grep -E 'error|warning: unused|FAILED' || true
ninja -C \$B >/dev/null
rm -rf $P/share/shell && ninja -C \$B install >/dev/null
# KWin grants restricted interfaces by a .desktop whose Exec is this binary's full path (docs/DESKTOP-WEB-SHELL.md 3.3).
sed "s|^Exec=.*|Exec=$P/bin/powos-shell|" \$S/sources/powos-shell/org.powos.shell.desktop > /usr/share/applications/org.powos.shell.desktop
ln -sf $P/bin/powos-desktop-shell /usr/bin/powos-desktop-shell
install -m 755 \$S/sources/powos-shell/dev/cdp-eval.py $P/bin/powos-shell-cdp
echo "built: \$(du -sh $P/bin/powos-shell | cut -f1) binary, \$(du -sh $P/share/shell | cut -f1) shell"
EOF
    "$adb" shell "su -c 'mv /data/local/tmp/powos-shell-src.tgz /data/powos/root/tmp/powos-shell-src.tgz'"
    "$repo/tools/phone/root.sh" "$cache/build.sh"
    ;;
  start) as_user "$RUN $DEV powos-desktop-shell start" ;;
  theme)
    # The phone home's picked theme (read-only: its bridge's theme.get) as Omarchy's current theme in the session -
    # what the desktop host reads (and watches) for the page's tokens. HACK: a copy, made by hand; real fix: the
    # Android app writes ~/.local/state/omarchy/current/theme into the rooted session itself whenever a theme is
    # picked, as GuestThemeConfig.kt does for proot.
    "$repo/tools/phone/cdp.sh" eval home 'importShim("./bridge.ts").then(m => m.powos.theme.get()).then(t => JSON.stringify(t))' 2>/dev/null |
      python3 "$here/theme-toml.py" >"$cache/theme.txt"
    { echo 'D=~/.local/state/omarchy/current; mkdir -p $D/theme'; echo "cat >\$D/theme/colors.toml <<'TOML'"; tail -n +2 "$cache/theme.txt"; echo TOML
      echo "printf '%s\n' '$(head -1 "$cache/theme.txt")' >\$D/theme.name; echo theme: \$(cat \$D/theme.name), \$(grep -c = \$D/theme/colors.toml) colors"; } >"$cache/theme.sh"
    "$repo/tools/phone/user.sh" "$cache/theme.sh" 2>&1 | grep -v ' pushed'
    ;;
  wallpaper)
    # The desktop home's own wallpaper (src/server.cpp desktopWallpaper): Android's still of its (live) wallpaper,
    # copied root-side once - the session can't read Android's system files.
    "$adb" shell "su -c 'mkdir -p /data/powos/root/home/powos/.local/state/powos && cp /data/system/users/0/wallpaper_screenshot.png /data/powos/root/home/powos/.local/state/powos/desktop-wallpaper.jpg && chown 10359:10359 /data/powos/root/home/powos/.local/state/powos/desktop-wallpaper.jpg && echo copied || echo failed'"
    ;;
  render)
    # The desktop home with the phone's REAL data at a desktop's size, off screen (the live session may be frozen, and
    # a capture of a page must not be the mock): a second powos-shell, QT_QPA_PLATFORM=offscreen at WxH and DPR, its
    # own browser profile and a temporary data home - the real PowOS apps (POWOS_APPS_DIR), theme and wallpaper
    # (state home), a copy of host.net's secrets - so the user's instance and layout are never touched. Its page is
    # captured over DevTools (127.0.0.1:9334); the instance and its temp are gone after.
    name=${2:?usage: phone.sh render NAME WxH [DPR]}
    size=${3:?usage: phone.sh render NAME WxH [DPR]}
    dpr=${4:-1}
    w=${size%x*} h=${size#*x}
    out=/home/powos/design-qa/desktop-$name.png
    {
      echo 'T=$(mktemp -d /home/powos/.cache/powos-shell-render.XXXXXX)'
      echo 'mkdir -p $T/powos/net && cp ~/.local/share/powos/net/secrets.json $T/powos/net/ 2>/dev/null; chmod -R go-rwx $T'
      echo "printf '{\"screens\":[{\"name\":\"render\",\"x\":0,\"y\":0,\"width\":$w,\"height\":$h,\"logicalDpi\":96,\"logicalBaseDpi\":96,\"dpr\":$dpr}]}' >\$T/screens.json"
      echo "XDG_DATA_HOME=\$T POWOS_APPS_DIR=/home/powos/.local/share/powos/apps POWOS_SHELL_PROFILE=powos-shell-render QTWEBENGINE_CHROMIUM_FLAGS=--disable-gpu QT_QPA_PLATFORM=offscreen:configfile=\$T/screens.json QTWEBENGINE_REMOTE_DEBUGGING=127.0.0.1:9334 POWOS_SHELL_DIR=$P/share/shell $P/bin/powos-shell home >\$T/log 2>&1 &"
      echo 'pid=$!; sleep 30'
      echo "PORT=9334 MODE=desktop $P/bin/powos-shell-cdp 'JSON.stringify({w: innerWidth, h: innerHeight, dpr: devicePixelRatio, alive: window.__powosAlive, tiles: document.querySelectorAll(\".home-tile\").length, errs: (window.__powosBoot || {}).errors})'"
      echo "PORT=9334 MODE=desktop $P/bin/powos-shell-cdp --shot $out || tail -5 \$T/log"
      echo 'kill $pid; sleep 1; kill -9 $pid 2>/dev/null; rm -rf $T'
    } >"$cache/render.sh"
    "$repo/tools/phone/user.sh" "$cache/render.sh" 2>&1 | grep -v ' pushed'
    "$adb" exec-out "su -c cat /data/powos/root$out" >"$cache/desktop-$name.png" && echo "here: $cache/desktop-$name.png (real data, off screen at ${w}x$h x$dpr; no compositor)"
    ;;
  cdp)
    # As base64 in a script file: the JS reaches the page as written (no shell quoting on the way).
    printf 'PORT=9333 MODE=desktop %s/bin/powos-shell-cdp "$(echo %s | base64 -d)"\n' "$P" \
      "$(printf '%s' "${2:?usage: phone.sh cdp JS}" | base64 | tr -d '\n')" >"$cache/cdp.sh"
    "$repo/tools/phone/user.sh" "$cache/cdp.sh" 2>&1 | grep -v ' pushed'
    ;;
  page)
    name=${2:?usage: phone.sh page NAME}
    out=/home/powos/design-qa/desktop-$name.png
    as_user "mkdir -p ~/design-qa && PORT=9333 MODE=desktop $P/bin/powos-shell-cdp --shot /home/powos/.cache/powos-shell/page.png" >/dev/null
    "$adb" exec-out "su -c cat /data/powos/root/home/powos/.cache/powos-shell/page.png" >"$cache/page.png"
    # Over the wallpaper as the compositor puts it there (no blur: KWin's isn't in a page capture): Android's own still
    # of the live wallpaper (what the phone shell's glass uses), cropped to the page from the top-left (KWin's
    # output is the screen; the page stops above Plasma's panel).
    "$adb" exec-out "su -c cat /data/system/users/0/wallpaper_screenshot.png" >"$cache/wallpaper.png"
    ffmpeg -loglevel error -y -i "$cache/wallpaper.png" -i "$cache/page.png" -filter_complex \
      "[0][1]scale2ref=w=iw:h=-1[wp][pg];[wp]crop=iw:ih:0:0[wpc];[wpc][pg]overlay=0:0:shortest=1" -frames:v 1 "$cache/desktop-$name.png"
    "$repo/tools/phone/review-image.sh" "$cache/desktop-$name.png" | tail -1
    echo "here: $cache/desktop-$name.png (a page capture over the wallpaper, not a compositor screenshot)"
    ;;
  stop) as_user "powos-desktop-shell stop" ;;
  status) as_user "powos-desktop-shell status" ;;
  shot)
    name=${2:?usage: phone.sh shot NAME}
    out=/home/powos/design-qa/desktop-$name.png
    as_user "mkdir -p ~/design-qa && $RUN spectacle -b -n -f -o $out >/dev/null 2>&1; ls -la $out"
    "$adb" exec-out "su -c cat /data/powos/root$out" >"$cache/desktop-$name.png" && echo "here: $cache/desktop-$name.png"
    ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
