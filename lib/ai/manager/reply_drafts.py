#!/usr/bin/env python3
"""Reply drafts for the keyboard's AI button (`powos manager --drafts`): a screenshot of the app being typed into, the
user's voice note (already transcribed) and the text field's context in; a few short reply variations out.

The swipe keyboard (com.swipekeyboard) never talks to a model itself and holds no key: it asks the PowOS app
(KeyboardAiProvider.kt, a permission-checked content provider), which captures the screen, runs this in PowOS Linux and
hands the variations back. The model call is this machine's own Claude Code, signed in exactly like the AI chat (the
fleet endpoint's claude-auth tenant, or the device's own Claude login): `claude -p` with the image as a stream-json
content block, no tools, no MCP, no session persisted (the screenshot never lands in ~/.claude), one turn.

stdin: one JSON request (contract v1, see [parse_request]):
  {"v": 1, "image": "<base64 jpeg>", "mime": "image/jpeg", "transcript": "...", "text": "...", "app": "com.whatsapp",
   "hint": "Message", "inputType": 147457, "imeOptions": 0, "n": 3, "avoid": ["an earlier variation", ...],
   "session": "<the press's screenshot id>"}
stdout: one JSON line - {"ok": true, "variations": ["...", ...], "model": "...", "learn": bool, "rid": "..."} or
  {"ok": false, "error": "...", "why": "..."}. Errors: "bad-request", "no-reply" (the model answered nothing usable),
  "model" (claude failed), "timeout". "rid" (only when learn): the id the keyboard reports this answer's outcome with.

Learning (reply_learn.py): the prompt carries the user's past committed replies most like this one and their style
profiles; the answer is recorded as text (app, contact the model read off the screen, hint, variations) in the
Keyboard AI app's database. The image is never written anywhere: it goes from stdin to claude's stdin.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))  # reply_learn beside it (also under python -I)
import reply_learn  # noqa: E402

CONTRACT = 1
MODEL = os.environ.get("POWOS_DRAFTS_MODEL", "sonnet")
TIMEOUT_S = int(os.environ.get("POWOS_DRAFTS_TIMEOUT", "60"))
MAX_VARIATIONS = 5
MAX_LEN = 600
MAX_TEXT = 2000
MAX_IMAGE_B64 = 6_000_000

SYSTEM = """You draft replies for the user from their phone keyboard. You see a screenshot of the app they are typing \
in (the keyboard itself is cropped away), the text field they are in and, when they recorded one, their voice \
instruction. Write what THEY would type into that field next: in their voice, in the conversation's language, the \
length that fits the app (a chat message is short; an email can be a few sentences). Follow the voice instruction when \
there is one; otherwise answer the latest message or fill the field sensibly. Each variation must differ in tone or \
content. When the prompt says how they write and shows replies they sent before, write like that (their length, tone, \
language, punctuation, emoji) without copying them. Never explain, never add quotes or labels, never write as an \
assistant. Answer ONLY with JSON: {"contact": "<the person or thread name shown on screen, or empty>", \
"variations": ["...", "..."]}"""

# EditorInfo.inputType's class and variation bits (android.text.InputType), named for the prompt.
_CLASS = {1: "text", 2: "number", 3: "phone", 4: "datetime"}
_TEXT_VARIATION = {
    0x10: "URL", 0x20: "email address", 0x30: "email subject", 0x40: "short message", 0x50: "long message",
    0x60: "person name", 0x70: "postal address", 0xA0: "web edit text", 0xB0: "filter", 0xD0: "web email address",
}


class BadRequest(ValueError):
    pass


def field_kind(input_type: int) -> str:
    """A field's kind in words ("text / short message", "number"), from EditorInfo.inputType."""
    cls = _CLASS.get(input_type & 0xF, "text")
    if cls != "text":
        return cls
    var = _TEXT_VARIATION.get(input_type & 0xFF0)
    multi = " (multi-line)" if input_type & 0x20000 else ""
    return f"text / {var}{multi}" if var else f"text{multi}"


def parse_request(raw: str) -> dict:
    """The request, checked and trimmed: BadRequest for anything that isn't contract v1 with an image."""
    try:
        req = json.loads(raw)
    except ValueError as e:
        raise BadRequest(f"not JSON: {e}") from None
    if not isinstance(req, dict):
        raise BadRequest("not an object")
    if req.get("v", CONTRACT) != CONTRACT:
        raise BadRequest(f"contract v{req.get('v')} (this is v{CONTRACT})")
    image = req.get("image")
    if not isinstance(image, str) or not image:
        raise BadRequest("no image")
    if len(image) > MAX_IMAGE_B64:
        raise BadRequest("image too large")
    mime = req.get("mime") or "image/jpeg"
    if mime not in ("image/jpeg", "image/png", "image/webp"):
        raise BadRequest(f"mime {mime}")

    def text(key: str, cap: int = MAX_TEXT) -> str:
        v = req.get(key)
        return v.strip()[:cap] if isinstance(v, str) else ""

    try:
        n = max(1, min(MAX_VARIATIONS, int(req.get("n", 3))))
        input_type = int(req.get("inputType", 0))
        ime_options = int(req.get("imeOptions", 0))
    except (TypeError, ValueError):
        raise BadRequest("n / inputType not numbers") from None
    avoid = [a.strip()[:MAX_LEN] for a in req.get("avoid") or [] if isinstance(a, str) and a.strip()][:10]
    return {
        "image": image, "mime": mime, "n": n, "inputType": input_type, "imeOptions": ime_options, "avoid": avoid,
        "session": text("session", 100),
        "transcript": text("transcript"), "text": text("text"), "app": text("app", 200), "hint": text("hint", 200),
    }


def prompt_text(req: dict, learned: str = "") -> str:
    """The user turn's text that goes with the screenshot; [learned]: reply_learn.prompt_block's part."""
    lines = [learned, ""] if learned else []
    lines += [f"App: {req['app'] or 'unknown'}", f"Field: {field_kind(req['inputType'])}"]
    if req["hint"]:
        lines.append(f"Field hint: {req['hint']}")
    lines.append(f"Already in the field: {json.dumps(req['text'])}" if req["text"] else "The field is empty.")
    if req["transcript"]:
        lines.append(f"The user's voice instruction: {json.dumps(req['transcript'])}")
    if req["avoid"]:
        lines.append("They didn't pick these, write different ones: " + json.dumps(req["avoid"], ensure_ascii=False))
    lines.append(f"Write {req['n']} variations. When the field already has text, each variation is the field's whole "
                 "new text (keep or rework what's there).")
    return "\n".join(lines)


def user_message(req: dict, learned: str = "") -> dict:
    """claude's stream-json input: one user message, the screenshot then the text."""
    return {"type": "user", "message": {"role": "user", "content": [
        {"type": "image", "source": {"type": "base64", "media_type": req["mime"], "data": req["image"]}},
        {"type": "text", "text": prompt_text(req, learned)},
    ]}}


def _clean(s: str) -> str:
    s = s.strip()
    s = re.sub(r"^(?:[-*•]|\d+[.)])\s+", "", s)  # a list marker the model added anyway
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'“”":
        s = s[1:-1].strip()
    return s[:MAX_LEN]


def parse_variations(text: str, n: int = MAX_VARIATIONS) -> list[str]:
    """The variations in a model answer: {"variations": [...]} (also inside a ```json fence or after prose), a bare
    JSON list, else one per non-empty line. Cleaned, deduplicated, at most n."""
    found: list = []
    for m in re.finditer(r"[\[{]", text or ""):
        try:
            obj, _ = json.JSONDecoder().raw_decode(text[m.start():])
        except ValueError:
            continue
        if isinstance(obj, dict) and isinstance(obj.get("variations"), list):
            found = obj["variations"]
            break
        if isinstance(obj, list) and obj and all(isinstance(x, str) for x in obj):
            found = obj
            break
    if not found:
        found = [l for l in (text or "").splitlines() if l.strip() and not l.strip().startswith("```")]
    out: list[str] = []
    for v in found:
        if not isinstance(v, str):
            continue
        v = _clean(v)
        if v and v.lower() not in (o.lower() for o in out):
            out.append(v)
    return out[:n]


def parse_contact(text: str) -> str:
    """The "contact" the model read off the screen, "" when it gave none."""
    for m in re.finditer(r"\{", text or ""):
        try:
            obj, _ = json.JSONDecoder().raw_decode(text[m.start():])
        except ValueError:
            continue
        if isinstance(obj, dict) and "variations" in obj:
            c = obj.get("contact")
            return " ".join(c.split())[:100] if isinstance(c, str) else ""
    return ""


def claude_cmd() -> list[str]:
    cmd = os.environ.get("MANAGER_CLAUDE_CMD", "claude").split()
    return cmd + ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                  "--model", MODEL, "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                  "--system-prompt", SYSTEM]


def run(req: dict, learned: str = "") -> dict:
    try:
        p = subprocess.run(claude_cmd(), input=json.dumps(user_message(req, learned)) + "\n", capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "timeout", "why": f"no answer in {TIMEOUT_S} s"}
    except OSError as e:
        return {"ok": False, "error": "model", "why": str(e)}
    result, model = None, MODEL
    for line in p.stdout.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "system" and ev.get("model"):
            model = ev["model"]
        if ev.get("type") == "result":
            result = ev
    if not result or result.get("is_error"):
        why = (result or {}).get("result") or p.stderr.strip().splitlines()[-1:] or [f"exit {p.returncode}"]
        return {"ok": False, "error": "model", "why": str(why if isinstance(why, str) else why[0])[:300]}
    variations = parse_variations(result.get("result") or "", req["n"])
    if not variations:
        return {"ok": False, "error": "no-reply", "why": "the model's answer had no variations"}
    return {"ok": True, "variations": variations, "model": model, "contact": parse_contact(result.get("result") or "")}


def drafts(req: dict, learn=reply_learn) -> dict:
    """One answered request with learning: the learned context in the prompt, the answer recorded as an offer."""
    ctx = learn.context(req)
    out = run(req, learn.prompt_block(ctx) if ctx["learn"] else "")
    contact = out.pop("contact", "") or ctx.get("contact", "")
    if not out["ok"]:
        return out
    rid = learn.record_offer(req, out["variations"], contact) if ctx["learn"] else None
    out["learn"] = bool(rid)
    if rid:
        out["rid"] = rid
    return out


def main() -> int:
    try:
        req = parse_request(sys.stdin.read())
    except BadRequest as e:
        print(json.dumps({"ok": False, "error": "bad-request", "why": str(e)}))
        return 2
    out = drafts(req)
    print(json.dumps(out, ensure_ascii=False))
    return 0 if out["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
