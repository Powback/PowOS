#!/usr/bin/env python3
"""The keyboard's reply drafts (lib/ai/manager/reply_drafts.py, `powos manager --drafts`): request/response contract v1
and the variation parsing, with a fake claude (MANAGER_CLAUDE_CMD) - no model, no network.

Pinned: a request without an image / with another contract version / a bad mime is "bad-request" (exit 2); the prompt
names the app, the field's kind from EditorInfo.inputType, the hint, the field text, the voice note and the variations
to avoid; claude gets ONE stream-json user message with the image first, no tools, no MCP, no session persisted; the
variations come out of {"variations": [...]}, a fenced block, a bare list or plain lines - cleaned, deduplicated, capped
at n; claude's error / an answer without variations / no claude are {"ok": false} with the right word; nothing is
written to disk by the helper.
"""
import json
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HELPER = os.path.join(REPO, "lib/ai/manager/reply_drafts.py")
sys.path.insert(0, os.path.dirname(HELPER))
import reply_drafts as rd  # noqa: E402

fails = 0


def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + (f" - {detail}" if detail and not ok else ""))
    if not ok:
        fails += 1


REQ = {"v": 1, "image": "aGVsbG8=", "mime": "image/jpeg", "transcript": "say I'm late, 10 minutes",
       "text": "", "app": "com.whatsapp", "hint": "Message", "inputType": 0x1 | 0x40 | 0x20000, "n": 3,
       "avoid": ["On my way"]}

# --- contract: requests ---
r = rd.parse_request(json.dumps(REQ))
check("request parses", r["app"] == "com.whatsapp" and r["n"] == 3 and r["avoid"] == ["On my way"])
for bad, why in ((dict(REQ, image=""), "no image"), (dict(REQ, v=2), "contract v2"), (dict(REQ, mime="text/html"), "mime"),
                 ("[1]", "not an object"), ("nope", "not JSON"), (dict(REQ, n="x"), "numbers")):
    try:
        rd.parse_request(bad if isinstance(bad, str) else json.dumps(bad))
        check(f"bad request refused ({why})", False, "accepted")
    except rd.BadRequest as e:
        check(f"bad request refused ({why})", why in str(e), str(e))
check("n clamped", rd.parse_request(json.dumps(dict(REQ, n=40)))["n"] == rd.MAX_VARIATIONS)
check("field text capped", len(rd.parse_request(json.dumps(dict(REQ, text="x" * 9000)))["text"]) == rd.MAX_TEXT)

check("field kind: short message, multi-line", rd.field_kind(0x1 | 0x40 | 0x20000) == "text / short message (multi-line)")
check("field kind: email subject", rd.field_kind(0x1 | 0x30) == "text / email subject")
check("field kind: number", rd.field_kind(0x2) == "number")

p = rd.prompt_text(r)
for want in ("com.whatsapp", "short message", "Message", "The field is empty", "late, 10 minutes", "On my way", "3 variations"):
    check(f"prompt names {want!r}", want in p, p)
m = rd.user_message(r)
c = m["message"]["content"]
check("one user message, image first", m["type"] == "user" and c[0]["type"] == "image" and c[0]["source"]["data"] == "aGVsbG8="
      and c[1]["type"] == "text")
cmd = rd.claude_cmd()
for flag in ("--tools", "--strict-mcp-config", "--no-session-persistence", "--model"):
    check(f"claude run with {flag}", flag in cmd)
check("tools empty", cmd[cmd.index("--tools") + 1] == "")

# --- variation parsing ---
check("json object", rd.parse_variations('{"variations": ["A", "B", "C"]}') == ["A", "B", "C"])
check("fenced + prose", rd.parse_variations('Sure:\n```json\n{"variations": ["Hi", "Hey"]}\n```') == ["Hi", "Hey"])
check("bare list", rd.parse_variations('["one", "two"]') == ["one", "two"])
check("plain lines, markers and quotes stripped", rd.parse_variations('1. "Running late"\n- Be there soon\n\n* Ten min') ==
      ["Running late", "Be there soon", "Ten min"])
check("dedup case-insensitive", rd.parse_variations('{"variations": ["Ok", "ok", "Sure"]}') == ["Ok", "Sure"])
check("capped at n", rd.parse_variations('{"variations": ["a", "b", "c", "d"]}', 2) == ["a", "b"])
check("non-strings dropped", rd.parse_variations('{"variations": ["a", 3, null, "b"]}') == ["a", "b"])
check("empty answer", rd.parse_variations("") == [])

# --- end to end with a fake claude ---
tmp = tempfile.mkdtemp()


def fake(body):
    path = os.path.join(tmp, f"claude{len(os.listdir(tmp))}")
    with open(path, "w") as f:
        f.write("#!/usr/bin/env python3\nimport sys, json\n" + body)
    os.chmod(path, 0o755)
    return path


def drafts(claude, req=REQ):
    env = dict(os.environ, MANAGER_CLAUDE_CMD=claude, POWOS_DRAFTS_TIMEOUT="20")
    p = subprocess.run([sys.executable, "-I", HELPER], input=json.dumps(req) if not isinstance(req, str) else req,
                       capture_output=True, text=True, env=env, cwd=tmp)
    return p.returncode, json.loads(p.stdout.strip().splitlines()[-1])


seen = os.path.join(tmp, "seen.json")
ok_claude = fake(f"""
msg = json.loads(sys.stdin.readline())
json.dump({{"argv": sys.argv[1:], "msg": msg}}, open({seen!r}, "w"))
print(json.dumps({{"type": "system", "subtype": "init", "model": "claude-sonnet-test"}}))
print(json.dumps({{"type": "result", "subtype": "success", "is_error": False,
                   "result": '{{"variations": ["Running 10 min late, sorry!", "Be there in 10", "Late by 10, start without me"]}}'}}))
""")
before = set(os.listdir(tmp))
rc, out = drafts(ok_claude)
check("drafts ok", rc == 0 and out["ok"] and len(out["variations"]) == 3, out)
check("model reported", out.get("model") == "claude-sonnet-test", out)
got = json.load(open(seen))
check("claude got the image block", got["msg"]["message"]["content"][0]["source"]["data"] == "aGVsbG8=")
check("nothing written by the helper", set(os.listdir(tmp)) - before == {"seen.json"}, set(os.listdir(tmp)) - before)

rc, out = drafts(fake('print(json.dumps({"type": "result", "is_error": True, "result": "401 run /login"}))'))
check("claude error -> model", rc == 1 and out == {"ok": False, "error": "model", "why": "401 run /login"}, out)
rc, out = drafts(fake('print(json.dumps({"type": "result", "is_error": False, "result": ""}))'))
check("empty answer -> no-reply", rc == 1 and out["error"] == "no-reply", out)
rc, out = drafts(os.path.join(tmp, "missing-claude"))
check("no claude -> model", rc == 1 and out["error"] == "model", out)
rc, out = drafts(ok_claude, "{}")
check("bad request -> exit 2", rc == 2 and out["error"] == "bad-request", out)

print(f"{'FAIL' if fails else 'PASS'}: reply drafts ({fails} failed)")
sys.exit(1 if fails else 0)
