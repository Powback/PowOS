#!/usr/bin/env python3
"""shell-pitfalls.py [file...] - lint the phone checks' shell for four pitfalls that produced false check FAILs.

WHY (11-10): three checks FAILed on shell pitfalls, not product bugs; each cost a queue run plus an agent.
  awk-ternary   `printf "%d", t>0?t:0` - BSD awk (the Mac's, 20200816) parses `>` as an output redirect: syntax
                error. Parenthesize the ternary: `(t>0?t:0)`. (plasma-modes desk_top)
  sigpipe       under `set -o pipefail`, `adb shell dumpsys ... | awk '/x/{print; exit}'` (or `| head -n1`,
                `| grep -q`, `| grep -m1`, `| grep x >/dev/null` - GNU grep and ugrep quit early then too) closes
                the pipe early; adb dies of SIGPIPE (141) and the pipeline reads as false even on a match. Read to
                the end (`awk '/x/&&!f{print;f=1}'`, `awk '/x/{f=1} END{exit !f}'` for a test) or filter on the
                phone side (`sh_ "dumpsys window | grep -m1 x"`). (plasma-modes focus())
  nested-quote  a single quote inside an argument that ends up inside `su -c '...'` (sh_ "...", a literal
                "su -c '...'") closes the su string early, so the command runs mangled. Use \\" or '\\''.
                (ww-popup-x11)
  logcat-dup-tag  one tag twice in a logcat filterspec (`-s Tag:I Tag:W`): the last spec wins, so `Tag:W` drops the
                tag's I lines - the check reads nothing. `Tag:I` already includes W/E. (ww-popups 11-10 09:21)

Escape a deliberate case with `# lint-ok: <why>` on the line (or on the line just above it).
With no arguments it scans tools/phone/**/*.sh and tools/agents/*.sh. Exit 1 if anything is found.
"""
import glob
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def default_files():
    fs = glob.glob(os.path.join(ROOT, "tools/phone/**/*.sh"), recursive=True)
    fs += glob.glob(os.path.join(ROOT, "tools/agents/*.sh"))
    return sorted(set(fs))


def lint_ok(lines, ln):
    """ln is 1-based. The escape counts on the line itself or on the one above."""
    for i in (ln - 1, ln - 2):
        if 0 <= i < len(lines) and "# lint-ok:" in lines[i]:
            return True
    return False


# ---------------------------------------------------------------- (a) awk ternary in print/printf
AWK_RE = re.compile(r"\b[gmn]?awk\b")


def awk_programs(text):
    """Yield (offset, program) for every awk program written as a single-quoted shell word after `awk`."""
    for m in AWK_RE.finditer(text):
        i = m.end()
        # skip options/assignments up to the program's opening quote, on the same logical line
        while i < len(text) and text[i] != "'" and text[i] != "\n":
            if text[i] in "|;&)`":
                break
            i += 1
        if i >= len(text) or text[i] != "'":
            continue
        if text.startswith("'\\''", i):  # awk inside a single-quoted string: '\''prog'\''
            start = i + 4
            end = text.find("'\\''", start)
        else:
            start = i + 1
            end = text.find("'", start)
        if end < 0:
            continue
        yield start, text[start:end]


def strip_awk_strings(s):
    out, q, esc = [], False, False
    for c in s:
        if q:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                q = False
            out.append(" ")
        elif c == '"':
            q = True
            out.append(" ")
        else:
            out.append(c)
    return "".join(out)


PRINT_RE = re.compile(r"\bprintf?\b")


def check_awk_ternary(text):
    hits = []
    for start, prog in awk_programs(text):
        clean = strip_awk_strings(prog)
        # regex literals /.../ could hold ? and > - drop the obvious ones (after { ( , ! ~ && || or at start)
        clean = re.sub(r"(^|[{(,!~&|;]\s*)/(?:\\.|[^/\n])*/", lambda m: m.group(1) + " ", clean)
        for pm in PRINT_RE.finditer(clean):
            j, depth, q_at, rel = pm.end(), 0, None, False
            while j < len(clean):
                c = clean[j]
                if c in "([":
                    depth += 1
                elif c in ")]":
                    depth -= 1
                    if depth < 0:
                        break
                elif depth == 0 and c in ";}\n":
                    break
                elif depth == 0 and c == "|" and q_at is None:
                    break  # print | "cmd"
                elif depth == 0 and c == "?":
                    q_at = j
                elif depth == 0 and c in "<>":
                    rel = True
                j += 1
            if q_at is not None and rel:
                hits.append(start + pm.start())
    return hits


# ---------------------------------------------------------------- (b) SIGPIPE under pipefail
PRODUCER_WORD = re.compile(r"\b(dumpsys|logcat|journalctl)\b|\bcat\b[^|'\"]*\.log\b")
LEAD_RE = re.compile(r"^(?:(?:function\s+)?[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{|\{|\(|!|then|do|else|if|elif|while|until|time)\s+")
ADB_RE = re.compile(r"""^(?:"?\$\{?(?:A|adb|ADB)\}?"?|"?[^\s"]*adb(?:\.sh)?"?)\s""")


def strip_lead(seg):
    s = seg.strip()
    while True:
        t = LEAD_RE.sub("", s)
        if t == s:
            return s
        s = t


def quoted_spans(s):
    """[(start, end)] of the top-level quoted strings in s (contents only)."""
    spans, i, q, st = [], 0, None, 0
    while i < len(s):
        c = s[i]
        if q == "'":
            if c == "'":
                spans.append((st, i)); q = None
        elif q == '"':
            if c == "\\":
                i += 1
            elif c == '"':
                spans.append((st, i)); q = None
        elif c == "\\":
            i += 1
        elif c in "'\"":
            q, st = c, i + 1
        i += 1
    return spans


def is_producer(seg, wrappers):
    """A segment that streams a big phone-side dump into this pipe: adb/sh_-style wrappers running dumpsys/logcat
    (unless filtered on the phone side by a | inside the same quoted command), or dumpsys/logcat run directly."""
    s = strip_lead(seg)
    first = s.split(None, 1)[0] if s.split() else ""
    remote = ADB_RE.match(s + " ") is not None or first in wrappers
    if not remote:
        return re.match(r"(dumpsys|logcat|journalctl)\b", s) is not None or re.match(r"cat\b[^|]*\.log\b", s) is not None
    spans = quoted_spans(s)
    for m in PRODUCER_WORD.finditer(s):
        inside = [sp for sp in spans if sp[0] <= m.start() < sp[1]]
        if not inside:
            return True
        a, b = inside[0]
        if "|" not in s[m.end():b]:
            return True
    return False


def consumer_kind(seg):
    s = seg.strip()
    s = re.sub(r"^(\{|\(|!|then|do|else|if|while|until)\s+", "", s)
    if re.match(r"head\b", s):
        return "head"
    if re.match(r"e?grep\b", s):
        opts = " ".join(re.findall(r"(?:^|\s)(-[A-Za-z]+\d*|--max-count\S*|--quiet|--silent)", s))
        if re.search(r"-[A-Za-z]*q", opts) or "--quiet" in opts or "--silent" in opts:
            return "grep -q"
        if re.search(r"-[A-Za-z]*m", opts) or "--max-count" in opts:
            return "grep -m"
        if re.search(r">\s*/dev/null", s):  # GNU grep and ugrep (the Mac's grep) stop at the first match then too
            return "grep >/dev/null"
        return None
    if re.match(r"[gmn]?awk\b", s):
        progs = [p for _, p in awk_programs(s)]
        if any(re.search(r"\bexit\b", strip_awk_strings(p)) and not re.search(r"\bEND\s*\{[^}]*\bexit\b", p)
               for p in progs):
            return "awk exit"
    return None


def logical_lines(lines):
    """Join backslash continuations and keep single-quoted strings spanning lines together.
    Yields (first_line_no, text)."""
    buf, start = "", None
    quote = None
    for n, line in enumerate(lines, 1):
        if start is None:
            start = n
        buf += line
        # track open quotes across this line (rough: comments outside quotes end the scan)
        i = 0
        while i < len(line):
            c = line[i]
            if quote == "'":
                if c == "'":
                    quote = None
            elif quote == '"':
                if c == "\\":
                    i += 1
                elif c == '"':
                    quote = None
            else:
                if c == "\\":
                    i += 1
                elif c in "'\"":
                    quote = c
                elif c == "#" and (i == 0 or line[i - 1] in " \t;"):
                    break
            i += 1
        if quote is None and not line.rstrip("\n").endswith("\\"):
            yield start, buf
            buf, start = "", None
        else:
            buf += "\n" if not buf.endswith("\n") else ""
    if buf:
        yield start, buf


def split_pipelines(s):
    """Split a logical line into pipelines at every nesting level.
    Returns [(segments, before_sep, after_sep, in_subst)] where before/after are the list separators around it
    (';', '&&', '||', '&', 'if', 'open', 'close', '!') and in_subst says the pipeline is inside $( ... )."""
    out = []
    stack = [{"segs": [""], "before": "open", "subst": False}]
    i, q = 0, None

    def close_pipeline(sep_after, cur):
        segs = [x for x in cur["segs"]]
        if any(x.strip() for x in segs):
            out.append((segs, cur["before"], sep_after, cur["subst"]))
        cur["segs"] = [""]
        cur["before"] = sep_after

    while i < len(s):
        c = s[i]
        cur = stack[-1]
        if q == "'":
            cur["segs"][-1] += c
            if c == "'":
                q = None
            i += 1
            continue
        if q == '"':
            if c == "\\" and i + 1 < len(s):
                cur["segs"][-1] += s[i:i + 2]
                i += 2
                continue
            if c == '"':
                q = None
                cur["segs"][-1] += c
                i += 1
                continue
            if s.startswith("$(", i) and not s.startswith("$((", i):
                cur["segs"][-1] += "$(…)"
                stack.append({"segs": [""], "before": "open", "subst": True, "q": '"'})
                q = None
                i += 2
                continue
            cur["segs"][-1] += c
            i += 1
            continue
        if c == "\\" and i + 1 < len(s):
            cur["segs"][-1] += s[i:i + 2]
            i += 2
            continue
        if c in "'\"":
            q = c
            cur["segs"][-1] += c
            i += 1
            continue
        if c == "#" and (i == 0 or s[i - 1] in " \t;\n"):
            j = s.find("\n", i)
            i = len(s) if j < 0 else j
            continue
        if s.startswith("$((", i):
            j = s.find("))", i)
            j = len(s) if j < 0 else j + 2
            cur["segs"][-1] += s[i:j]
            i = j
            continue
        if s.startswith("$(", i) or s.startswith("<(", i) or s.startswith(">(", i):
            cur["segs"][-1] += "$(…)"
            stack.append({"segs": [""], "before": "open", "subst": s[i] == "$", "q": None})
            i += 2
            continue
        if c == "(" and not cur["segs"][-1].strip():
            stack.append({"segs": [""], "before": cur["before"], "subst": cur["subst"], "q": None, "group": True})
            i += 1
            continue
        if c == ")":
            if len(stack) > 1:
                close_pipeline("close", cur)
                top = stack.pop()
                if top.get("q"):
                    q = top["q"]
                i += 1
                continue
        if s.startswith("&&", i) or s.startswith("||", i):
            close_pipeline(s[i:i + 2], cur)
            i += 2
            continue
        if c == "|":
            cur["segs"].append("")
            i += 1
            continue
        if c in ";&\n":
            close_pipeline(";" if c != "&" else "&", cur)
            i += 1
            continue
        cur["segs"][-1] += c
        i += 1
    while stack:
        close_pipeline("eol", stack.pop())
    return out


FUNC_START = re.compile(r"^\s*(function\s+)?[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{?\s*$|^\s*(function\s+)?[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{")


def file_has(text, what):
    if what == "pipefail":
        return re.search(r"^\s*set\s+[^#\n]*(-o\s+pipefail|-[a-z]*o[a-z]*\s+pipefail)", text, re.M) is not None
    if what == "errexit":
        return re.search(r"^\s*set\s+-[a-zA-Z]*e", text, re.M) is not None


def check_sigpipe(text, lines):
    if not file_has(text, "pipefail"):
        return []
    errexit = file_has(text, "errexit")
    wrappers = su_wrappers(text) | {"sh_", "ash", "_kw_sh", "asroot", "ww_us", "us_"}
    hits = []
    llist = list(logical_lines(lines))
    for idx, (ln, s) in enumerate(llist):
        for segs, before, after, subst in split_pipelines(s):
            if len(segs) < 2:
                continue
            kind = consumer_kind(segs[-1])
            if not kind:
                continue
            if not any(is_producer(x, wrappers) for x in segs[:-1]):
                continue
            head = re.sub(r"^(?:function\s+)?[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{\s*", "", segs[0].strip())
            used = (before in ("&&", "||") or after in ("&&", "||") or head.startswith("!")
                    or re.match(r"(if|elif|while|until)\b", head) is not None
                    or (subst and errexit))
            # the last command of a function: its status is the function's (`f | grep -q`, `if f`)
            if not used:
                rest = s[s.find(segs[-1]) + len(segs[-1]):]
                nxt = llist[idx + 1][1].strip() if idx + 1 < len(llist) else ""
                if re.match(r"\s*[;\n]?\s*\}", rest) or (nxt.startswith("}") and re.sub(r"\s", "", rest) in ("", ";")):
                    used = True
            if used:
                hits.append((ln, kind))
    return hits


# ---------------------------------------------------------------- (c) single quotes nested in su -c '...'
WRAP_DEF = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{(.*)$", re.M)


def su_wrappers(text):
    """Functions that paste their arguments into a single-quoted remote string, e.g.
    sh_() { "$A" shell "su -c '$*'" ...; }"""
    names = set()
    for m in WRAP_DEF.finditer(text):
        body = m.group(2)
        if re.search(r"'\$(\*|1|@|\{\*\}|\{1\}|\{@\})'", body) and re.search(r"\bsu\s+-c\b", body):
            names.add(m.group(1))
    return names


def dq_string_at(s, i):
    """s[i] == '"'. Return the string's content (raw) and the index after its closing quote."""
    j, depth = i + 1, 0
    while j < len(s):
        c = s[j]
        if c == "\\":
            j += 2
            continue
        if s.startswith("$(", j):
            depth += 1
            j += 2
            continue
        if c == ")" and depth:
            depth -= 1
        elif c == '"' and not depth:
            return s[i + 1:j], j + 1
        j += 1
    return s[i + 1:], len(s)


def bad_quotes(content):
    """Single quotes in content that are not the '\\'' or '"'"' idioms, outside nested $( )."""
    c = content.replace("'\\''", "").replace("'\"'\"'", "")
    out, i, depth, q = [], 0, 0, None
    while i < len(c):  # drop $( ... ) - a nested command's quotes belong to the local shell
        if depth:
            ch = c[i]
            if q:
                if ch == q:
                    q = None
            elif ch in "'\"":
                q = ch
            elif c.startswith("$(", i):
                depth += 1; i += 1
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            i += 1
            continue
        if c.startswith("$(", i):
            depth, i = 1, i + 2
            continue
        out.append(c[i]); i += 1
    return "'" in "".join(out)


def check_nested_quotes(text, lines):
    hits = []
    wrappers = su_wrappers(text)
    for ln, s in logical_lines(lines):
        if WRAP_DEF.match(s):
            pass  # the wrapper's own definition is checked like any line for literal su -c below
        # 1. wrapper calls whose argument is double-quoted: sh_ "... 'x' ..."
        for name in wrappers:
            for m in re.finditer(r"(?:^|[\s;&|(`$])" + re.escape(name) + r"\s+(?=\")", s):
                content, _ = dq_string_at(s, m.end())
                if bad_quotes(content):
                    hits.append(ln)
        # 2. a literal su -c '...' inside a double-quoted string: the single-quoted part must end at a word boundary
        for m in re.finditer(r"\bsu\s+-c\s+'", s):
            # only when we're inside double quotes (otherwise the shell here parses it and nesting is visible)
            pre = s[:m.start()]
            if pre.count('"') - pre.count('\\"') == 0 or (pre.count('"') - pre.count('\\"')) % 2 == 0:
                continue
            k = s.find("'", m.end())
            while k >= 0 and (s.startswith("'\\''", k) or s.startswith("'\"'\"'", k)):
                k = s.find("'", k + (4 if s.startswith("'\\''", k) else 5))
            if k < 0:
                continue
            after = s[k + 1:k + 2]
            if after and after not in " \t\n;|&)\"<>":
                hits.append(ln)
    return sorted(set(hits))


LOGCAT_SPEC = re.compile(r"(?<![\w.-])([A-Za-z][\w.]*):[VDIWEFS*]\b")


def check_logcat_dup_tag(lines):
    """Lines running logcat whose filterspecs name one tag twice (the last spec wins)."""
    hits = []
    for ln, s in logical_lines(lines):
        for m in re.finditer(r"\blogcat\b", s):
            seg = re.split(r"[|;&\n]", s[m.end():], maxsplit=1)[0]
            tags = [t for t in LOGCAT_SPEC.findall(seg) if t != "*"]
            if len(tags) != len(set(tags)):
                hits.append(ln)
    return sorted(set(hits))


def lint_file(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    lines = text.splitlines(keepends=True)
    found = []
    for off in check_awk_ternary(text):
        ln = text.count("\n", 0, off) + 1
        if not lint_ok(lines, ln):
            found.append((ln, "awk-ternary", "unparenthesized ?: with < or > in print/printf (BSD awk reads a redirect)"))
    for ln, kind in check_sigpipe(text, lines):
        if not lint_ok(lines, ln):
            found.append((ln, "sigpipe", f"pipefail + adb/dumpsys/logcat producer + early-exit consumer ({kind})"
                                         " whose status is used; read to the end (awk '/x/{f=1} END{exit !f}')"))
    for ln in check_nested_quotes(text, lines):
        if not lint_ok(lines, ln):
            found.append((ln, "nested-quote", "single quote inside a su -c '...' string closes it early"))
    for ln in check_logcat_dup_tag(lines):
        if not lint_ok(lines, ln):
            found.append((ln, "logcat-dup-tag", "a tag twice in a logcat filterspec: the last spec wins (Tag:W drops"
                                                " its I lines); give it once, Tag:I includes W"))
    return sorted(set(found))


def main(argv):
    files = argv or default_files()
    n = 0
    for p in files:
        for ln, kind, msg in lint_file(p):
            rel = os.path.relpath(p, ROOT) if os.path.isabs(p) and p.startswith(ROOT) else p
            print(f"{rel}:{ln}: {kind}: {msg}")
            n += 1
    return 1 if n else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
