#!/bin/bash
# self.sh - the "edit PowOS → test → push" dev loop, made memorable and SAFE.
#
#   powos self status   What's baked, is git attached, local edits, ahead/behind
#   powos self test     Apply your local /var/lib/powos/src edits to THIS running
#                       system, transiently (auto-reverts on reboot on installed
#                       composefs; direct on live/RAM). No commit needed.
#   powos self pull     SAFE update from upstream — NEVER discards local edits.
#   powos self push     git add -A + commit + push (helpful errors, not raw git).
#
# The bundled source (/var/lib/powos/src) ships as a plain FILE SNAPSHOT with no
# .git. The image bakes the exact commit it came from into
# /usr/lib/powos/.powos-src-commit so `self pull` can attach to that TRUE base
# and treat any bundle edits as pending changes — instead of the old
# `git checkout -f` that blindly reset to master and nuked local work.
# Marker path note: was /var/lib/powos/... historically, moved to /usr/lib/...
# because bootc doesn't re-seed /var on switch/upgrade so the /var marker went
# stale (or missing) after any bootc operation. /usr is part of the OS image.
set -uo pipefail
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/common.sh"
POWOS_TAG=self

SELF_SRC="${POWOS_SRC:-/var/lib/powos/src}"
# Prefer /usr (current-image truth); fall back to /var for images built
# before the move — will disappear once every machine has upgraded past it.
if [[ -n "${POWOS_SRC_COMMIT_FILE:-}" ]]; then
    SELF_MARKER="$POWOS_SRC_COMMIT_FILE"
elif [[ -r /usr/lib/powos/.powos-src-commit ]]; then
    SELF_MARKER="/usr/lib/powos/.powos-src-commit"
else
    SELF_MARKER="/var/lib/powos/.powos-src-commit"
fi
SELF_UPSTREAM="${POWOS_UPSTREAM:-https://github.com/Powback/PowOS.git}"

# Indent a stream by two spaces without sed (repo owner forbids sed).
self_indent() { awk '{ print "  " $0 }'; }

# The commit the bundled source was built from (baked into the image), or
# "unknown" if the marker is missing/empty (e.g. an old image or a dev build).
self_baked_sha() {
    if [[ -r "$SELF_MARKER" ]]; then
        local s; s="$(tr -d '[:space:]' < "$SELF_MARKER" 2>/dev/null)"
        [[ -n "$s" ]] && { printf '%s\n' "$s"; return 0; }
    fi
    printf 'unknown\n'
}

self_git_dirty() { [[ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]]; }

# Read-only /usr (installed bootc/composefs) → can't cp into /usr directly.
#
# Kernel-authoritative writability probe. The old implementation compared
# findmnt OPTIONS for `ro` on /usr OR /, but on bootc composefs the ROOT
# composefs stays `ro` even after `bootc usr-overlay` adds a writable
# overlay at /usr — so the fallthrough falsely reported "ro" and `powos
# self test` aborted every time on installed systems.
self_usr_ro() {
    local probe="/usr/.self-usr-ro-probe.$$"
    if : > "$probe" 2>/dev/null; then
        rm -f "$probe" 2>/dev/null
        return 1  # writable
    fi
    return 0  # read-only
}

# ══════════════════════════════════════════════════════════════════
# SAFE pull — replaces the old `git checkout -f` footgun.
#
# Contract: this function NEVER discards uncommitted local edits and NEVER runs
# `checkout -f` over a dirty tree.
#
#   A) $src/.git exists            → stash-if-dirty, `git pull --rebase`,
#                                     stash pop (conflicts surfaced, not dropped).
#   B) no .git (bundled snapshot):
#      - git init + add origin
#      - baked SHA known & fetchable → seed the index from the TRUE base so only
#        real edits show as pending, stash-if-dirty, checkout origin/master,
#        stash pop.
#      - baked SHA unknown/unfetchable → align with origin/master ONLY if the
#        tree is clean; otherwise REFUSE (tell the user to commit/copy first).
# ══════════════════════════════════════════════════════════════════
self_safe_pull() {
    local src="${1:-$SELF_SRC}"
    local upstream="${POWOS_UPSTREAM:-$SELF_UPSTREAM}"

    if [[ ! -d "$src" ]]; then
        perr "PowOS source not found at: $src"
        return 1
    fi

    # ── Case A: already a git checkout → plain safe pull ──
    if [[ -d "$src/.git" ]]; then
        local stashed=0
        if self_git_dirty "$src"; then
            plog "Local edits present — stashing before pull…"
            if git -C "$src" stash push -u -m "powos-self-pull" >/dev/null 2>&1; then
                stashed=1
            else
                pwarn "git stash failed — not pulling (your edits are untouched)."
                return 1
            fi
        fi
        plog "Pulling latest (rebase) in $src…"
        git -C "$src" pull --rebase 2>&1 | self_indent \
            || git -C "$src" pull 2>&1 | self_indent \
            || pwarn "git pull reported issues."
        if (( stashed )); then
            plog "Restoring your local edits…"
            if ! git -C "$src" stash pop 2>&1 | self_indent; then
                pwarn "Your edits are SAFE in 'git stash' but conflicted with upstream."
                pwarn "Resolve in $src (git status), then 'git stash drop' when done."
                return 2
            fi
        fi
        pok "Up to date; local edits preserved."
        return 0
    fi

    # ── Case B: bundled snapshot (no .git) ──
    if [[ ! -w "$src" ]]; then
        perr "Bundled source at $src is not writable — can't attach git."
        perr "Re-run with sudo, or copy the source somewhere writable and use --from."
        return 1
    fi

    local baked; baked="$(self_baked_sha)"
    plog "No .git in $src — attaching to upstream:"
    plog "  $upstream   (baked base: $baked)"

    git -C "$src" init -q 2>/dev/null || { perr "git init failed."; return 1; }
    git -C "$src" remote add origin "$upstream" 2>/dev/null \
        || git -C "$src" remote set-url origin "$upstream" 2>/dev/null || true

    # Always need origin/master to align onto.
    local have_master=0
    git -C "$src" fetch --depth 200 origin master 2>/dev/null && have_master=1

    if [[ "$baked" != "unknown" && -n "$baked" ]]; then
        # Ensure the baked base commit is present (depth fallback → master).
        git -C "$src" cat-file -e "${baked}^{commit}" 2>/dev/null \
            || git -C "$src" fetch --depth 200 origin "$baked" 2>/dev/null || true

        if git -C "$src" cat-file -e "${baked}^{commit}" 2>/dev/null && (( have_master )); then
            # Seed HEAD+index from the TRUE base: only genuine edits show as
            # pending. (Spec said `reset --soft`; on a freshly-init'd repo the
            # index is empty, so --soft would flag every bundle file as a change.
            # `reset --mixed` seeds the index from the baked tree, correctly
            # realizing the stated goal.)
            git -C "$src" reset --mixed "$baked" >/dev/null 2>&1 || true
            local stashed=0
            if self_git_dirty "$src"; then
                plog "Bundle carries local edits — stashing before checkout…"
                git -C "$src" stash push -u -m "powos-bundle-edits" >/dev/null 2>&1 && stashed=1
            fi
            if ! git -C "$src" checkout -B master origin/master >/dev/null 2>&1; then
                perr "checkout of origin/master failed."
                (( stashed )) && git -C "$src" stash pop >/dev/null 2>&1 || true
                return 1
            fi
            if (( stashed )); then
                plog "Restoring your local edits…"
                if ! git -C "$src" stash pop 2>&1 | self_indent; then
                    pwarn "Edits are SAFE in 'git stash' but conflicted with upstream."
                    pwarn "Resolve in $src, then 'git stash drop'."
                    return 2
                fi
            fi
            pok "Attached to upstream at baked base; local edits preserved."
            return 0
        fi
    fi

    # ── Fallback: baked SHA unknown/unfetchable. NEVER force over edits. ──
    if (( ! have_master )); then
        perr "Couldn't fetch upstream (network/auth?)."
        perr "Set up auth (gh auth login) or deploy locally: powos update self --from /path"
        return 1
    fi
    # Without the true base we can't perfectly separate edits from a pristine
    # bundle. Seed the index from origin/master and REFUSE if anything differs.
    git -C "$src" reset --mixed origin/master >/dev/null 2>&1 || true
    if self_git_dirty "$src"; then
        perr "Baked base commit is unknown and the tree differs from origin/master."
        perr "Refusing to reset — that could discard local edits. Your files are UNTOUCHED."
        perr "Commit or copy your changes out of $src first, then re-run:"
        perr "  (cd $src && git add -A && git commit -m 'my edits')   # then: powos self pull"
        return 1
    fi
    # Clean tree → safe to align with master (no data to lose).
    if ! git -C "$src" checkout -B master origin/master >/dev/null 2>&1; then
        perr "checkout of origin/master failed."
        return 1
    fi
    pok "Attached to upstream (no local edits detected)."
    return 0
}

# ══════════════════════════════════════════════════════════════════
# status — read-only
# ══════════════════════════════════════════════════════════════════
self_status() {
    local src="${1:-$SELF_SRC}"
    echo -e "${BOLD}PowOS self — source status${NC}"
    echo "════════════════════════════════════════"
    echo "Source:        $src"
    echo "Baked commit:  $(self_baked_sha)"
    if [[ -d "$src/.git" ]]; then
        echo "Git:           attached"
        local head; head="$(git -C "$src" log -1 --format='%h %s' 2>/dev/null || echo unknown)"
        echo "HEAD:          $head"
        local changes; changes="$(git -C "$src" status --short 2>/dev/null)"
        if [[ -n "$changes" ]]; then
            echo "Local edits:"
            printf '%s\n' "$changes" | self_indent
        else
            echo "Local edits:   none"
        fi
        local ab; ab="$(git -C "$src" rev-list --left-right --count 'origin/master...HEAD' 2>/dev/null)"
        if [[ -n "$ab" ]]; then
            local behind="${ab%%[[:space:]]*}" ahead="${ab##*[[:space:]]}"
            echo "vs origin/master: $ahead ahead, $behind behind"
        fi
    else
        echo "Git:           not attached (bundled snapshot)"
        echo "Run 'powos self pull' once to attach to upstream."
    fi
}

# ══════════════════════════════════════════════════════════════════
# test — transient live apply of local edits to the running system
# ══════════════════════════════════════════════════════════════════
self_test() {
    local src="${1:-$SELF_SRC}"
    [[ -d "$src" ]] || { perr "Source not found: $src"; return 1; }

    local powos_bin; powos_bin="$(command -v powos 2>/dev/null || echo powos)"

    if self_usr_ro; then
        pwarn "/usr is read-only (installed composefs) — enabling a writable overlay."
        pwarn "This AUTO-REVERTS on the next reboot (bootc usr-overlay)."
        if ! command -v bootc >/dev/null 2>&1; then
            perr "bootc not found — can't make /usr writable transiently."
            perr "Use a live/RAM system, or make it durable with 'powos reload'."
            return 1
        fi
        if ! sudo bootc usr-overlay 2>&1 | self_indent; then
            perr "bootc usr-overlay failed — /usr still read-only, nothing applied."
            return 1
        fi
        if self_usr_ro; then
            perr "/usr still read-only after usr-overlay — aborting (nothing applied)."
            return 1
        fi
        pok "Writable /usr overlay engaged (transient)."
    else
        plog "/usr is writable (live/RAM) — applying directly."
    fi

    plog "Applying $src to the RUNNING system…"
    if "$powos_bin" update self --from "$src"; then
        pok "Applied live from $src."
        pwarn "This is TRANSIENT: an installed composefs system reverts it on reboot."
        pwarn "Make it durable: 'powos self push' then rebuild, or 'powos reload --build'."
        return 0
    fi
    perr "Deploy failed — see output above."
    return 1
}

# ══════════════════════════════════════════════════════════════════
# push — add/commit/push with human-friendly errors
# ══════════════════════════════════════════════════════════════════
self_push() {
    local src="${1:-$SELF_SRC}"; local msg="${2:-}"
    if [[ ! -d "$src/.git" ]]; then
        perr "No git attached at $src."
        perr "Run 'powos self pull' once to attach to upstream, then push."
        return 1
    fi
    [[ -n "$msg" ]] || msg="PowOS self: sync local changes"

    # ── Self-heal repo hygiene so a fresh install can push without manual git
    # setup. All idempotent; safe to run every push. ──────────────────────────
    #   1. safe.directory: the src tree is root-owned; whoever runs `self push`
    #      (often root via sudo) must be allowed to operate on it. Guard the add
    #      so we don't append a duplicate line to ~/.gitconfig on every push.
    git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$src" \
        || git config --global --add safe.directory "$src" 2>/dev/null || true
    #   2. core.fileMode false: installed composefs flips exec bits on carry-over,
    #      which otherwise show as dozens of phantom "modified" files and get
    #      swept into `git add -A`.
    git -C "$src" config core.fileMode false 2>/dev/null || true
    #   3. author identity: if none is configured anywhere, derive it from the
    #      gh-authenticated account so commit doesn't fail "author identity
    #      unknown". `powos setup gh` normally sets this globally; this is a
    #      last-resort, repo-local net.
    if ! git -C "$src" config user.email >/dev/null 2>&1; then
        local _gl _gn
        if command -v gh >/dev/null 2>&1 && _gl="$(gh api user --jq .login 2>/dev/null)" && [[ -n "$_gl" ]]; then
            _gn="$(gh api user --jq '.name // .login' 2>/dev/null)"
            git -C "$src" config user.name  "${_gn:-$_gl}"
            git -C "$src" config user.email "${_gl}@users.noreply.github.com"
            plog "Set git identity from GitHub: ${_gn:-$_gl} <${_gl}@users.noreply.github.com>"
        else
            perr "No git author identity and no gh login to derive one."
            perr "Run 'powos setup gh' (sets identity + credentials), then retry."
            return 1
        fi
    fi

    git -C "$src" add -A || { perr "git add failed."; return 1; }
    if git -C "$src" diff --cached --quiet 2>/dev/null; then
        pwarn "Nothing staged — working tree already matches HEAD; pushing anyway."
    else
        # Transparency: `add -A` stages the ENTIRE tree, so a stray/unrelated edit
        # can ride along under a single-purpose message (happened 2026-07-07 — an
        # unrelated vortex.sh change shipped under a mods-fix commit). Always show
        # exactly what's about to be committed so it's a choice, not a surprise.
        plog "Committing these files:"
        git -C "$src" diff --cached --name-status 2>/dev/null | self_indent
        # Let git stamp the commit date itself (no build-time timestamp baked in).
        if ! git -C "$src" commit -m "$msg" 2>&1 | self_indent; then
            perr "git commit failed."
            return 1
        fi
    fi

    plog "Pushing to remote…"
    local out rc
    out="$(git -C "$src" push 2>&1)"; rc=$?
    if (( rc != 0 )); then
        printf '%s\n' "$out" | self_indent
        perr "Push failed. Common fixes:"
        perr "  • No remote/upstream:  git -C $src remote -v   (or run 'powos self pull' to attach)"
        perr "  • Not authenticated:   run 'gh auth login', or configure a git credential helper"
        return 1
    fi
    printf '%s\n' "$out" | self_indent
    pok "Pushed."
    return 0
}

# Force-refresh /var/lib/powos/src from the current image's /usr/lib/powos/src
# snapshot. Necessary when a bootc-switch inherited a wildly-different /var
# tree from an older PowOS install: `self pull` would then treat the entire
# stale tree as "local edits" and preserve it, silently reverting real code.
# Backs the old tree up under /var/lib/powos/src.stale-<sha>-<ts> so nothing
# is destroyed — the user can rescue real edits from there.
self_reseed() {
    local src="$1"
    local usr_src="/usr/lib/powos/src"
    if [[ ! -d "$usr_src" ]]; then
        perr "$usr_src doesn't exist — this image doesn't bundle a source snapshot."
        return 1
    fi
    if [[ -d "$src" ]]; then
        local backup="${src}.stale-$(self_baked_sha)-$(date +%s)"
        plog "Backing up existing $src → $backup"
        if ! mv "$src" "$backup" 2>/dev/null; then
            perr "Backup move failed (permission?). Re-run with sudo."
            return 1
        fi
    fi
    plog "Copying $usr_src → $src …"
    if ! cp -a "$usr_src" "$src" 2>/dev/null; then
        perr "Copy failed (permission? disk full?). Try sudo."
        return 1
    fi
    pok "Reseeded from image snapshot (commit $(self_baked_sha))."
    plog "If the backup at ${src}.stale-* had real edits, cherry-pick them in."
    return 0
}

self_usage() {
    cat <<EOF
PowOS self — edit → test → push loop

  powos self status   Baked commit, git attach state, local edits, ahead/behind
  powos self test     Apply local /var/lib/powos/src edits to THIS running system
                      (transient; auto-reverts on reboot on installed composefs)
  powos self pull     SAFE update from upstream (never discards local edits)
  powos self push     git add -A + commit + push  (-m "message")
  powos self reseed   Wipe /var/lib/powos/src and re-copy from the CURRENT image
                      snapshot at /usr/lib/powos/src. Use after bootc-switch when
                      the /var tree was inherited from an older PowOS install and
                      self pull is misidentifying stale carry-over as local edits.
                      Backs up the old tree to /var/lib/powos/src.stale-<sha>-<ts>.
EOF
}

cmd_self() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        status|st)  self_status "$SELF_SRC" ;;
        test|t)     self_test "$SELF_SRC" ;;
        pull)       self_safe_pull "$SELF_SRC" ;;
        reseed)     self_reseed "$SELF_SRC" ;;
        push)
            local msg=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -m|--message) msg="${2:-}"; shift 2 ;;
                    *) shift ;;
                esac
            done
            if [[ -z "$msg" ]] && [[ -t 0 ]]; then
                read -rp "Commit message [PowOS self: sync local changes]: " msg || true
            fi
            self_push "$SELF_SRC" "$msg"
            ;;
        help|-h|--help|"") self_usage ;;
        *) perr "Unknown: powos self $sub"; self_usage; return 1 ;;
    esac
}
