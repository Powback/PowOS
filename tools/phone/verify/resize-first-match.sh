# Sourced on the device and in the offline shell simulation. No pipeline wait on logcat.
resize_first_match() (
  token=$1
  # su on Android may have no TMPDIR, and /tmp does not exist there.
  dir=$(mktemp -d "${TMPDIR:-/data/local/tmp}/wwr.XXXXXX") || { echo "WWR_WATCH mktemp failed"; exit 1; }
  producer=
  cleanup() {
    if [ -n "$producer" ]; then
      kill "$producer" 2>/dev/null || :
      wait "$producer" 2>/dev/null || :
    fi
    exec 3>&-
    rm -f "$dir/events"
    rmdir "$dir"
  }
  trap cleanup EXIT
  trap "exit 1" HUP INT TERM
  mkfifo "$dir/events" || { echo "WWR_WATCH mkfifo failed"; exit 1; }
  # Read/write open avoids hanging if logcat fails before opening its writer.
  exec 3<>"$dir/events"
  # -T 1: new lines only. Without it logcat first replays its whole buffer, which a line-at-a-time shell read
  # could not get through in 8 s (11-10 23:11/23:14: deadline with lines still streaming, while the 3 s resize sat
  # 6.0-9.0 s and 2.9-5.9 s into the observer records - inside the window, never reached).
  # No single quotes anywhere in this file: it is embedded in su -c with single quotes.
  echo "WWR_WATCH start $(date +%s%3N)"
  logcat -T 1 -v raw -s PowosShell:I > "$dir/events" 3>&- &
  producer=$!
  deadline=$(( $(date +%s) + ${WWR_WATCH_S:-8} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] || { echo "WWR_WATCH deadline"; exit 1; }
    IFS= read -r -t "$remaining" line <&3 || { echo "WWR_WATCH read timed out or ended"; exit 1; }
    case "$line" in
      *"${token}_ACTIVE"*) echo "WWR_WATCH matched $(date +%s%3N)"; exit 0 ;;
    esac
  done
  echo "WWR_WATCH deadline"
  exit 1
)
