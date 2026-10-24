# lanes: phone
# bf-window.sh [wait <secs> <touch irq count>]: (in the PowOS session as powos; APP=<appid>, WIN_NAME=<its window's
# name>, default Steam's name for the app from its appmanifest) the game's X window size vs the X screen - prints
# "win=WxH screen=WxH", win= empty while there's no window yet. Matches the name exactly or a title starting "<name> "
# (bf-lib gamewin's rule). `wait`: the same, looked at every 2 s for up to <secs> s in this one call (one adb call
# instead of two per 5 s from the Mac: those calls were most of bf-pacing's time), "touched" as soon as the touch IRQs
# move from <count>.
export DISPLAY=:0 XAUTHORITY=$(tr "\0" "\n" < /proc/$(pgrep -x Xwayland | head -1)/cmdline | grep -A1 -x -- -auth | tail -1)
if [ -z "${WIN_NAME:-}" ]; then
  S=$HOME/.local/share/Steam
  for f in "$S/steamapps/appmanifest_${APP:-274190}.acf" $(sed -nE 's/^\s*"path"\s*"(.*)"/\1/p' "$S/steamapps/libraryfolders.vdf" 2>/dev/null | sed "s|\$|/steamapps/appmanifest_${APP:-274190}.acf|"); do
    [ -f "$f" ] && { WIN_NAME=$(sed -nE 's/^\s*"name"\s*"(.*)"/\1/p' "$f" | head -1); break; }; done
fi
win() {
  w=$(xwininfo -root -tree 2>/dev/null | awk -v n="\"${WIN_NAME:-Broforce}\"" -v p="\"${WIN_NAME:-Broforce} " 'index($0, n) || index($0, p)' \
    | grep -oE '[0-9]+x[0-9]+\+' | tr -d + | sort -t x -k1 -n | tail -1)
  s=$(xwininfo -root 2>/dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')
  echo "win=$w screen=$s"
}
if [ "${1:-}" = wait ]; then
  end=$(( $(date +%s) + ${2:-60} )) r="win= screen="
  while [ "$(date +%s)" -lt $end ]; do
    [ -n "${3:-}" ] && [ "$(awk '/touch-0/{s+=$2+$3+$4+$5+$6+$7+$8+$9} END{print s}' /proc/interrupts)" != "$3" ] && { echo touched; exit 0; }
    r=$(win); case $r in win=[0-9]*) echo "$r"; exit 0 ;; esac
    sleep 2
  done
  echo "$r"; exit 0
fi
win
