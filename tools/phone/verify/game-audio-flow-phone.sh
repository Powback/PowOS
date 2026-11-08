#!/bin/bash
# game-audio-flow-phone.sh: (in the PowOS session as powos, a Steam game running) prove whether sound flows through
# Steam's per-game audio group, stage by stage, by peak level - board task no-game-audio-per-game-audio-group-loopback-drop.
#   tools/phone/user.sh tools/phone/verify/game-audio-flow-phone.sh
# Graph (11-08 dump, Broforce): game output_1/2 -> device.audio_group:pw-audio-namespace.<pid> (Audio/Sink, unpositioned
# playback_1/2) = capture side of a module-loopback Steam loads in ITS process (node.link-group loopback-<steampid>-N)
# -> stream.audio_group:... output_FL/FR -> anland-speaker (KWin -> Android). Channel maps are not the drop: PipeWire's
# channelmix pairs unpositioned channels 1:1 (channelmix-ops.c make_matrix "pairing UNK channels").
# Taps: a private pw-record (node.autoconnect=false) linked by hand to an output port pair, 2 s, peak of S16 samples:
#   A game's own output   B the loopback's output (what anland-speaker receives)   C B again while a 440 Hz tone
#   plays INTO the group sink (pw-play --target <group sink>, media.role Game).
# Also: the loopback owner's process state (a frozen/stopped Steam = a dead loopback with every node still "running"),
# each node's Props (mute, channel/soft volumes). Read-only except the tone (2 s, the group sink only).
# Exit: 0 = tone reaches the loopback output (B or C non-silent); 1 = tone silent at the loopback output; 3 = no group.
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
T=$(mktemp -d /tmp/gaflow.XXXX); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
pw-dump >"$T/dump.json" 2>/dev/null
python3 - "$T/dump.json" >"$T/info" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cl={o["id"]:o["info"]["props"] for o in d if o.get("type")=="PipeWire:Interface:Client"}
for o in d:
  if o.get("type")!="PipeWire:Interface:Node": continue
  p=o["info"]["props"]; n=p.get("node.name","")
  role=("group" if n.startswith("device.audio_group:") else "fwd" if n.startswith("stream.audio_group:") else
        "spk" if n=="anland-speaker" else "game" if p.get("media.class")=="Stream/Output/Audio" and "audio_group" not in n else None)
  if not role: continue
  c=cl.get(p.get("client.id"),{}); pr=(o["info"].get("params",{}).get("Props") or [{}])[0]
  print(role, o["id"], n.replace(" ","_"), c.get("application.process.id","?"), c.get("application.name","?").replace(" ","_"),
        "mute=%s vol=%s ch=%s soft=%s" % (pr.get("mute"), pr.get("volume"), pr.get("channelVolumes"), pr.get("softVolumes")))
PY
cat "$T/info"
grep -q '^group ' "$T/info" || { echo "FAIL: no device.audio_group sink (no game in Steam's audio group running)"; exit 3; }
read -r _ gid gname gpid _ < <(grep '^group ' "$T/info" | head -1)
fname=$(awk '$1=="fwd"{print $3; exit}' "$T/info")
echo "loopback owner pid $gpid: $(ps -o pid=,stat=,args= -p "$gpid" 2>/dev/null | cut -c1-120) cgroup=$(cat /proc/$gpid/cgroup 2>/dev/null | tail -1)"

peak() {  # <label> <out port A> <out port B> -> prints the peak (0..32767) of 2 s recorded from those two ports
  local n=gaflow-$RANDOM
  pw-record -P "{ node.name=$n node.autoconnect=false }" --format s16 --rate 48000 --channels 2 --channel-map FL,FR - >"$T/$n.raw" 2>/dev/null &
  local p=$!; for _ in $(seq 20); do pw-link -i 2>/dev/null | grep -q "^$n:input_FL" && break; sleep 0.1; done
  pw-link "$2" "$n:input_FL" 2>/dev/null; pw-link "$3" "$n:input_FR" 2>/dev/null
  sleep 2; kill $p 2>/dev/null; wait $p 2>/dev/null
  python3 -c 'import sys,array; a=array.array("h"); b=open(sys.argv[1],"rb").read(); a.frombytes(b[:len(b)//2*2]); print(sys.argv[2], "samples=%d peak=%d" % (len(a), max(map(abs,a)) if a else -1))' "$T/$n.raw" "$1"
}
gout=$(pw-link -l 2>/dev/null | awk -v g="$gname" '/^[^ |]/ && $0 !~ /audio_group/ {cur=$0} /\|->/ && index($0,g) && cur {print cur; cur=""}' | head -2 | tr '\n' ' ')
echo "game ports into the group: ${gout:-none}"
[ -n "$gout" ] && peak "A game-output" $gout
peak "B loopback-output" "$fname:output_FL" "$fname:output_FR" | tee "$T/B"
python3 - "$T/tone.wav" <<'PY'
import sys,wave,math,struct
w=wave.open(sys.argv[1],"wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
w.writeframes(b"".join(struct.pack("<hh",v,v) for v in (int(8000*math.sin(2*math.pi*440*i/48000)) for i in range(48000*4))))
PY
pw-play --target "$gid" -P '{ media.role=Game application.name=gaflow-tone }' "$T/tone.wav" 2>"$T/play.err" &
sleep 0.8
peak "C loopback-output+tone" "$fname:output_FL" "$fname:output_FR" | tee "$T/C"
wait 2>/dev/null; [ -s "$T/play.err" ] && echo "pw-play: $(head -c 300 "$T/play.err")"
c=$(sed -n 's/.*peak=\(-*[0-9]*\).*/\1/p' "$T/C"); b=$(sed -n 's/.*peak=\(-*[0-9]*\).*/\1/p' "$T/B")
if [ "${c:-0}" -gt 1000 ]; then echo "PASS: tone into $gname reaches the loopback output (peak $c; game-only $b)"; exit 0; fi
echo "FAIL: tone into $gname is silent at the loopback output (peak ${c:-none}; game-only ${b:-none})"; exit 1
