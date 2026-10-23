#!/bin/bash
# steam-install-phone.sh <appid>...: (in the PowOS session as powos; steam-install.sh pushes and runs it) Steam's own
# install of games the user already owns: `steam steam://install/<appid>` (/usr/bin/steam thaws a frozen Steam first),
# Return on Steam's install dialog if one comes up, until Steam writes the game's appmanifest (its download queued).
# Never launches a game, never signs in or buys: a game Steam can't install (not owned) only shows its dialog / the
# store, which this closes again ("FAIL install-<id>"). Windows that came up for the installs (the dialog, Steam's main
# window) are closed again at the end (Steam keeps running in the tray, downloading). A touch: exit 3.
set -uo pipefail
APP=${1:?appid}
. /var/tmp/powos-bf-lib.sh
S=$HOME/.local/share/Steam
flags() { sed -nE 's/^\s*"StateFlags"\s*"([0-9]+)"/\1/p' "$S/steamapps/appmanifest_$1.acf" 2>/dev/null | head -1; }
vis() { xdotool search --onlyvisible --name . 2>/dev/null | sort -u; }
before=$(vis); RES_=""
for id in "$@"; do
  case $id in *[!0-9]* | '') fail "install-$id" "not an appid"; continue ;; esac
  f=$(flags "$id")
  if [ "$f" = 4 ]; then echo "== $id: installed already"; RES_="$RES_ $id:installed"; continue; fi
  if [ -n "$f" ]; then echo "== $id: queued already (StateFlags $f)"; RES_="$RES_ $id:queued"; continue; fi
  pill "Steam install $id"; w0=$(vis)
  setsid -f steam "steam://install/$id" >/dev/null 2>&1 </dev/null
  pressed=0 ok=0
  for i in $(seq 90); do
    touched; sleep 1
    [ -n "$(flags "$id")" ] && { ok=1; break; }
    # Steam's install dialog (new windows since the URL): Return = its default button (Install). Twice at most.
    if [ $i -ge 4 ] && [ $pressed -lt 2 ] && [ $((i % 8)) = 4 ]; then
      for w in $(comm -13 <(echo "$w0") <(vis)); do
        n=$(xdotool getwindowname "$w" 2>/dev/null)
        case $n in *[Ii]nstall*) echo "   dialog '$n' ($w): Return"; xdotool windowactivate --sync "$w" >/dev/null 2>&1; sleep 0.5
          xdotool key --window "$w" Return; pressed=$((pressed + 1)) ;; esac
      done
    fi
  done
  if [ $ok = 1 ]; then echo "== $id: download queued after ${i} s (StateFlags $(flags "$id"))"; RES_="$RES_ $id:queued"
  else fail "install-$id" "no appmanifest after 90 s (Return pressed $pressed x); new windows: $(for w in $(comm -13 <(echo "$w0") <(vis)); do printf "'%s' " "$(xdotool getwindowname "$w")"; done)"; fi
done
sleep 3
# What came up for the installs goes away again (wmctrl -c = the window's own close: Steam's main window -> tray).
for w in $(comm -13 <(echo "$before") <(vis)); do echo "   closing '$(xdotool getwindowname "$w" 2>/dev/null)'"; wmctrl -ic "$(printf '0x%08x' "$w")"; done
echo "   downloading: $(ls "$S/steamapps/downloading" 2>/dev/null | tr '\n' ' ')"
rm -rf "$T" /tmp/powos-verify-step
echo "RESULT steam-install: ${FAILS:+FAIL$FAILS - }$RES_"
[ -z "$FAILS" ]
