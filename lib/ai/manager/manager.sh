#!/usr/bin/env bash
# PowOS Manager launcher — resolves the PowOS-native bits (manager persona with
# !cmd expansion, live state context, comms identity + mcp-config: comms and the
# TypeScript sandbox, lib/ai/sandbox) and hands off
# to the streaming broker (manager.py). Sourced by bin/powos.

_MANAGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGER_SERVER="${MANAGER_SERVER:-$_MANAGER_DIR/manager.py}"
MANAGER_SANDBOX="${MANAGER_SANDBOX:-$_MANAGER_DIR/../sandbox/sandbox.sh}"

# One --mcp-config from several {"mcpServers":{...}} documents (claude takes one file per flag; one file keeps it simple).
_manager_merge_mcp() {
    python3 -c 'import json,sys
print(json.dumps({"mcpServers": {k: v for a in sys.argv[1:] for k, v in json.loads(a)["mcpServers"].items()}}))' "$@"
}

# The system prompt: the persona, then the live state (AGENT_CONTEXT_CMD) so the manager boots oriented.
_manager_sysprompt() {
    local ctx=""
    [[ -n "${AGENT_CONTEXT_CMD:-}" ]] && ctx="$(eval "$AGENT_CONTEXT_CMD" 2>/dev/null || true)"
    printf '%s' "${AGENT_SYSTEM_PROMPT:-}"
    [[ -z "$ctx" ]] || printf '\n\n## Current system state (at session start)\n%s' "$ctx"
}

# Its MCP servers, as one --mcp-config JSON written to $1 (status 3, nothing written, when it has none; never in a
# subshell: the identity it exports is the session's): comms when enabled, exporting the
# manager's identity (the escalation hub: it reports to the user, everyone else to it; see comms_export_identity),
# and the TypeScript sandbox (lib/ai/sandbox: tools sandbox eval/declarations) when its runtime and in-app deps are
# here (`powos sandbox status`) and POWOS_SANDBOX_ENABLED isn't 0.
_manager_mcp_config() {
    local servers=()
    if declare -f comms_enabled &>/dev/null && comms_enabled; then
        comms_export_identity manager user
        servers+=("$(comms_mcp_config_json)")
    fi
    if [[ -f "$MANAGER_SANDBOX" ]] && source "$MANAGER_SANDBOX" && sandbox_enabled; then
        servers+=("$(sandbox_mcp_config_json manager)")
    fi
    (( ${#servers[@]} )) || return 3
    _manager_merge_mcp "${servers[@]}" > "$1"
}

# The manager's own CLI: this launcher's checkout (lib/ai/manager -> repo bin/, or /usr/bin when installed), first on
# PATH and in POWOS_BIN, so its `powos` calls (the persona's !cmd lines, its board/friction tool calls) match the code
# it runs under, not whatever stale checkout the shell's PATH points at (f215).
_manager_use_own_cli() {
    local bin
    bin="$(cd "$_MANAGER_DIR/../../../bin" 2>/dev/null && pwd)" || return 0
    [[ -x "$bin/powos" ]] || return 0
    export POWOS_BIN="$bin/powos"
    PATH="$bin:$PATH"
    export PATH
    # On the phone (rooted mode) links the manager opens go to the phone's own Chrome, not a Linux browser.
    if command -v powos-android-open &>/dev/null; then export BROWSER=powos-android-open; fi
}

# The manager's CLI (claude, or MANAGER_CLAUDE_CMD's first word), installed on first use when it's missing: the PowOS
# image a phone without root downloads has no claude (the rooted phone's was installed by hand, `powos ai install
# claude`), and the AI page's first message answered "FileNotFoundError: 'claude'" (11-04, emulator, no root). The
# vendor's native installer into ~/.local/bin (on the session's PATH), ~20 s; its output on stderr, never into the
# --json-events stream on stdout; in a subshell, as install.sh sets -uo pipefail.
_manager_ensure_claude() {
    local bin="${MANAGER_CLAUDE_CMD:-claude}"; bin="${bin%% *}"
    command -v "$bin" &>/dev/null && return 0
    [[ "$bin" == claude ]] || { echo "manager: $bin not found (MANAGER_CLAUDE_CMD)" >&2; return 1; }
    PATH="$HOME/.local/bin:$PATH"; export PATH
    command -v claude &>/dev/null && return 0
    echo "manager: installing Claude Code (first use)" >&2
    ( source "$_MANAGER_DIR/../install.sh" && ai_install_cmd claude ) >&2 && command -v claude &>/dev/null && return 0
    echo "manager: Claude Code isn't installed and its installer failed (powos ai install claude)" >&2
    return 1
}

# How the manager's claude is signed in, one word on stdout (sign-in for the non-root build, 11-04 decision: the buyer's
# own Claude account inside the app; the fleet endpoint stays the owner's devices'):
#   endpoint  the machine's Anthropic endpoint (/etc/powos/ai/endpoint.conf, or ANTHROPIC_BASE_URL exported): the
#             owner's devices, the fleet authority - unchanged, nothing else is looked at
#   login     Claude Code's own login in this image (its credentials file, or a key/token the environment exports)
#   relogin   the endpoint's tenant needs its login (missing, or the refresh failed): the native sign-in
#             (powos manager --fleet-login status|start|complete; the authority's claude-login flow, never /login here)
#   signin    neither: the AI page asks to sign in (powos manager --signin)
# Only file presence and variable names are looked at - never a credential's contents.
_manager_auth() {
    declare -f _ai_ensure_config &>/dev/null && _ai_ensure_config
    if [[ -r "${POWOS_AI_ENDPOINT_FILE:-/etc/powos/ai/endpoint.conf}" || -n "${ANTHROPIC_BASE_URL:-}" ]]; then
        # relogin: the authority says this machine's tenant has no login, or its refresh failed (what claude itself
        # reports as "run /login"): the page's native sign-in (fleet_login.py; the authority's claude-login flow).
        # The authority unreachable or fine: endpoint, as before. Capped at a few seconds; only its state word is read.
        local w=""
        local cap=(); command -v timeout &>/dev/null && cap=(timeout 12)
        command -v python3 &>/dev/null && w=$("${cap[@]}" python3 "$_MANAGER_DIR/fleet_login.py" word 2>/dev/null)
        [[ "$w" == relogin ]] && echo relogin || echo endpoint
    elif [[ -n "${ANTHROPIC_API_KEY:-}" || -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" || -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
        echo login
    elif [[ -s "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]]; then
        # Its own login (direct mode): relogin once it can't refresh any more (fleet_login.py reads only its expiry
        # and whether a refresh token is there).
        local w=""
        command -v python3 &>/dev/null && w=$(python3 "$_MANAGER_DIR/fleet_login.py" word 2>/dev/null)
        [[ "$w" == relogin ]] && echo relogin || echo login
    else
        echo signin
    fi
}

# powos manager --signin: Claude Code's own login (`claude auth login`, the Claude subscription), run in the AI page's
# terminal. Its browser step opens in Android's browser (BROWSER / xdg-open -> the app's open bridge) and comes back to
# claude's localhost listener, or the code is pasted into the terminal. Claude Code keeps the credentials in this image
# only (~/.claude, the app's private storage); nothing here reads, copies, logs or prints them.
_manager_signin() {
    _manager_ensure_claude || return 1
    if command -v powos-android-open &>/dev/null; then export BROWSER=powos-android-open; fi
    claude auth login --claudeai
}

# powos manager --signout: Claude Code's own logout (its credentials leave the image). Never the endpoint's.
_manager_signout() {
    command -v claude &>/dev/null || PATH="$HOME/.local/bin:$PATH"
    command -v claude &>/dev/null || return 0
    claude auth logout
}

# Its CLI (installed on first use), the AI config and the manager persona.
_manager_load() {
    _manager_ensure_claude || return 1
    _ai_ensure_config
    _ai_load_agent manager
}

# powos ai manager [--safe] [--no-sandbox]  — start / resume the persistent manager session (--help: its flags).
# The sign-in flags of manager_run, $1 the flag, the rest its args:
#   --auth         how it's signed in (one word: endpoint / relogin / login / signin)
#   --signin       Claude Code's login        --signout  its logout
#   --fleet-login  the native fleet sign-in: status | start <tenant> | complete <tenant> (code#state on stdin); JSON out
_manager_auth_cmd() {
    case "$1" in
        --auth) _manager_auth ;;
        --signin) _manager_signin ;;
        --fleet-login) shift; python3 "$_MANAGER_DIR/fleet_login.py" "$@" ;;
        --signout) _manager_signout ;;
    esac
}

manager_run() {
    command -v python3 &>/dev/null || { echo "manager needs python3" >&2; return 1; }
    [[ -f "$MANAGER_SERVER" ]] || { echo "manager.py not found" >&2; return 1; }

    local store="${AI_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/powos/ai}/manager"
    mkdir -p "$store"

    # Split our own flags from broker pass-throughs (--once, --json-events, --cwd, ...).
    local passthru=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --safe) export POWOS_MANAGER_SAFE=1 ;;
            --no-sandbox) export POWOS_SANDBOX_ENABLED=0 ;;
            # --help: the broker's own (manager.py), without the persona load below.
            -h|--help) python3 "$MANAGER_SERVER" --help; return ;;
            # How it's signed in, Claude Code's login, the native fleet sign-in, its logout (_manager_auth_cmd).
            --auth|--signin|--fleet-login|--signout) _manager_auth_cmd "$@"; return ;;
            *) passthru+=("$1") ;;
        esac
        shift
    done

    # Lightweight data query for the widget sidebar — skip the (expensive)
    # persona load / mcp wiring / context gathering the chat path needs.
    if [[ " ${passthru[*]} " == *" --list-json "* ]]; then
        export COMMS_ROOT
        python3 "$MANAGER_SERVER" --agent-id manager --session-store "$store" --list-json
        return
    fi

    _manager_use_own_cli

    # Load the manager persona. _ai_load_agent expands the !cmd lines, so the
    # system prompt carries the CURRENT `powos help` / `powos comms help`.
    if ! declare -f _ai_load_agent &>/dev/null; then
        echo "AI framework not loaded (agent.sh)" >&2; return 1
    fi
    # The AI config, the Anthropic endpoint included (/etc/powos/ai/endpoint.conf: the fleet's auth authority), so the
    # manager's claude uses it wherever it's started - not only from a session whose environment.d already has it
    # (a phone's PowOS session doesn't).
    _manager_load || return 1
    _manager_signed_in "${passthru[@]}" || return 4
    _manager_chat "$store" "${passthru[@]}"
}

# No endpoint and no Claude login in the image (the non-root build before its user signs in): no claude run that only
# answers 401 - the page's event ("signin": its Sign in to Claude state) and status 1 (manager_run returns 4). $@: the
# broker's flags.
_manager_signed_in() {
    local how; how="$(_manager_auth)"
    [[ "$how" != signin && "$how" != relogin ]] && return 0
    [[ " $* " == *" --json-events "* ]] && echo "{\"kind\": \"$how\"}"
    if [[ "$how" == relogin ]]; then
        echo "manager: the fleet's Claude login needs you - sign in from the AI page (powos manager --fleet-login status)" >&2
    else
        echo "manager: not signed in to Claude (powos manager --signin)" >&2
    fi
    return 1
}

# The chat itself: its MCP config and system prompt as temp files, the broker (manager.py) with them; $1 the session
# store, the rest the broker's flags. Its status.
_manager_chat() {
    local store="$1"; shift
    local mcp_file spf rc=0
    mcp_file="$(mktemp "${TMPDIR:-/tmp}/powos-manager-mcp.XXXXXX")"
    _manager_mcp_config "$mcp_file" || rc=$?
    if (( rc )); then
        rm -f "$mcp_file"; mcp_file=""
        (( rc == 3 )) || return 1
        rc=0
    fi
    spf="$(mktemp "${TMPDIR:-/tmp}/powos-manager-sys.XXXXXX")"
    _manager_sysprompt > "$spf"

    python3 "$MANAGER_SERVER" \
        --agent-id manager \
        --system-prompt-file "$spf" \
        ${mcp_file:+--mcp-config-file "$mcp_file"} \
        --session-store "$store" \
        "$@" || rc=$?

    rm -f "$spf" "$mcp_file" 2>/dev/null
    return $rc
}
