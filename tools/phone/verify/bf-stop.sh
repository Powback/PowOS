# bf-stop.sh: (in the PowOS session as powos) close Broforce + Steam, drop the never-sleep entry. Thaws a frozen Steam
# first (a frozen client never answers -shutdown) and kills every Broforce launch chain, also one left behind by a dead
# Steam (ppid 1: never frozen, never resumed, it held the prefix's wineserver so the next launch hung, 2026-10-22).
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/powos-app}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
dbus-send --session --print-reply=literal --reply-timeout=3000 --dest=dev.powos.Sleep /Gui dev.powos.Sleep.Gui.Wake \
  string:steam >/dev/null 2>&1
kids() { local p; for p in "$@"; do echo "$p"; kids $(pgrep -P "$p"); done; }
pkill -f Broforce_beta.exe; sleep 3
for p in $(kids $(pgrep -f 'SteamLaunch AppId=274190( |$)')); do kill -9 "$p" 2>/dev/null; done
steam -shutdown >/dev/null 2>&1
for i in $(seq 40); do pgrep -f 'steam -cef|steamwebhelper|ubuntu12_32/steam|steamrtarm64/steam' >/dev/null || break; sleep 1; done
pkill -9 -f steamwebhelper; pkill -9 -f 'ubuntu12_32/steam'; pkill -9 -f 'steamrtarm64/steam '; pkill -9 -f '^\./steam -cef'; pkill -f wineserver
powos sleep never --remove steam 2>&1 | tail -2
pgrep -af 'steam|Broforce|wineserver' | grep -v pgrep | head -5; echo stopped
