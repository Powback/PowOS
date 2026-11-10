#!/usr/bin/env python3
"""Stage D of game-audio-flow.sh: did Android actually play what KWin's audio bridge sent? Reads two
`dumpsys media.audio_flinger` snapshots taken a few seconds apart while the game plays (the Mac side takes them through
tools/phone/adb.sh), finds the PowOS app's tracks (the andromarchy engine's AAudio output, Client = the app's pid), and
prints per track: output thread + device, frames the server consumed between the snapshots, underruns, and its gains
(L/R/VS dB: -inf = muted by Android's stream/app volume). Then STREAM_MUSIC's volume/mute from `dumpsys audio` and the
app's player lines (Android 12+ lists per-player mute reasons there).
  game-audio-android.py <app pid> <af snapshot 1> <af snapshot 2> <dumpsys audio> -> rc 0 = a PowOS track advanced
  with audible gain, 1 = no track / not advancing / muted (the line says which), 5 = SKIP: the only "mute" is the
  user's own media volume at 0 (STREAM_MUSIC index 0 on its active device, not Muted) - Android plays nothing audible
  by the user's choice, so playback can't be judged; the reason is the last line ("D SKIP: ...")."""
import re, sys

pid, af1, af2, aud = sys.argv[1], *(open(p, errors="replace").read() for p in sys.argv[2:5])


def tracks(txt):
    """{(thread, track id): {column: value, 'thread': ..., 'device': ...}} for rows whose Client is pid."""
    out, thread, device, hdr = {}, "?", "?", None
    for line in txt.splitlines():
        m = re.match(r"\s*Output thread (0x[0-9a-f]+)", line)
        if m: thread, device, hdr = m.group(1), "?", None; continue
        # "Local log:" is the thread's track history (AT::add / removeTrack_l rows of long-gone tracks): not a live
        # track - 11-08's "not consuming frames" was read off such rows. Skip it until the next thread.
        if line.strip() == "Local log:": hdr, thread = None, "log"; continue
        if thread == "log": continue
        m = re.search(r"Output devices?: *(.*)", line)
        if m: device = m.group(1).strip()[:60]
        if "Client" in line and "Underruns" in line:
            # "L dB", "Chn mask", "Port Id" are two header words over one value: fold them to one column name
            h = [w for w in line.split() if w not in ("dB", "db", "mask")]
            hdr = []
            for w in h:
                if w == "Id" and hdr and hdr[-1] == "Port": hdr[-1] = "PortId"
                else: hdr.append(w)
            continue
        if hdr is None or not line.strip():
            hdr = None if not line.strip() else hdr; continue
        tok = line.split()
        # Android 14+ prints Client as "28967/  10359" (pid/ uid, a space after the slash) under a one-word
        # "Client(pid/uid)" header: rejoin it, or every later column shifts by one (11-10: the shift read G's -inf as L
        # and the stream volume's PortVol -inf was never seen)
        for i in range(len(tok) - 1):
            if tok[i].endswith("/") and tok[i][:-1].isdigit(): tok[i:i + 2] = [tok[i] + tok[i + 1]]; break
        if not any(t == pid or t.startswith(pid + "/") for t in tok): continue
        if hdr[0] == "Type" and tok[0].isdigit(): tok = [""] + tok   # blank Type column
        row = dict(zip(hdr, tok)); row.update(thread=thread, device=device, raw=line.strip())
        out[(thread, row.get("Id", tok[1] if len(tok) > 1 else "?"))] = row
    return out


def music_volume(txt):
    """(index on STREAM_MUSIC's active device or None, Muted flag) from `dumpsys audio`'s "- STREAM_MUSIC:" block
    ("Muted: false | ... | Current: 2 (speaker): 0, 40000000 (default): 100 | Devices: speaker(2)")."""
    m = re.search(r"- STREAM_MUSIC:\n((?:\s{3,}.*\n?){1,12})", txt)
    if not m: return None, False
    blk = m.group(1)
    muted = bool(re.search(r"^\s*Muted: true", blk, re.M))
    cur = dict((n.strip(), int(v)) for n, v in re.findall(r"\(([^)]+)\): (\d+)", blk.split("Current:", 1)[-1].split("\n")[0]))
    dev = re.search(r"Devices: *([\w ]+?)\(", blk)
    name = dev.group(1).strip() if dev else "speaker"
    return cur.get(name, cur.get("default")), muted


vol, music_muted = music_volume(aud)
vol0 = vol == 0 and not music_muted   # the user's media volume slider at 0: their setting, not a mute bug
t1, t2 = tracks(af1), tracks(af2)
ok = skip = False
if not t2:
    print(f"D FAIL: no AudioFlinger track for the PowOS app (pid {pid}) - the bridge's AAudio output is not open/started")
for k, r in t2.items():
    prev = t1.get(k, {})
    def num(row, col, base=10):
        try: return int(row.get(col, ""), base)
        except ValueError: return None
    s1, s2 = num(prev, "Server", 16), num(r, "Server", 16)
    adv = (s2 - s1) if s1 is not None and s2 is not None else None
    u1, u2 = num(prev, "Underruns"), num(r, "Underruns")
    gains = {c: r.get(c) for c in ("L", "R", "VS", "G", "PortVol", "PortMuted") if c in r}
    # G (the aux/master send column) reads -inf on normal playing tracks; only L/R/VS are the track's own volume
    muted = any(gains.get(c) and "inf" in gains[c] for c in ("L", "R", "VS"))
    # Android 14+: the stream volume/mute lands on the output port (PortVol dB / PortMuted), the track's own L/R/VS stay 0
    muted = muted or "inf" in (gains.get("PortVol") or "") or gains.get("PortMuted") == "true"
    print(f"D track thread={r['thread']} device={r['device']} active={r.get('Active', '?')} "
          f"server_frames_advanced={adv} underruns={u1}->{u2} gains_dB={gains}")
    print("   ", r["raw"][:200])
    if adv and adv > 0 and not muted: ok = True
    # -inf with the media volume at 0 (not Muted): the user's slider, so neither PASS nor FAIL can be judged
    elif muted and vol0: skip = True
    elif muted: print("D FAIL: the PowOS track is muted by Android (L/R/VS or port gain -inf / PortMuted: stream/app volume or mute)")
    elif not adv: print("D FAIL: the PowOS track is not consuming frames (stopped/paused or its thread is not running)")
m = re.search(r"- STREAM_MUSIC:\n((?:\s{3,}.*\n){1,12})", aud)
print("D STREAM_MUSIC:", " | ".join(l.strip() for l in (m.group(1).splitlines() if m else ["not found"])
                                    if re.search(r"Muted|Current|Min|Max|Devices", l) or not m)[:400])
for l in aud.splitlines():
    if re.search(rf"\bpid:{pid}\b|/{pid}\b", l) and re.search(r"(?i)player|mute|usage", l):
        print("D player:", l.strip()[:220])
if ok:
    print("D PASS: a PowOS track is consuming frames at audible gain - Android plays it"); sys.exit(0)
if skip:
    print("D SKIP: media volume is 0 (user setting) - can't judge Android playback"); sys.exit(5)
print("D verdict: Android does NOT play the bridge's audio (see the FAIL line above)")
sys.exit(1)
