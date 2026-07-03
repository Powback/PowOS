#!/bin/bash
# upgrade.sh - one command to pull + apply OS base updates with the LIGHTEST
# restart each update allows. Wraps bootc and picks:
#   • nothing staged            -> you're current, done
#   • staged, kernel unchanged  -> offer `systemctl soft-reboot` (~seconds, warm)
#   • staged, kernel changed    -> a real reboot is required (can't swap a live kernel)
#
#   powos upgrade            # stage the update, recommend the lightest restart
#   powos upgrade --check    # just check if an update is available
#   powos upgrade --now      # stage AND apply the lightest restart automatically
#   powos upgrade --soft     # force a soft-reboot (EXPERIMENTAL on bootc)
#   powos upgrade --reboot   # force a full reboot
#
# NOTE: soft-reboot into a freshly-staged bootc deployment is still FRONTIER —
# it restarts userspace (your apps close/reopen) but not the kernel. It's opt-in;
# the safe default is to just stage and let you reboot on your schedule.
set -uo pipefail
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/common.sh"
POWOS_TAG=upgrade


# Is a non-booted deployment currently staged? (echo "yes"/"")
up_has_staged() {
    rpm-ostree status --json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print("yes" if any(dep.get("staged") for dep in d.get("deployments",[])) else "")' 2>/dev/null
}

# Does the staged deployment carry a different kernel than the running one?
# Best-effort: compares the running `uname -r` against kernels shipped in the
# staged deployment's /usr/lib/modules. Prints "changed", "same", or "unknown".
up_kernel_delta() {
    local running; running="$(uname -r)"
    local staged_root
    # newest staged ostree deploy dir that isn't the booted one
    staged_root="$(rpm-ostree status --json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for dep in d.get("deployments",[]):
    if dep.get("staged"):
        print(dep.get("checksum",""))
        break' 2>/dev/null)"
    [[ -n "$staged_root" ]] || { echo "unknown"; return; }
    local moddir
    moddir="$(ls -d /ostree/deploy/*/deploy/"$staged_root".*/usr/lib/modules/*/ 2>/dev/null | head -20)"
    [[ -n "$moddir" ]] || { echo "unknown"; return; }
    if echo "$moddir" | grep -q "/modules/$running/"; then echo "same"; else echo "changed"; fi
}

up_apply() {   # $1 = mode: soft|reboot
    if [[ "$1" == "soft" ]]; then
        pwarn "Soft-rebooting (experimental): userspace restarts, kernel stays. Apps will close."
        sudo systemctl soft-reboot
    else
        plog "Rebooting to apply…"
        sudo systemctl reboot
    fi
}

cmd_upgrade() {
    local mode="auto" check=0 now=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)   check=1 ;;
            --now)     now=1 ;;
            --soft)    mode="soft" ;;
            --reboot)  mode="reboot" ;;
            --no-reboot) mode="none" ;;
            -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
            *) perr "Unknown arg: $1"; return 1 ;;
        esac
        shift
    done

    command -v bootc >/dev/null 2>&1 || { perr "bootc not found."; return 1; }

    if (( check )); then
        plog "Checking for a base update…"
        sudo bootc upgrade --check
        return $?
    fi

    plog "Fetching + staging base update via bootc…"
    if ! sudo bootc upgrade; then perr "bootc upgrade failed."; return 1; fi

    if [[ "$(up_has_staged)" != "yes" ]]; then
        pok "Already up to date — nothing staged, nothing to restart."
        return 0
    fi

    local delta; delta="$(up_kernel_delta)"
    echo
    case "$delta" in
        same)    pok "Update staged. Kernel unchanged → a soft-reboot (~seconds) is enough." ;;
        changed) pwarn "Update staged. Kernel CHANGED → a full reboot is required." ;;
        *)       pwarn "Update staged. Couldn't tell if the kernel changed → full reboot is the safe choice." ;;
    esac
    plog "Old deployment stays as rollback."

    # Decide what to do.
    local chosen=""
    if [[ "$mode" == "reboot" || "$mode" == "soft" ]]; then chosen="$mode"
    elif [[ "$mode" == "none" ]]; then pok "Staged only. Apply when ready: powos upgrade --reboot"; return 0
    elif [[ "$delta" == "same" ]]; then chosen="soft"
    else chosen="reboot"; fi

    if (( now )); then up_apply "$chosen"; return; fi

    read -rp "Apply now with a ${chosen}? [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] && up_apply "$chosen" || pok "Left staged — apply anytime: powos upgrade --now"
}
