# Agent tool-output waste, 2026-10-24

Tool: `tools/agents/efficiency.py --tools --since 2026-10-24T00:00` (add `--json` for raw numbers).
Data: 147 agent transcripts + coordinator, 8,952 tool calls, 4.10 M tokens of tool output.

## Method and caveats

- Output size = chars of each `tool_result` / 4 (the requested unit). The real tokenizer is denser on code and logs: context growth over 56 long agents works out to about 2.6 chars/token, so real sizes are roughly 1.5x the numbers below.
- carry = result tokens x the number of later model calls. Every later call re-reads the result from the context, so this is the real price of one output. Total carry today is 335 Mtok, which is 18% of the 1,827 Mtok context the fleet consumed. The rest is the ~45k brief and skill prefix re-read on every call, plus the agents' own thinking, text and tool inputs.
- Waste signals:
  - Hard waste: the call errored, repeated an identical call, was a wait/poll, or the output was >=1k tokens and fewer than 2 distinctive tokens (or <10% of them) were ever reused in later assistant text or tool inputs.
  - Low-use: a >=1k-token output where under 30% of its distinctive tokens were reused. This is the honest "mostly dead weight" number. A 6k Read where one function mattered counts here but not as hard waste.
- The "wait/poll" bucket is a regex on the command (`sleep`, `until`, `--wait`, `idle.sh`, `tasks/*.output`, `get-state`). It also catches compound commands that merely contain one of those words, so its tokens are an upper bound. The 231 results under 100 tokens are the true polls.
- Error = harness `is_error`, or a short output containing a "command not found / No such file / usage: / Exit code N" signature. A `grep` that finds nothing exits 1 and is flagged even when the agent meant it as a test. Treat grep errors as an upper bound.

## Per tool

| tool | calls | output tok | median | max | errors | repeats | truncated | hard-waste tok | carry Mtok |
|---|---|---|---|---|---|---|---|---|---|
| Bash | 6,983 | 2,969,733 | 124 | 6,949 | 634 | 124 | 26 | 434,288 | 227 |
| Read | 595 | 1,007,129 | 649 | 15,884 | 22 | 9 | 6 | 88,525 | 84 |
| WebFetch | 24 | 43,137 | 472 | 11,192 | 0 | 0 | 2 | 0 | <1 |
| Agent | 146 | 38,289 | 264 | 264 | 0 | 0 | 0 | 0 | 18 |
| Edit | 752 | 25,899 | 32 | 184 | 30 | 0 | 0 | 1,252 | 2 |
| everything else | ~420 | ~15k | | | | | | | <3 |

Bash plus Read is 97% of all output. Edit, Write, SendMessage, Monitor and the others are noise: tiny outputs. Their cost is the call, not the output.

Distribution: 1,081 results of >=1k tokens (12% of calls) carry 2.66 M tokens, which is 65% of all output. Of those, 1.84 M tokens (69%) had under 30% of their content reused, and they account for 110 Mtok of carry (a third of all carry).

## (1) Top 15 waste sources

Ranked by carry (wasted or low-use output x later calls that re-read it) and total tokens. "Fix" is a concrete change.

| # | tool + pattern | n | out tok | waste / low-use tok | carry Mtok | worst example | fix |
|---|---|---|---|---|---|---|---|
| 1 | Bash wait/poll | 406 (231 under 100 tok) | 89k | 89k hard | 9.9 (+~47 Mtok for the 231 calls themselves) | `idle.sh`/`sed` polling loops, `tasks/*.output` cats | One blocking `timeout N <cmd> --wait` per wait, never a poll loop. Every poll call re-reads the whole ~200k context. |
| 2 | Read, whole file >=5k tok | 46 (of 242 whole-file Reads) | 426k | 74k hard; 508k low-use among all Reads >=3k | 40.5 | `queue.sh` 13.5k (4 Reads, 38 across all forms), `AGENT-HANDBOOK.md` 15k | Read with `offset`/`limit` after `grep -n`; PreToolUse hook warns on Read without limit when the file is over 20 KB. |
| 3 | Reads of the same big docs by many agents (HANDBOOK, SKILL.md, CLAUDE.md) via Read + sed + cat | 456 reads, 53 and 47 agents | 495k | mostly low-use (sed of the handbook has util 0.2-0.3) | 43 (HANDBOOK 18.4, SKILL 19.9, CLAUDE 4.3) | `sed -n 34,136p docs/AGENT-HANDBOOK.md` 6.6k tok, util 0.28 | Put a 1.5k-token "agent card" (the ~15 rules agents actually apply) in the brief or skill header. Mark the handbook "read §X only" with `grep -n '^## '` first. |
| 4 | Bash sed -n range | 881 | 922k | 436k low-use (113 results >=2k = 352k tok) | 2.3 hard, ~20 low-use | `sed -n 120,362p AGENT-HANDBOOK.md` 6k | Cap ranges at ~80 lines; `grep -n` first. Optional harness output cap: head 2k tok plus "N more lines, narrow the range". |
| 5 | Bash grep (recursive, no head) | 1,168 | 409k | 47k hard (15 unreferenced); 129k low-use | 6.5 | `grep -hE ': (PASS\|FAIL\|SKIP\|INVALID)' runner.log ...` 6k tok, util 0.01 | Always `grep -l`/`-c`/`-m 20` or `\| head -40`. Add `queue.sh summary` / `verify-queue digest` so nobody greps `runner.log`. |
| 6 | Errored calls, all tools | 706 (8% of calls) | 100k | 100k direct | 9 (+~140 Mtok if you price each failed call at the 204k context it re-read) | `ls ~/.cache/powos-verify/e2e-.../` of missing dirs (69), `grep` no match (94), `bash` (38), `python3` (36), `timeout` (23) | Recipes: `ls` with a known path or `git ls-files \| grep`; zsh: quote globs; `timeout` needs the right binary (`gtimeout`/perl alarm, not `timeout` on mac). |
| 7 | Bash cat | 352 | 403k | 39k hard; 208k low-use | 1.3 | `cat appcap_serve.py ...` 6.5k, util 0.53 | `cat` of multiple files is the Read-whole-file problem in disguise; same fix as #2. |
| 8 | adb.sh shell | 85 | 51k | 30k hard (10 unreferenced) | 2.4 | `adb.sh shell 'su -c "for ...'` 6.2k, util 0.03 | Pipe device output through `grep`/`tail -40` on the device side; `shot.sh` style helpers print one line. |
| 9 | Bash ls | 352 | 106k | 24k hard | 1.2 | `ls ~/.cache/.../ ; grep -nE ...` 3.2k | `ls \| tail`, or `ls -t \| head`; avoid `ls -R`. |
| 10 | Bash wc + cat combos | 91 | 89k | 11k hard | 0.6 | `wc -l e2e-lib.sh && cat ...` 5.3k | Do not `wc` then `cat`; `sed -n 1,60p`. |
| 11 | Bash python3 heredocs | 452 | 116k | 19k hard | 0.6 | test run `| head -100` 2.5k | `python3 ... 2>&1 \| tail -20`, failures only. |
| 12 | Bash bash / test scripts | 311 | 42k | 10k hard (16 repeats, 38 errors) | 0.5 | `bash test/tier1/test-land.sh 2>&1` run repeatedly | Re-run only the failing test file; `... \| tail -15`. |
| 13 | Repeated identical Read/Bash | 133 repeats | 35k | 35k | ~3 | `add.tsx` 4k read twice, `main.tsx` 3.3k twice | Brief rule: "edit from the first read; re-read only after your own Edit or a rebase". |
| 14 | `pwd && ls -la && git ...` orientation | 31 | 14k | 3k hard | 0.4 | `pwd && echo --- && ls -la . ... git rev-parse` 1.2k | The brief already names the worktree; delete the orientation habit. |
| 15 | Skill loads that error or are tiny | 29 (13 errors) | 2k | 2k | 0.3 | `{"skill": "powos-verify"}` repeated | Name the exact skill + path in the brief. Small, but each is a wasted call. |

Truncated by the harness: 34 results (26 Bash, 6 Read, 2 WebFetch). Few enough that truncation is not a problem; the problem is untruncated 5-15k outputs.

## (2) Per agent: useful / waste, 10 biggest by output tokens

waste = hard waste; low-use = >=1k outputs with under 30% of tokens reused. First = context of the agent's first call (brief + skills). Coordinator first call is 920k because it runs on the 1M context.

| agent | calls | avg ctx | first ctx | output tok | hard waste | low-use | carry Mtok | errors |
|---|---|---|---|---|---|---|---|---|
| af8ebd0c (coordinator) | 884 | 472k | 920k | 141k | 26k (18%) | 9k (6%) | 65 | 43 |
| a4b08ae558 | 169 | 262k | 45k | 117k | 3k (2%) | 64k (55%) | 15 | 5 |
| a086142394 | 382 | 408k | 44k | 108k | 29k (26%) | 45k (41%) | 28 | 12 |
| ab20e64539 | 303 | 339k | 44k | 98k | 7k (7%) | 8k (8%) | 17 | 25 |
| a99160a4c3 | 146 | 232k | 39k | 97k | 1k (1%) | 25k (25%) | 10 | 13 |
| ab4934dabf | 260 | 296k | 45k | 92k | 10k (10%) | 20k (21%) | 14 | 20 |
| aa77cc1603 | 241 | 290k | 39k | 91k | 16k (17%) | 13k (14%) | 16 | 28 |
| a3673568be | 206 | 298k | 44k | 86k | 3k (4%) | 9k (9%) | 13 | 14 |
| af971ed8a9 | 227 | 249k | 44k | 75k | 2k (2%) | 28k (36%) | 11 | 13 |
| ac94c0c1a6 | 114 | 154k | 39k | 72k | 1k (1%) | 32k (44%) | 5 | 8 |

Useful share (100% minus hard waste minus low-use): 76%, 43%, 33%, 85%, 74%, 69%, 69%, 87%, 62%, 55%. Fleet-wide: 13% hard waste (550k of 4.10 M), ~45% low-use among >=1k outputs, but 100% of the outputs under 1k tokens count as useful (87% of calls).

What the table says:
- The worst agents (a086142394, a4b08ae558, ac94c0c1a6, af971ed8a9) are doc/code readers: big Reads and `sed` ranges where a fraction was used.
- The coordinator and aa77cc1603 lose most to polling and errors.
- All ten finished at 150-470k average context, far past the 150k handback rule. Output waste is the smaller part; the base prefix is re-read on every call.

## (3) Top 5 fixes, ranked by estimated context tokens saved

Savings are estimates of tokens re-read by later calls (carry, plus call overhead where noted), assuming the stated cut rate.

| rank | fix | est. saved | basis |
|---|---|---|---|
| 1 | Replace poll loops with one blocking wait: `timeout N <cmd> --wait`; ban `sleep` loops and repeated `tasks/*.output` cats. | ~45 Mtok | 231 tiny polls x ~204k context, 80% avoidable, plus 10 Mtok output carry |
| 2 | Kill avoidable errors: recipes for missing-path `ls`, zsh glob quoting, `timeout` on mac, `grep` as test (`grep -q ...; true`). | ~35 Mtok | 706 error calls x 204k, ~25% avoidable |
| 3 | Read big files by section: PreToolUse hook/warning on Read without `limit` for files over 20 KB; brief rule "grep -n then offset/limit". | ~20 Mtok | 46 whole-file Reads >=5k tok, carry 40.5 M, 50% cut |
| 4 | Put the handbook and per-skill rules an agent needs into a 1.5k-token "agent card" in the brief; stop agents reading the 15k handbook and 4k SKILL.md pages whole. | ~19 Mtok | 456 doc reads, carry 43 M, ~45% cut; overlaps rank 3 by up to half |
| 5 | Output caps and digests: cap `sed -n`/`cat`/`grep` output at ~2k tokens with "N more lines" hint; add `queue.sh summary` for runner.log; require `\| head -40` on recursive grep. | ~12 Mtok | sed/cat/grep results >=2k: 450k tok, util mostly under 0.3 |

Together roughly 130 Mtok of 1,827 Mtok (7%). The other 93% is the base prefix re-read, so the largest lever is still calls per agent: hand back at the 120k rule and keep briefs small. Output hygiene alone cannot get average context below 200k.

## Reproduce

```
tools/agents/efficiency.py --tools --since 2026-10-24T00:00           # tables above
tools/agents/efficiency.py --tools --since 2026-10-24T00:00 --json    # per-result data
```
