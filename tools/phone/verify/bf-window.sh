# bf-window.sh: (in the PowOS session as powos; APP=<appid>, WIN_NAME=<its window's name>, default Steam's name for the
# app from its appmanifest) the game's X window size vs the X screen - prints "win=WxH screen=WxH", win= empty while
# there's no window yet. Matches the name exactly or a title starting "<name> " (bf-lib gamewin's rule).
export DISPLAY=:0 XAUTHORITY=$(tr "\0" "\n" < /proc/$(pgrep -x Xwayland | head -1)/cmdline | grep -A1 -x -- -auth | tail -1)
if [ -z "${WIN_NAME:-}" ]; then
  S=$HOME/.local/share/Steam
  for f in "$S/steamapps/appmanifest_${APP:-274190}.acf" $(sed -nE 's/^\s*"path"\s*"(.*)"/\1/p' "$S/steamapps/libraryfolders.vdf" 2>/dev/null | sed "s|\$|/steamapps/appmanifest_${APP:-274190}.acf|"); do
    [ -f "$f" ] && { WIN_NAME=$(sed -nE 's/^\s*"name"\s*"(.*)"/\1/p' "$f" | head -1); break; }; done
fi
w=$(xwininfo -root -tree 2>/dev/null | awk -v n="\"${WIN_NAME:-Broforce}\"" -v p="\"${WIN_NAME:-Broforce} " 'index($0, n) || index($0, p)' \
  | grep -oE '[0-9]+x[0-9]+\+' | tr -d + | sort -t x -k1 -n | tail -1)
s=$(xwininfo -root 2>/dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')
echo "win=$w screen=$s"
