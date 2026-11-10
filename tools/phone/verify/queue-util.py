#!/usr/bin/env python3
"""queue-util.py: how much of the phone's idle-window time the verify queue turned into verdicts.

  queue-util.py [--since EPOCH] [--windows] UTIL_LOG          the runner's own records (queue.sh util_rec)
  queue-util.py [--last S] [--windows] --runner-log LOG       the same, rebuilt from runner.log's text (older runs;
                                                              --last: its trailing S seconds)
  queue-util.py --history LOG                                 per check script, from runner.log: "<script> <runs>
                                                              <p50 s> <budget s>" (queue.sh's job_budget / order_quick)

UTIL_LOG lines (queue.sh writes them):
  J <start> <end> <class> <job>   one job: class pass | fail | skip | touched | precond | early | stopped | timeout
  W <open> <close>                one idle window: from window_lock's grant to its release
Useful = pass + fail seconds (a job that produced a verdict). Everything else in a window is wasted: rc-3 tries
(precond = nobody touched the phone and it still had no result; touched = the user came back; early = gave up at once),
SKIPs, and the gaps between jobs (launch of the next job, re-checks, yields). Why (11-07 03:3x): the user saw the
phone "just waiting in the switcher" while ABZU jobs ended rc 3 "touched" six times in a row with nobody on it.
One line out; --windows adds one line per window.
"""
import re
import sys

USEFUL = {"pass", "fail", "timeout"}   # a timeout is a FAIL verdict too


WAKES = []


def from_util(path, since):
    jobs, wins = [], []
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return jobs, wins
    for ln in lines:
        p = ln.split()
        try:
            if p[0] == "J" and len(p) >= 4 and int(p[2]) >= since:
                jobs.append((int(p[1]), int(p[2]), p[3]))
            elif p[0] == "K" and len(p) >= 3 and int(p[1]) >= since:
                WAKES.append(int(p[2]))   # queue.sh wl_done: the queue woke the phone for that many jobs
            elif p[0] == "W" and len(p) >= 3 and int(p[2]) >= since:
                wins.append((int(p[1]), int(p[2])))
        except (ValueError, IndexError):
            continue
    return jobs, wins


RUN = re.compile(r"^(\d\d):(\d\d):(\d\d) run (\S+): ")
END = re.compile(r"^(\d\d):(\d\d):(\d\d) (\S+): (.*)$")


def classify(rest):
    if rest.startswith("PASS"):
        return "pass"
    if rest.startswith("FAIL"):
        return "fail"
    if rest.startswith(("SKIP", "INVALID")):
        return "skip"
    if rest.startswith(("no window / touched (rc 3)", "rc 3 for the ")):
        return "rc3"
    if rest.startswith("stopped from the phone"):
        return "stopped"
    return None


def from_runner_log(path, since, gap_s=90):
    """Old runner.log has HH:MM:SS only: days follow from the clock going backwards. A window = jobs back to back
    (the next one starts within gap_s of the last one's end). An rc 3 followed by "rc 3 but the phone is still idle"
    was nobody's touch (the old runner called every rc 3 "touched"): precond; without it, touched."""
    jobs, day, last, cur, rc3 = [], 0, -1, {}, {}
    for ln in open(path, encoding="utf-8", errors="replace"):
        m = RUN.match(ln) or END.match(ln)
        if not m:
            continue
        t = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        if last >= 0 and t < last - 3600:
            day += 1
        last = t
        at = day * 86400 + t
        if RUN.match(ln):
            cur[m.group(4)] = at
            continue
        job, rest = m.group(4), m.group(5)
        if rest.startswith("rc 3 but the phone is still idle") and job in rc3:
            jobs[rc3.pop(job)][2] = "precond"
            continue
        c = classify(rest)
        if c and job in cur:
            if c == "rc3":
                c = "touched"; rc3[job] = len(jobs)
            jobs.append([cur.pop(job), at, c])
    jobs.sort()
    wins = []
    for s, e, _ in jobs:
        if wins and s - wins[-1][1] <= gap_s:
            wins[-1][1] = max(wins[-1][1], e)
        else:
            wins.append([s, e])
    if since < 0 and jobs:   # --last S: the trailing S seconds of the log
        base = jobs[-1][1] + since
        jobs = [j for j in jobs if j[1] >= base]
        wins = [w for w in wins if w[1] >= base]
    return [tuple(j) for j in jobs], [tuple(w) for w in wins]


def report(jobs, wins, per_window=False):
    tot = sum(max(0, e - s) for s, e in wins)
    by = {}
    for s, e, c in jobs:
        by[c] = by.get(c, 0) + max(0, e - s)
    useful = sum(v for k, v in by.items() if k in USEFUL)
    inj = sum(by.values())
    gaps = max(0, tot - inj)
    pct = (100 * useful // tot) if tot else 0
    nv = sum(1 for _, _, c in jobs if c in USEFUL)
    waste = ", ".join(f"{k} {v}s" for k, v in sorted(by.items()) if k not in USEFUL and v) or "none"
    # A timeout is a FAIL verdict, but a kill at the budget usually says only "still at step X" (11-08..11-09: 3452 s
    # of 48 h window time, the largest class, mostly killed at their first step) - shown so it isn't read as useful.
    tmo = f" - {by['timeout']}s of it timeouts" if by.get("timeout") else ""
    lines = [f"utilization: {len(wins)} windows, {tot}s window time, {useful}s on {nv} verdicts ({pct}%{tmo}); "
             f"wasted {tot - useful}s: {waste}, gaps {gaps}s"
             + (f"; woke the phone {len(WAKES)} times for {sum(WAKES)} jobs" if WAKES else "")]
    if per_window:
        for a, b in wins:
            inw = [(s, e, c) for s, e, c in jobs if s >= a and e <= b + 1]
            u = sum(e - s for s, e, c in inw if c in USEFUL)
            lines.append(f"  window {a}-{b}: {b - a}s, {u}s verdicts ({(100 * u // (b - a)) if b > a else 0}%), {len(inw)} jobs")
    return "\n".join(lines)


# --history: what each check script costs, from its past runs in runner.log ("run <job>: <cmd>" + its verdict line).
# Why (11-09, the window ledger 11-07 05:31 - 11-09 04:03): 15336 s of idle windows, 45% on PASS/FAIL verdicts, 16% on
# "FAIL timeout" kills - every one at the 300 s default budget (962 of 1104 jobs carry it), never an explicit one. A
# check known to finish in 60 s that hangs burnt 300 s; a check that passes in 366 s by design (e2e-desktop: 9 passes over
# 240 s) was killed as a FAIL. The budget follows the check's own history instead (queue.sh job_budget, default
# budgets only):
#   lower: >= HIST_MIN_DONE completed runs (PASS/FAIL, no timeout) in its last 20: 2 x their max + 60, at least 120 s
#   raise: >= 3 PASSes, the longest over 80% of the default, not a games/Steam check (a slow game launch IS the FAIL,
#          the add-time rule): 1.25 x the longest pass + 30, at most HIST_MAX_S (900)
# The p50 is the expected run time: queue.sh order_quick runs short checks first in a window.
HRUN = re.compile(r"^(\d\d):(\d\d):(\d\d) run (\S+): (.*)$")
HEND = re.compile(r"^(\d\d):(\d\d):(\d\d) (\S+): (PASS|FAIL|SKIP|INVALID|no window|rc 3|stopped|past its)(.*)$")
GAMES = re.compile(r"^(bf-|steam-|td-launch|mc-launch|games?-)|fps|(^|[^a-z])fold([^a-z]|$)|kernel")   # queue.sh HW_ONLY
HIST_MIN_DONE, HIST_MAX_S, DEFAULT_BUDGET = 5, 900, 300


def script_key(cmd):
    """The check a command runs: its first *.sh / *.py word's basename (env X=1 ... / bash -c "..." aside)."""
    for w in cmd.replace('"', " ").replace("'", " ").split():
        if w.endswith((".sh", ".py")):
            return w.rsplit("/", 1)[-1]
    return ""


def history(path):
    day, last, cur, runs = 0, -1, {}, {}
    try:
        f = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return {}
    for ln in f:
        m = HRUN.match(ln) or HEND.match(ln)
        if not m:
            continue
        t = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        if last >= 0 and t < last - 3600:
            day += 1
        last = t
        at = day * 86400 + t
        if HRUN.match(ln):
            cur[m.group(4)] = (at, script_key(m.group(5)))
            continue
        if m.group(5) == "past its" or m.group(4) not in cur:
            continue
        a, k = cur.pop(m.group(4))
        if not k:
            continue
        rest = m.group(5) + m.group(6)
        kind = "timeout" if rest.startswith("FAIL timeout") else ("pass" if rest.startswith("PASS") else
                                                                   "fail" if rest.startswith("FAIL") else "other")
        runs.setdefault(k, []).append((at - a, kind))
    return runs


def budget_of(key, runs):
    """(p50, budget) for one script's runs (oldest first); budget 0 = keep the job's own."""
    recent = runs[-20:]
    done = sorted(d for d, k in recent if k in ("pass", "fail"))
    p50 = done[len(done) // 2] if done else 0
    passes = [d for d, k in runs if k == "pass"][-20:]
    if len(passes) >= 3 and max(passes) > 0.8 * DEFAULT_BUDGET and not GAMES.match(key):
        return p50, min(HIST_MAX_S, int(1.25 * max(passes)) + 30)
    if len(done) >= HIST_MIN_DONE and not key.endswith("-install.sh"):   # an install's time follows its package
        b = max(120, 2 * done[-1] + 60)
        return p50, (b if b < DEFAULT_BUDGET else 0)
    return p50, 0


def main(argv):
    if argv[:1] == ["--history"] and len(argv) >= 2:
        for k, v in sorted(history(argv[1]).items()):
            p50, b = budget_of(k, v)
            print(k, len(v), p50, b)
        return 0
    since, per, rlog, path = 0, False, None, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--since":
            since = int(argv[i + 1]); i += 2; continue
        if a == "--last":
            since = -int(argv[i + 1]); i += 2; continue
        if a == "--windows":
            per = True
        elif a == "--runner-log":
            rlog = argv[i + 1]; i += 2; continue
        else:
            path = a
        i += 1
    if rlog:
        jobs, wins = from_runner_log(rlog, since)
    elif path:
        jobs, wins = from_util(path, since)
    else:
        print(__doc__.strip().splitlines()[0]); return 2
    print(report(jobs, wins, per))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
