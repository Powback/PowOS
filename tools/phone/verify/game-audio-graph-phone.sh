#!/bin/bash
# Read-only: dump the PipeWire graph for a running Steam game's per-game audio group (Steam's pw-audio-namespace
# loopback 'device.audio_group:pw-audio-namespace.<pid>' -> forward -> anland-speaker), with each node's negotiated
# Format, channel maps and port links, so the silent-loopback cause (board task
# no-game-audio-per-game-audio-group-loopback-drop) is read from evidence. Run as the session user:
#   tools/phone/user.sh tools/phone/verify/game-audio-graph-phone.sh
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
ps -eo pid,args | grep -E '[p]w-audio-namespace' | cut -c1-200
pw-link -l 2>&1 | head -80
pw-dump 2>/dev/null | python3 -c '
import json,sys
for o in json.load(sys.stdin):
  if o.get("type")!="PipeWire:Interface:Node": continue
  p=o["info"]["props"]; s=json.dumps(p)
  if not any(k in s for k in ("audio_group","forward","anland-speaker","loopback","namespace")): continue
  print(o["id"], o["info"].get("state"), p.get("node.name"), p.get("media.class"), p.get("audio.position"), p.get("node.group"), p.get("node.link-group"))
  for prm in ("Format","EnumFormat"):
    v=o["info"].get("params",{}).get(prm)
    if v: print("   ",prm, json.dumps(v)[:400])
'
