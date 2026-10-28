# Agent card (injected once on your first tool call; do not Read the handbook for these)

Budgets: 5 min, ~30 tool calls, 150k context. At 4 min land what works and hand back.

Start
- `tools/agents/worktree.sh new <name>`, then prefix EVERY Bash with `cd ~/pw/<name> &&`. Never edit the shared checkout.
- Edit from your first Read; re-read only after your own Edit or a rebase.
- Docs/code: `grep -n '<term>' file | head -20`, then Read with offset/limit. Never Read a >400-line file whole,
  `cat` it, `grep -r` uncapped, or `sed -n` >200 lines (hooks deny these).

Land
- `tools/agents/land.sh "msg" -- <every path, incl. new untracked files> [--task <id> --step "..."] [--no-ship]`
  Flags go AFTER the paths. It commits, rebases, pushes and auto-ships; `--no-ship` for docs/tests/tools only.
- Land check changes (the check script itself) BEFORE queueing the check: the runner runs origin's tip.

Phone/emulator checks
- `tools/phone/verify/queue.sh add <task> <check.sh> [args]` then END YOUR TURN or block once with
  `queue.sh wait <job-id> [max_s]` (PASS/FAIL lines only). `queue.sh summary [--since HH:MM]` = one line per finished job.
  Never poll `queue.sh list/status`, `ship.sh status`, `ls ~/.cache/powos-verify-queue`, `tail runner.log`
  (the hook denies repeats); never grep runner.log.
- Waiting: `tools/phone/idle.sh --wait`, or a background `until ...` with run_in_background. Never a foreground sleep loop.
- Jobs blocked (paused queue, phone in use, ship pending): hand back with the job id instead of waiting.
- Evidence first: capture with `~/pw/verify-runner/tools/phone/adb.sh` (screenshot, logcat tail) BEFORE theorising.
  OPEN the screenshot before calling a FAIL a product bug: it is often the check (timing, wrong crop, stale APK).
- Phone input outside the queue is denied; `adb.sh shell` output: pipe through `grep`/`tail -40` on the device side.

Mac/zsh gotchas
- No `timeout`: `perl -e 'alarm N; exec @ARGV' cmd args`.
- Quote globs (`'*.sh'`), zsh errors on no-match. Never put several paths in one variable (no word splitting): use arrays.
- `grep` with no match exits 1: add `|| true` when absence is fine; it is not an error.
- `ls` only paths you know exist; `git ls-files | grep` to find files.
- Test output: `... 2>&1 | tail -15`; re-run only the failing test file.

Friction (log every one, then list in your hand-back)
Phone evidence files (screenshots under /home/powos/...) are pulled read-only with `tools/phone/pull-root.sh <path-under-/data/powos/root> <dest>`; plain `adb devices` is empty on the Mac - always use tools/phone/adb.sh (it connects over the VPN).
(run every `bin/powos …` from YOUR worktree, `cd ~/pw/<name> && bin/powos …` — ~/Projects/PowOS is a stale master whose bin/powos has no friction/agents commands)
`bin/powos friction add --area <area> --kind <refused|broken-tool|flaky-check|unclear-rule|slow|other> "text" --repro "cmd"`
refused = a hook/tool denied valid work; broken-tool = script/tool errored; flaky-check = result changed with no code change;
unclear-rule = docs contradict/omit; slow = waited >1 min; other.

Hand-back: sha, what changed, test results, "Friction & missing info" list, Time line (minutes, top 3 sinks).
