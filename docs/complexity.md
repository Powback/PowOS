# Cyclomatic complexity

There is **no complexity gate in CI** — it lints `shellcheck -S error` only.
`build/complexity.py` measures on demand:

```bash
python3 build/complexity.py lib/*.sh bin/* build/*.sh
```

CC = 1 + decision points (`if`/`elif`/`while`/`until`/`for`, `&&`, `||`, case
patterns). It tracks brace depth, so single-line functions are measured
correctly — a first version did not, and reported a two-line helper at 67
because it kept accumulating until the next definition. Sanity-check any
analyzer before believing its output.

## Current state

286 functions. 17 over 15, 6 over 25. The large ones are long-standing install
paths, not recent additions.

| function | CC | verdict |
|---|---|---|
| `isv_install_alongside` | 37 | pre-existing; partitioning has many branches |
| `isv_install_whole_disk` | 35 | was 49 after edits; extracted back down |
| `parse_sudo_argv` | 32 | **deliberate** — see below |
| `cmd_install_wizard` | 32 | pre-existing |

## Why parse_sudo_argv stays

It parses sudo's option grammar: short clusters (`-Anu root`), long forms
(`--user=x`), options that consume the next argv, `VAR=val` prefixes. The branch
count *is* the specification. Splitting it by line count would scatter one
grammar across several functions and make it harder to verify against `sudo(8)`.

An extraction of the short-cluster loop was attempted and abandoned: it broke
the file (a dangling `;;`), and the helper is covered by 50 tests that all
passed before the refactor. Breaking working, tested code to satisfy a metric
that is not enforced is the wrong trade.

## If a gate is ever added

Set it above the current maximum and ratchet down, so it fails on *new* debt
rather than demanding a rewrite of the installer on day one. Exempt parsers
explicitly rather than letting someone "fix" them.

## The gate (added)

CI runs `build/complexity.py --check` as a **ratchet**:

* a function listed in `build/complexity-budget.txt` may not exceed its entry
* anything else may not exceed **15**

So existing debt is frozen rather than demanded away on day one, and new debt
fails the build. When a function improves, the check prints the lower number and
asks you to update the budget — the ratchet only turns one way.

Raising an entry is allowed. It must be deliberate and explained in the commit,
the way `parse_sudo_argv` is explained above.

Verified in both directions before being enabled: a new function at CC 16 fails,
a budgeted function grown past its entry fails, and a clean tree passes.

## Repo-wide picture

1526 functions in production shell. **113 over 15, 42 over 25.** The gate freezes
all of it; none of it is today's work.

The gate originally globbed `lib/*.sh`, which does **not** descend into
`lib/mods/` (16 files) or `lib/ai/` (8) — 24 files of real production code were
silently uncovered. It now enumerates by shebang via `git ls-files`.

### Raw CC misranks dispatchers

Separating `case` arms from genuine branching changes the priority order:

| function | CC | case arms | real | note |
|---|---|---|---|---|
| `powos:cmd_health` | 100 | 6 | **92** | 423 lines, 53 `if`, 39 `&&`/`\|\|` |
| `harness.sh:harness_run` | 77 | 0 | 77 | |
| `windows.sh:win_install` | 69 | 0 | 69 | |
| `agent.sh:ai_call` | 82 | 15 | 67 | |
| ~~`mods/adopt.sh:mods_adopt_cmd`~~ | ~~52~~ | | **8** | measured wrong — see below |
| `game.sh:cmd_game` | 44 | **25** | 19 | a dispatcher; leave it alone |

`cmd_game` looks bad and is not: a flat 25-arm `case` is what a dispatcher
should be, and splitting it by CC would make it worse. `cmd_health` is the
opposite — nearly all of its 100 is real branching in one function.

**If anything gets refactored, `cmd_health` first.** Nothing here is urgent: it
is long-standing code that works, and the ratchet stops it growing.

### It also miscounts heredocs

`build/complexity.py` is line-based and does not track heredoc boundaries, so
every `for`/`if`/`elif` inside an embedded `python3 - <<'PY'` payload is scored
as *shell* branching. That is not a rounding error:

| function | measured | shell | the rest |
|---|---|---|---|
| `mods/adopt.sh:mods_adopt_cmd` | 52 | **8** | 297 lines of embedded Python |
| `mods/portable.sh:mods_import_cmd` | 38 | 25 | three small Python payloads |

The table above ranked `mods_adopt_cmd` third-worst in the repo and described
it as "21 loops — nesting, not width". Those loops are in Python, and the
shell around them is eight branches of argument handling. Anyone who acted on
that ranking would have spent the effort restructuring a function that was
already fine.

Two ways out, and the choice is not about the metric:

* If the payload is big enough to be a program, **make it a file**.
  `adopt.py` now sits beside `adopt.sh` the way `vu-rcon.py` sits beside
  `vu.sh`; it is lintable, runnable and diffable on its own, and the shell
  function drops to what it actually does. `COPY lib/` ships it either way.
* If it is a ten-line filter feeding a `while read`, leave it inline. Moving
  it would scatter one thought across two files to satisfy a tool's blind
  spot. `mods_import_cmd` keeps its three.

Teaching the analyzer about heredocs is the real fix and would lower numbers
across the tree — treat it as a separate change, because it moves many budget
entries at once.

### Results of the lib/ai + lib/mods pass

| function | before | after | how |
|---|---|---|---|
| `agent.sh:ai_call` | 85 | 14 | split by call STAGE: parse, resolve backends, resolve session, compose prompt, dispatch, record |
| `harness.sh:harness_run` | 78 | 9 | split by PHASE, plus one helper per monitor-loop signal |
| `adopt.sh:mods_adopt_cmd` | 53 | 9 | payload moved to `adopt.py` |
| `vu.sh:vu_mod_install_cmd` | 43 | 15 | option grammar, then one helper per "which mods do you mean" branch |
| `portable.sh:mods_import_cmd` | 38 | 11 | parse / plan / apply |

`agent.sh:_ai_parse_args` (21) is budgeted, not fixed: 15 of its 21 are case
arms, one per option — the `parse_sudo_argv` exemption above.

The helpers write into the caller's locals rather than echoing, because bash
is dynamically scoped and these stages resolve several interdependent values
at once; `x=$(helper)` would fork a subshell and lose `export` side effects
(`--yolo`) or buffer output that exists precisely to stream. Every name so
written is declared `local` in the top-level function — and one that was NOT
is the single bug this pass introduced: `mhud_ever_seen` was a monitor-loop
local that `_harness_confidence` reads afterwards, so hoisting it was
required. It surfaced only because `test-mods-harness.sh` was fixed to source
the checkout instead of `/usr/lib/powos` — until then the suite had been
reporting green against an installed copy three weeks stale.


## The analyzer counted Python as shell

`build/complexity.py` did not track heredoc boundaries, so `for`/`if` inside a
`python3 - <<'PY'` payload counted as shell branching. **`mods_adopt_cmd` measured
53 when its real shell complexity is 8** — the other 45 were 297 lines of Python.
That inflated number was published in the table above as the third-worst function
in the repo, and acting on it would have meant restructuring a function that was
already fine.

47 Python payloads and 19 other heredocs across 29 files were affected.

Fixing it also revealed a second fault: a `}` inside a heredoc body corrupted
brace-depth tracking and silently merged adjacent functions, so some branches
were attributed to the wrong one. Function count went 1632 → 1663 once heredoc
bodies were skipped.

Repo-wide after the fix: **103 over 15, 24 over 25.**

The lesson is the one this file already carries about the first version
reporting a two-line helper at CC 67: **sanity-check a measuring tool against a
known case before believing its output, and again before writing its output into
documentation.** I did the first and not the second.
