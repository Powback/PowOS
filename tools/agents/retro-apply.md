# retro-apply: turn one retro.py digest into fixes, cheaply

For a short Haiku/Sonnet agent, run right after an agent hands back (see docs/AGENT-HANDBOOK.md, "Retro after
every agent"). Budget: one pass, small edits only, hand back in a few minutes. Never a long-lived agent.

1. **Get the digest.** `tools/agents/retro.py <agent-id> --json` (the id is the transcript's filename minus
   `agent-`/`.jsonl`, from the hand-off notification). If it says "no friction found - clean run", stop here
   - nothing to do.

2. **Doc and skill fixes - do these yourself, now, if small (a few lines):**
   - `info-hunt` items (a hunt before the first edit, a file read 3+ times, a repeated "where is X" search):
     add ONE line to the relevant skill (`.claude/skills/<area>/SKILL.md`) or to
     docs/AGENT-HANDBOOK.md's "Where things live" section - the fact the agent had to dig for, not a
     transcript of the digging.
   - `misled` items (a FAIL the agent later decided wasn't real): fix the check's FAIL message so it says
     the caveat up front (e.g. "FAIL (likely stale baseline, verify before treating as a regression)").
   - `wait` items pointing at a poll loop or a bare `sleep N` with N >= 60: if the fix is genuinely a
     one-line swap to an existing helper (`land.sh`, `queue.sh`, the PostToolUse hook's notice pattern -
     docs/AGENT-HANDBOOK.md, Efficiency), make it. If it needs new plumbing, log it as friction instead
     (step 4) - don't build new process tooling from this agent.
   - Keep every edit scoped to your own section/line. Don't rewrite someone else's doc section to fit yours.

3. **Script/code fixes - do NOT patch code yourself here.** `error` items (grouped tool errors) and
   `permission` items that need more than an allowlist entry are real code: a script that should fail with a
   clearer message, a path that drifted, a command that needs a flag. These go to step 4, except:
   - a `permission` item that's just "this safe, read-only command keeps prompting" - run the
     `fewer-permission-prompts` skill, which edits `.claude/settings.json` directly; that's in scope here.

4. **Log the rest as friction clusters, don't fix them inline.** For each remaining item (retries, grouped
   errors, unresolved permission refusals, anything you didn't fix in step 2-3):
   - Check it isn't already logged: `tools/agents/friction list --area <area>` (the digest's `friction`
     section already shows what the agent itself logged, and whether it's `fixed`).
   - If not logged, log it: `tools/agents/friction add --area <ship|gate|verify|board|comms|permissions|
     worktree|phone|apk|...> --kind <refused|broken-tool|flaky-check|unclear-rule|slow|other> "<title>"
     --repro "<the exact command, from the digest>" --details -` (stdin: what the agent saw, what it
     expected). The same area+kind+title counts up instead of duplicating - that count is what tells the
     coordinator which clusters are worth a real fix.
   - For an agent-logged friction item still `unknown`/open: leave it; it is already in the system and will
     surface in the board sweep's digest.

5. **Across many agents (`retro.py --since 4h --all`):** same two passes, in order of tokens wasted - do
   steps 2-3 for the top few, then step 4 for the rest in one batch (one `friction add` per distinct
   cause, not per occurrence).

6. **Hand back** with: what you fixed directly (file:line), what you logged as friction (ids), and nothing
   else - no transcript, no restated digest.
