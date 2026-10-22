# bf-checker-phone.sh <cmd>: (in the PowOS session as powos; bf-checker.sh pushes and runs it) one Broforce render variant
#   set <variant>      Proton user_settings.py (env: TU_DEBUG, DXVK_LOG_PATH) + dxvk.conf in the game dir for <variant>
#   grab <secs> <dir>  in the background: Xwayland's copy of the game window, 1 fps half-res (h*.png, nearest) and one
#                      full-res frame per 10 s (f*.png) via x11grab; the window id is looked up again every 10 s
#   logs <dir>         DXVK's log (config, device, warnings) + the Unity log tail into <dir>
#   clean              back to no user_settings.py (or the one there before) and no dxvk.conf
S=$HOME/.local/share/Steam; G=$S/steamapps/common/Broforce; P="$S/steamapps/common/Proton - Experimental"
L=$HOME/.cache/bfc-dxvk
export DISPLAY=:0
XAUTHORITY=$(tr '\0' '\n' < "/proc/$(pgrep -x Xwayland | head -1)/cmdline" | grep -A1 -x -- -auth | tail -1); export XAUTHORITY
gamewin() { xwininfo -root -tree 2>/dev/null | awk '/"Broforce"/ && !/has no name/ {print $1; exit}'; }
case $1 in
set)
  tu= conf=
  case $2 in
    base) ;; noubwc) tu=noubwc ;; sysmem) tu=sysmem ;; flushall) tu=flushall ;; nolrz) tu=nolrz ;;
    nomsaa) conf='d3d11.disableMsaa = True' ;; zeromem) conf='dxvk.zeroMappedMemory = True' ;;
    zerowg) conf='d3d11.zeroInitWorkgroupMemory = True' ;; relaxed) conf='d3d11.relaxedBarriers = True' ;;
    *) echo "unknown variant $2"; exit 2 ;;
  esac
  [ -d "$P" ] || { echo "no Proton dir $P"; exit 2; }
  [ -e "$P/user_settings.py" ] && [ ! -e "$P/user_settings.py.powos-bak" ] && mv "$P/user_settings.py" "$P/user_settings.py.powos-bak"
  { echo 'user_settings = {'; echo "    \"DXVK_LOG_PATH\": \"Z:$L\","; [ -n "$tu" ] && echo "    \"TU_DEBUG\": \"$tu\","; echo '}'; } > "$P/user_settings.py"
  rm -f "$G/dxvk.conf"; [ -n "$conf" ] && echo "$conf" > "$G/dxvk.conf"
  rm -rf "$L"; mkdir -p "$L"; echo "set $2: TU_DEBUG=${tu:-} dxvk.conf=${conf:-none}" ;;
grab)
  mkdir -p "$3"; setsid -f sh "$0" grabloop "$2" "$3" </dev/null >/dev/null 2>&1; echo grabbing ;;
grabloop)
  for c in $(seq $(( $2 / 10 ))); do
    w=$(gamewin)
    [ -n "$w" ] || { echo "$c: no window" >> "$3/grab.log"; sleep 10; continue; }
    echo "$c $(date +%T) $w $(xwininfo -id "$w" | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')" >> "$3/grab.log"
    ffmpeg -nostdin -loglevel error -y -f x11grab -framerate 1 -window_id "$w" -i :0 -t 10 \
      -filter_complex "[0]split[a][b];[a]scale=iw/2:-2:flags=neighbor[h];[b]select=eq(n\,0)[f]" \
      -map "[h]" -start_number $(( (c - 1) * 10 )) "$3/h%03d.png" -map "[f]" -update 1 "$3/f$c.png" 2>> "$3/grab.log"
  done
  echo done >> "$3/grab.log" ;;
logs)
  mkdir -p "$2"; f=$(ls -t "$L"/*d3d11*.log "$L"/*.log 2>/dev/null | head -1)
  if [ -n "$f" ]; then grep -iE "config|Found|Device|Driver|Turnip|Adreno|err:|warn:|format" "$L"/*.log | head -60 > "$2/dxvk.txt"
  else echo "no DXVK log in $L" > "$2/dxvk.txt"; fi
  u=$(find "$S/steamapps/compatdata/274190" "$G" -name 'output_log.txt' -o -name 'Player.log' 2>/dev/null | head -1)
  [ -n "$u" ] && tail -c 20000 "$u" > "$2/unity.txt"; echo "logs: $(wc -l < "$2/dxvk.txt") dxvk lines, unity ${u:-none}" ;;
clean)
  rm -f "$P/user_settings.py" "$G/dxvk.conf"
  [ -e "$P/user_settings.py.powos-bak" ] && mv "$P/user_settings.py.powos-bak" "$P/user_settings.py"
  rm -rf "$L"; echo clean ;;
esac
