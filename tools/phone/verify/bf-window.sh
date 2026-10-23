# bf-window.sh: (in the PowOS session as powos; WIN_NAME=<its window's name>, default Broforce) the game's X window size vs the X screen - prints "win=WxH screen=WxH",
# win= empty while there's no window yet.
export DISPLAY=:0 XAUTHORITY=$(tr "\0" "\n" < /proc/$(pgrep -x Xwayland | head -1)/cmdline | grep -A1 -x -- -auth | tail -1)
w=$(xwininfo -root -tree 2>/dev/null | grep "\"${WIN_NAME:-Broforce}\"" | grep -oE '[0-9]+x[0-9]+\+' | tr -d + | sort -t x -k1 -n | tail -1)
s=$(xwininfo -root 2>/dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')
echo "win=$w screen=$s"
