#!/bin/bash
# self.sh - the "edit PowOS → test → push" dev loop, made memorable and SAFE.
#
#   powos self status   What's baked, is git attached, local edits, ahead/behind
#   powos self apply    Phone: deploy the working tree (uncommitted edits too); saves a rollback point
#   powos self rollback Phone: restore the state before the last apply
#   powos self check [names]  Phone: on-device checks (applied syntax cli self manifest)
#   powos self test     Apply your local /var/lib/powos/src edits to THIS running
#                       system, transiently (auto-reverts on reboot on installed
#                       composefs; direct on live/RAM). No commit needed.
#   powos self pull     SAFE update from upstream — NEVER discards local edits.
#   powos self update   pull, then apply (on the phone: bin/lib copy from the tree; no composefs/bootc).
#   powos self push     commit + push (helpful errors, not raw git): `-- <paths>` commits only those; no paths: the
#                       whole tree, refused when others' changes are already staged (a tree agents share).
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

# Resolve through the SHARED resolver (common.sh) rather than hardcoding the
# bundled tree. `powos reload` always resolved this way; `self` did not, so the
# two edited different trees and the bundled one rotted unnoticed. Same resolver
# = they cannot disagree. Bundled /var/lib/powos/src is still the last resort
# inside powos_src_find, so the "no external checkout" case is unaffected.
SELF_SRC="${POWOS_SRC:-$(powos_src_find 2>/dev/null || echo /var/lib/powos/src)}"
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
# Branch `self` follows: `powos config upstream-branch <name>` (key upstream-branch in /etc/powos/config), default master.
SELF_BRANCH="${POWOS_UPSTREAM_BRANCH:-$(awk -F= '$1=="upstream-branch" { v=$2 } END { print v }' /etc/powos/config 2>/dev/null)}"
SELF_BRANCH="${SELF_BRANCH:-master}"

# The phone applies a tree with one small routine shared with its rootfs build and rooted deploy.
source "$(dirname "${BASH_SOURCE[0]}")/self-phone.sh"
# The phone has no composefs or bootc and a writable /: its apply and test skip the usr-overlay parts.
self_is_phone() { [[ "$(cat /etc/powos/platform 2>/dev/null)" == phone ]]; }

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
#
# Must probe AS ROOT: /usr is root-owned, so an unprivileged `: > probe`
# fails with EACCES even on a writable overlay — which this function then
# misreported as "read-only", aborting `self test` right after usr-overlay
# succeeded. The actual deploy uses sudo cp anyway, so root is the right
# identity to ask "can we write here?".
self_usr_ro() {
    local probe="/usr/.self-usr-ro-probe.$$"
    if sudo sh -c ": > '$probe'" 2>/dev/null; then
        sudo rm -f "$probe" 2>/dev/null
        return 1  # writable
    fi
    return 0  # read-only
}

# ══════════════════════════════════════════════════════════════════
# Image file map — the SINGLE SOURCE OF TRUTH for `update self`.
#
# The Containerfile's `staging` stage is a list of `COPY <src...> <dst>` lines
# that place every shipped file. Rather than hand-maintain a parallel copy list
# in `update self` (which drifted — profile.d / konsole / MOTD were shipped by
# the image but not live-appliable), we derive the map straight from those COPY
# lines. Add a COPY to the Containerfile and `update self` picks it up for free;
# test/tier1/test-self-manifest.sh enforces that they stay in lockstep.
# ══════════════════════════════════════════════════════════════════

# Emit `src<TAB>dst` for every applicable staging COPY. Multi-src lines expand
# to one row per src. Build-only entries are skipped: `.snapshot` (the source
# snapshot itself, not a runtime file) and anything under /tmp (KDE build stage).
self_copy_manifest() {
    local containerfile="${1:-$SELF_SRC/Containerfile}"
    [[ -r "$containerfile" ]] || return 0
    awk '
        /^FROM[[:space:]]+scratch[[:space:]]+AS[[:space:]]+staging/ { instage=1; next }
        /^FROM[[:space:]]/ { instage=0 }
        instage && /^COPY[[:space:]]/ {
            n=0; delete a
            for (i=2; i<=NF; i++) { if ($i ~ /^--/) continue; a[++n]=$i }  # drop --flags
            if (n < 2) next
            dst=a[n]
            if (dst ~ /^\/tmp\//) next
            for (i=1; i<n; i++) {
                if (a[i] ~ /^\.snapshot/) continue
                print a[i] "\t" dst
            }
        }
    ' "$containerfile"
}

# Apply the image file map onto the running system from $src_root. rsync's
# default (temp file + atomic rename) is safe even for the running /usr/bin/powos
# and for a lib/*.sh being sourced right now; --no-owner/--no-group keep the
# installed files root-owned (we copy under sudo). Caller must have engaged the
# usr-overlay for /usr first. Echoes each applied target.
self_apply_manifest() {
    # Separate declarations — bash creates every name in one `local` before
    # assigning, so the default here would expand an unset $src_root.
    local src_root="$1"
    local containerfile="${2:-$src_root/Containerfile}"
    local src dst abs
    while IFS=$'\t' read -r src dst; do
        [[ -n "$src" && -n "$dst" ]] || continue
        abs="$src_root/${src%/}"
        if [[ ! -e "$abs" ]]; then
            echo "  (skip: $src not in tree)"
            continue
        fi
        if [[ -d "$abs" ]]; then
            dst="${dst%/}"
            sudo mkdir -p "$dst"
            sudo rsync -a --no-owner --no-group "$abs/" "$dst/" && echo "  $dst/  ← $src"
        else
            if [[ "$dst" == */ ]]; then sudo mkdir -p "$dst"
            else sudo mkdir -p "$(dirname "$dst")"; fi
            sudo rsync -a --no-owner --no-group "$abs" "$dst" && echo "  $dst  ← $src"
        fi
    done < <(self_copy_manifest "$containerfile")
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
#        real edits show as pending, stash-if-dirty, checkout origin/$SELF_BRANCH,
#        stash pop.
#      - baked SHA unknown/unfetchable → align with origin/$SELF_BRANCH ONLY if the
#        tree is clean; otherwise REFUSE (tell the user to commit/copy first).
# ══════════════════════════════════════════════════════════════════
# self_safe_pull's phases. Each is a named step of the flow above, in the
# order the orchestrator runs them. Values a phase produces are published in
# a SELF_PULL_* global rather than echoed: every one of them also PRINTS
# progress, and a command substitution would swallow exactly that.
SELF_PULL_BAKED=""         # baked base SHA, or "unknown" (self_pull_attach)
SELF_PULL_HAVE_MASTER=0    # did the origin/$SELF_BRANCH fetch succeed?

# ── Case A: already a git checkout → plain safe pull ──
# Local edits are stashed first and popped after, so a pull can never eat them.
self_pull_existing() {
    local src="$1" stashed=0
    # Offline or unreachable: say so and leave the tree exactly as it is (before any stash).
    if ! git -C "$src" fetch -q origin "$SELF_BRANCH" 2>/dev/null; then
        perr "Cannot reach upstream - nothing changed. Current tree: $(git -C "$src" log -1 --format='%h %s' 2>/dev/null)"
        return 1
    fi
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
}

# ── Case B, step 1: turn the bundled snapshot into a git checkout ──
# Publishes SELF_PULL_BAKED and SELF_PULL_HAVE_MASTER. Non-zero means nothing
# was attached and the caller must stop.
self_pull_attach() {
    local src="$1" upstream="$2"
    if [[ ! -w "$src" ]]; then
        perr "Bundled source at $src is not writable — can't attach git."
        perr "Re-run with sudo, or copy the source somewhere writable and use --from."
        return 1
    fi

    SELF_PULL_BAKED="$(self_baked_sha)"
    plog "No .git in $src — attaching to upstream:"
    plog "  $upstream   (baked base: $SELF_PULL_BAKED)"

    git -C "$src" init -q 2>/dev/null || { perr "git init failed."; return 1; }
    git -C "$src" remote add origin "$upstream" 2>/dev/null \
        || git -C "$src" remote set-url origin "$upstream" 2>/dev/null || true

    # Always need origin/$SELF_BRANCH to align onto.
    SELF_PULL_HAVE_MASTER=0
    git -C "$src" fetch --depth 200 origin "$SELF_BRANCH" 2>/dev/null && SELF_PULL_HAVE_MASTER=1
    # Unknown baked commit (no marker): find the origin commit whose bin/ and lib/ equal this tree's, and treat that as
    # the base. Everything else that differs then shows up as local edits (stashed and restored), never discarded.
    if [[ "$SELF_PULL_BAKED" == unknown ]] && (( SELF_PULL_HAVE_MASTER )); then
        local m; m="$(self_find_matching_commit "$src")"
        if [[ -n "$m" ]]; then SELF_PULL_BAKED="$m"; plog "  matched baked tree to origin commit ${m:0:12}"
        else pwarn "No origin commit matches this tree's bin/ and lib/ - attaching on the branch tip."; fi
    fi
    # A failed fetch is NOT an error here — the fallback below reports it with
    # the right message. Without this `return 0` the `&&` above would become
    # the return value and abort the attach on a perfectly normal offline run.
    return 0
}

# The origin/$SELF_BRANCH commit whose bin/ and lib/ trees equal the working files' (prints its sha, or nothing).
# Needs the commits: deepens the fetch (SELF_MATCH_DEPTH, default 1500). Read-only on the files; uses a temp index.
self_find_matching_commit() {
    local src="$1" idx t_bin t_lib c
    idx="$(mktemp)"; rm -f "$idx"
    git -C "$src" fetch -q --depth "${SELF_MATCH_DEPTH:-1500}" origin "$SELF_BRANCH" 2>/dev/null || true
    t_bin="$(GIT_INDEX_FILE=$idx git -C "$src" --work-tree="$src" add -A bin >/dev/null 2>&1 && GIT_INDEX_FILE=$idx git -C "$src" write-tree --prefix=bin/ 2>/dev/null)"
    t_lib="$(GIT_INDEX_FILE=$idx git -C "$src" --work-tree="$src" add -A lib >/dev/null 2>&1 && GIT_INDEX_FILE=$idx git -C "$src" write-tree --prefix=lib/ 2>/dev/null)"
    rm -f "$idx"
    [[ -n "$t_bin" && -n "$t_lib" ]] || return 0
    for c in $(git -C "$src" rev-list "origin/$SELF_BRANCH" -- bin lib 2>/dev/null); do
        [[ "$(git -C "$src" rev-parse "$c:bin" 2>/dev/null)" == "$t_bin" && "$(git -C "$src" rev-parse "$c:lib" 2>/dev/null)" == "$t_lib" ]] \
            && { printf '%s\n' "$c"; return 0; }
    done
    return 0
}

# Can we align onto the TRUE baked base? Ensures the baked commit is present
# (depth fallback → an explicit fetch of it) and that origin/$SELF_BRANCH arrived.
# Non-zero means "not usable" — the caller falls back to the master-only path.
self_pull_have_base() {
    local src="$1" baked="$2"
    [[ "$baked" != "unknown" && -n "$baked" ]] || return 1
    git -C "$src" cat-file -e "${baked}^{commit}" 2>/dev/null \
        || git -C "$src" fetch --depth 200 origin "$baked" 2>/dev/null || true
    git -C "$src" cat-file -e "${baked}^{commit}" 2>/dev/null || return 1
    (( SELF_PULL_HAVE_MASTER ))
}

# ── Case B, step 2: align onto origin/$SELF_BRANCH FROM the baked base ──
# Returns SELF_PULL_SKIP (90) when the baked base is unusable, so the caller
# can fall through — any other code is this phase's final answer.
SELF_PULL_SKIP=90
self_pull_align_baked() {
    local src="$1" baked="$2"
    self_pull_have_base "$src" "$baked" || return "$SELF_PULL_SKIP"

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
    if ! git -C "$src" checkout -B "$SELF_BRANCH" origin/$SELF_BRANCH >/dev/null 2>&1; then
        perr "checkout of origin/$SELF_BRANCH failed."
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
}

# ── Case B, fallback: baked SHA unknown/unfetchable. NEVER force over edits. ──
# Without the true base we can't perfectly separate edits from a pristine
# bundle. Seed the index from origin/$SELF_BRANCH and REFUSE if anything differs.
self_pull_align_master() {
    local src="$1"
    if (( ! SELF_PULL_HAVE_MASTER )); then
        perr "Couldn't fetch upstream (network/auth?)."
        perr "Set up auth (gh auth login) or deploy locally: powos update self --from /path"
        return 1
    fi
    git -C "$src" reset --mixed origin/$SELF_BRANCH >/dev/null 2>&1 || true
    if self_git_dirty "$src"; then
        perr "Baked base commit is unknown and the tree differs from origin/$SELF_BRANCH."
        perr "Refusing to reset — that could discard local edits. Your files are UNTOUCHED."
        perr "Commit or copy your changes out of $src first, then re-run:"
        perr "  (cd $src && git add -A && git commit -m 'my edits')   # then: powos self pull"
        return 1
    fi
    # Clean tree → safe to align with master (no data to lose).
    if ! git -C "$src" checkout -B "$SELF_BRANCH" origin/$SELF_BRANCH >/dev/null 2>&1; then
        perr "checkout of origin/$SELF_BRANCH failed."
        return 1
    fi
    pok "Attached to upstream (no local edits detected)."
    return 0
}

self_safe_pull() {
    local src="${1:-$SELF_SRC}"
    local upstream="${POWOS_UPSTREAM:-$SELF_UPSTREAM}"

    if [[ ! -d "$src" ]]; then
        perr "PowOS source not found at: $src"
        return 1
    fi

    [[ -d "$src/.git" ]] && { self_pull_existing "$src"; return $?; }

    self_pull_attach "$src" "$upstream" || return 1

    local rc
    self_pull_align_baked "$src" "$SELF_PULL_BAKED"; rc=$?
    (( rc == SELF_PULL_SKIP )) || return "$rc"

    self_pull_align_master "$src"
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
        local ab; ab="$(git -C "$src" rev-list --left-right --count "origin/$SELF_BRANCH...HEAD" 2>/dev/null)"
        if [[ -n "$ab" ]]; then
            local behind="${ab%%[[:space:]]*}" ahead="${ab##*[[:space:]]}"
            echo "vs origin/$SELF_BRANCH: $ahead ahead, $behind behind"
        fi
    else
        echo "Git:           not attached (bundled snapshot)"
        echo "Run 'powos self pull' once to attach to upstream."
    fi
}

# ══════════════════════════════════════════════════════════════════
# phone apply / update — no composefs, no bootc: copy bin+lib from the tree
# ══════════════════════════════════════════════════════════════════
# Apply the tree at $1 to the running phone (HEAD's sha when it is a checkout, else the baked marker).
self_phone_apply_tree() {
    local src="${1:-$SELF_SRC}" sha
    sha="$(git -C "$src" rev-parse HEAD 2>/dev/null || self_baked_sha)"
    self_phone_apply "$src" "$sha" || return 1
    pok "Applied ${sha:0:12} from $src (bin/, lib/, revision, marker)."
}

# `powos self apply` (phone): deploy the CURRENT working tree, uncommitted edits included. Saves a rollback point first.
self_apply() {
    local src="${1:-$SELF_SRC}"
    self_is_phone || { self_test "$src"; return $?; }
    [[ -d "$src/bin" && -d "$src/lib" ]] || { perr "$src has no bin/ and lib/."; return 1; }
    self_phone_snapshot "$src" || { perr "Could not save a rollback point - nothing applied."; return 1; }
    plog "Rollback point saved (powos self rollback restores it)."
    self_phone_apply_tree "$src" || { pwarn "Apply failed part-way; rolling back."; self_phone_rollback; return 1; }
    if self_git_dirty "$src"; then
        git -C "$src" status --short > /usr/share/powos/applied-wip 2>/dev/null
        pwarn "Applied with uncommitted edits ($(wc -l < /usr/share/powos/applied-wip) paths) - listed in /usr/share/powos/applied-wip."
    else rm -f /usr/share/powos/applied-wip; fi
    plog "Next: powos self check"
}

self_rollback() {
    self_is_phone || { perr "powos self rollback is phone-only (the desktop test overlay reverts on reboot)."; return 1; }
    self_phone_rollback && pok "Rolled back to the state before the last 'powos self apply'."
}

# `powos self check [names]`: on-device checks of the applied state. Runs only what works on the phone itself.
#   applied   installed bin/lib equal the source tree (the apply took, nothing drifted)
#   syntax    bash -n on every shell script in bin/ and lib/
#   cli       the installed `powos` runs (help, self status)
#   self      test/tier1/test-self.sh      manifest  test/tier1/test-self-manifest.sh
# Not run here (need the Mac + adb): tools/phone/verify/*.sh, UI/gesture checks, the web shell, the APK.
SELF_CHECKS="applied syntax cli self manifest"
# Each check prints its findings and returns non-zero on failure.
self_check_applied() {
    local f g
    for f in $(cd "$SELF_SRC" && self_phone_files "$SELF_SRC" | grep -v '^usr/share\|\.powos-src-commit'); do
        g="${f/#usr\/bin\//bin/}"; g="${g/#usr\/lib\/powos\//lib/}"
        cmp -s "$SELF_SRC/$g" "$SELF_CHECK_ROOT/$f" || echo "differs: $f"
    done
}
self_check_syntax() {
    local f
    for f in $(cd "$SELF_SRC" && { git ls-files bin lib 2>/dev/null || find bin lib -type f; }); do
        head -c 80 "$SELF_SRC/$f" | grep -q '^#!.*\(ba\)\?sh' || continue
        bash -n "$SELF_SRC/$f" 2>&1 || echo "syntax: $f"
    done
}
self_check_cli() { "$SELF_CHECK_ROOT/usr/bin/powos" help 2>&1 | head -3; "$SELF_CHECK_ROOT/usr/bin/powos" self status >/dev/null 2>&1 || echo "powos self status failed"; }
self_check_self() { bash "$SELF_SRC/test/tier1/test-self.sh" 2>&1 | tail -5; }
self_check_manifest() { bash "$SELF_SRC/test/tier1/test-self-manifest.sh" 2>&1 | tail -5; }

# A check fails when its output says so (differs/syntax/failed/FAIL).
self_check() {
    local names=("$@") n out fails=0
    SELF_CHECK_ROOT="${SELF_CHECK_ROOT:-}"
    [[ ${#names[@]} -gt 0 ]] || names=($SELF_CHECKS)
    for n in "${names[@]}"; do
        declare -F "self_check_$n" >/dev/null || { perr "Unknown check: $n (have: $SELF_CHECKS)"; return 2; }
        out="$("self_check_$n")"
        if grep -q 'differs:\|syntax:\|failed\|FAIL' <<<"$out"; then
            perr "check $n: FAIL"; printf '%s\n' "$out" | self_indent; fails=$((fails+1))
        else pok "check $n: ok"; fi
    done
    (( fails )) && { perr "$fails check(s) failed - 'powos self rollback' restores the previous state."; return 1; }
    plog "Local checks passed. Still needs the Mac: tools/phone/verify/*.sh (adb-driven UI checks)."
}

# `powos self update` / `powos update self` on the phone: fast-forward the editable tree (local edits are stashed and
# restored), then apply FROM it. A failed fetch stops before anything is applied.
self_phone_update() {
    local src="${1:-$SELF_SRC}"
    self_safe_pull "$src" || { perr "Update not applied; the running PowOS is unchanged."; return 1; }
    self_phone_apply_tree "$src"
}

# `powos self update`: pull, then apply (the phone's way, or the desktop's transient test).
self_update() {
    plog "source: $1"
    if self_is_phone; then self_phone_update "$1"; else self_safe_pull "$1" && self_test "$1"; fi
}

# ══════════════════════════════════════════════════════════════════
# test — transient live apply of local edits to the running system
# ══════════════════════════════════════════════════════════════════
self_test() {
    local src="${1:-$SELF_SRC}"
    [[ -d "$src" ]] || { perr "Source not found: $src"; return 1; }

    self_is_phone && { self_phone_apply_tree "$src"; return $?; }
    local powos_bin; powos_bin="$(command -v powos 2>/dev/null || echo powos)"

    # Merged sysext extensions sit as a READ-ONLY overlay on /usr — they must
    # be unmerged BEFORE we probe writability or engage bootc usr-overlay, or
    # the probe falsely reports "read-only" even on an unlocked deployment.
    # Same ordering as `powos update self` (which already did this right).
    sysext_unmerge_if_needed

    if self_usr_ro; then
        pwarn "/usr is read-only (installed composefs) — enabling a writable overlay."
        pwarn "This AUTO-REVERTS on the next reboot (bootc usr-overlay)."
        if ! command -v bootc >/dev/null 2>&1; then
            sysext_remerge_if_needed
            perr "bootc not found — can't make /usr writable transiently."
            perr "Use a live/RAM system, or make it durable with 'powos reload'."
            return 1
        fi
        if ! sudo bootc usr-overlay 2>&1 | self_indent; then
            sysext_remerge_if_needed
            perr "bootc usr-overlay failed — /usr still read-only, nothing applied."
            return 1
        fi
        if self_usr_ro; then
            sysext_remerge_if_needed
            perr "/usr still read-only after usr-overlay — aborting (nothing applied)."
            return 1
        fi
        pok "Writable /usr overlay engaged (transient)."
    else
        plog "/usr is writable (live/RAM) — applying directly."
    fi

    plog "Applying $src to the RUNNING system…"
    # `update self` does its own sysext unmerge/remerge internally, but we
    # already unmerged above — it will see "none" and skip the unmerge, then
    # re-merge at the end. That's correct and idempotent.
    # Run via sudo so the sudoers rule for `powos update self` covers us —
    # the deploy writes to /usr via cp/mv/chmod/mkdir which need root.
    if sudo "$powos_bin" update self --from "$src"; then
        pok "Applied live from $src."
        pwarn "This is TRANSIENT: an installed composefs system reverts it on reboot."
        pwarn "Make it durable: 'powos self push' then rebuild, or 'powos reload --build'."
        return 0
    fi
    sysext_remerge_if_needed
    perr "Deploy failed — see output above."
    return 1
}

# git push; with no credentials, sign in by GitHub device code right here and retry once.
# No separate setup step. Prints git's output; returns git's status.
self_push_authed() {
    local src="$1" out rc
    out="$(GIT_TERMINAL_PROMPT=0 git -C "$src" push 2>&1)"; rc=$?
    if (( rc != 0 )) && grep -qiE "could not read (Username|Password)|Authentication failed|terminal prompts disabled|HTTP 40[13]|error: 40[13]" <<<"$out"; then
        plog "Not signed in to GitHub - starting device sign-in." >&2
        # shellcheck source=setup.sh
        source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/setup.sh"
        # The sign-in's code line must reach the user, so it goes to stderr, not into $out.
        if setup_gh_cmd >&2; then
            out="$(GIT_TERMINAL_PROMPT=0 git -C "$src" push 2>&1)"; rc=$?
        fi
    fi
    printf '%s\n' "$out"
    return "$rc"
}

# ══════════════════════════════════════════════════════════════════
# push — add/commit/push with human-friendly errors
# ══════════════════════════════════════════════════════════════════
self_push() {
    local src="${1:-$SELF_SRC}"; local msg="${2:-}"
    # Paths after the message: only those are staged and committed (a shared tree - several agents in one checkout -
    # must never sweep up what others staged or changed). None: the whole tree, as before.
    local paths=("${@:3}")
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

    if ((${#paths[@]})); then
        git -C "$src" add -- "${paths[@]}" || { perr "git add failed."; return 1; }
    else
        # Someone else's staged changes in the index: `add -A` + commit would ship them under this message. A tree
        # several agents share must commit by path (status --porcelain's index column: diff --cached --quiet below is the post-add-A check, not this one).
        if git -C "$src" status --porcelain 2>/dev/null | grep -qE '^[^ ?]'; then
            perr "Other changes are already staged in $src (another agent or tool?):"
            git -C "$src" diff --cached --name-status 2>/dev/null | self_indent
            perr "Commit only yours:  powos self push -m \"message\" -- <your files>"
            return 1
        fi
        git -C "$src" add -A || { perr "git add failed."; return 1; }
    fi
    if git -C "$src" diff --cached --quiet -- "${paths[@]}" 2>/dev/null; then
        pwarn "Nothing staged — working tree already matches HEAD; pushing anyway."
    else
        # Transparency: `add -A` stages the ENTIRE tree, so a stray/unrelated edit
        # can ride along under a single-purpose message (happened 2026-07-07 — an
        # unrelated vortex.sh change shipped under a mods-fix commit). Always show
        # exactly what's about to be committed so it's a choice, not a surprise.
        plog "Committing these files:"
        git -C "$src" diff --cached --name-status -- "${paths[@]}" 2>/dev/null | self_indent
        # Let git stamp the commit date itself (no build-time timestamp baked in).
        if ! git -C "$src" commit -m "$msg" -- "${paths[@]}" 2>&1 | self_indent; then
            perr "git commit failed."
            return 1
        fi
    fi

    plog "Pushing to remote…"
    local out rc
    out="$(self_push_authed "$src")"; rc=$?
    if (( rc != 0 )); then
        printf '%s\n' "$out" | self_indent
        perr "Push failed. Common fixes:"
        perr "  • No remote/upstream:  git -C $src remote -v   (or run 'powos self pull' to attach)"
        perr "  • Not authenticated:   run 'powos login github' (or 'gh auth login'), or configure a git credential helper"
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

  powos self apply    Phone: deploy the working tree (uncommitted edits too); saves a rollback point
  powos self rollback Phone: restore the state before the last apply
  powos self check [names]  Phone: on-device checks (applied syntax cli self manifest)
  powos self status   Baked commit, git attach state, local edits, ahead/behind
  powos self test     Apply local /var/lib/powos/src edits to THIS running system
                      (transient; auto-reverts on reboot on installed composefs)
  powos self pull     SAFE update from upstream (never discards local edits)
  powos self push     commit + push  (-m "message" [-- <paths>]: only those files; no paths = whole tree)
                      --ship "note" [--task ID]: then ask the Mac ship service to ship that sha
  powos self reseed   Wipe /var/lib/powos/src and re-copy from the CURRENT image
                      snapshot at /usr/lib/powos/src. Use after bootc-switch when
                      the /var tree was inherited from an older PowOS install and
                      self pull is misidentifying stale carry-over as local edits.
                      Backs up the old tree to /var/lib/powos/src.stale-<sha>-<ts>.
EOF
}

# ── push --ship: ask the Mac ship service to ship what we just pushed ──────────
# The Mac runs tools/phone/ship-gate.py (unit ship-gate-mac). Config, never a value in git:
#   POWOS_SHIP_GATE_URL   (default http://192.168.50.99:7433; or "url=" in the conf file)
#   POWOS_SHIP_GATE_SECRET_FILE (default ~/.config/powos/ship-gate.secret, mode 0600: the Mac's same file)
self_ship_conf() {   # echoes "URL<TAB>SECRET_FILE"
    local conf="${POWOS_SHIP_GATE_CONF:-$HOME/.config/powos/ship-gate.conf}" url=""
    [[ -r "$conf" ]] && url="$(sed -n 's/^url=//p' "$conf" | head -1)"
    printf '%s\t%s\n' "${POWOS_SHIP_GATE_URL:-${url:-http://192.168.50.99:7433}}" \
        "${POWOS_SHIP_GATE_SECRET_FILE:-$HOME/.config/powos/ship-gate.secret}"
}

# self_ship_post URL SECRET_FILE JSON: the secret goes to curl on stdin as a header (never argv, never printed).
# Echoes "HTTP_CODE<NL>BODY"; curl failure (unreachable) returns 7.
self_ship_post() {
    local out
    out="$(printf 'Authorization: Bearer %s\n' "$(tr -d '\r\n' <"$2")" | curl -sS --max-time 70 -H @- \
        -H 'Content-Type: application/json' -d "$3" -w '\n%{http_code}' "$1/request" 2>&1)" || { printf '%s\n' "$out"; return 7; }
    printf '%s\n%s\n' "${out##*$'\n'}" "${out%$'\n'*}"
}

# self_json_str TEXT: TEXT escaped for the inside of a JSON string (no python/jq needed on the phone).
self_json_str() {
    local t="$1"; t="${t//\\/\\\\}"; t="${t//\"/\\\"}"; t="${t//$'\n'/ }"; t="${t//$'\t'/ }"; t="${t//$'\r'/ }"
    printf '%s' "$t"
}

# self_ship_request SRC NOTE [TASK]: after a successful push. The push stays done whatever happens here.
self_ship_request() {
    local src="$1" note="$2" task="${3:-}" url sf sha dev json res code body
    IFS=$'\t' read -r url sf < <(self_ship_conf)
    [[ -r "$sf" ]] || { perr "Pushed, but not shipped: no ship secret at $sf (copy the Mac's ~/.config/powos/ship-gate.secret there, chmod 600)."; return 1; }
    sha="$(git -C "$src" rev-parse HEAD)"; dev="$(hostname 2>/dev/null | tr -c 'A-Za-z0-9._\n-' '-')"
    json="$(printf '{"sha":"%s","note":"%s","task":"%s","from":"%s"}' "$sha" "$(self_json_str "$note")" \
        "$(self_json_str "$task")" "${dev:-phone}")"
    res="$(self_ship_post "$url" "$sf" "$json")" || { perr "Pushed, but the Mac ship service is unreachable at $url: ${res:0:200}"; perr "Ship later from the Mac: tools/phone/ship.sh request --note \"...\""; return 1; }
    code="${res%%$'\n'*}"; body="${res#*$'\n'}"
    case "$code" in
        200) pok "Ship requested for ${sha:0:9}: id $(printf '%s' "$body" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')"
             plog "Status: curl -H @<(secret header) $url/status   (or on the Mac: tools/phone/ship.sh status)" ;;
        401) perr "Pushed, but the ship service rejected the secret (does $sf match the Mac's?)."; return 1 ;;
        403) perr "Pushed, but the Mac says ${sha:0:9} is not on origin yet: $body"; return 1 ;;
        *)   perr "Pushed, but the ship request failed (HTTP $code): ${body:0:300}"; return 1 ;;
    esac
}

# `powos self push [-m msg] [--ship NOTE] [--task ID] [-- paths]`
self_push_args() {
    local msg="" paths=() ship="" task=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--message) msg="${2:-}"; shift 2 ;;
            --ship) ship="${2:-}"; shift 2 ;;
            --task) task="${2:-}"; shift 2 ;;
            --) shift; paths+=("$@"); break ;;
            *) paths+=("$1"); shift ;;
        esac
    done
    if [[ -z "$msg" ]] && [[ -t 0 ]]; then
        read -rp "Commit message [PowOS self: sync local changes]: " msg || true
    fi
    self_push "$SELF_SRC" "$msg" "${paths[@]}" || return 1
    [[ -z "$ship" ]] || self_ship_request "$SELF_SRC" "$ship" "$task"
}

cmd_self() {
    local sub="${1:-help}"; shift || true

    # Say WHICH tree we resolved, and shout if it is behind upstream. Both of
    # these were invisible before: `self` silently used the bundled snapshot and
    # never checked freshness, so it could apply, commit and push days-old code
    # while the real checkout sat elsewhere, fully up to date.
    case "$sub" in
        status|st|test|t|pull|push|reseed|apply|rollback|check)
            plog "source: $SELF_SRC"
            powos_src_staleness "$SELF_SRC"
            ;;
    esac

    case "$sub" in
        status|st)  self_status "$SELF_SRC" ;;
        test|t)     self_test "$SELF_SRC" ;;
        apply)      self_apply "$SELF_SRC" ;;
        rollback)   self_rollback ;;
        check)      self_check "$@" ;;
        pull|update) "self_${sub/pull/safe_pull}" "$SELF_SRC" ;;
        reseed)     self_reseed "$SELF_SRC" ;;
        push)       self_push_args "$@" ;;
        help|-h|--help|"") self_usage ;;
        *) perr "Unknown: powos self $sub"; self_usage; return 1 ;;
    esac
}
