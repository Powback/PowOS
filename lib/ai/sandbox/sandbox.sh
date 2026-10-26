#!/usr/bin/env bash
# powos sandbox - the manager's TypeScript sandbox (lib/ai/sandbox, ported from SpaceTimeAI's code mode,
# ~/Projects/SpaceTimeAI/agents/worker/codemode). Run by bin/powos (`powos sandbox ...`), sourced by
# lib/ai/manager/manager.sh (sandbox_enabled, sandbox_mcp_config_json).
#
# Its runtime deps (package-lock.json: quickjs-emscripten + typescript; pure JS + WebAssembly, no install scripts)
# live INSIDE this directory, lib/ai/sandbox/node_modules (gitignored), never on the host: `powos sandbox setup` runs
# `npm ci --ignore-scripts` from the lock, here, and nothing else. No deps, no sandbox: the manager simply starts
# without its sandbox tools (fail closed: there is no fallback that runs code unsandboxed).
_SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SANDBOX_NM="$_SANDBOX_DIR/node_modules"

# The JS runtime: bun when there is one, else node >= 22.18 (type stripping on by default; worker threads run .ts).
sandbox_runtime() {
    if command -v bun >/dev/null 2>&1; then echo bun; return 0; fi
    if command -v node >/dev/null 2>&1; then
        local v; v=$(node -p 'process.versions.node' 2>/dev/null) || return 1
        local maj=${v%%.*} min; min=${v#*.}; min=${min%%.*}
        if (( maj > 22 || (maj == 22 && min >= 18) )); then echo node; return 0; fi
    fi
    return 1
}

# The lock's hash, recorded at setup: deps from an older lock are stale (`setup` again).
_sandbox_lock_hash() { (shasum -a 256 2>/dev/null || sha256sum) < "$_SANDBOX_DIR/package-lock.json" | cut -c1-16; }

# Are the deps here and from the current lock?
sandbox_deps_ok() {
    [[ -f "$_SANDBOX_NM/quickjs-emscripten/package.json" && -f "$_SANDBOX_NM/typescript/package.json" ]] || return 1
    [[ "$(cat "$_SANDBOX_NM/.powos-lock" 2>/dev/null)" == "$(_sandbox_lock_hash)" ]]
}

# powos sandbox setup: the lock's exact versions into this directory (npm ci: nothing global, no install scripts).
sandbox_setup() {
    if sandbox_deps_ok; then echo "powos sandbox: deps up to date ($_SANDBOX_NM)"; return 0; fi
    command -v npm >/dev/null 2>&1 || { echo "powos sandbox: setup needs npm (it installs into $_SANDBOX_NM only)" >&2; return 1; }
    sandbox_runtime >/dev/null || echo "powos sandbox: note: no bun or node >= 22.18 here to run it" >&2
    local log; log=$(mktemp "${TMPDIR:-/tmp}/powos-sandbox-setup.XXXXXX")
    if ! (cd "$_SANDBOX_DIR" && npm ci --no-audit --no-fund --ignore-scripts) >"$log" 2>&1; then
        echo "powos sandbox: npm ci failed:" >&2; tail -20 "$log" >&2; rm -f "$log"; return 1
    fi
    rm -f "$log"
    _sandbox_lock_hash > "$_SANDBOX_NM/.powos-lock"
    echo "powos sandbox: deps installed ($_SANDBOX_NM, $(du -sh "$_SANDBOX_NM" 2>/dev/null | cut -f1))"
}

sandbox_exec() {
    local rt
    rt=$(sandbox_runtime) || { echo "powos sandbox: needs bun or node >= 22.18: powos sandbox setup" >&2; return 1; }
    sandbox_deps_ok || { echo "powos sandbox: its deps are missing or stale: powos sandbox setup" >&2; return 1; }
    [[ $rt == node ]] && exec node --no-warnings "$_SANDBOX_DIR/main.ts" "$@"
    exec bun "$_SANDBOX_DIR/main.ts" "$@"
}

# Does the manager get the sandbox? On when a runtime and the deps are here; POWOS_SANDBOX_ENABLED=0 opts out.
sandbox_enabled() {
    [[ "${POWOS_SANDBOX_ENABLED:-1}" != "0" ]] || return 1
    sandbox_runtime >/dev/null && sandbox_deps_ok
}

# The ceiling for an agent role: what its jobs may ever be granted (the model picks a subset per job, never more).
# The manager: everything this host serves. Any other role (none is wired yet): read the board/inbox/phone, send mail.
sandbox_ceiling_for() {
    case "$1" in
        manager) echo "comms.read,comms.send,board.read,board.write,checks.queue,phone.read" ;;
        *)       echo "comms.read,comms.send,board.read,phone.read" ;;
    esac
}

# The mcpServers entry (one JSON member, "sandbox":{...}) that starts the sandbox server for agent role $1.
sandbox_mcp_server_json() {
    local role="${1:-${COMMS_AGENT_ID:-}}"
    printf '"sandbox":{"command":"bash","args":["%s/sandbox.sh","mcp"],"env":{"POWOS_SANDBOX_CEILING":"%s"}}' \
        "$_SANDBOX_DIR" "$(sandbox_ceiling_for "$role")"
}

# A whole --mcp-config JSON with only the sandbox in it.
sandbox_mcp_config_json() { printf '{"mcpServers":{%s}}\n' "$(sandbox_mcp_server_json "$@")"; }

sandbox_help() {
    cat <<'EOF'
powos sandbox - run TypeScript jobs in a sandbox (QuickJS + a TypeScript check; ported from SpaceTimeAI's code mode)

A job's code gets NOTHING but the functions of the capabilities granted to that job: no process, file, network,
environment or secret. Each function runs one fixed PowOS command (argv, no shell); a call to anything not granted
is a type error before the job runs. The manager gets it as the MCP tools sandbox eval / declarations.

Usage:
  powos sandbox run [--grant CAP]... [--args JSON] [--timeout S] [--memory MB] [--max-calls N] FILE|-
                          run one job (stdin with -); prints the last expression + console output; exit 1 = failed
  powos sandbox caps [--json]          the capabilities, their functions, and which may be granted here
  powos sandbox declarations [CAP...]  the exact TypeScript declarations those grants give the code
  powos sandbox setup                  install its deps (npm ci from its lock) into lib/ai/sandbox/node_modules only
  powos sandbox status                 runtime, deps, and whether the manager gets it
  powos sandbox mcp                    the MCP server (the manager's launcher starts it; stdio)

Capabilities (grant only what the job needs):
  comms.read    commsInbox            this agent's own inbox, peeked (nothing consumed)
  comms.send    sendMessage           mail another agent, as this agent
  board.read    boardTasks, boardChecks   the work board's tasks (their TRUE state) and phone checks
  board.write   boardSetTask, boardAddTask  move a task (step/note/progress/plan/status/owner), add one
  checks.queue  queueCheck, checkQueue  queue a tools/phone/verify/*.sh check (each arg one word), read the queue
                                        (only where the verify queue lives: the Mac's PowOS checkout)
  phone.read    phoneState            read-only views: overview, status, units, sleep, apps.running, shell.errors
                                        (at most 5 per job: never poll the phone)
  Always: console.log, args, and a per-session virtual workspace (readVfs/writeVfs/editVfs/deleteVfs/searchVfs/
  listVfs, in memory) to save a script and rerun it by path.

Limits per job: --timeout (default 60 s, max 300), --memory (default 64 MB, max 256), --max-calls host calls
(default 40, max 400); each host command at most 30 s. The manager's ceiling is every capability this host can
serve (POWOS_SANDBOX_CEILING, set by its launcher, never by the model). Every job is logged to
~/.local/state/powos/sandbox/jobs.jsonl (agent, grants, code hash, calls, outcome). POWOS_SANDBOX_ENABLED=0 unwires it.

Example (one job instead of a dozen tool calls):
  powos sandbox run --grant board.read --grant comms.send - <<'TS'
  const stalled = (await boardTasks({ state: "stalled" })).map(t => t.title);
  if (stalled.length) await sendMessage({ to: "coder", body: `stalled: ${stalled.join("; ")}` });
  stalled.length
  TS
EOF
}

sandbox_status() {
    local rt; rt=$(sandbox_runtime) || rt="none (needs bun or node >= 22.18)"
    echo "runtime:  $rt"
    if sandbox_deps_ok; then echo "deps:     ok ($_SANDBOX_NM)"; else echo "deps:     missing or stale (powos sandbox setup)"; fi
    if sandbox_enabled; then echo "manager:  wired (MCP server 'sandbox')"
    elif [[ "${POWOS_SANDBOX_ENABLED:-1}" == "0" ]]; then echo "manager:  off (POWOS_SANDBOX_ENABLED=0)"
    else echo "manager:  not wired (no runtime or deps)"; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-help}" in
        help|-h|--help) sandbox_help ;;
        setup) sandbox_setup ;;
        status) sandbox_status ;;
        mcp|run|caps|declarations) sandbox_exec "$@" ;;
        *) echo "powos sandbox: unknown command '$1' (powos sandbox help)" >&2; exit 2 ;;
    esac
fi
