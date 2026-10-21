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
  -DPOWOS_SHELL_WEB=\$S/shell -DPOWOS_SHELL_WEB_DEST=share/shell >/dev/null
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
