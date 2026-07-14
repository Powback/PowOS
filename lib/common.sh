#!/bin/bash
# common.sh - shared helpers for PowOS lib/*.sh. Source this instead of
# re-declaring colors and log functions in every file:
#
#   source "${POWOS_LIB:-/usr/lib/powos}/common.sh"
#   POWOS_TAG=cuda        # sets the [tag] prefix for plog/pok/pwarn/perr
#
#   plog "building…"      ->  [cuda] building…      (cyan)
#   pok  "done"           ->  [cuda] done           (green)
#   pwarn "heads up"      ->  [cuda] heads up        (yellow)
#   perr "broke"          ->  [cuda] broke           (red, to stderr)
#   need_root || return   ->  errors + fails if not root
#   confirm "Reboot?"     ->  y/N prompt, true on yes
#
# Idempotent: safe to source multiple times.
[[ -n "${_POWOS_COMMON_SH:-}" ]] && return 0
_POWOS_COMMON_SH=1

# ANSI-C quoting ($'...') stores real ESC bytes, so these render correctly via
# echo -e / printf AND inside `cat` heredocs. A plain '\033[..' literal only
# works with echo -e/printf and leaks raw \033 when emitted through cat.
# works with echo -e/printf and leaks raw \033 through cat).
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'

plog()  { echo -e "${CYAN}[${POWOS_TAG:-powos}]${NC} $*"; }
pok()   { echo -e "${GREEN}[${POWOS_TAG:-powos}]${NC} $*"; }
pwarn() { echo -e "${YELLOW}[${POWOS_TAG:-powos}]${NC} $*"; }
perr()  { echo -e "${RED}[${POWOS_TAG:-powos}]${NC} $*" >&2; }

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { perr "${1:-This} needs root — re-run with sudo."; return 1; }; }
confirm()   { local a; read -rp "${1:-Proceed?} [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }
