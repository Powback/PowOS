#!/bin/bash
# test-lib-collisions.sh - Guard against name collisions between shell libs.
#
# bin/powos sources many libs into ONE shell. That makes two things silently
# dangerous, and both were real bugs in this tree:
#
#   1. Two files defining the same FUNCTION name.
#      `cmd_sync` was defined by lib/sync.sh (RAM<->USB sync) AND by
#      lib/backup.sh (as a "legacy alias" for cmd_backup). bin/powos sources
#      backup.sh second, so `powos sync status` silently ran the CLOUD GIT
#      BACKUP — it even initialised a git repo — instead of showing sync
#      conflicts. The entire documented `powos sync` surface was unreachable.
#      Likewise `mods_deploy_cmd` existed in both mods/deploy.sh (v2 overlayfs)
#      and mods/install.sh (NMA loadout sync) — two unrelated implementations
#      whose winner depended purely on source order.
#
#   2. Two files assigning the same CONSTANT with different values, where at
#      least one is a BARE assignment (no ${VAR:-default}). A bare assignment
#      clobbers whatever loaded before it. POWOS_NEXUS_UA was bare-assigned
#      "powos-mods/0.1" in install.sh, overriding nexus-api.sh's 2.0 for every
#      v2 API call. POWOS_CONFIG_DIR disagreed about XDG_CONFIG_HOME, so setup
#      wrote one directory and backup archived another.
#
# Usage:  bash test/tier1/test-lib-collisions.sh

# NOTE: deliberately NO `pipefail`. These harnesses assert with
# `echo "$out" | grep -q ...`, and `grep -q` exits on its first match — which
# SIGPIPEs the writer, making the pipeline return 141 under pipefail depending
# on scheduling. That produced random failures (test-windows.sh swung between 4
# and 11 "failures" on identical runs). Last-command status is the correct
# semantics for an assertion anyway.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."
cd "$REPO_ROOT" || exit 1

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && echo "$2"; }
skip() { echo "  skip - $1"; SKIP=$((SKIP+1)); }

echo "== test-lib-collisions.sh =="

# Files bin/powos actually sources into its own shell. Excluded by design:
#   ai/clients/*.sh  - intentionally override base.sh (polymorphism)
#   dracut/, ramfs/  - run in initramfs / as standalone scripts, never sourced
#                      into the CLI shell
#   *-standalone     - scripts with their own main()
mapfile -t LIBS < <(find lib -name '*.sh' \
    ! -path 'lib/ai/clients/*' \
    ! -path 'lib/dracut/*' \
    ! -path 'lib/ramfs/*' \
    | sort)

echo "  (scanning ${#LIBS[@]} shell libs)"

# ── 1. Function-name collisions ──────────────────────────────────────────
echo
echo "-- function name collisions --"

# Known-intentional duplicates: standalone tools that are never sourced
# together into the CLI shell. Keep this list SHORT and justified.
is_allowed_fn_dup() {
    case "$1" in
        # Generic logging/UI helpers redefined by standalone scripts that
        # each run via `bash lib/foo.sh` with their own main().
        log|log_info|log_warn|log_error|log_ok|log_detail|log_success|\
        main|usage|show_help|show_status|confirm) return 0 ;;
        *) return 1 ;;
    esac
}

_fn_report=""
while read -r fn files; do
    is_allowed_fn_dup "$fn" && continue
    _fn_report="$_fn_report\n    $fn ->$files"
done < <(
    for f in "${LIBS[@]}"; do
        grep -oE '^[a-z_][a-z0-9_]*\(\)' "$f" 2>/dev/null | tr -d '()' | sed "s|\$| $f|"
    done | sort -u | awk '{c[$1]=c[$1]" "$2; n[$1]++} END{for(k in n) if(n[k]>1) print k, c[k]}'
)

if [[ -z "$_fn_report" ]]; then
    ok "no function defined in more than one sourced lib"
else
    bad "function name defined in multiple sourced libs" "$(echo -e "$_fn_report")"
fi

# ── 2. Shared constants, checked by RESOLVED VALUE ───────────────────────
echo
echo "-- shared constants resolve consistently --"
#
# A static scan here is more noise than signal: per-module values like
# POWOS_TAG and LOG_PREFIX are SUPPOSED to differ, colour definitions repeat as
# deliberate `source common.sh || { fallback }` blocks, and heredoc bodies that
# generate wrapper scripts look like top-level assignments. So instead of
# grepping, source the real libs together and assert the value that actually
# wins — which is what the bugs were about anyway. Order is varied deliberately:
# a bare assignment only shows up as a bug when it loads second.

_resolves() {  # name expected lib...
    local name="$1" expect="$2"; shift 2
    local got
    got="$(HOME=/tmp bash -c '
        for f in "$@"; do source "$f" >/dev/null 2>&1; done
        printf "%s" "${'"$name"':-}"' _ "$@" 2>/dev/null)"
    [[ "$got" == "$expect" ]] \
        && ok "$name resolves to '$expect' ($(basename "$1") first)" \
        || bad "$name resolved to '$got', expected '$expect'"
}

# install.sh loads before nexus-api.sh in bin/powos, so a bare assignment there
# wins over the v2 Nexus module. Both must be parameterized, same default.
_resolves POWOS_NEXUS_UA "powos-mods/2.0" lib/mods/install.sh lib/mods/nexus-api.sh
_resolves POWOS_NEXUS_UA "powos-mods/2.0" lib/mods/nexus-api.sh lib/mods/install.sh

# setup.sh WRITES config here, backup.sh ARCHIVES it — they must agree in
# either order, including whether XDG_CONFIG_HOME is honoured.
_resolves POWOS_CONFIG_DIR "/tmp/.config/powos" lib/setup.sh lib/backup.sh
_resolves POWOS_CONFIG_DIR "/tmp/.config/powos" lib/backup.sh lib/setup.sh

echo
echo "-- named regressions --"

_defines() { grep -qE "^$2\(\)" "$1"; }

! _defines lib/backup.sh cmd_sync \
    && ok "backup.sh does not define cmd_sync (would shadow the real sync)" \
    || bad "backup.sh redefines cmd_sync — powos sync would run the backup"

! _defines lib/mods/install.sh mods_deploy_cmd \
    && ok "install.sh does not define mods_deploy_cmd (deploy.sh owns it)" \
    || bad "install.sh redefines mods_deploy_cmd — deploy depends on source order"

_defines lib/sync.sh cmd_sync \
    && ok "sync.sh still owns cmd_sync" \
    || bad "sync.sh no longer defines cmd_sync"

_defines lib/mods/deploy.sh mods_deploy_cmd \
    && ok "deploy.sh still owns mods_deploy_cmd" \
    || bad "deploy.sh no longer defines mods_deploy_cmd"

# The two files that read/write the same config dir must agree, including
# whether they honour XDG_CONFIG_HOME.
_bk="$(grep -m1 '^POWOS_CONFIG_DIR=' lib/backup.sh | cut -d= -f2-)"
_st="$(grep -m1 '^POWOS_CONFIG_DIR=' lib/setup.sh  | cut -d= -f2-)"
[[ "$_bk" == "$_st" ]] \
    && ok "backup.sh and setup.sh agree on POWOS_CONFIG_DIR" \
    || bad "POWOS_CONFIG_DIR differs: backup=$_bk setup=$_st"

# Prove the resolved value at runtime, not just the literal text.
_ua="$(HOME=/tmp bash -c '
    source lib/mods/install.sh   >/dev/null 2>&1
    source lib/mods/nexus-api.sh >/dev/null 2>&1
    printf "%s" "$POWOS_NEXUS_UA"')"
[[ "$_ua" == "powos-mods/2.0" ]] \
    && ok "POWOS_NEXUS_UA resolves to the current version ($_ua)" \
    || bad "POWOS_NEXUS_UA resolved to '$_ua' — a stale bare assignment won"

# Source order must not decide which deploy implementation you get.
for order in "deploy.sh install.sh" "install.sh deploy.sh"; do
    _body="$(HOME=/tmp bash -c "
        for f in core.sh $order; do source lib/mods/\$f >/dev/null 2>&1; done
        declare -f mods_deploy_cmd" 2>/dev/null)"
    grep -q "mods_deploy_mount\|refresh" <<< "$_body" \
        && ok "deploy resolves to the v2 overlayfs impl (order: $order)" \
        || bad "wrong mods_deploy_cmd for source order: $order"
done

echo
echo "== Results: $PASS passed, $FAIL failed, $SKIP skipped =="
if [[ $FAIL -gt 0 ]]; then echo "TESTS FAILED"; exit 1; fi
echo "ALL TESTS PASSED"
