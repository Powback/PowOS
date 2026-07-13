#!/bin/bash
# setup.sh - `powos setup <thing>` — one-liner auth / credential wiring so
# the AI (and user) never have to Google how to log into stuff.
#
# Currently covered:
#   powos setup gh         GitHub auth via gh CLI (device code flow)
#   powos setup nexus      Save Nexus API key (from file, stdin, or URL flow)
#   powos setup all        Walk through everything above in order.

set -uo pipefail
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/common.sh" 2>/dev/null || {
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
    plog()  { echo -e "${CYAN}[setup]${NC} $*"; }
    pok()   { echo -e "${GREEN}[setup]${NC} $*"; }
    pwarn() { echo -e "${YELLOW}[setup]${NC} $*"; }
    perr()  { echo -e "${RED}[setup]${NC} $*" >&2; }
}
POWOS_TAG=setup

POWOS_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/powos"

# ─── GitHub auth ─────────────────────────────────────────────────────────
# Wraps gh's device-code flow. gh handles the token storage + configures a
# git credential helper so subsequent `git push` calls Just Work over HTTPS.
setup_gh_cmd() {
    if ! command -v gh >/dev/null 2>&1; then
        plog "gh CLI missing — installing via dnf (needs sudo)..."
        if ! sudo dnf5 -y install --setopt=install_weak_deps=False gh 2>&1 | tail -3; then
            perr "dnf install gh failed. Fedora repo should have it — check network."
            return 1
        fi
    fi

    if gh auth status -h github.com >/dev/null 2>&1; then
        pok "Already authenticated with GitHub."
        gh auth status -h github.com 2>&1 | grep -E "Logged in|Token scopes" | head -3
        plog "Re-run with --refresh to reauthenticate or add scopes."
        [[ "${1:-}" == "--refresh" ]] || return 0
        gh auth refresh -h github.com -s read:packages,repo,workflow,write:packages
        return 0
    fi

    plog "Starting GitHub login (device code — opens a browser tab)..."
    plog "  Scopes: repo, workflow, read:packages, write:packages"
    plog "  Git protocol: https (gh will configure the credential helper)"
    if ! gh auth login \
            --hostname github.com \
            --git-protocol https \
            --scopes "repo,workflow,read:packages,write:packages" \
            --web; then
        perr "gh auth login failed."
        return 1
    fi

    # Make gh the git-credential helper for github.com so subsequent
    # `git push`es use the stored token automatically. Idempotent.
    if command -v gh >/dev/null 2>&1; then
        gh auth setup-git 2>&1 | tail -2 || true
    fi

    # Give git an author identity so `powos self push` (which commits as
    # whatever account runs it — often root via sudo) doesn't die with
    # "author identity unknown" on a fresh install. Derived from the just-
    # authenticated GitHub account; email uses GitHub's noreply form so we
    # never leak or guess a private address. Idempotent — only sets if unset.
    if command -v gh >/dev/null 2>&1; then
        local ghlogin ghname
        ghlogin="$(gh api user --jq .login 2>/dev/null)"
        if [[ -n "$ghlogin" ]]; then
            ghname="$(gh api user --jq '.name // .login' 2>/dev/null)"
            git config --global user.name  >/dev/null 2>&1 || git config --global user.name  "${ghname:-$ghlogin}"
            git config --global user.email >/dev/null 2>&1 || git config --global user.email "${ghlogin}@users.noreply.github.com"
            # Root-owned source tree is safe to operate on, and exec-bit-only
            # diffs (composefs carry-over) must not show up as changes.
            git config --global --add safe.directory /var/lib/powos/src 2>/dev/null || true
            plog "git identity: $(git config --global user.name) <$(git config --global user.email)>"
        fi
    fi

    pok "GitHub auth complete."
    plog "Test:  ssh -T git@github.com   OR   gh api user --jq .login"
}

# ─── Nexus Mods API key ──────────────────────────────────────────────────
# Save the user's Personal API Key at $POWOS_CONFIG_DIR/nexus.key (0600).
# Modes:
#   powos setup nexus                     Interactive: opens the URL,
#                                          reads key from tty.
#   powos setup nexus --key <key>         From arg (leaks in shell history).
#   powos setup nexus --from-file <path>  From file (safest for scripts).
#   powos setup nexus --stdin             From stdin (safest for automation).
setup_nexus_cmd() {
    local mode="prompt" key="" src=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --key)       mode="arg";  key="$2"; shift 2 ;;
            --from-file) mode="file"; src="$2"; shift 2 ;;
            --stdin)     mode="stdin"; shift ;;
            --help|-h)   echo "Usage: powos setup nexus [--key <k> | --from-file <f> | --stdin]"; return 0 ;;
            *)           perr "Unknown option: $1"; return 1 ;;
        esac
    done

    mkdir -p "$POWOS_CONFIG_DIR"
    local target="$POWOS_CONFIG_DIR/nexus.key"

    case "$mode" in
        prompt)
            plog "Get your Personal API Key (long-lived, script-friendly) from:"
            plog "  ${BOLD}https://www.nexusmods.com/users/myaccount?tab=api${NC}"
            plog "Scroll to 'Personal API Key' → click ${BOLD}Request Api Key${NC}"
            plog "(If you're inside KDE, this URL was just opened for you.)"
            xdg-open "https://www.nexusmods.com/users/myaccount?tab=api" >/dev/null 2>&1 &
            echo -n "Paste it here (input is hidden): "
            read -rs key
            echo
            ;;
        file)
            [[ -f "$src" ]] || { perr "File not found: $src"; return 1; }
            key="$(< "$src")"
            ;;
        stdin)
            key="$(cat)"
            ;;
    esac
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    if [[ -z "$key" ]] || [[ ${#key} -lt 20 ]]; then
        perr "Key looks too short (${#key} chars). Nexus Personal API Keys are ~85 chars."
        return 1
    fi

    umask 077
    printf '%s\n' "$key" > "$target"
    chmod 600 "$target"
    pok "Nexus API key saved to $target (mode 0600)."
    plog "Also pushing it into Nexus Mods App so its CLI sees it..."
    if [[ -x "$HOME/Applications/NexusModsApp.AppImage" ]]; then
        if "$HOME/Applications/NexusModsApp.AppImage" as-main nexus-api-key "$key" \
                >/dev/null 2>&1; then
            pok "NMA CLI accepted the key."
        else
            pwarn "NMA CLI didn't accept the key (GUI running?). Skipped — file save"
            pwarn "  is still authoritative for powos mods."
        fi
    fi
}

# ─── Everything ──────────────────────────────────────────────────────────
setup_all_cmd() {
    plog "Running all setup steps in order. Ctrl-C to bail at any prompt."
    echo
    plog "1/2  GitHub"
    setup_gh_cmd || pwarn "GitHub step failed — continuing."
    echo
    plog "2/2  Nexus"
    setup_nexus_cmd || pwarn "Nexus step failed — continuing."
    echo
    pok "Setup complete. What agents can now do:"
    echo "  • Push PowOS changes:      powos self push"
    echo "  • Watch CI runs:           gh run watch"
    echo "  • Resolve Nexus mod IDs:   see powos mods (key is at $POWOS_CONFIG_DIR/nexus.key)"
}

# ─── Help + dispatch ─────────────────────────────────────────────────────
setup_help() {
    cat <<EOF
${BOLD}powos setup${NC} — one-liner credential wiring

  powos setup gh             GitHub auth (device-code login via gh CLI)
                             --refresh: reauthenticate / add scopes.
  powos setup nexus          Nexus API key. Modes:
                             --key <k>          from arg (leaks to shell history)
                             --from-file <p>    read from file
                             --stdin            read from stdin
                             (no flag)          interactive prompt in your tty
  powos setup all            Walk through everything above.

After setup:
  • Git identity + push:     configured for /var/lib/powos/src (SSH origin).
                             gh setup-git also configures HTTPS helper.
  • Agents (powos ai --agent coder/modder/…) can commit + push + open
    Nexus API endpoints without asking you to click anything.
EOF
}

cmd_setup() {
    local action="${1:-help}"; shift || true
    case "$action" in
        gh|github)              setup_gh_cmd "$@" ;;
        nexus|nexusmods)        setup_nexus_cmd "$@" ;;
        all)                    setup_all_cmd ;;
        help|--help|-h|"")      setup_help ;;
        *)                      perr "Unknown: powos setup $action"; setup_help; return 1 ;;
    esac
}
