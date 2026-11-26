#!/usr/bin/env python3
"""tools/agents/coordinator-relay.py (Mac) - the phone's mail to the "coordinator" role, relayed to the Mac coordinator.

PowOS mobile's manager on the phone writes `powos comms send coordinator ...`; that lands in the phone's spool
(/var/lib/powos/comms/agents/coordinator/inbox) where nobody reads it (11-26: "agent is messaging coordinator, are you
aware"). The coordinator is the Claude Code session on the Mac, so each pass:

  1. phone off the VPN (tools/phone/adb.sh --vpn-state exits non-zero)? exit 0 at once, no adb call - mail waits in
     the phone's spool and goes out on the first pass after it reconnects;
  2. `powos comms inbox --agent coordinator --peek --json` on the phone, as the session user (tools/phone/user.sh);
  3. every message whose id is not yet in ~/.cache/powos-coordinator-inbox.jsonl is appended there (id, from,
     priority, time, body, ...) and gets one summary line in ~/.cache/powos-coordinator-inbox.log (what the Mac
     coordinator watches: `tail -F`, or Monitor);
  4. only then `powos comms read <ids> --agent coordinator` on the phone, for the ids the Mac file now holds.
     A crash between 3 and 4 re-sees them next pass; the id check makes that a no-op append + the read.

Read-only on the phone except step 4. Idempotent by id. Reply: tools/agents/reply-phone.sh <id> <text>.
Run by launchd com.powos.coordinator-relay every 60 s (tools/agents/coordinator-relay-deploy.sh; unit
units/mac/coordinator-relay-mac.json).

Tests (test/tier1/test-coordinator-relay.sh) swap the phone for a local fake spool:
  RELAY_PHONE_STATE  command whose exit status says online (0) / offline (else)   default: adb.sh --vpn-state
  RELAY_PHONE_RUN    command run with one argument, a bash script to run as the phone's session user
                                                                                   default: tools/phone/user.sh
  RELAY_INBOX        the .jsonl path (the .log sits next to it, same stem)         default: ~/.cache/powos-coordinator-inbox.jsonl
  RELAY_AGENT        the role relayed                                              default: coordinator
"""
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PHONE = os.path.join(HERE, "..", "phone")
AGENT = os.environ.get("RELAY_AGENT", "coordinator")
INBOX = os.path.expanduser(os.environ.get("RELAY_INBOX", "~/.cache/powos-coordinator-inbox.jsonl"))
LOG = os.path.splitext(INBOX)[0] + ".log"
LOCK = INBOX + ".lock"
STATE_CMD = shlex.split(os.environ.get("RELAY_PHONE_STATE", "")) or [os.path.join(PHONE, "adb.sh"), "--vpn-state"]
RUN_CMD = shlex.split(os.environ.get("RELAY_PHONE_RUN", "")) or [os.path.join(PHONE, "user.sh")]
TIMEOUT = float(os.environ.get("RELAY_TIMEOUT_S", "90"))
# comms ids are uuid4().hex[:12]; anything else never reaches a phone command line.
_ID = re.compile(r"^[0-9A-Za-z_-]{1,64}$")
_ROLE = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")


def err(*a):
    print(time.strftime("%F %T"), "coordinator-relay:", *a, file=sys.stderr)


def phone_online():
    try:
        return subprocess.run(STATE_CMD, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def phone_run(script):
    """Run a bash script as the phone's session user; (rc, stdout). rc 124: timed out."""
    with tempfile.NamedTemporaryFile("w", suffix=".sh", prefix="coord-relay-", delete=False) as f:
        f.write("set -eo pipefail\n" + script)
        path = f.name
    try:
        p = subprocess.run(RUN_CMD + [path], capture_output=True, text=True, timeout=TIMEOUT,
                           stdin=subprocess.DEVNULL)
        if p.returncode:
            err(f"phone command rc {p.returncode}: {p.stderr.strip()[-300:]}")
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired:
        err(f"phone command timed out after {TIMEOUT:.0f} s")
        return 124, ""
    finally:
        os.unlink(path)


def known_ids():
    ids = set()
    try:
        with open(INBOX, encoding="utf-8") as f:
            for line in f:
                try:
                    ids.add(json.loads(line)["id"])
                except (ValueError, KeyError, TypeError):
                    continue
    except FileNotFoundError:
        pass
    return ids


def summary(m):
    body = " ".join(str(m.get("body", "")).split())
    if len(body) > 200:
        body = body[:199] + "…"
    flag = "!! " if m.get("priority") in ("high", "urgent") else ""
    return (f"{m.get('time', '?')} {flag}[{m.get('priority', 'normal')}] {m.get('from', '?')} -> {AGENT} "
            f"(id {m['id']}): {body}  | reply: tools/agents/reply-phone.sh {m['id']} '<text>'")


def lock():
    """One pass at a time (launchd never overlaps its own job, but a manual `run` may). A lock older than 10 min is a
    dead pass's: taken over."""
    os.makedirs(os.path.dirname(INBOX), exist_ok=True)
    try:
        os.mkdir(LOCK)
        return True
    except FileExistsError:
        try:
            if time.time() - os.path.getmtime(LOCK) > 600:
                os.rmdir(LOCK)
                os.mkdir(LOCK)
                return True
        except OSError:
            pass
        return False


def relay():
    if not phone_online():
        return 0  # mail stays in the phone's spool; the first pass after reconnect delivers it
    rc, out = phone_run(f"powos comms inbox --agent {shlex.quote(AGENT)} --peek --json\n")
    if rc:
        return 0  # dropped mid-call / phone busy: next pass
    msgs = []
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue  # user.sh / powos-run.sh chatter
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if isinstance(m, dict) and _ID.match(str(m.get("id", ""))):
            msgs.append(m)
    if not msgs:
        return 0
    have = known_ids()
    new = [m for m in msgs if m["id"] not in have]
    if new:
        now = time.strftime("%Y-%m-%dT%H:%M:%S")
        with open(INBOX, "a", encoding="utf-8") as f, open(LOG, "a", encoding="utf-8") as lg:
            for m in new:
                rec = {"id": m["id"], "from": m.get("from", "unknown"), "priority": m.get("priority", "normal"),
                       "time": m.get("iso") or m.get("ts"), "body": m.get("body", ""), "kind": m.get("kind"),
                       "to": m.get("to", AGENT), "relayed": now}
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                lg.write(summary(rec) + "\n")
                have.add(m["id"])
            f.flush()
            os.fsync(f.fileno())
            lg.flush()
    # Only ids the Mac file holds (all of them now) are marked read on the phone.
    done = [m["id"] for m in msgs if m["id"] in have]
    rc, _ = phone_run(f"powos comms read {' '.join(done)} --agent {shlex.quote(AGENT)} >/dev/null\n")
    if rc:
        err(f"{len(done)} relayed message(s) not yet marked read on the phone; next pass retries (no duplicates)")
    if new:
        err(f"relayed {len(new)} new message(s) to {INBOX}")
    return 0


def reply(mid, text):
    """tools/agents/reply-phone.sh: send `text` to the sender of relayed message `mid`, on the phone, from the
    coordinator role."""
    rec = None
    try:
        with open(INBOX, encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("id") == mid:
                    rec = r
    except FileNotFoundError:
        pass
    if rec is None:
        print(f"reply-phone: no relayed message {mid!r} in {INBOX}", file=sys.stderr)
        return 2
    to = str(rec.get("from", ""))
    if not _ROLE.match(to) or to == "unknown":
        print(f"reply-phone: message {mid} has no usable sender ({to!r})", file=sys.stderr)
        return 2
    if not text.strip():
        print("reply-phone: refusing an empty reply", file=sys.stderr)
        return 2
    if not phone_online():
        print("reply-phone: phone offline (adb.sh --vpn-state); nothing sent", file=sys.stderr)
        return 69
    pri = rec.get("priority") if rec.get("priority") in ("high", "urgent") else "normal"
    body = f"Re {mid}: {text}"
    eof = "POWOS_REPLY_EOF_" + os.urandom(6).hex()  # a quoted heredoc: the body reaches send byte for byte
    rc, out = phone_run(f"powos comms send {shlex.quote(to)} - --from {shlex.quote(AGENT)} --priority {pri} "
                        f"<<'{eof}'\n{body}\n{eof}\n")
    if rc:
        print(f"reply-phone: send failed (rc {rc})", file=sys.stderr)
        return rc
    print(out.strip())
    with open(LOG, "a", encoding="utf-8") as lg:
        lg.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {AGENT} -> {to} (re {mid}): "
                 f"{' '.join(text.split())[:200]}\n")
    return 0


def main(argv):
    if argv[:1] == ["reply"]:
        if len(argv) < 3:
            print("usage: tools/agents/reply-phone.sh <id> <text...|->", file=sys.stderr)
            return 2
        text = sys.stdin.read() if argv[2:] == ["-"] else " ".join(argv[2:])
        return reply(argv[1], text)
    if argv and argv[0] not in ("run",):
        print(__doc__.strip().split("\n\n")[0], file=sys.stderr)
        return 2
    if not lock():
        return 0
    try:
        return relay()
    finally:
        try:
            os.rmdir(LOCK)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
