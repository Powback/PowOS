# lanes: phone
# ue-screen.sh: (read-only; tools/phone/root.sh tools/phone/verify/ue-screen.sh, APP=<appid>, default 384190 ABZU)
# whether an Unreal Engine game's last launch got the screen's size from user_settings.py's _ue_screen (steam package):
# its powos-screen.log, the resolution keys of each GameUserSettings.ini in its prefix, the game's own UE log (its
# command line and "Scene viewport resized to WxH" lines) and the X screen now. Pass: the viewport size = the screen.
APP=${APP:-384190}
H=${POWOS_HOME:-/home/powos}; D=$H/.local/share/Steam/steamapps/compatdata/$APP
echo "== $D/powos-screen.log"; tail -n 6 "$D/powos-screen.log" 2>/dev/null || echo "(none: the hook hasn't run for $APP - steam package/user_settings.py not in that Proton yet?)"
U=$D/pfx/drive_c/users/steamuser
find "$U" -path '*/Saved/Config/Windows*/GameUserSettings.ini' 2>/dev/null | while read -r f; do
  echo "== $f"; grep -aE '^\[.*GameUserSettings\]|^(ResolutionSize[XY]|LastUserConfirmed(ResolutionSize[XY]|DesiredScreen(Width|Height))|DesiredScreen(Width|Height)|bUseDesktopResolutionForFullscreen|FullscreenMode|PreferredFullscreenMode)=' "$f" | tr -d '\r'
done
find "$U" -path '*/Saved/Logs/*.log' -newer "$D/powos-screen.log" 2>/dev/null | grep -v backup | while read -r f; do
  echo "== $f"; grep -aE 'Command Line:|Scene viewport resized|Set(ting)? ?[Rr]esolution' "$f" | tr -d '\r' | tail -n 6
done
X=$(pgrep -x Xwayland | head -1)
[ -n "$X" ] && DISPLAY=:0 XAUTHORITY=$(tr "\0" "\n" < /proc/$X/cmdline | grep -A1 -x -- -auth | tail -1) \
  xwininfo -root 2>/dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print "== X screen now " w "x" h}'
