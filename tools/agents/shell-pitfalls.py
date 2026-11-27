#!/usr/bin/env python3
"""shell-pitfalls.py [file...] - lint shell for seven pitfalls that produced false check FAILs or silent script deaths.

WHY (11-10): three checks FAILed on shell pitfalls, not product bugs; each cost a queue run plus an agent.
  awk-ternary   `printf "%d", t>0?t:0` - BSD awk (the Mac's, 20200816) parses `>` as an output redirect: syntax
                error. Parenthesize the ternary: `(t>0?t:0)`. (plasma-modes desk_top)
  sigpipe       under `set -o pipefail`, `adb shell dumpsys ... | awk '/x/{print; exit}'` (or `| head -n1`,
                `| grep -q`, `| grep -m1`, `| grep x >/dev/null` - GNU grep and ugrep quit early then too) closes
                the pipe early; adb dies of SIGPIPE (141) and the pipeline reads as false even on a match. Read to
                the end (`awk '/x/&&!f{print;f=1}'`, `awk '/x/{f=1} END{exit !f}'` for a test) or filter on the
                phone side (`sh_ "dumpsys window | grep -m1 x"`). (plasma-modes focus()) Any `docker ...` producer
                too: adb.sh's `docker exec wireguard wg show | awk '...exit'` killed rooted deploys rc 141 (11-25).
  nested-quote  a single quote inside an argument that ends up inside `su -c '...'` (sh_ "...", a literal
                "su -c '...'") closes the su string early, so the command runs mangled. Use \\" or '\\''.
                (ww-popup-x11)
  logcat-dup-tag  one tag twice in a logcat filterspec (`-s Tag:I Tag:W`): the last spec wins, so `Tag:W` drops the
                tag's I lines - the check reads nothing. `Tag:I` already includes W/E. (ww-popups 11-10 09:21)
  py-c          a `python3 -c '...'` program that doesn't compile, or has a backslash inside an f-string's {...}
                (a SyntaxError before Python 3.12; the Mac's /usr/bin/python3 is 3.9). Inside shell single quotes
                `\\"` reaches Python as backslash-quote, so `f"{p[\\"n\\"]}"` breaks on every version. Put the
                program in a quoted heredoc (`prog=$(cat <<'PY' ... PY)`, `python3 -c "$prog"`) and write p['n'].
                (ai-tab-head 11-23)
  nomatch-grep  under `set -e` + `set -o pipefail`, a grep (`grep -v`, `grep -c`, `grep -o`...) in a pipeline, or alone in
                an assignment's `$(...)` (`x=$(... | grep -v y | sort)`, `n=$(grep -c x f)`, `r="a $(...)"`), exits 1
                when nothing matches and the script ends right there with no message. gate.sh twice on 11-25/26 (a
                clean tree's `| grep -v node_modules | sort`; the widget block's grep after re-enabling set -e). Handle
                it: `|| true` on the pipeline, `{ grep x || true; } |` to keep the producer's status, or test it
                (if/while/!/a non-final && || member). Not flagged: `local x=$(...)`, `$(...)` as an argument, `<(...)`,
                a $(...)'s non-final commands, a function's last command (its caller tests it), a bare `grep x f`
                statement (an assertion), heredoc bodies, and lines after `set +e` / `set +o pipefail`.
  silent-return under `set -e`, a plain statement call (`fn args`, `fn a; step`) of a function that can fail without a
                word - a bare `cmd || return N` in its body, or an untested call of such a function - ends the script
                right there with status N and nothing printed. shell/dev/preview.sh 11-27: browser_job's `|| return 2`
                (a docker exec/tar to the gate job failing) under `browser plan` killed the widget sweep with exit 2
                before its verdict, so the gate FAILed with no reason. Say what failed (`|| { echo "x: y failed" >&2;
                return 2; }`) or test the call (`fn || die ...`, if fn; then).

Escape a deliberate case with `# lint-ok: <why>` on the line (or on the line just above it).
With no arguments it scans tools/phone/**/*.sh and tools/agents/*.sh; tools/lint/changed-lints.sh runs it on every
changed shell script (push hook + scoped gate). Exit 1 if anything is found.
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
        # skip options/assignments up to the program's opening quote, on the same logical line. An option word is
        # skipped whole, its quotes too: `awk -F'\t' -v ip="$x" '...exit'` (adb.sh's wg_age, 11-25) read '\t' as the
        # program and missed the exit.
        while i < len(text) and text[i] != "'" and text[i] != "\n":
            if text.startswith("\\\n", i):  # a line continuation between the words
                i += 2
                continue
            if text[i] == '"':  # a double-quoted word (-v now="$(date +%s)"): skipped whole
                close = text.find('"', i + 1)
                i = close + 1 if close > 0 else len(text)
                continue
            if text[i] in "|;&)`":
                break
            if text[i] == "-" and (i == 0 or text[i - 1] in " \t"):
                while i < len(text) and text[i] not in " \t\n|;&)`":
                    if text[i] in "'\"":
                        close = text.find(text[i], i + 1)
                        i = close if close > 0 else len(text) - 1
                    i += 1
                continue
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
        # docker's CLI (Go) dies of SIGPIPE on its stdout too: `docker exec wireguard wg show wg0 dump | awk '...exit'`
        # in adb.sh's wg_age failed ~1 in 200 calls with rc 141, silently ending every rooted deploy that hit it (11-25).
        return (re.match(r"(dumpsys|logcat|journalctl|docker)\b", s) is not None
                or re.match(r"cat\b[^|]*\.log\b", s) is not None)
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
    # heredoc bodies are another shell's script (a phone-side `sh <<EOF`), without this file's pipefail
    llist = list(logical_lines(blank_heredocs(text).splitlines(keepends=True)))
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
                # located by its tail: split_pipelines shows a $(...) inside the segment as $(…), so the whole
                # segment is not in s (adb.sh's wg_age `awk -v now="$(date +%s)" '...exit'` was missed, 11-25)
                tail = segs[-1].rstrip()[-24:]
                pos = s.rfind(tail) if tail else -1
                rest = s[pos + len(tail):] if pos >= 0 else ""
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


# ---------------------------------------------------------------- (e) python3 -c '...' programs
PY_C_RE = re.compile(r"\bpython3?(?:\s+-[A-Za-z]+)*\s+-c\s+'")
HEREDOC_RE = re.compile(r"""<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1""")
FSTR_RE = re.compile(r"""(?<![A-Za-z0-9_])[rRbB]?[fF][rRbB]?("{3}|'{3}|"|')""")


def toplevel_offsets(text):
    """bytearray, 1 where the offset is outside any shell quote, comment or heredoc body (rough, but enough to skip
    programs that sit inside a double-quoted remote command, whose text the shell rewrites first)."""
    top = bytearray(len(text))
    i, q, pending = 0, None, []
    while i < len(text):
        c = text[i]
        if q is None:
            top[i] = 1
            if c == "\\":
                i += 2
                continue
            if c in "'\"":
                q = c
            elif c == "#" and (i == 0 or text[i - 1] in " \t;\n"):
                j = text.find("\n", i)
                i = len(text) if j < 0 else j
                continue
            elif text.startswith("<<", i) and not text.startswith("<<<", i):
                m = HEREDOC_RE.match(text, i)
                if m:
                    pending.append(m.group(2))
            elif c == "\n" and pending:
                j = i + 1
                for d in pending:  # skip each body up to its delimiter line
                    m = re.compile(r"^\t*" + re.escape(d) + r"[ \t]*$", re.M).search(text, j)
                    j = len(text) if not m else m.end()
                pending = []
                i = j
                continue
        elif q == "'":
            if c == "'":
                q = None
        else:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                q = None
        i += 1
    return top


def single_quoted_word(text, start):
    """text[start - 1] is the opening '. The word's shell value, following the '\\'' and '"'"' joins."""
    out, i = [], start
    while True:
        end = text.find("'", i)
        if end < 0:
            return None
        out.append(text[i:end])
        if text.startswith("'\\''", end):
            out.append("'"); i = end + 4
        elif text.startswith("'\"'\"'", end):
            out.append("'"); i = end + 5
        else:
            return "".join(out)


def fstring_brace_backslash(prog):
    """1-based program lines where an f-string's {...} holds a backslash (a SyntaxError before Python 3.12)."""
    hits = []
    for m in FSTR_RE.finditer(prog):
        qt, i, depth, field_bs = m.group(1), m.end(), 0, False
        while i < len(prog):
            c = prog[i]
            if depth == 0:
                if prog.startswith(qt, i) or (c == "\n" and len(qt) == 1):
                    break
                if c == "\\":
                    i += 2
                    continue
                if prog.startswith("{{", i):
                    i += 2
                    continue
                if c == "{":
                    depth, field_bs = 1, False
            elif c == "\\":
                field_bs = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0 and field_bs:
                    hits.append(prog.count("\n", 0, i) + 1)
            i += 1
    return hits


def check_py_c(text):
    """[(offset, why)] for top-level python3 -c '...' programs that won't compile on the hosts' Pythons."""
    hits, top = [], None
    for m in PY_C_RE.finditer(text):
        if top is None:
            top = toplevel_offsets(text)
        if not top[m.start()]:
            continue
        prog = single_quoted_word(text, m.end())
        if prog is None:
            continue
        bs = fstring_brace_backslash(prog)
        if bs:
            hits.append((m.start(), f"backslash inside an f-string {{...}} (program line {bs[0]})"))
            continue
        try:
            compile(prog, "<python3 -c>", "exec")
        except SyntaxError as e:
            hits.append((m.start(), f"SyntaxError: {e.msg} (program line {e.lineno})"))
    return hits


# ---------------------------------------------------------------- (f) grep's "no match" status under errexit + pipefail
GREP_SEG = re.compile(r"(?:command\s+|env\s+(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*|(?:LC_ALL|LANG)=\S*\s+)?[ef]?grep\b")
ASSIGN_ONLY = re.compile(r"^(?:[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=(?:\"[^\"]*\"|'[^']*'|\S)*\s*)+$")
SET_LINE = re.compile(r"^\s*set\s+([^#\n;&|]*)")


def shell_modes(lines):
    """[(errexit, pipefail)] per 1-based line (index 0 unused), following top-level `set -e/+e`, `set -o pipefail`,
    `set -o errexit` in text order. Rough: a `set +e` inside a subshell or function stays off after it."""
    e = p = False
    out = [(False, False)]
    for line in lines:
        m = SET_LINE.match(line)
        if m:
            for w in re.findall(r"[-+]o\s+\w+|[-+][A-Za-z]+", m.group(1)):
                on = w[0] == "-"
                if w[1] == "o" and " " in w:
                    name = w.split()[1]
                    if name == "pipefail":
                        p = on
                    elif name == "errexit":
                        e = on
                    continue
                if "e" in w[1:]:
                    e = on
                if w.endswith("o") and re.search(re.escape(w) + r"\s+pipefail", m.group(1)):
                    p = on
        out.append((e, p))
    return out


def blank_heredocs(text):
    """text with every heredoc body line emptied (their content belongs to another shell or file)."""
    top = toplevel_offsets(text)
    lines = text.splitlines(keepends=True)
    out, pend, off = [], [], 0
    for line in lines:
        if pend:
            d = pend[0]
            out.append("\n" if line.endswith("\n") else "")
            if re.match(r"^\t*" + re.escape(d) + r"[ \t]*$", line.rstrip("\n")):
                pend.pop(0)
            off += len(line)
            continue
        out.append(line)
        for m in HEREDOC_RE.finditer(line):
            k = off + m.start()
            if top[k] and not line.startswith("<<<", m.start()) and not (m.start() and line[m.start() - 1] == "<"):
                pend.append(m.group(2))
        off += len(line)
    return "".join(out)


def nomatch_lines(lines):
    """Logical lines for the nomatch rule: logical_lines, plus lines that end in | && || or leave a $( open."""
    buf, start, depth = "", None, 0
    for n, s in logical_lines(lines):
        if start is None:
            start = n
        buf += s
        code = s
        for sp in sorted(quoted_spans(s), reverse=True):  # drop quoted text, then a trailing comment
            code = code[:sp[0]] + code[sp[1]:]
        code = re.sub(r"(^|[\s;])#.*", r"\1", code)
        depth = max(0, depth + code.count("$(") + code.count("<(") - code.count("$((") * 2
                    - (code.count(")") - code.count("))") * 2))
        if depth == 0 and not re.search(r"(\|\||&&|\|)\s*$", code.rstrip()):
            yield start, buf
            buf, start, depth = "", None, 0
    if buf:
        yield start, buf


def split_pipelines_tree(s):
    """split_pipelines with structure: [{segs, before, after, kind, parent, last}] where kind is 'top', 'subst'
    ($(...)), 'proc' (<(...)/>(...)), 'group' ((...)); parent is the index of the enclosing pipeline (or None) and
    last says it is the last pipeline of its $(...)/(...)."""
    out, i, q = [], 0, None
    counter = [0]

    def frame(kind, before, parent, q_=None):
        counter[0] += 1
        return {"segs": [""], "before": before, "kind": kind, "q": q_, "pid": counter[0], "parent": parent,
                "items": []}

    stack = [frame("top", "open", None)]
    pid_index = {}

    def close_pipeline(sep_after, cur):
        if any(x.strip() for x in cur["segs"]):
            e = {"segs": cur["segs"], "before": cur["before"], "after": sep_after, "kind": cur["kind"],
                 "parent_pid": cur["parent"], "last": False}
            out.append(e)
            pid_index[cur["pid"]] = len(out) - 1
            cur["items"].append(len(out) - 1)
        counter[0] += 1
        cur["pid"] = counter[0]
        cur["segs"] = [""]
        cur["before"] = sep_after

    def open_child(kind, before, q_=None):
        stack.append(frame(kind, before, stack[-1]["pid"], q_))

    def pop_child():
        cur = stack.pop()
        if cur["items"]:
            out[cur["items"][-1]]["last"] = True
        return cur

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
                open_child("subst", "open", '"')
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
            open_child("subst" if s[i] == "$" else "proc", "open")
            i += 2
            continue
        if c == "(" and not cur["segs"][-1].strip():
            cur["segs"][-1] += "(…)"
            open_child("group", "open")
            i += 1
            continue
        if c == ")" and len(stack) > 1:
            close_pipeline("close", cur)
            top = pop_child()
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
        close_pipeline("eol", stack[-1])
        pop_child()
    for e in out:
        p = e.pop("parent_pid")
        e["parent"] = pid_index.get(p)
    # a pipeline in an if/while condition: its head starts the condition, or it follows one through && / ||
    for k, e in enumerate(out):
        head = strip_lead_kw(e["segs"][0])
        e["cond"] = re.match(r"(if|elif|while|until)\b", head.strip()) is not None or head.lstrip().startswith("!")
    prev_in_frame = {}
    for k, e in enumerate(out):
        key = (e["parent"], e["kind"])
        pk = prev_in_frame.get(key)
        if pk is not None and out[pk]["after"] in ("&&", "||") and out[pk]["cond"]:
            e["cond"] = True
        prev_in_frame[key] = k
    return out


def strip_lead_kw(seg):
    s = seg.strip()
    s = re.sub(r"^(?:function\s+)?[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{\s*", "", s)
    while True:
        t = re.sub(r"^(?:\{|then|do|else|time)\s+", "", s)
        if t == s:
            return s
        s = t


def pipeline_guarded(out, k):
    """errexit can't fire on out[k]: it is tested (if/while/!/a non-final && || member), or it is an argument
    ($(...) in a command's words, <(...)), or its enclosing pipeline is guarded."""
    e = out[k]
    if e["cond"] or e["after"] in ("&&", "||"):
        return True
    if e["kind"] == "top":
        return False
    p = e["parent"]
    if p is None:
        return False
    if e["kind"] == "proc":
        return True
    if e["kind"] == "subst":
        if not e["last"]:
            return True  # bash's $(...) doesn't inherit errexit: only its last status reaches the assignment
        par = out[p]
        if len(par["segs"]) != 1 or not ASSIGN_ONLY.match(strip_lead_kw(par["segs"][0])):
            return True  # an argument (echo "$(...)", local x=$(...), for x in $(...)): the status is dropped
    return pipeline_guarded(out, p)


def is_function_tail(s, segs, rest_lines):
    tail = segs[-1].rstrip()[-24:]
    pos = s.rfind(tail) if tail else -1
    rest = s[pos + len(tail):] if pos >= 0 else ""
    nxt = rest_lines.strip()
    return bool(re.match(r"\s*[;\n]?\s*\}", rest) or (nxt.startswith("}") and re.sub(r"\s", "", rest) in ("", ";")))


def check_nomatch_grep(text, lines):
    """grep (any pipeline member, or alone in an assignment's $(...)) under errexit + pipefail whose no-match status 1
    isn't handled: the script ends right there with no message (gate.sh 11-25/26 twice)."""
    if not (file_has(text, "pipefail") and file_has(text, "errexit")):
        return []
    modes = shell_modes(lines)
    blank = blank_heredocs(text).splitlines(keepends=True)
    llist = list(nomatch_lines(blank))
    hits = []
    for idx, (ln, s) in enumerate(llist):
        e_on, p_on = modes[ln] if ln < len(modes) else (False, False)
        if not (e_on and p_on):
            continue
        out = split_pipelines_tree(s)
        nxt = llist[idx + 1][1] if idx + 1 < len(llist) else ""
        for k, e in enumerate(out):
            segs = e["segs"]
            greps = [x for x in segs if GREP_SEG.match(strip_lead_kw(x))]
            if not greps:
                continue
            if len(segs) == 1 and e["kind"] != "subst":
                continue  # a bare `grep x f` statement: an assertion, the script's choice
            if pipeline_guarded(out, k):
                continue
            if e["kind"] == "top" and is_function_tail(s, segs, nxt):
                continue  # a function's last command: its status is the function's, the caller decides
            g = strip_lead_kw(greps[0])
            hits.append((ln, g.split()[0] if not g.startswith("command") else "grep"))
    return sorted(set(hits))


# ---------------------------------------------------------------- (g) silent return under set -e
FUNC_DEF = re.compile(r"^(\s*)(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)\s*\{")
SILENT_RET = re.compile(r"\|\|\s*return\s+[1-9]\d*\s*(?:$|[;#}])")


def functions(lines):
    """{name: (first, last)} 1-based line spans of function bodies: `name() {` up to its closing `}` (the line that is
    `}` at the definition's indentation, or the same line for a one-liner `name() { ...; }`)."""
    out, i = {}, 0
    while i < len(lines):
        m = FUNC_DEF.match(lines[i])
        if not m:
            i += 1
            continue
        ind, name = m.group(1), m.group(2)
        rest = lines[i][m.end():]
        if re.search(r"\}\s*(?:#.*)?$", rest.rstrip("\n")) and rest.count("{") < rest.count("}"):
            out[name] = (i + 1, i + 1)
            i += 1
            continue
        j = i + 1
        while j < len(lines) and not re.match("^" + re.escape(ind) + r"\}", lines[j]):
            j += 1
        out[name] = (i + 1, min(j + 1, len(lines)))
        i = j + 1
    return out


def bare_calls(code, names):
    """names called as a plain statement in this line of code (not tested by if/while/!/&&/||, not in $(...))."""
    hits = []
    if re.search(r"\|\||&&", code) or re.match(r"\s*(if|elif|while|until|!)\b", code):
        # A tested line: only `...; then fn x; fi`-style tails after then/else/do are plain statements.
        segs = re.split(r"\b(?:then|else|do)\b", code)[1:] if re.search(r"\b(then|else|do)\b", code) else []
        segs = [x for seg in segs for x in seg.split(";") if not re.search(r"\|\||&&", x)]
    else:
        segs = code.split(";")
    for seg in segs:
        w = seg.strip().split()
        if w and w[0] in names:
            hits.append(w[0])
    return hits


def check_silent_return(text, lines):
    if not file_has(text, "errexit"):
        return []
    blank = blank_heredocs(text).splitlines(keepends=True)
    code = []
    for line in blank:
        c = line
        for sp in sorted(quoted_spans(line), reverse=True):
            c = c[:sp[0]] + '""' + c[sp[1]:]
        code.append(re.sub(r"(^|[\s;])#.*", r"\1", c).rstrip("\n"))
    funcs = functions(blank)
    def guards_external(c):
        """`cmd || return N` where cmd isn't one of this file's functions (those say why themselves, or are
        followed through the propagation below)."""
        m = SILENT_RET.search(c)
        if not m:
            return False
        stmt = re.split(r";|\b(?:then|else|do)\b|\{", c[:m.start()])[-1].strip()
        stmt = re.sub(r"^(?:local\s+)?[A-Za-z_]\w*=\$\(", "", stmt)  # x=$(fn ...) || return: fn's status
        w = re.sub(r"^(?:[A-Za-z_]\w*=\S*\s+)*", "", stmt).split()
        return bool(w) and w[0] not in funcs
    silent = {n for n, (a, b) in funcs.items() if any(guards_external(code[k - 1]) for k in range(a, b + 1))}
    grew = True
    while grew:  # a function that calls a silent one as a plain statement fails as silently
        grew = False
        for n, (a, b) in funcs.items():
            if n not in silent and any(bare_calls(code[k - 1], silent - {n}) for k in range(a + 1, b + 1)):
                silent.add(n)
                grew = True
    if not silent:
        return []
    inside = {k for a, b in funcs.values() for k in range(a, b + 1)}
    modes = shell_modes(lines)
    hits = []
    for ln in range(1, len(code) + 1):
        if ln in inside or not (modes[ln][0] if ln < len(modes) else False):
            continue
        for n in bare_calls(code[ln - 1], silent):
            hits.append((ln, n))
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
            found.append((ln, "sigpipe", f"pipefail + adb/dumpsys/logcat/docker producer + early-exit consumer ({kind})"
                                         " whose status is used; read to the end (awk '/x/{f=1} END{exit !f}')"))
    for ln in check_nested_quotes(text, lines):
        if not lint_ok(lines, ln):
            found.append((ln, "nested-quote", "single quote inside a su -c '...' string closes it early"))
    for ln in check_logcat_dup_tag(lines):
        if not lint_ok(lines, ln):
            found.append((ln, "logcat-dup-tag", "a tag twice in a logcat filterspec: the last spec wins (Tag:W drops"
                                                " its I lines); give it once, Tag:I includes W"))
    for off, why in check_py_c(text):
        ln = text.count("\n", 0, off) + 1
        if not lint_ok(lines, ln):
            found.append((ln, "py-c", f"python3 -c program: {why}; move it to a quoted heredoc"))
    for ln, g in check_nomatch_grep(text, lines):
        if not lint_ok(lines, ln):
            found.append((ln, "nomatch-grep", f"{g} under set -e + pipefail exits 1 on no match and ends the script"
                                              " silently; add `|| true`, or test it (if/&&/||)"))
    for ln, fn in check_silent_return(text, lines):
        if not lint_ok(lines, ln):
            found.append((ln, "silent-return", f"{fn} can `|| return N` without a message; under set -e this call ends"
                                               " the script silently - say what failed, or test the call"))
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
