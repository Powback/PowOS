#!/usr/bin/env bash
# build/cycle-lib.sh — shared plumbing for the three build tiers.
#
#   build/iterate.sh   image + in-image tests          (the edit->verify loop)
#   build/media.sh     raw disk image + boot gate      (only when media is wanted)
#   build/burn.sh      write the stick + verify it     (rarest)
#
# Sourced, never executed. Everything here is either a measurement helper or a
# fact-about-an-artifact helper; no policy lives in this file.

[[ -n "${POWOS_CYCLE_LIB:-}" ]] && return 0
POWOS_CYCLE_LIB=1

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$REPO/build/.cache"
mkdir -p "$CACHE"

# ── sudo ──────────────────────────────────────────────────────────
# The existing /var/tmp scripts all do `echo powos | sudo -S`. Keep working the
# same way, but try a cached/passwordless sudo first: -S with a password on
# stdin costs a PAM round trip per call, and the burn verification alone makes
# forty of them.
# Prime the credential cache with its OWN stdin, then run the real command with
# -n so the caller's stdin reaches it untouched.
#
# The obvious form — `echo pass | sudo -S "$@"` — is wrong here in a way that is
# invisible until it corrupts something. It hands the password pipe to the
# command as ITS stdin, so `S bash -s <<EOF` runs bash with the password as its
# script instead of the heredoc, and
# `printf 'YES\n' | S ./install-to-usb.sh` writes a disk without ever
# delivering the confirmation the script is blocking on.
S() {
    sudo -n true 2>/dev/null || echo "${POWOS_SUDO_PASS:-powos}" | sudo -S -v 2>/dev/null
    sudo -n "$@"
}
export -f S 2>/dev/null || true

# ── timing ────────────────────────────────────────────────────────
# Every tier prints a breakdown at the end. The point of this work was that
# nobody knew where the 35 minutes went; a pipeline that does not report its own
# costs will drift back there without anyone noticing.
_T_NAMES=(); _T_SECS=(); _T0=$(date +%s)
_stage_start=0; _stage_name=""
stage() {
    stage_end
    _stage_name="$1"; _stage_start=$(date +%s)
    printf '\n\033[1;34m==> %s\033[0m\n' "$1"
}
stage_end() {
    [[ -z "$_stage_name" ]] && return 0
    local d=$(( $(date +%s) - _stage_start ))
    _T_NAMES+=("$_stage_name"); _T_SECS+=("$d")
    printf '\033[2m    (%ss)\033[0m\n' "$d"
    _stage_name=""
}
timings() {
    stage_end
    local total=$(( $(date +%s) - _T0 )) i
    printf '\n\033[1m── %s: %ss total ──\033[0m\n' "${1:-timings}" "$total"
    for i in "${!_T_NAMES[@]}"; do
        printf '  %5ss  %s\n' "${_T_SECS[$i]}" "${_T_NAMES[$i]}"
    done
    printf '  %5ss  TOTAL\n' "$total"
    # Machine-readable, so a regression is greppable rather than eyeballed.
    { printf '%s\t%s\t%s\t' "$(date -u +%FT%TZ)" "${1:-tier}" "$total"
      for i in "${!_T_NAMES[@]}"; do printf '%s=%s;' "${_T_NAMES[$i]}" "${_T_SECS[$i]}"; done
      printf '\n'; } >> "$CACHE/timings.tsv"
}

say()  { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m   %s\n' "$*"; }
warn() { printf '    \033[33mwarn\033[0m %s\n' "$*"; }
die()  {
    printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2
    timings "${POWOS_TIER:-tier} (FAILED)" >&2
    exit 1
}

# A decision the pipeline made on your behalf must never scroll past as one
# grey line. Anything that SKIPS work prints through this.
loud() {
    printf '\n\033[1;33m'
    printf '  ┏%s┓\n' "$(printf '━%.0s' $(seq 1 68))"
    local l; for l in "$@"; do printf '  ┃ %-66s ┃\n' "$l"; done
    printf '  ┗%s┛\033[0m\n' "$(printf '━%.0s' $(seq 1 68))"
}

# ── facts about artifacts, never about notes ──────────────────────
head_commit() { git -C "$REPO" rev-parse HEAD; }

# The podman image ID. This is the raw cache's primary key: bootc-image-builder's
# output is a function of the image it is given, so two runs over the same image
# ID produce the same disk. A commit is NOT enough — the same commit built with a
# different POWOS_EXTRAS or a refreshed base is a different system.
image_digest() { S podman image inspect --format '{{.Id}}' "$1" 2>/dev/null; }

# What the image itself says it was built from. Read out of the image, not out of
# a build log: the log-grepping version of this check once reported success for a
# failed build because it was reading a stale log from an earlier run.
image_baked_commit() {
    S podman run --rm --entrypoint /bin/bash "$1" \
        -c 'cat /usr/lib/powos/.powos-src-commit' 2>/dev/null | tr -d '[:space:]'
}

# Everything the image build actually copies out of the working tree. `git
# archive HEAD` supplies /usr/lib/powos/src, but bin/ lib/ config/ systemd/
# desktop/ come from the CONTEXT — so uncommitted edits are in the image while
# .powos-src-commit still claims HEAD. That is an image nobody can rebuild.
CONTEXT_DIRS=(bin lib config systemd desktop sources Containerfile)
tree_is_dirty() {
    local out
    out=$(git -C "$REPO" status --porcelain -- "${CONTEXT_DIRS[@]}" 2>/dev/null)
    [[ -n "$out" ]] && { printf '%s\n' "$out"; return 0; }
    return 1
}

# ── mutual exclusion ──────────────────────────────────────────────
# Two mechanisms, because they answer different questions.
#
# The lock is authoritative for THESE tiers. The first version of this used
# `pgrep -f 'prepare\.sh|burn-prepared\.sh|boot-gate\.sh'`, which matches any
# process whose command line merely CONTAINS those strings — including the
# shell that was about to launch the tier, if that shell's command line quoted
# the name. It refused to run and blamed a cycle that did not exist. A pattern
# over other processes' argv is a guess; a lock is a fact.
#
# The pgrep survives only for the legacy /var/tmp/*.sh cycle, which knows
# nothing about this lock. It is anchored to the start of the command line so
# it matches a shell EXECUTING those scripts, not one talking about them.
# Re-entrant DOWN A PROCESS TREE, which is the whole point: media.sh holds the
# lock and then runs build/iterate.sh as a child, and a child blocking on its
# parent's lock is a deadlock dressed as a safety feature. It did exactly that
# once — "another build tier already holds the lock" was media.sh describing
# itself. The exported marker is inherited by children and by nothing else.
acquire_lock() {
    [[ -n "${POWOS_TIER_LOCK:-}" ]] && return 0
    exec 9>"$CACHE/.lock" || die "cannot open the tier lock"
    if ! flock -n 9; then
        die "another build tier already holds $CACHE/.lock — refusing to compete for podman"
    fi
    export POWOS_TIER_LOCK=$$
}

refuse_if_cycle_running() {
    acquire_lock
    local p
    p=$(pgrep -af '^(/usr/bin/|/bin/)?bash /var/tmp/(prepare|burn-prepared|boot-gate)\.sh' 2>/dev/null | head -3)
    [[ -z "$p" ]] && return 0
    die "the legacy /var/tmp build cycle is running — refusing to compete for podman/the device:
$p"
}
