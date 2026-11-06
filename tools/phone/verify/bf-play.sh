# lanes: phone
# bf-play.sh <out dir> [key...]: (in the PowOS session as powos; bf-pacing.sh's `play` mode pushes and runs it) take the
# game from its menu into gameplay, so a benchmark measures play and not the title screen (11-06: bf-pacing base, the
# menu, reached 116 fps while the user's real play ran at 38 - CPU-bound main thread at the thermal cap). Sends each key
# to the game's X window (XTEST through xdotool after activating it: Wine drops XSendEvent's synthetic keys), BF_PLAY_GAP_S (3) s apart, and grabs the
# window (1/4 size PNG) before the first key and after each one into <out dir>/play-<n>.png - the proof the run
# reached a level (look at the last one) and the record to tune the sequence from. Keys default to BF_PLAY_KEYS:
# Broforce's "any key" title, then Return through the main menu's first entries (Start -> Campaign -> the save slot ->
# the world map's next mission). Prints "play <n> keys, last grab <file>" or "play: no game window".
export DISPLAY=:0 XAUTHORITY=$(tr "\0" "\n" < /proc/$(pgrep -x Xwayland | head -1)/cmdline | grep -A1 -x -- -auth | tail -1)
OUT=${1:?usage: bf-play.sh <out dir> [key...]}; shift
[ $# -gt 0 ] || set -- ${BF_PLAY_KEYS:-Return Return Return Return Return Return}
mkdir -p "$OUT"
w=$(xdotool search --onlyvisible --class "^steam_app_${APP:-274190}\$" 2>/dev/null | head -1)
[ -n "$w" ] || { echo "play: no game window"; exit 1; }
grab() { ffmpeg -loglevel error -y -f x11grab -window_id "$w" -i :0 -frames:v 1 -vf scale=iw/4:-1 "$OUT/play-$1.png" 2>/dev/null; }
n=0; grab 0
for k in "$@"; do
  xdotool windowactivate --sync "$w" 2>/dev/null
  xdotool key --delay 80 "$k"
  sleep "${BF_PLAY_GAP_S:-3}"; n=$((n + 1)); grab $n
done
echo "play $n keys ($*), last grab $OUT/play-$n.png"
