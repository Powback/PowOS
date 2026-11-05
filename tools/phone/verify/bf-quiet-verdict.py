#!/usr/bin/env python3
"""bf-quiet-verdict.py <samples.txt> <secs> [min game cpu %]: bf-quiet.sh's pass criteria over its soak samples.

Each sample block (bf-quiet-phone.sh output, one per ~60 s) holds "start focus X", "start resumed X", "gamecpu N
procs=a/b", "end focus X", "end resumed X". PASS only when the samples cover <secs> s of soak, the game's window
(PowosWindowActivity: KWin's window task) is focused AND resumed at the start and end of every sample - or, unfolded,
home (HomeShell) is, with its full-screen web window composed ("onscreen <n> web": bf-onscreen.sh; every unfolded soak
of 11-05 19:49-22:36 failed "start focus = HomeShell" though the game showed there) - and the game's
processes (FEX wine64 running Broforce_beta.exe) use >= min % of a core in every sample. The 2026-11-05 03:02 soak
printed PASS with home focused, no game process, for 600 s: a soak that measures no game is a FAIL, never a PASS.
Last line: "PASS ..." or "FAIL ..." (exit 0 / 1).
"""
import re
import sys

GAME = "PowosWindowActivity"
HOME = "HomeShell"  # unfolded: the game is its full-screen web window


def samples(text):
    out, cur = [], None
    for line in text.splitlines():
        m = re.match(r"^sample t=(\d+)", line)
        if m:
            cur = {"t": int(m.group(1)), "front": [], "cpu": None, "procs": "0/0"}
            out.append(cur)
            continue
        if cur is None:
            continue
        m = re.match(r"^(start|end) (focus|resumed) ?(\S*)", line)
        if m:
            cur["front"].append((m.group(1), m.group(2), m.group(3) or "none"))
        m = re.match(r"^(start|end) onscreen (\d+) (\S+)", line)
        if m:
            cur.setdefault("onscreen", {})[m.group(1)] = (int(m.group(2)), m.group(3))
        m = re.match(r"^gamecpu (-?\d+) procs=(\S+)", line)
        if m:
            cur["cpu"], cur["procs"] = int(m.group(1)), m.group(2)
    return out


def verdict(text, secs, min_cpu=25):
    ss = samples(text)
    if not ss:
        return False, "FAIL no soak samples"
    for s in ss:
        if len(s["front"]) < 4:
            return False, f"FAIL t={s['t']}s: sample incomplete (front {s['front']})"
        for when, what, who in s["front"]:
            n, how = s.get("onscreen", {}).get(when, (0, "none"))
            if who == HOME and how == "web" and n >= 1:
                continue
            if who != GAME:
                why = f", game layers {n} {how}" if who == HOME else ""
                return False, f"FAIL t={s['t']}s: the game's window not in front ({when} {what} = {who}{why})"
        if s["cpu"] is None:
            return False, f"FAIL t={s['t']}s: no game CPU reading"
        if s["procs"].startswith("0/") or s["procs"].endswith("/0"):
            return False, f"FAIL t={s['t']}s: no game process (Broforce_beta.exe procs {s['procs']})"
        if s["cpu"] < min_cpu:
            return False, f"FAIL t={s['t']}s: game CPU {s['cpu']}% < {min_cpu}% (not running?)"
    covered = ss[-1]["t"] + 60
    if covered < secs:
        return False, f"FAIL soak covered {covered} s of {secs} s"
    cpus = [s["cpu"] for s in ss]
    return True, (f"PASS game in front and running {secs} s: {len(ss)} samples, game CPU "
                  f"{min(cpus)}-{max(cpus)}% (mean {sum(cpus) // len(cpus)}%)")


if __name__ == "__main__":
    ok, line = verdict(open(sys.argv[1]).read(), int(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 25)
    print(line)
    sys.exit(0 if ok else 1)
