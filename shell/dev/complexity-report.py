#!/usr/bin/env python3
"""ESLint JSON (stdin) -> the N worst functions over the complexity limits, one line each:
   <cognitive> <cyclomatic> <lines> <file>:<line> <name>   ranked by cognitive complexity, then cyclomatic.
Also prints the totals: functions over a limit, and the count per rule. Used by lint-complexity.sh --report N."""
import json, os, re, sys

n = int(sys.argv[1]) if len(sys.argv) > 1 else 10
base = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
data = json.load(sys.stdin)
funcs, per_rule = {}, {}
for f in data:
    path = os.path.relpath(f["filePath"], base)
    for m in f["messages"]:
        rule = m.get("ruleId")
        if not rule:
            continue
        per_rule[rule] = per_rule.get(rule, 0) + 1
        e = funcs.setdefault((path, m["line"]), {"name": "", "cog": 0, "cc": 0, "lines": 0})
        nums = [int(x) for x in re.findall(r"\b(\d+)\b", m["message"])]
        name = re.search(r"(?:Method|Function|function|Arrow function|Async \w+) '([^']+)'", m["message"])
        if name:
            e["name"] = name.group(1)
        if rule == "sonarjs/cognitive-complexity" and nums:
            e["cog"] = nums[0]
        elif rule == "complexity" and nums:
            e["cc"] = nums[0]
        elif rule == "max-lines-per-function" and nums:
            e["lines"] = nums[0]
# sonarjs reports at the function's name, ESLint at its start: fold reports a line apart into one function.
merged = {}
for (path, line), e in sorted(funcs.items()):
    prev = merged.get((path, line - 1))
    if prev:
        for k in ("cog", "cc", "lines"):
            prev[k] = max(prev[k], e[k])
        prev["name"] = prev["name"] or e["name"]
        merged[(path, line)] = prev
    else:
        merged[(path, line)] = e
uniq = {id(v): (k, v) for k, v in merged.items()}.values()
print(f"functions over a limit: {len(uniq)}  (" + ", ".join(f"{r} {c}" for r, c in sorted(per_rule.items())) + ")")
for (path, line), e in sorted(uniq, key=lambda kv: (-kv[1]["cog"], -kv[1]["cc"]))[:n]:
    print(f"{e['cog']:4} {e['cc']:4} {e['lines']:4} {path}:{line} {e['name'] or '(anonymous)'}")
