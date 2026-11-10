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
  logcat -v raw -s PowosShell:I > "$dir/events" 3>&- &
  producer=$!
  deadline=$(( $(date +%s) + ${WWR_WATCH_S:-8} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] || { echo "WWR_WATCH deadline"; exit 1; }
    IFS= read -r -t "$remaining" line <&3 || { echo "WWR_WATCH read timed out or ended"; exit 1; }
    case "$line" in
      *"${token}_ACTIVE"*) exit 0 ;;
    esac
  done
  echo "WWR_WATCH deadline"
  exit 1
)
