#!/usr/bin/env bash
# build/gate-decision.sh — decide whether the QEMU boot gate must run.
#
# A PURE FUNCTION of its arguments, in its own file, for one reason: this is the
# piece of the pipeline whose failure mode is silence. Everything else fails
# loudly — a bad build errors, a stale raw is caught by its baked commit. A gate
# that decides not to run just… does not run, and the way you find out it was
# wrong is that someone's machine will not boot.
#
# So it is separated from the doing, and test/tier1/test-build-tiers.sh drives
# every branch of it directly with synthetic inputs.
#
# Usage:
#   gate-decision.sh --mode auto|always|never --rawkey K \
#                    [--gated-key K] [--gated-commit SHA] [--changed "a\nb"]
#
# Prints DECISION=<run|skip-same-artifact|skip-inferred|skip-disabled> and WHY=.
# Exit 0 always; the caller reads DECISION.
set -uo pipefail
MODE=auto; RAWKEY=""; GKEY=""; GCOMMIT=""; CHANGED=""
while [[ $# -gt 0 ]]; do case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --rawkey) RAWKEY="$2"; shift 2 ;;
    --gated-key) GKEY="$2"; shift 2 ;;
    --gated-commit) GCOMMIT="$2"; shift 2 ;;
    --changed) CHANGED="$2"; shift 2 ;;
    *) echo "gate-decision: unknown option: $1" >&2; exit 2 ;;
esac; done

# %q on the reason: it is free-form English with spaces, and the caller reads
# this back with `eval`. Unquoted, `WHY=no boot-path file changed` assigned
# WHY=no and then tried to RUN `boot-path` — which is how a working gate
# decision turned into "WHY: unbound variable" three lines later.
emit(){ printf "DECISION=%q\nWHY=%q\n" "$1" "$2"; exit 0; }

# Explicit instructions win, in both directions.
[[ "$MODE" == "always" ]] && emit run "--gate always was requested"
[[ "$MODE" == "never"  ]] && emit skip-disabled "--gate never was requested"

# An artifact that has already been booted does not need booting again. This is
# not an inference about which changes are safe — it is the same bytes.
[[ -n "$RAWKEY" && "$RAWKEY" == "$GKEY" ]] \
    && emit skip-same-artifact "this exact raw (key $RAWKEY) already passed a gate"

# No record at all means nothing has ever booted anything comparable.
[[ -z "$GCOMMIT" ]] && emit run "no previous gate result is on record"

# Something on the boot path moved. Note the default: ANY doubt runs the gate.
[[ -n "${CHANGED//[[:space:]]/}" ]] \
    && emit run "boot-path files changed since ${GCOMMIT:0:8}: $(printf '%s' "$CHANGED" | tr '\n' ' ')"

emit skip-inferred "no boot-path file changed since ${GCOMMIT:0:8}"
