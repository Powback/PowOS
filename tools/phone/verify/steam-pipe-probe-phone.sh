#!/bin/bash
# steam-pipe-probe-phone.sh: (in the PowOS session as powos; steam-pipe-probe.sh pushes and runs it) why Steam's ARM64
# client never takes a launch forwarded through ~/.steam/steam.pipe (skill: powos-games). It reads the pipe (0 bytes
# left unread, 2026-10-23 04:32) but logs no ExecCommandLine. Three probes against the running client:
#   capture  the forwarder's bytes: a copy of ~/.steam (steam.pid = the live client) with a FIFO of our own as the pipe,
#            HOME pointed at it, `./steam steam://rungameid/<APP>` -> what it writes (od -c)
#   line     a line written by hand into the real pipe in the format the client logs ("'<exe>' 'steam://...'\n")
#   replay   the captured bytes written into the real pipe by cat
# Each: did console_log get "ExecCommandLine ... rungameid" within 15 s. A game that starts is closed (bf-stop.sh).
set -uo pipefail
APP=${APP:-274190}
. /var/tmp/powos-bf-lib.sh
S=$HOME/.local/share/Steam CL=$S/logs/console_log.txt
p=$(steam_pid)
[ -d "/proc/$p" ] || { echo "== no running Steam: starting one (-silent), 60 s"; ( cd ~ && setsid -f steam -silent >/dev/null 2>&1 </dev/null ); sleep 60; p=$(steam_pid); }
[ -d "/proc/$p" ] || { echo "RESULT steam-pipe-probe: FAIL no Steam"; exit 1; }
echo "== $(date +%T) client $p $(readlink /proc/$p/exe), $(pacman -Q steam)"
taken() {  # taken <line count before>: the client logged the launch
  for _ in $(seq 30); do tail -n +$(($1 + 1)) "$CL" | grep -q "rungameid/$APP" && return 0; touched; sleep 0.5; done; return 1; }
after() { tail -n +$(($1 + 1)) "$CL" | grep -v SlowJSMethodCall | tail -4 | cut -c1-160 | tr '\n' '|'; }
gone() { bash /var/tmp/powos-bf-stop.sh >/dev/null 2>&1; sleep 3; }
mine=1

# capture
pill "Steam pipe probe: capturing the forwarder's bytes"
H=$(mktemp -d /tmp/pipe-probe.XXXX); mkdir -p "$H/.steam"
for f in steam.pid steam.token registry.vdf; do cp -p ~/.steam/$f "$H/.steam/" 2>/dev/null; done
for l in root steam sdkarm64; do ln -s "$(readlink ~/.steam/$l)" "$H/.steam/$l"; done
mkfifo "$H/.steam/steam.pipe"; ( exec 3<>"$H/.steam/steam.pipe"; timeout 25 cat <&3 > "$H/cap" ) &
mkdir -p "$H/.local/share"; ln -s "$S" "$H/.local/share/Steam"
cl=$(wc -l < "$CL")
# As /usr/bin/steam runs it: the sysvipc shim preloaded (Y700_SYSV_DEBUG: its semget/semop calls in fwd.out).
SV=$HOME/.local/share/powos-sysvipc
( cd "$S/steamrtarm64" && HOME=$H Y700_SYSV_DEBUG=1 LD_PRELOAD="$SV/aarch64/libsysvipc-emu.so" timeout 20 ./steam -cef-disable-gpu-sandbox "steam://rungameid/$APP" > "$H/fwd.out" 2>&1 < /dev/null ); rc=$?
sleep 2
echo "capture: forwarder rc $rc said '$(grep -v 'LD_PRELOAD\|^$' "$H/fwd.out" | tail -2 | cut -c1-100 | tr '\n' '|')'; $(stat -c %s "$H/cap" 2>/dev/null || echo 0) bytes:"
od -c "$H/cap" 2>/dev/null | head -12 | sed 's/^/   /'
echo "capture: forwarder's System V IPC: $(grep -a '^\[sysvipc-emu' "$H/fwd.out" | sed 's/^\[sysvipc-emu [0-9]*\] //' | head -8 | cut -c1-90 | tr '\n' '|')"
echo "capture: the real client logged it anyway: $(taken "$cl" && echo yes || echo no)"
# Anything still running with that HOME (a forwarder that took itself for the first Steam): gone.
for e in /proc/[0-9]*/environ; do tr '\0' '\n' < "$e" 2>/dev/null | grep -qx "HOME=$H" && kill -9 "$(basename "$(dirname "$e")")" 2>/dev/null; done

# line
pill "Steam pipe probe: a line written by hand"
gone; cl=$(wc -l < "$CL")
printf "'%s' '%s' 'steam://rungameid/%s'\n" "$S/steamrtarm64/steam" -cef-disable-gpu-sandbox "$APP" > ~/.steam/steam.pipe
echo "line: $(taken "$cl" && echo TAKEN || echo "not taken") - after: $(after "$cl")"

# replay
if [ -s "$H/cap" ]; then
  pill "Steam pipe probe: the forwarder's bytes replayed"
  gone; cl=$(wc -l < "$CL")
  cat "$H/cap" > ~/.steam/steam.pipe
  echo "replay: $(taken "$cl" && echo TAKEN || echo "not taken") - after: $(after "$cl")"
fi
rm -rf "$H"
close_mine
echo "RESULT steam-pipe-probe: done"
