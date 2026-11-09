#!/bin/bash
# game-audio-android.py (stage D of tools/phone/verify/game-audio-flow.sh, board task
# no-game-audio-per-game-audio-group-loopback-drop) reads AudioFlinger's track table, whose header has two-word
# columns over one value ("L dB", "Chn mask", "Port Id") and a blank Type column: a playing PowOS track must read as
# PASS, a stalled one as "not consuming", a -inf L/R/VS one as "muted", none as "no AudioFlinger track".
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); P=$ROOT/tools/phone/verify/game-audio-android.py
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok() { if grep -q "$3" <<<"$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: want /$3/ in: $2"; fi; }
af() {  # <server frames> <underruns> <VS dB>
  printf 'Output thread 0x7a1 type 0 (MIXER):\n  Output devices: 0x2 (AUDIO_DEVICE_OUT_SPEAKER)\n'
  printf '  Type     Id Active Client Session Port Id S  Flags   Format Chn mask  SRate ST Usg CT  G db  L dB  R dB  VS dB   Server FrmCnt  FrmRdy F Underruns  Flushed   Latency\n'
  printf '           58    yes  12345    233      25 A  0x000 00000001 00000003 48000  3   1  2  -inf     0     0  %s  %08X    1920    1920 A  %s        0  41.67 k\n\n' "$3" "$1" "$2"
}
printf -- '- STREAM_MUSIC:\n   Muted: false\n   Current: 2 (speaker): 9\n' >"$T/audio"
af 1000 0 0 >"$T/a"; af 97000 2 0 >"$T/b"; af 1000 0 -inf >"$T/m"
o=$(python3 "$P" 12345 "$T/a" "$T/b" "$T/audio"); ok "playing" "$o" "D PASS"
ok "frames counted" "$o" "server_frames_advanced=96000 underruns=0->2"
ok "music volume" "$o" "Current: 2 (speaker): 9"
o=$(python3 "$P" 12345 "$T/a" "$T/a" "$T/audio"); ok "stalled" "$o" "not consuming frames"
o=$(python3 "$P" 12345 "$T/a" "$T/m" "$T/audio"); ok "muted" "$o" "muted by Android"
o=$(python3 "$P" 999 "$T/a" "$T/b" "$T/audio"); ok "no track" "$o" "no AudioFlinger track"
# 11-08: only the thread's "Local log" history held the pid (no live track): that is "no track", not a stalled one
{ printf 'Output thread 0x7a1 type 0 (MIXER):\n  Local log:\n'
  printf '      Type     Id Active Client Session Port Id S  Flags   Format Chn mask  SRate ST Usg CT  G db  L dB  R dB  VS dB   Server FrmCnt  FrmRdy F Underruns  Flushed   Latency\n'
  printf '   11-08 18:36:18.739 AT::add  (0xb4)  110  no  12345/  10359  577  145 r  0x000 00000001 00000003  48000  3   1  2  -inf  0  0  0  00000000  2886  0 f  0  0  new\n\n'; } >"$T/l"
o=$(python3 "$P" 12345 "$T/l" "$T/l" "$T/audio"); ok "local log is history" "$o" "no AudioFlinger track"
python3 "$P" 12345 "$T/a" "$T/b" "$T/audio" >/dev/null; ok "rc pass" "$?" "^0$"
python3 "$P" 12345 "$T/a" "$T/a" "$T/audio" >/dev/null; ok "rc fail" "$?" "^1$"
echo "test-game-audio-android: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
