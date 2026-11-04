# bf-checker-phone.sh <cmd>: (in the PowOS session as powos; bf-checker.sh pushes and runs it) one Broforce render variant
#   set <variant>      Proton user_settings.py (env: TU_DEBUG, TU_KGSL_FORCE_NONCOHERENT, DXVK_LOG_PATH) + dxvk.conf in
#                      the game dir for <variant>
#   grab <secs> <dir>  in the background: Xwayland's copy of the game window, 1 fps half-res (h*.png, nearest) and one
#                      full-res frame per 10 s (f*.png): bf-lib.sh's xframes grab (needs /var/tmp/powos-bf-lib.sh);
#                      the window is looked up by name each second
#   logs <dir>         DXVK's log (config, device, warnings) + the Unity log tail into <dir>
#   clean              back to no user_settings.py (or the one there before) and no dxvk.conf
S=$HOME/.local/share/Steam; G=$S/steamapps/common/Broforce; P="$S/steamapps/common/Proton - Experimental"
L=$HOME/.cache/bfc-dxvk
export DISPLAY=:0
XAUTHORITY=$(tr '\0' '\n' < "/proc/$(pgrep -x Xwayland | head -1)/cmdline" | grep -A1 -x -- -auth | tail -1); export XAUTHORITY
gamewin() { xwininfo -root -tree 2>/dev/null | awk '/"Broforce"/ && !/has no name/ {print $1; exit}'; }
case $1 in
set)
  tu= conf= nc=
  case $2 in
    base) ;; noubwc) tu=noubwc ;;
    # noncoherent: FEX's WoW64 module (Proton ARM64's libwow64fex.dll) sets tu_override_uncached_as_cache_coherent=true
    # in every game, so Turnip turns DXVK's uncached (write-combined) host-visible memory into cached + IOCOHERENT
    # KGSL BOs. lfdevs's TU_KGSL_FORCE_NONCOHERENT drops the cached-coherent type, which makes that override a no-op
    # (docs/research/broforce-black-columns.md, 'Coherency override').
    noncoherent) nc=1 ;;
    sysmem) tu=sysmem ;; flushall) tu=flushall ;; nolrz) tu=nolrz ;;
    # ubwc: steam-env's TU_DEBUG=noubwc (the dash fix, 2026-11-04) back off - any TU_DEBUG value replaces it; startup
    # only logs. syncdraw / gmem / 3dload: which UBWC path dashes (flushall does NOT fix it: not a missing flush).
    ubwc) tu=startup ;; syncdraw) tu=syncdraw ;; gmem) tu=gmem ;; 3dload) tu=3d_load ;;
    nomsaa) conf='d3d11.disableMsaa = True' ;; zeromem) conf='dxvk.zeroMappedMemory = True' ;;
    zerowg) conf='d3d11.zeroInitWorkgroupMemory = True' ;; relaxed) conf='d3d11.relaxedBarriers = True' ;;
    *) echo "unknown variant $2"; exit 2 ;;
  esac
  [ -d "$P" ] || { echo "no Proton dir $P"; exit 2; }
  # PowOS's own user_settings.py (pkgs/steam) takes them from ~/.config/powos/proton-settings.json and stays in place
  # (it also skips the install script evaluator); a Proton without it gets a user_settings.py of the check's own.
  if head -1 "$P/user_settings.py" 2>/dev/null | grep -q '^# PowOS user_settings'; then
    mkdir -p ~/.config/powos
    { printf '{"DXVK_LOG_PATH": "Z:%s"' "$L"; [ -n "$tu" ] && printf ', "TU_DEBUG": "%s"' "$tu"; [ -n "$nc" ] && printf ', "TU_KGSL_FORCE_NONCOHERENT": "1"'; echo '}'; } > ~/.config/powos/proton-settings.json
  else
    [ -e "$P/user_settings.py" ] && [ ! -e "$P/user_settings.py.powos-bak" ] && mv "$P/user_settings.py" "$P/user_settings.py.powos-bak"
    { echo 'user_settings = {'; echo "    \"DXVK_LOG_PATH\": \"Z:$L\","; [ -n "$tu" ] && echo "    \"TU_DEBUG\": \"$tu\","; [ -n "$nc" ] && echo '    "TU_KGSL_FORCE_NONCOHERENT": "1",'; echo '}'; } > "$P/user_settings.py"
  fi
  rm -f "$G/dxvk.conf"; [ -n "$conf" ] && echo "$conf" > "$G/dxvk.conf"
  rm -rf "$L"; mkdir -p "$L"; echo "set $2: TU_DEBUG=${tu:-} TU_KGSL_FORCE_NONCOHERENT=${nc:-} dxvk.conf=${conf:-none}" ;;
grab)
  mkdir -p "$3"; setsid -f bash "$0" grabloop "$2" "$3" </dev/null >/dev/null 2>&1; echo grabbing ;;
grabloop)  # bf-lib's xframes grab (Xlib XGetImage): ffmpeg's x11grab needs MIT-SHM, which Android doesn't have
  . /var/tmp/powos-bf-lib.sh; xframes grab Broforce "$2" "$3"; rm -rf "$T" ;;
logs)
  mkdir -p "$2"; f=$(ls -t "$L"/*d3d11*.log "$L"/*.log 2>/dev/null | head -1)
  if [ -n "$f" ]; then grep -iE "config|Found|Device|Driver|Turnip|Adreno|err:|warn:|format" "$L"/*.log | head -60 > "$2/dxvk.txt"
  else echo "no DXVK log in $L" > "$2/dxvk.txt"; fi
  u=$(find "$S/steamapps/compatdata/274190" "$G" -name 'output_log.txt' -o -name 'Player.log' 2>/dev/null | head -1)
  [ -n "$u" ] && tail -c 20000 "$u" > "$2/unity.txt"; echo "logs: $(wc -l < "$2/dxvk.txt") dxvk lines, unity ${u:-none}" ;;
clean)
  rm -f ~/.config/powos/proton-settings.json "$G/dxvk.conf"
  head -1 "$P/user_settings.py" 2>/dev/null | grep -q '^# PowOS user_settings' || rm -f "$P/user_settings.py"
  [ -e "$P/user_settings.py.powos-bak" ] && mv "$P/user_settings.py.powos-bak" "$P/user_settings.py"
  rm -rf "$L"; echo clean ;;
esac
