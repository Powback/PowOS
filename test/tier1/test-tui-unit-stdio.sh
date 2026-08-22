#!/bin/bash
# A unit that runs the whiptail wizard must have StandardError on the TTY.
#
# iwz_menu/iwz_input use the standard whiptail idiom:
#
#     whiptail --menu ... 3>&1 1>&2 2>&3
#
# which swaps stdout and stderr so the SELECTION returns on stdout (for $(...)
# capture) and the DIALOG is drawn on stderr. That works in a terminal because
# stderr IS the terminal. With StandardError=journal the entire menu is written
# into the journal and the screen stays blank — on a Steam Deck the installer
# printed its plain-echo header ("PowOS Guided Installer", "backend: tui",
# "-- Target disk --") and then nothing, with no error anywhere.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'
P=0; F=0
ok(){ echo -e "${GREEN}✓${NC} $1"; P=$((P+1)); }
bad(){ echo -e "${RED}✗${NC} $1"; [[ -n "${2:-}" ]] && echo "    $2"; F=$((F+1)); }

# Units whose ExecStart runs something that drives the wizard UI.
for u in powos-installer powos-safemode; do
    f="$ROOT/systemd/$u.service"
    [[ -f "$f" ]] || { bad "$u.service missing"; continue; }
    err=$(grep -E '^StandardError=' "$f" | tail -1 | cut -d= -f2)
    case "$err" in
        tty) ok "$u: StandardError=tty (whiptail can draw)" ;;
        "")  bad "$u: no StandardError set" "defaults do not guarantee a tty; set StandardError=tty" ;;
        *)   bad "$u: StandardError=$err" "the whiptail dialog would be written to '$err', not the screen" ;;
    esac
    out=$(grep -E '^StandardOutput=' "$f" | tail -1 | cut -d= -f2)
    [[ "$out" == "tty" ]] && ok "$u: StandardOutput=tty" || bad "$u: StandardOutput=$out (expected tty)"
done

echo ""
echo "== Results: $P passed, $F failed =="
[[ $F -eq 0 ]]
