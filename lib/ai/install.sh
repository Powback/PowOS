#!/bin/bash
# ai/install.sh - PowOS AI CLI installer.
#
# Installs the vendor-official version of each AI CLI. Each vendor has a
# different preferred path — we don't force everything through npm/bun
# because Anthropic and OpenAI explicitly prefer their native binary
# installers over the npm packages (Anthropic even warns that
# `sudo npm install -g @anthropic-ai/claude-code` is "the single most common
# cause of permission errors and a security risk"). Google is npm-only for
# now — they haven't shipped a native installer for @google/gemini-cli.
#
# Preferred path per tool (no explicit version):
#   claude → curl https://claude.ai/install.sh          native binary
#   codex  → curl https://chatgpt.com/codex/install.sh  native binary
#   gemini → bun install -g @google/gemini-cli          bun runtime
#   aider  → uv tool install aider-chat                 uv runtime
#
# Version-pinned path (`powos ai install claude 2.4.0`): switches to the
# runtime-tool path (bun for the npm ones, uv for the python one) because
# the vendor curl-installers only ship 'latest'. Uniform version-pin story
# across every tool.
#
# Bun and uv are both bundled in the OS image (dnf install ...) so every
# command below is offline-idempotent for the runtime and only needs
# network for the actual package download.

set -uo pipefail
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}/common.sh" 2>/dev/null || {
    # Fall back on the base colors if common.sh is elsewhere.
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
    plog()  { echo -e "${CYAN}[ai]${NC} $*"; }
    pok()   { echo -e "${GREEN}[ai]${NC} $*"; }
    pwarn() { echo -e "${YELLOW}[ai]${NC} $*"; }
    perr()  { echo -e "${RED}[ai]${NC} $*" >&2; }
}
POWOS_TAG=ai

# ─── Tool registry ───────────────────────────────────────────────────────
# Each tool maps to:
#   NPM package (for version-pinned installs and gemini)
#   Native installer URL (empty for gemini — no native path exists)
#   Binary name that lands on PATH after install

ai_pkg_of() {
    case "$1" in
        claude)  echo "@anthropic-ai/claude-code" ;;
        codex)   echo "@openai/codex" ;;
        gemini)  echo "@google/gemini-cli" ;;
        aider)   echo "aider-chat" ;;  # PyPI package (installs `aider` binary)
        *) return 1 ;;
    esac
}

ai_runtime_of() {
    # bun for the npm-scoped ones, uv for the Python one.
    case "$1" in
        claude|codex|gemini)  echo "bun" ;;
        aider)                echo "uv"  ;;
        *) return 1 ;;
    esac
}

ai_native_url_of() {
    case "$1" in
        claude)  echo "https://claude.ai/install.sh" ;;
        codex)   echo "https://chatgpt.com/codex/install.sh" ;;
        gemini)  echo "" ;;   # no vendor native installer
        aider)   echo "" ;;   # no vendor native installer
        *) return 1 ;;
    esac
}

ai_binary_of() {
    case "$1" in
        claude)  echo "claude" ;;
        codex)   echo "codex" ;;
        gemini)  echo "gemini" ;;
        aider)   echo "aider" ;;
        *) return 1 ;;
    esac
}

ai_known_tools() { echo "claude codex gemini aider"; }

# ─── Version detection ───────────────────────────────────────────────────

ai_installed_version() {
    local tool="$1"
    local bin; bin="$(ai_binary_of "$tool")" || return 1
    command -v "$bin" >/dev/null 2>&1 || { echo "not-installed"; return 1; }
    # Each tool shows its version differently; try `--version` (universal)
    # and grep the first version-shaped token. Best-effort.
    local out
    out="$("$bin" --version 2>/dev/null | head -1)"
    if [[ "$out" =~ ([0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.+_-]*) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "${out:-unknown}"
    fi
}

# ─── Installers ──────────────────────────────────────────────────────────

# Ensure bun exists on PATH. Bun is bundled in the OS image at
# /usr/local/bin/bun so this is a safety net — only trips on a machine
# where /usr/local was clobbered, or a live-boot variant that stripped it.
# Falls back to the upstream install script (installs to $HOME/.bun/bin —
# per-user, no sudo). bun is NOT in Fedora repos so we don't try dnf.
ai_ensure_bun() {
    command -v bun >/dev/null 2>&1 && return 0
    pwarn "bun not found — falling back to per-user install via bun.sh."
    plog "  ${DIM}curl -fsSL https://bun.sh/install | bash${NC}"
    if curl -fsSL https://bun.sh/install | bash; then
        # bun installer writes to ~/.bun/bin; add it to PATH for THIS shell.
        export PATH="$HOME/.bun/bin:$PATH"
    fi
    command -v bun >/dev/null 2>&1 || {
        perr "bun install failed. Check network / write access to \$HOME."
        return 1
    }
}

# Same for uv — bundled in the OS image, this is the safety net.
ai_ensure_uv() {
    command -v uv >/dev/null 2>&1 && return 0
    pwarn "uv not found. Trying dnf install uv (needs sudo)..."
    sudo dnf5 -y install --setopt=install_weak_deps=False uv 2>&1 | tail -3
    command -v uv >/dev/null 2>&1 || {
        perr "Could not install uv via dnf. Falling back to the upstream installer:"
        perr "  curl -LsSf https://astral.sh/uv/install.sh | sh"
        return 1
    }
}

ai_install_native() {
    local tool="$1"
    local url; url="$(ai_native_url_of "$tool")"
    if [[ -z "$url" ]]; then
        return 2   # sentinel: no native path, caller should try bun
    fi
    plog "Installing ${BOLD}$tool${NC} via vendor native installer:"
    plog "  ${DIM}$url${NC}"
    # We DELIBERATELY curl | sh here. Every alternative (download → inspect
    # → run) still requires trusting the vendor with the payload — the
    # installer script IS the vendor's release artifact. If you want a
    # non-curl-piped path, use the version-pinned form which goes via bun.
    if curl -fsSL "$url" | bash; then
        pok "$tool installed."
        ai_post_install "$tool"
        return 0
    else
        perr "Native installer for $tool failed."
        return 1
    fi
}

# Per-tool post-install fixups: things vendor installers don't do but
# every headless user hits within their first two minutes.
ai_post_install() {
    local tool="$1"
    case "$tool" in
        claude)  ai_seed_claude_onboarding ;;
    esac
}

# Claude Code shows a first-run onboarding screen (theme picker, welcome,
# trust dialog) that blocks `claude --interactive` even when the user is
# already authenticated. The screen is gated by ~/.claude.json's
# `hasCompletedOnboarding` field — writing true there tells Claude to skip
# it. Additive: only sets the key if missing/false, preserving anything
# else the file already contained.
ai_seed_claude_onboarding() {
    local cfg="$HOME/.claude.json"
    python3 - "$cfg" <<'PY' 2>/dev/null || return 0
import json, os, sys
p = sys.argv[1]
d = {}
if os.path.exists(p):
    try: d = json.load(open(p))
    except Exception: d = {}
if d.get("hasCompletedOnboarding") is True:
    sys.exit(0)
d["hasCompletedOnboarding"] = True
open(p, "w").write(json.dumps(d, indent=2))
os.chmod(p, 0o600)
PY
    plog "  Set hasCompletedOnboarding=true in ${DIM}~/.claude.json${NC} (skips the welcome screen)."
}

ai_install_bun() {
    local tool="$1" version="$2"
    local pkg; pkg="$(ai_pkg_of "$tool")" || { perr "Unknown tool: $tool"; return 1; }
    ai_ensure_bun || return 1
    local spec="$pkg"
    [[ -n "$version" && "$version" != "latest" ]] && spec="${pkg}@${version}"
    plog "Installing ${BOLD}$tool${NC} via bun: ${DIM}bun install -g $spec${NC}"
    if bun install -g "$spec"; then
        pok "$tool installed (bun global — ~/.bun/bin)."
        # Bun's global install dir needs to be on PATH; it usually is via
        # ~/.bashrc after `bun completions` but not always. Print a hint.
        if ! echo "$PATH" | grep -q "$HOME/.bun/bin"; then
            pwarn "\$HOME/.bun/bin is not on your PATH. Add:"
            pwarn "  export PATH=\"\$HOME/.bun/bin:\$PATH\"     # to ~/.bashrc"
        fi
        return 0
    else
        perr "bun install failed for $spec"
        return 1
    fi
}

ai_install_uv() {
    local tool="$1" version="$2"
    local pkg; pkg="$(ai_pkg_of "$tool")" || { perr "Unknown tool: $tool"; return 1; }
    ai_ensure_uv || return 1
    local spec="$pkg"
    # uv uses PEP 440-style `pkg==version` for pinned installs.
    [[ -n "$version" && "$version" != "latest" ]] && spec="${pkg}==${version}"
    plog "Installing ${BOLD}$tool${NC} via uv: ${DIM}uv tool install $spec${NC}"
    if uv tool install "$spec"; then
        pok "$tool installed (uv tool — ~/.local/bin)."
        return 0
    else
        perr "uv tool install failed for $spec"
        return 1
    fi
}

# Dispatch to the right runtime for a tool at a given version.
ai_install_via_runtime() {
    local tool="$1" version="$2"
    case "$(ai_runtime_of "$tool")" in
        bun) ai_install_bun "$tool" "$version" ;;
        uv)  ai_install_uv  "$tool" "$version" ;;
        *)   perr "No runtime configured for $tool"; return 1 ;;
    esac
}

# ─── Commands ────────────────────────────────────────────────────────────

ai_install_cmd() {
    local tool="${1:-}" version="${2:-}"
    if [[ -z "$tool" ]]; then
        ai_install_help
        return 1
    fi
    if ! ai_pkg_of "$tool" >/dev/null 2>&1; then
        perr "Unknown AI tool: $tool"
        plog "Known tools: $(ai_known_tools)"
        return 1
    fi

    if [[ -z "$version" || "$version" == "latest" ]]; then
        # Prefer the vendor's native installer when they ship one.
        ai_install_native "$tool"
        local rc=$?
        [[ $rc -eq 0 ]] && return 0
        # rc=2 means "no native path exists" (gemini, aider). rc=1 means
        # native installer errored. Either way, fall through to the tool's
        # runtime path (bun for npm-scoped, uv for python).
        ai_install_via_runtime "$tool" "latest"
    else
        # Pinned version → always go through the runtime so we can pass a
        # version spec that the vendor curl-installers don't accept.
        ai_install_via_runtime "$tool" "$version"
    fi
}

ai_uninstall_cmd() {
    local tool="${1:-}"
    if [[ -z "$tool" ]]; then
        perr "Usage: powos ai uninstall <tool>"
        return 1
    fi
    local pkg; pkg="$(ai_pkg_of "$tool")" || { perr "Unknown tool: $tool"; return 1; }
    local bin; bin="$(ai_binary_of "$tool")"

    local removed=false
    local runtime; runtime="$(ai_runtime_of "$tool")"

    # Uninstall from whichever runtime owns the tool.
    case "$runtime" in
        bun)
            if command -v bun >/dev/null 2>&1 \
               && bun pm ls -g 2>/dev/null | grep -q "$pkg"; then
                plog "Uninstalling $tool (bun global)..."
                bun remove -g "$pkg" 2>&1 | tail -3 && removed=true
            fi
            ;;
        uv)
            if command -v uv >/dev/null 2>&1 \
               && uv tool list 2>/dev/null | grep -q "$pkg"; then
                plog "Uninstalling $tool (uv tool)..."
                uv tool uninstall "$pkg" 2>&1 | tail -3 && removed=true
            fi
            ;;
    esac

    # Native installers put binaries at ~/.local/bin/<name>. If still there
    # after the runtime uninstall, the vendor script was used — remove it too.
    if [[ -x "$HOME/.local/bin/$bin" ]]; then
        plog "Removing native binary at ~/.local/bin/$bin"
        rm -f "$HOME/.local/bin/$bin" && removed=true
        # Vendor installer may also drop a directory alongside it — best-effort.
        rm -rf "$HOME/.local/share/$bin" 2>/dev/null || true
    fi
    if $removed; then
        pok "$tool uninstalled."
    else
        pwarn "$tool doesn't appear to be installed."
    fi
}

ai_installed_cmd() {
    echo -e "${BOLD}Installed AI CLIs${NC}"
    echo "════════════════════════════════════════"
    local tool
    for tool in $(ai_known_tools); do
        local ver; ver="$(ai_installed_version "$tool" 2>/dev/null)"
        if [[ "$ver" == "not-installed" ]]; then
            printf "  %-10s ${DIM}not installed${NC}\n" "$tool"
        else
            printf "  %-10s ${GREEN}%s${NC}\n" "$tool" "$ver"
        fi
    done
    echo ""
    echo -e "${DIM}Install:   powos ai install <tool> [version]${NC}"
    echo -e "${DIM}Uninstall: powos ai uninstall <tool>${NC}"
}

ai_install_help() {
    cat <<EOF
${BOLD}powos ai install${NC} — install an AI coding CLI via its vendor-preferred path

  powos ai install <tool> [version]     Install (vendor-native if no version)
  powos ai uninstall <tool>             Remove
  powos ai installed                    List installed tools + versions

Known tools:
  ${BOLD}claude${NC}   Anthropic Claude Code
                Default: curl -fsSL https://claude.ai/install.sh | bash
                Pinned:  bun install -g @anthropic-ai/claude-code@<ver>
  ${BOLD}codex${NC}    OpenAI Codex CLI
                Default: curl -fsSL https://chatgpt.com/codex/install.sh | sh
                Pinned:  bun install -g @openai/codex@<ver>
  ${BOLD}gemini${NC}   Google Gemini CLI (Antigravity CLI on non-paid tiers)
                Always:  bun install -g @google/gemini-cli[@<ver>]
                (Google doesn't ship a native binary installer.)
  ${BOLD}aider${NC}    Aider — AI pair-programming in the terminal (Python)
                Always:  uv tool install aider-chat[==<ver>]

Examples:
  powos ai install claude
  powos ai install claude 2.4.0
  powos ai install gemini
  powos ai install aider
  powos ai installed
EOF
}
