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
| `mods/adopt.sh:mods_adopt_cmd` | 52 | 0 | 52 | 21 loops — nesting, not width |
| `game.sh:cmd_game` | 44 | **25** | 19 | a dispatcher; leave it alone |

`cmd_game` looks bad and is not: a flat 25-arm `case` is what a dispatcher
should be, and splitting it by CC would make it worse. `cmd_health` is the
opposite — nearly all of its 100 is real branching in one function.

**If anything gets refactored, `cmd_health` first.** Nothing here is urgent: it
is long-standing code that works, and the ratchet stops it growing.
