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
# Fire and forget, no steam:// URL: with Steam closed, each game gets an appmanifest (StateFlags 1026 = update
# required) named and placed from Steam's own appinfo cache; Steam, started once out of sight, downloads them all in
# the background and this exits. URLs handed to a running Steam were dropped (skill: powos-games, forwarded launches):
# 2026-10-23 05:40 six installs waited 90 s each for nothing, 300 s budget gone. Never with a game of Steam's
# running (it would be closed): then the URL path below, as before. Games appinfo doesn't know: the URL path too.
stubs() {
  python3 - "$S" "$@" <<'PY'
import os, struct, sys
S, ids = sys.argv[1], sys.argv[2:]
b = open(os.path.join(S, "appcache/appinfo.vdf"), "rb").read()
magic = struct.unpack_from("<I", b, 0)[0]; strtab = None; pos = 8
if magic >= 0x07564429:
    so = struct.unpack_from("<q", b, 8)[0]; n = struct.unpack_from("<I", b, so)[0]; q = so + 4; strtab = []
    for _ in range(n):
        e = b.index(b"\0", q); strtab.append(b[q:e].decode("utf8", "replace")); q = e + 1
    pos = 16
def key(p):
    if strtab is not None: return strtab[struct.unpack_from("<I", b, p)[0]], p + 4
    e = b.index(b"\0", p); return b[p:e].decode("utf8", "replace"), e + 1
def parse(p):
    d = {}
    while True:
        ty = b[p]; p += 1
        if ty == 8: return d, p
        k, p = key(p)
        if ty == 0: v, p = parse(p)
        elif ty == 1: e = b.index(b"\0", p); v = b[p:e].decode("utf8", "replace"); p = e + 1
        elif ty in (2, 3, 4, 6): v = struct.unpack_from("<i", b, p)[0]; p += 4
        elif ty in (7, 10): v = struct.unpack_from("<Q", b, p)[0]; p += 8
        else: raise ValueError(ty)
        d[k] = v
head = 8 + 4 + 4 + 8 + 20 + 4 + (20 if magic >= 0x07564428 else 0)
want, found = set(ids), {}
while True:
    appid, size = struct.unpack_from("<II", b, pos)
    if appid == 0: break
    if str(appid) in want:
        try:
            a = parse(pos + head)[0].get("appinfo", {})
            found[str(appid)] = (a.get("common", {}).get("name"), a.get("config", {}).get("installdir"))
        except Exception:
            pass
    pos += 8 + size
for i in ids:
    name, idir = found.get(i, (None, None))
    m = os.path.join(S, "steamapps", "appmanifest_%s.acf" % i)
    if not name or not idir or os.path.exists(m):
        print(i, "skip"); continue
    with open(m + ".tmp", "w") as f:
        f.write('"AppState"\n{\n\t"appid"\t\t"%s"\n\t"Universe"\t\t"1"\n\t"name"\t\t"%s"\n\t"StateFlags"\t\t"1026"\n'
                '\t"installdir"\t\t"%s"\n\t"LastUpdated"\t\t"0"\n\t"SizeOnDisk"\t\t"0"\n\t"buildid"\t\t"0"\n'
                '\t"AutoUpdateBehavior"\t\t"0"\n}\n' % (i, name.replace('"', ''), idir.replace('"', '')))
    os.replace(m + ".tmp", m)
    print(i, "stub", name)
PY
}
todo=(); for id in "$@"; do [ -n "$(flags "$id")" ] || todo+=("$id"); done
if [ ${#todo[@]} -gt 0 ] && ! pgrep -f 'SteamLaunch AppId=' >/dev/null; then
  pill "Steam installs: closing Steam to queue ${#todo[@]} download(s)"
  bash /var/tmp/powos-bf-stop.sh --steam | head -1
  stubs "${todo[@]}" | while read -r id how name; do [ "$how" = stub ] && echo "== $id: appmanifest written ($name), Steam downloads it"; done
  ( cd ~ && setsid -f steam -silent >/dev/null 2>&1 </dev/null )
  for _ in $(seq 60); do pgrep -f steamwebhelper >/dev/null && break; touched; sleep 1; done
fi
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
