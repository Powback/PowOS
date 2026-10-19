#!/usr/bin/env python3
"""PowOS inter-agent comms — a daemonless mailbox MCP server.

Every ``powos ai`` agent is launched with this server wired in via
``--mcp-config`` and an identity in ``COMMS_AGENT_ID`` (its role name, e.g.
``devops``). The store is a plain spool directory — one inbox per agent role —
so there is NO daemon and NO backend: an agent "sends" by writing a JSON file
into the recipient's inbox, and "receives" by reading its own.

That fits PowOS's model, where an agent is a one-shot ``claude --print`` call
rather than a live session. Mail addressed to a role is durable: it waits in the
inbox until *whoever next runs as that role* drains it — or until a currently
running agent of that role is parked on ``wait_for_message`` and gets woken.

Delivery to an idle agent without polling: ``wait_for_message`` BLOCKS (watches
the inbox, returns the moment mail lands). Every tool result also carries a hint
pointing there — or at the native ``Monitor`` tool on the inbox path — so the
model yields instead of spinning on ``read_inbox``.

Transport: newline-delimited JSON-RPC 2.0 over stdio (the MCP stdio contract).
stdout carries protocol messages ONLY; all logging goes to stderr.

Environment:
  COMMS_AGENT_ID    this agent's role/identity (required; server errors without)
  COMMS_PARENT_ID   role that ``escalate`` reports to (default: ``user``)
  COMMS_ROOT        spool root (default: /var/lib/powos/comms; override for tests)
  COMMS_CAN_NOTIFY  "0" to forbid notify_user (non-root agents escalate instead)
"""

import json
import os
import re
import sys
import time
import uuid
import glob
import shutil
import subprocess

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "powos-comms"
SERVER_VERSION = "1.0.0"

AGENT_ID = os.environ.get("COMMS_AGENT_ID", "").strip()
PARENT_ID = os.environ.get("COMMS_PARENT_ID", "user").strip() or "user"
# Default spool under XDG state (user-writable); /var/lib/powos is root-owned on
# a fresh install. In practice comms.sh always passes COMMS_ROOT explicitly.
_XDG = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
ROOT = os.environ.get("COMMS_ROOT", "").strip() or os.path.join(_XDG, "powos", "comms")
CAN_NOTIFY = os.environ.get("COMMS_CAN_NOTIFY", "1").strip() != "0"

# A role name maps 1:1 onto an inbox directory, so it must be a safe path
# component — no traversal, no separators. Reject anything else loudly.
_SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$")

VALID_PRIORITIES = ("low", "normal", "high", "urgent")


def log(*a):
    print(f"[{SERVER_NAME}]", *a, file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Spool store
# ---------------------------------------------------------------------------

def _safe_name(name):
    name = (name or "").strip()
    if not _SAFE_NAME.match(name):
        raise ValueError(
            f"invalid agent name {name!r}: use letters/digits/._:- (max 64 chars)"
        )
    return name


def inbox_dir(agent):
    """Absolute path to an agent's inbox, created on demand."""
    d = os.path.join(ROOT, "agents", _safe_name(agent), "inbox")
    os.makedirs(d, exist_ok=True)
    return d


def _deliver(to, kind, message, priority, result=None):
    """Write one message atomically into ``to``'s inbox. Returns the message id."""
    to = _safe_name(to)
    if priority not in VALID_PRIORITIES:
        priority = "normal"
    mid = uuid.uuid4().hex[:12]
    # Millisecond timestamp prefix keeps the inbox filename-sortable = FIFO.
    stamp = f"{time.time():015.4f}"
    payload = {
        "id": mid,
        "from": AGENT_ID or "unknown",
        "to": to,
        "kind": kind,           # message | escalate | notify
        "priority": priority,
        "ts": stamp,
        "iso": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime()),
        "body": message,
    }
    if result is not None:
        payload["result"] = result
    d = inbox_dir(to)
    fname = f"{stamp}-{priority}-{mid}.json"
    dst = os.path.join(d, fname)
    tmp = dst + ".tmp"
    with open(tmp, "w") as f:
        json.dump(payload, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, dst)  # atomic: a reader never sees a half-written message
    _phone_wake(to)
    _agents_note(payload)
    return mid


def _pending_files(agent):
    """Inbox message files, oldest first (FIFO by filename timestamp prefix)."""
    d = inbox_dir(agent)
    files = sorted(glob.glob(os.path.join(d, "*.json")))
    return files


def _read_pending(agent, drain):
    """Return pending messages (oldest first). If ``drain``, remove them."""
    msgs = []
    for path in _pending_files(agent):
        try:
            with open(path) as f:
                msgs.append(json.load(f))
        except (OSError, json.JSONDecodeError):
            continue  # skip a torn/partial file; a later poll picks it up
        if drain:
            try:
                os.remove(path)
            except OSError:
                pass
    if drain and _safe_name(agent) == "user":
        # The user's mail read here: the phone's notifications of it go too (one read state).
        _phone_read([m.get("id") for m in msgs if m.get("id")])
    return msgs


def _consume(agent, ids):
    """Removes the messages with these ids from ``agent``'s inbox (read elsewhere: on the phone, by a test's clean-up).
    Returns how many were there. The user's: the phone is told too."""
    want = set(ids)
    n = 0
    for path in _pending_files(agent):
        try:
            with open(path) as f:
                mid = json.load(f).get("id")
        except (OSError, json.JSONDecodeError):
            continue
        if mid in want:
            try:
                os.remove(path)
                n += 1
            except OSError:
                pass
    if _safe_name(agent) == "user":
        _phone_read(list(want))
    return n


def _batched(key, text, window):
    """--batch: notices of one kind within [window] s of the last become one. Returns (the text to post: the latest
    note first, then every note of the batch as a list; the batch's previous message id to take back, or None).
    State: <root>/batches/<key>.json, under a lock (two deploys at once still make one batch)."""
    import fcntl

    d = os.path.join(ROOT, "batches")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, f"{_safe_name(key)}.json")
    with open(path + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(path) as f:
                st = json.load(f)
        except (OSError, json.JSONDecodeError):
            st = {}
        now = time.time()
        fresh = now - float(st.get("ts", 0)) < window
        notes = (st.get("notes") or []) if fresh else []
        prev = st.get("id") if fresh else None
        notes = [n for n in notes if n != text] + [text]
        if len(notes) == 1:
            body = text
        else:
            # Line 1 is what the collapsed notification shows; the list is what a tap expands to.
            body = f"{text} (+{len(notes) - 1} more)\n" + "\n".join(f"• {n}" for n in reversed(notes))
        st = {"ts": now, "notes": notes[-20:], "id": None}
        with open(path + ".tmp", "w") as f:
            json.dump(st, f)
        os.replace(path + ".tmp", path)
    return body, prev


def _batch_sent(key, mid):
    path = os.path.join(ROOT, "batches", f"{_safe_name(key)}.json")
    try:
        with open(path) as f:
            st = json.load(f)
        st["id"] = mid
        with open(path + ".tmp", "w") as f:
            json.dump(st, f)
        os.replace(path + ".tmp", path)
    except (OSError, json.JSONDecodeError):
        pass


def _list_agents():
    """Every known inbox role and its current unread depth."""
    base = os.path.join(ROOT, "agents")
    out = []
    for name in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        d = os.path.join(base, name, "inbox")
        if not os.path.isdir(d):
            continue
        depth = len(glob.glob(os.path.join(d, "*.json")))
        out.append({"agent": name, "pending": depth})
    return out


# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------

def _fmt_msgs(msgs):
    if not msgs:
        return "(no messages)"
    lines = []
    for m in msgs:
        tag = f"[{m.get('priority', 'normal')}]"
        kind = m.get("kind", "message")
        frm = m.get("from", "?")
        lines.append(f"• {tag} from {frm} ({kind}) at {m.get('iso', '?')}")
        lines.append(f"    {m.get('body', '')}")
        if m.get("result"):
            lines.append(f"    result: {m['result']}")
    return "\n".join(lines)


def _idle_hint():
    """Tell the model how to be *woken* by mail instead of polling."""
    d = inbox_dir(AGENT_ID) if AGENT_ID else os.path.join(ROOT, "agents")
    return (
        "\n\nIdle and expecting a reply? Don't poll read_inbox in a loop. "
        "Either call wait_for_message (it blocks and returns the instant mail "
        f"arrives), or Monitor the inbox path directly: {d}"
    )


def _phone_notify(message, priority="normal", mid=None):
    """On a phone running PowOS: the message as an Android notification too, where the user is - the PowOS desktop
    may not be on screen. Written into the PowOS app's run dir (agent-mail/, the session's XDG_RUNTIME_DIR); the app
    posts it with an inline reply that comes back to this agent's inbox (targets/android: AgentMail).
    Best-effort, never fatal."""
    platform = os.environ.get("POWOS_PLATFORM", "")
    if not platform:
        try:
            with open("/etc/powos/platform") as f:
                platform = f.read().strip()
        except OSError:
            return
    if platform != "phone":
        return
    try:
        run = os.environ.get("XDG_RUNTIME_DIR") or "/run/powos-app"
        box = os.path.join(run, "agent-mail")
        os.makedirs(box, exist_ok=True)
        name = f"{int(time.time() * 1000)}-{uuid.uuid4().hex[:8]}"
        tmp = os.path.join(box, f".{name}.tmp")
        with open(tmp, "w") as f:
            # id: the user-inbox message's (the app keeps the mail by it, read or not); time: Unix seconds.
            json.dump({"id": mid or name, "from": AGENT_ID or "agent", "text": message, "priority": priority,
                       "time": int(time.time())}, f)
        os.rename(tmp, os.path.join(box, f"{name}.json"))
    except Exception:
        pass


def _phone_read(ids):
    """On a phone running PowOS: these user-mail ids are read - the app marks them read and takes their
    notifications away (agent-mail/ again, {"op": "read", "ids": [...]}). Best-effort, never fatal."""
    if not ids or not _on_phone():
        return
    try:
        run = os.environ.get("XDG_RUNTIME_DIR") or "/run/powos-app"
        box = os.path.join(run, "agent-mail")
        os.makedirs(box, exist_ok=True)
        name = f"{int(time.time() * 1000)}-read-{uuid.uuid4().hex[:8]}"
        tmp = os.path.join(box, f".{name}.tmp")
        with open(tmp, "w") as f:
            json.dump({"op": "read", "ids": list(ids)}, f)
        os.rename(tmp, os.path.join(box, f"{name}.json"))
    except Exception:
        pass


def _phone_wake(agent):
    """On a phone running PowOS: tells the PowOS app that [agent] has mail. The phone's chat runs the manager one turn
    at a time, so between turns nothing watches its inbox and mail sat there until the user wrote again; the app runs
    the inbox's turn when it sees this (agent-wake/<agent>-<time> in its run dir; targets/android: PowosAiChat).
    Best-effort, never fatal."""
    if not _on_phone():
        return
    try:
        run = os.environ.get("XDG_RUNTIME_DIR") or "/run/powos-app"
        box = os.path.join(run, "agent-wake")
        os.makedirs(box, exist_ok=True)
        name = f"{agent}-{int(time.time() * 1000)}"
        tmp = os.path.join(box, f".{name}.tmp")
        open(tmp, "w").close()
        os.rename(tmp, os.path.join(box, name))
    except Exception:
        pass


def _agents_queue():
    """powos-agentsd's queue (lib/ai/agents; the same choice as powos-agent-hook's), or None while no hook made it."""
    q = os.environ.get("POWOS_AGENTS_QUEUE")
    if not q:
        user = os.environ.get("USER") or os.environ.get("LOGNAME") or "u"
        if os.path.isdir("/dev/shm"):
            q = f"/dev/shm/powos-agents-{user}"
        else:
            spool = (os.path.join(os.environ["XDG_RUNTIME_DIR"], "agents") if os.environ.get("XDG_RUNTIME_DIR")
                     else os.path.join(os.environ.get("TMPDIR") or "/tmp", f"powos-agents-{user}"))
            q = os.path.join(spool, "in")
    return q if os.path.isdir(q) else None


def _agents_note(payload):
    """The message as a row of the Agents view's comms feed (docs/AGENTS-VIEW-DESIGN.md §3 message): who to whom,
    its kind and a preview - agentsd caps and scrubs it. Best-effort, never fatal; nothing when no agent reports."""
    try:
        q = _agents_queue()
        if not q:
            return
        rec = {"powos_agents": "message", "id": payload["id"], "from": payload["from"], "to": payload["to"],
               "kind": payload["kind"], "priority": payload["priority"], "ts": int(time.time() * 1000),
               "body": payload["body"][:400]}
        name = f"m{payload['id']}"
        with open(os.path.join(q, f".{name}.tmp"), "w") as f:
            json.dump(rec, f)
        os.rename(os.path.join(q, f".{name}.tmp"), os.path.join(q, f"{name}.ev"))
    except Exception:
        pass


def _on_phone():
    platform = os.environ.get("POWOS_PLATFORM", "")
    if not platform:
        try:
            with open("/etc/powos/platform") as f:
                platform = f.read().strip()
        except OSError:
            return False
    return platform == "phone"


def _desktop_notify(message, priority, mid=None):
    """Best-effort desktop toast for notify_user. Never fatal."""
    urgency = {"low": "low", "normal": "normal", "high": "critical",
               "urgent": "critical"}.get(priority, "normal")
    _phone_notify(message, priority, mid)
    if not shutil.which("notify-send"):
        return
    try:
        subprocess.run(
            ["notify-send", "-u", urgency, "-a", "PowOS agents",
             f"Agent: {AGENT_ID or 'unknown'}", message],
            check=False, timeout=5,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

def tool_send_message(args):
    to = args.get("to") or args.get("agent") or args.get("agent_id")
    message = args.get("message") or args.get("body") or ""
    priority = args.get("priority", "normal")
    if not to:
        raise ValueError("send_message requires 'to' (a target agent role)")
    if not message:
        raise ValueError("send_message requires a non-empty 'message'")
    mid = _deliver(to, "message", message, priority)
    return (f"Delivered to '{_safe_name(to)}' inbox (id {mid}). It will be read "
            f"by whoever next runs as '{to}', or by a live '{to}' agent waiting "
            f"on wait_for_message.")


def tool_notify_user(args):
    message = args.get("message") or args.get("body") or ""
    priority = args.get("priority", "normal")
    if not message:
        raise ValueError("notify_user requires a non-empty 'message'")
    if not CAN_NOTIFY:
        # Sub-agents report up the chain rather than pinging the human directly.
        mid = _deliver(PARENT_ID, "escalate", message, priority)
        return (f"This agent may not notify the user directly; forwarded to "
                f"'{PARENT_ID}' instead (id {mid}).")
    mid = _deliver("user", "notify", message, priority)
    _desktop_notify(message, priority, mid)
    return f"User notified (id {mid})."


def tool_escalate(args):
    message = args.get("message") or args.get("body") or ""
    result = args.get("result")
    priority = args.get("priority", "high")
    if not message:
        raise ValueError("escalate requires a non-empty 'message'")
    mid = _deliver(PARENT_ID, "escalate", message, priority, result=result)
    return f"Escalated to '{PARENT_ID}' (id {mid})."


def tool_read_inbox(args):
    if not AGENT_ID:
        raise ValueError("no COMMS_AGENT_ID set; this agent has no inbox")
    peek = bool(args.get("peek", False))
    msgs = _read_pending(AGENT_ID, drain=not peek)
    verb = "Peeked" if peek else "Read (and cleared)"
    text = f"{verb} {len(msgs)} message(s) for '{AGENT_ID}':\n{_fmt_msgs(msgs)}"
    if not msgs:
        text += _idle_hint()
    return text


def tool_wait_for_message(args):
    if not AGENT_ID:
        raise ValueError("no COMMS_AGENT_ID set; this agent has no inbox")
    timeout = float(args.get("timeout_seconds", args.get("timeout", 60)))
    timeout = max(1.0, min(timeout, 900.0))  # clamp 1s..15min
    poll = 0.5
    deadline = time.time() + timeout
    while True:
        msgs = _read_pending(AGENT_ID, drain=True)
        if msgs:
            return (f"Woke with {len(msgs)} new message(s) for '{AGENT_ID}':\n"
                    f"{_fmt_msgs(msgs)}")
        if time.time() >= deadline:
            return (f"No message arrived within {timeout:.0f}s for '{AGENT_ID}'. "
                    f"Call wait_for_message again to keep waiting, or continue.")
        time.sleep(poll)


def tool_list_agents(args):
    agents = _list_agents()
    if not agents:
        return "No agent inboxes exist yet."
    lines = [f"• {a['agent']}  ({a['pending']} pending)" for a in agents]
    me = f"\nYou are '{AGENT_ID}'." if AGENT_ID else ""
    return "Known agent inboxes:\n" + "\n".join(lines) + me


TOOLS = {
    "send_message": {
        "fn": tool_send_message,
        "description": (
            "Send a message to another PowOS agent by role name (e.g. 'devops', "
            "'health', 'coder'). It lands in that role's durable inbox and is "
            "read by whoever next runs as that role, or by a live agent of that "
            "role waiting on wait_for_message."),
        "schema": {
            "type": "object",
            "properties": {
                "to": {"type": "string", "description": "Target agent role name."},
                "message": {"type": "string", "description": "Message body."},
                "priority": {"type": "string", "enum": list(VALID_PRIORITIES),
                             "default": "normal"},
            },
            "required": ["to", "message"],
        },
    },
    "notify_user": {
        "fn": tool_notify_user,
        "description": (
            "Push a notification to the human user (also raises a desktop toast "
            "when possible). Restricted agents forward to their parent instead."),
        "schema": {
            "type": "object",
            "properties": {
                "message": {"type": "string"},
                "priority": {"type": "string", "enum": list(VALID_PRIORITIES),
                             "default": "normal"},
            },
            "required": ["message"],
        },
    },
    "escalate": {
        "fn": tool_escalate,
        "description": (
            "Report a result or problem UP to your parent agent (COMMS_PARENT_ID, "
            "default 'user'). Use this to hand a finding back to whoever "
            "delegated to you."),
        "schema": {
            "type": "object",
            "properties": {
                "message": {"type": "string"},
                "result": {"type": "string",
                           "description": "Optional concrete result/outcome."},
                "priority": {"type": "string", "enum": list(VALID_PRIORITIES),
                             "default": "high"},
            },
            "required": ["message"],
        },
    },
    "read_inbox": {
        "fn": tool_read_inbox,
        "description": (
            "Read messages addressed to you. By default this DRAINS the inbox "
            "(messages are consumed); pass peek=true to look without clearing. "
            "For an idle wait, prefer wait_for_message over polling this."),
        "schema": {
            "type": "object",
            "properties": {
                "peek": {"type": "boolean", "default": False,
                         "description": "Look without consuming."},
            },
        },
    },
    "wait_for_message": {
        "fn": tool_wait_for_message,
        "description": (
            "BLOCK until a message arrives in your inbox, then return and drain "
            "it. This is the way to yield while idle without polling — it wakes "
            "the instant mail lands (or times out). Call again to keep waiting."),
        "schema": {
            "type": "object",
            "properties": {
                "timeout_seconds": {"type": "number", "default": 60,
                                    "description": "Max block time (1..900s)."},
            },
        },
    },
    "list_agents": {
        "fn": tool_list_agents,
        "description": "List known agent inboxes and how many messages each holds.",
        "schema": {"type": "object", "properties": {}},
    },
}


# ---------------------------------------------------------------------------
# JSON-RPC / MCP stdio loop
# ---------------------------------------------------------------------------

def _result(rid, result):
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def _error(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def handle(req):
    """Return a response dict, or None for notifications (no id)."""
    method = req.get("method")
    rid = req.get("id")
    params = req.get("params") or {}

    if method == "initialize":
        return _result(rid, {
            "protocolVersion": params.get("protocolVersion", PROTOCOL_VERSION),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })

    if method in ("notifications/initialized", "initialized"):
        return None

    if method == "ping":
        return _result(rid, {})

    if method == "tools/list":
        tools = [{
            "name": name,
            "description": spec["description"],
            "inputSchema": spec["schema"],
        } for name, spec in TOOLS.items()]
        return _result(rid, {"tools": tools})

    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        spec = TOOLS.get(name)
        if not spec:
            return _error(rid, -32602, f"unknown tool: {name}")
        try:
            text = spec["fn"](args)
            return _result(rid, {"content": [{"type": "text", "text": text}]})
        except Exception as e:  # surface as a tool error, not a protocol crash
            return _result(rid, {
                "content": [{"type": "text", "text": f"Error: {e}"}],
                "isError": True,
            })

    if rid is None:
        return None  # unknown notification — ignore
    return _error(rid, -32601, f"method not found: {method}")


# ---------------------------------------------------------------------------
# CLI mode — the same store, for humans and shell scripts (`powos comms ...`).
# Any argv beyond the program name selects CLI mode; bare invocation is the
# stdio MCP server.
# ---------------------------------------------------------------------------

def run_cli(argv):
    global AGENT_ID  # send/watch reset the actor identity; declare up front
    if not AGENT_ID:
        AGENT_ID = "user"  # a human at the CLI acts as 'user' unless overridden
    import argparse
    p = argparse.ArgumentParser(prog="powos comms",
                                description="PowOS inter-agent mailbox.")
    sub = p.add_subparsers(dest="cmd", required=True)

    ps = sub.add_parser("send", help="Send a message to an agent role.")
    ps.add_argument("to")
    ps.add_argument("message", nargs="+")
    ps.add_argument("--priority", choices=VALID_PRIORITIES, default="normal")
    ps.add_argument("--from", dest="frm", default=AGENT_ID or "user")

    pn = sub.add_parser("notify", help="Notify the human user.")
    pn.add_argument("message", nargs="+")
    pn.add_argument("--priority", choices=VALID_PRIORITIES, default="normal")
    pn.add_argument("--from", dest="frm", default=AGENT_ID or "user",
                    help="Who it's from (tests: their own name, never 'user').")
    pn.add_argument("--batch", metavar="KEY",
                    help="Fold into the last notice with this key if it came within --window s: one notification, "
                         "the latest line first and all of them as a list (deploys: --batch deploy).")
    pn.add_argument("--window", type=float, default=120, help="--batch's window in seconds (default 120).")

    pr = sub.add_parser("read", help="Mark messages read by id: out of the inbox (the user's: off the phone too).")
    pr.add_argument("ids", nargs="+")
    pr.add_argument("--agent", default="user")

    pi = sub.add_parser("inbox", help="Show an inbox (default: yours / user).")
    pi.add_argument("--agent", default=AGENT_ID or "user")
    pi.add_argument("--peek", action="store_true",
                    help="Don't consume the messages.")

    pw = sub.add_parser("watch", help="Block until a message arrives, then drain.")
    pw.add_argument("--agent", default=AGENT_ID or "user")
    pw.add_argument("--timeout", type=float, default=300)

    sub.add_parser("agents", help="List known inboxes and their depth.")

    a = p.parse_args(argv)

    if a.cmd == "send":
        AGENT_ID = a.frm
        text = " ".join(a.message)
        # An empty body is always a mistake upstream (an unset shell variable, a file that wasn't there): refuse it
        # rather than deliver a blank message the recipient can't act on.
        if not text.strip():
            print("powos comms send: refusing an empty message", file=sys.stderr)
            sys.exit(2)
        mid = _deliver(a.to, "message", text, a.priority)
        print(f"Sent to '{a.to}' (id {mid}).")
    elif a.cmd == "notify":
        AGENT_ID = a.frm
        # "-": the message from stdin (scripts passing text through layers of shell quoting).
        text = sys.stdin.read().strip() if a.message == ["-"] else " ".join(a.message)
        if not text.strip():
            print("powos comms notify: refusing an empty message", file=sys.stderr)
            sys.exit(2)
        prev = None
        if a.batch:
            text, prev = _batched(a.batch, text, a.window)
        mid = _deliver("user", "notify", text, a.priority)
        if prev:
            # The batch's earlier notice: out of the inbox, the feed and the shade - this one replaces it.
            _consume("user", [prev])
        if a.batch:
            _batch_sent(a.batch, mid)
        _desktop_notify(text, a.priority, mid)
        print(f"User notified (id {mid}).")
    elif a.cmd == "inbox":
        msgs = _read_pending(a.agent, drain=not a.peek)
        verb = "Peek" if a.peek else "Inbox (cleared)"
        print(f"{verb} for '{a.agent}': {len(msgs)} message(s)")
        print(_fmt_msgs(msgs))
    elif a.cmd == "watch":
        AGENT_ID = a.agent
        print(f"Watching '{a.agent}' inbox (Ctrl-C to stop)...", file=sys.stderr)
        deadline = time.time() + max(1.0, a.timeout)
        while time.time() < deadline:
            msgs = _read_pending(a.agent, drain=True)
            if msgs:
                print(_fmt_msgs(msgs))
                return 0
            time.sleep(0.5)
        print("(timed out, no messages)", file=sys.stderr)
        return 0
    elif a.cmd == "read":
        n = _consume(a.agent, a.ids)
        print(f"Read {len(a.ids)} id(s); {n} were waiting in '{a.agent}'.")
    elif a.cmd == "agents":
        for row in _list_agents():
            print(f"{row['agent']:20s} {row['pending']} pending")
    return 0


def main():
    if not AGENT_ID:
        log("warning: COMMS_AGENT_ID is empty — read_inbox/wait_for_message "
            "will refuse (this agent has no inbox), but sending still works.")
    log(f"up: id={AGENT_ID or '(none)'} parent={PARENT_ID} root={ROOT}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            log("dropping non-JSON line")
            continue
        try:
            resp = handle(req)
        except Exception as e:  # last-resort guard; keep the loop alive
            resp = _error(req.get("id"), -32603, f"internal error: {e}")
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    if len(sys.argv) > 1:
        sys.exit(run_cli(sys.argv[1:]))
    main()
