#!/usr/bin/env bash
# One worktree per task, removed when it is pushed.
#   worktree.sh new <name>   worktree at $POWOS_WT_ROOT/<name> (default ~/pw/<name>, OUTSIDE the repo - an agent
#                            in it never picks up ~/Projects/CLAUDE.md or any ancestor .claude/ skill catalog) on
#                            branch agent/<name>, from origin's tip, shell/node_modules linked from
#                            powos-multiplatform (no per-worktree install)
#   worktree.sh done <name>  remove it; refuses while it has uncommitted or unpushed work; lists the phone checks
#                            queued from it (they run in the verify checkout, so removing it is fine); looks under
#                            $POWOS_WT_ROOT first, then the old .claude/worktrees location (pre-move worktrees)
#   worktree.sh list         name, age of HEAD, commits not on origin (patch-id), dirty files; both locations
#   worktree.sh gc [--dry-run]   remove every worktree (both locations) that's clean, fully merged into
#                            origin/worktree-powos-multiplatform (ahead=0, as `done` checks) AND untouched for
#                            30+ min (HEAD commit age AND no file/index/reflog mtime in it, f405) with no live
#                            process in it (cwd or command line, f405); logs each removal to $RMLOG: agents that
#                            finished without `worktree.sh done` (friction f3). Never touches a runner's own
#                            checkout (its .powos-runner-checkout marker, f57) or the shared base checkouts
#                            (powos-multiplatform, emu-build) even if they'd otherwise match. --dry-run: lists
#                            what it would remove, touches nothing. Run from tools/agents/board-sweep.sh each
#                            sweep (board-sweep.sh fetches and runs origin's copy, same as it does for the
#                            agents CLI, so a fix here reaches every sweep without each worktree updating by hand).
set -euo pipefail
BASE=worktree-powos-multiplatform
# Resolve from CWD (git-common-dir is identical across every worktree of this repo, main or not), never from $0:
# $0 is wherever this script's BYTES happen to sit (a /tmp copy, "bash" when piped via `bash -s`, a worktree's own
# tools/agents/) - resolving the repo root from it nests a new worktree inside whichever worktree you ran this
# FROM instead of the repo's main root (friction f124). cd into any checkout of this repo before running it.
# This already covers today's bootstrap (`git show origin/...:tools/agents/worktree.sh | bash -s new NAME`, $0
# literally "bash") from anywhere inside a checkout, main or any worktree, on any branch (f150's repro: cwd on
# master, which has no tools/agents/ of its own - CWD resolution never looks at the script's own path for that).
# --git-common-dir over --show-toplevel is deliberate, not a style choice: --show-toplevel gives THIS worktree's
# own root, which varies per worktree, while $WT (.claude/worktrees) below must be the one true repo root every
# worktree agrees on - --git-common-dir is identical from any of them. --show-toplevel is only the fallback, for
# the rare git old enough to not support --path-format (it still won't nest in the wrong worktree: a bare
# checkout's toplevel IS its common dir's parent, same answer there).
gcd=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
  REPO=$(cd "$(dirname "$gcd")" && pwd) ||
  REPO=$(git rev-parse --show-toplevel 2>/dev/null) ||
  { echo "worktree.sh: cd into a PowOS checkout (any worktree) first" >&2; exit 1; }
WT=$REPO/.claude/worktrees
# New agent worktrees live outside the repo (default ~/pw) so they have no ancestor CLAUDE.md/.claude/skills to
# load - the old $WT/<name> location put every agent worktree under the repo's own tree, which is also the parent
# of 40+ sibling worktrees' skill catalogs.
WTR=${POWOS_WT_ROOT:-$HOME/pw}
# Runner checkouts (verify-runner, emu-runner, ship-runner*) and the shared base checkout (powos-multiplatform)
# are moving out from under $WT too (wt-move-rest), to $POWOS_RUN_ROOT (default ~/pw, same default dir as
# $WTR - two separate knobs for two separate kinds of checkout). Old $WT/<name> kept as a fallback while they move.
POWOS_RUN_ROOT=${POWOS_RUN_ROOT:-$HOME/pw}
# A runner's own checkout (verify-runner, ship-runner, ship-runner-apk): marked by .powos-runner-checkout when the
# runner creates it (friction f57). An agent whose cwd landed there (this script resolves its own location, not
# $PWD) must make its own worktree instead of operating on the runner's.
here_top=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null) || here_top=
[ -z "$here_top" ] || [ ! -f "$here_top/.powos-runner-checkout" ] ||
  { echo "worktree.sh: refused - $(cat "$here_top/.powos-runner-checkout") owns $here_top, never run worktree.sh from it (use your own worktree)" >&2; exit 1; }

ahead() { git -C "$1" cherry "origin/$BASE" HEAD 2>/dev/null | grep -c '^+' || true; }
# The node_modules symlink shows as untracked (.gitignore's node_modules/ doesn't match a link); it is not work.
dirty() { git -C "$1" status --porcelain | grep -vc '^?? shell/node_modules$' || true; }
# live <dir>: why <dir> is in use right now, or nothing. gc removed ~/pw/tile-bar-btns mid-task (f405) because its
# only liveness signal was HEAD's commit age: an agent that landed its commit (ahead=0), was clean, and kept
# working for 30+ min without a new commit looked abandoned. Now any of these keeps a worktree:
#   - a process whose cwd is inside it (lsof), or whose command line names a path in it (ps)
#   - any file in it, or its HEAD/reflog, modified in the last 30 min (agents' edits, builds, commits, resets).
#     Not its index: dirty()'s own `git status` (this gc, `list`) refreshes it, so it'd keep everything forever.
live() {
  local d gd p
  d=$(cd "$1" && pwd -P) || d=$1   # lsof prints resolved paths (/private/var/..., symlinked roots)
  p=$(lsof -a -d cwd -Fpn 2>/dev/null | awk -v d="$d" '/^p/{pid=substr($0,2)} /^n/{n=substr($0,2); if (n==d || index(n, d"/")==1) {print pid; exit}}')
  [ -z "$p" ] || { echo "process $p has its cwd in it"; return; }
  p=$(ps -axo pid=,command= 2>/dev/null | grep -F -e "$d/" -e "$d " | grep -v -e 'worktree.sh' -e 'grep -F' | head -1 | awk '{print $1}')
  [ -z "$p" ] || { echo "process $p names it on its command line"; return; }
  gd=$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null) || gd=
  p=$({ [ -z "$gd" ] || find "$gd/HEAD" "$gd/logs/HEAD" -mmin -30 2>/dev/null
        find "$d" \( -name .git -o -name node_modules \) -prune -o -mmin -30 -print -quit 2>/dev/null; } | head -1)
  [ -z "$p" ] || echo "modified in the last 30 min: ${p#$d/}"
}
# created <dir>: when the worktree was made (epoch). f407: gc aged a brand-new worktree from its base tip's COMMIT
# time, so `new` on a tip older than 30 min was gc-able before its first edit. `new` stamps powos-created in the
# worktree's admin dir (.git/worktrees/<name>); older worktrees fall back to that dir's commondir file, which
# `git worktree add` writes once and nothing rewrites.
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
created() {
  local gd; gd=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  cat "$gd/powos-created" 2>/dev/null || mtime "$gd/commondir" || true
}
# rmlog <name> <dir> <reason>: every removal is logged with what and why (f405), outside any worktree.
RMLOG=${POWOS_WT_RMLOG:-$HOME/.cache/powos-worktree-removals.log}
rmlog() {
  mkdir -p "$(dirname "$RMLOG")"
  echo "$(date '+%F %T') removed $1 ($2) branch=$(git -C "$2" symbolic-ref --short -q HEAD || echo detached) head=$(git -C "$2" rev-parse --short HEAD 2>/dev/null) by=${3%% *} why: ${3#* }" >> "$RMLOG"
}

# find_wt <name>: echoes the existing worktree's path (new root first, then the legacy $WT location), or nothing.
find_wt() { [ -e "$WTR/$1/.git" ] && { echo "$WTR/$1"; return; }; [ -e "$WT/$1/.git" ] && echo "$WT/$1"; }

case "${1:-}" in
new)
  n=${2:?name}; d=$WTR/$n
  { [ -e "$d" ] || [ -e "$WT/$n" ]; } && { echo "exists: $(find_wt "$n")" >&2; exit 1; }
  mkdir -p "$WTR"
  git -C "$REPO" fetch -q origin "$BASE"
  git -C "$REPO" worktree add -q --track -b "agent/$n" "$d" "origin/$BASE"
  date +%s > "$(git -C "$d" rev-parse --absolute-git-dir)/powos-created"   # gc's age floor (f407)
  # Absolute symlink target: $d is no longer a fixed two-levels-deep sibling of powos-multiplatform (it can be
  # anywhere under $WTR), so the old relative "../../powos-multiplatform/..." target would resolve wrong.
  # powos-multiplatform itself is moving to $POWOS_RUN_ROOT/powos-multiplatform (wt-move-rest); prefer that,
  # fall back to the old $WT location while it still has the real checkout.
  PMP=$POWOS_RUN_ROOT/powos-multiplatform
  [ -d "$PMP/shell/node_modules" ] || [ ! -d "$WT/powos-multiplatform/shell/node_modules" ] || PMP=$WT/powos-multiplatform
  [ -d "$PMP/shell/node_modules" ] && ln -s "$PMP/shell/node_modules" "$d/shell/node_modules"
  # Android package build inputs git ignores (out/powos-rootfs.tar.gz, pkgs/steam/sysvipc-emu.tar.gz): a fresh
  # worktree had neither, and agents hard-linked them by hand from another worktree (friction f76, f87). The
  # shared Mac-side cache (tools/agents/build-inputs-cache.sh, content-addressed, never pruned) has them once;
  # link them in here the way shell/node_modules is linked above. Best-effort: a worktree that never builds
  # Android packages, or a cache that's empty (no rootfs built yet), is fine without either.
  bic=$REPO/tools/agents/build-inputs-cache.sh
  if [ -x "$bic" ]; then
    mkdir -p "$d/targets/android/out" "$d/targets/android/pkgs/steam"
    { "$bic" get powos-rootfs.tar.gz "$d/targets/android/out/powos-rootfs.tar.gz" &&
      "$bic" get powos-rootfs.tar.gz.sha256 "$d/targets/android/out/powos-rootfs.tar.gz.sha256"; } >/dev/null 2>&1 || true
    "$bic" get steam-sysvipc-emu.tar.gz "$d/targets/android/pkgs/steam/sysvipc-emu.tar.gz" >/dev/null 2>&1 || true
    "$bic" get steam-proton-arm64-kernelbase.dll "$d/targets/android/pkgs/steam/proton-arm64-kernelbase.dll" >/dev/null 2>&1 || true
  fi
  # The OWL CLI (targets/android/app/owl/build/cli/owl.jar, gitignored): the widget sweep (shell/dev/preview.sh)
  # needs it and a fresh worktree's offline gradle can't build it (friction f402). owl-jar.sh puts in the one built
  # from these exact sources - from the shared cache, or seeded from powos-multiplatform's when its sources match.
  [ ! -x "$d/shell/dev/owl-jar.sh" ] || OWL_JAR_FROM=$PMP "$d/shell/dev/owl-jar.sh" "$d" >/dev/null 2>&1 || true
  echo "$d" ;;
done)
  n=${2:?name}; d=$(find_wt "$n")
  [ -n "$d" ] && [ -d "$d" ] || { echo "no worktree: $n (looked in $WTR and $WT)" >&2; exit 1; }
  git -C "$d" fetch -q origin "$BASE"
  a=$(ahead "$d"); x=$(dirty "$d")
  [ "$a" = 0 ] && [ "$x" = 0 ] || { echo "refused: $n has $a unpushed commit(s), $x uncommitted file(s)" >&2; exit 1; }
  br=$(git -C "$d" symbolic-ref --short -q HEAD || true)
  q=$(grep -lE "${d//./\\.}([/ )']|\$)" "$HOME"/.cache/powos-verify-queue/*.job 2>/dev/null || true)
  [ -z "$q" ] || echo "queued phone checks from $n (they run from the verify checkout): $(for f in $q; do basename "$f" .job; done | tr '\n' ' ')"
  [ -L "$d/shell/node_modules" ] && rm "$d/shell/node_modules"
  rmlog "$n" "$d" "done explicit worktree.sh done (pid $$ ppid $PPID), ahead=0 dirty=0"
  git -C "$REPO" worktree remove "$d"
  [ -n "$br" ] && git -C "$REPO" branch -D "$br" >/dev/null
  echo "removed $n" ;;
list)
  for d in "$WTR"/*/ "$WT"/*/; do d=${d%/}; [ -e "$d/.git" ] || continue
    printf '%-28s %-16s ahead=%-3s dirty=%s\n' "$(basename "$d")" \
      "$(git -C "$d" log -1 --format=%cr | sed 's/ ago//')" "$(ahead "$d")" "$(dirty "$d")"
  done ;;
gc)
  dry=; [ "${2:-}" = --dry-run ] && dry=1
  git -C "$REPO" fetch -q origin "$BASE"
  now=$(date +%s)
  for d in "$WTR"/*/ "$WT"/*/; do
    d=${d%/}; [ -e "$d/.git" ] || continue
    name=$(basename "$d")
    # Never a runner's own checkout (marker file, f57) or a shared base checkout - these are never agent
    # worktrees to sweep, whatever their ahead/dirty/age happen to read.
    [ -f "$d/.powos-runner-checkout" ] && continue
    case "$name" in powos-multiplatform|emu-build) continue ;; esac
    a=$(ahead "$d"); x=$(dirty "$d")
    [ "$a" = 0 ] && [ "$x" = 0 ] || continue
    last=$(git -C "$d" log -1 --format=%ct 2>/dev/null) || continue
    born=$(created "$d"); [ -n "$born" ] && [ "$born" -gt "$last" ] && last=$born   # f407: never older than itself
    age=$(( now - last ))
    [ "$age" -ge 1800 ] || continue
    why=$(live "$d")
    if [ -n "$why" ]; then echo "$(date '+%F %T') kept $name (in use: $why)"; continue; fi
    if [ -n "$dry" ]; then
      echo "would remove $name (idle $((age / 60))m, ahead=0 dirty=0)"
      continue
    fi
    br=$(git -C "$d" symbolic-ref --short -q HEAD || true)
    [ -L "$d/shell/node_modules" ] && rm "$d/shell/node_modules"
    rmlog "$name" "$d" "gc ahead=0 dirty=0, HEAD idle $((age / 60))m, no process in it, nothing modified for 30+ min"
    if git -C "$REPO" worktree remove "$d" 2>&1; then
      echo "$(date '+%F %T') removed $name (idle $((age / 60))m)"
      [ -z "$br" ] || git -C "$REPO" branch -D "$br" >/dev/null 2>&1 || true
    else
      echo "gc: couldn't remove $name (left as is)" >&2
    fi
  done ;;
*) sed -n '2,19p' "$0"; exit 1 ;;
esac
