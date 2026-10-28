#!/bin/sh
# self-phone.sh - how the PHONE applies a PowOS source tree to itself. POSIX sh and no PowOS helpers: the rootfs
# build (install-powos-android.sh, inside the chroot), the rooted deploy (powos-deploy.sh, Android's sh) and
# `powos self` / `powos update self` on the phone all source this one file, so there is one copy routine.
#
# The phone has no composefs or bootc and its / is writable, so "apply" is just: bin/ -> /usr/bin, lib/ ->
# /usr/lib/powos, then the revision and the marker `powos self` reads. The desktop applier (self_apply_manifest)
# walks the Containerfile COPY map, which names desktop paths. Phone-only files (session, shims, plasmoids) are not
# in the source tree's bin/lib; the rootfs build and the rooted deploy own them.

# self_phone_apply SRC SHA [ROOT]: copy SRC/bin and SRC/lib into ROOT (default /) and stamp SHA.
self_phone_apply() {
    _sp_src=$1; _sp_sha=$2; _sp_root=${3:-}
    if [ ! -d "$_sp_src/bin" ] || [ ! -d "$_sp_src/lib" ]; then
        echo "self-phone: $_sp_src has no bin/ and lib/ - nothing applied" >&2; return 1
    fi
    mkdir -p "$_sp_root/usr/bin" "$_sp_root/usr/lib/powos" "$_sp_root/usr/share/powos" || return 1
    cp -a "$_sp_src/bin/." "$_sp_root/usr/bin/" || return 1
    cp -a "$_sp_src/lib/." "$_sp_root/usr/lib/powos/" || return 1
    printf '%s\n' "$_sp_sha" > "$_sp_root/usr/share/powos/revision"
    printf '%s\n' "$_sp_sha" > "$_sp_root/usr/lib/powos/.powos-src-commit"
}

# self_phone_seed SRC [ROOT]: the editable tree /var/lib/powos/src, only when absent (an existing one holds the
# user's edits and git state), and the branch `powos self` follows (upstream-branch, only when not set).
self_phone_seed() {
    _sp_src=$1; _sp_root=${2:-}
    if [ ! -e "$_sp_root/var/lib/powos/src" ]; then
        mkdir -p "$_sp_root/var/lib/powos" && cp -a "$_sp_src" "$_sp_root/var/lib/powos/src" || return 1
    fi
    grep -qs '^upstream-branch=' "$_sp_root/etc/powos/config" ||
        { mkdir -p "$_sp_root/etc/powos" && echo "upstream-branch=worktree-powos-multiplatform" >> "$_sp_root/etc/powos/config"; }
}

# self_phone_bake SRC SHA [ROOT]: what a fresh install does - apply, bake the read-only copy the marker describes
# (/usr/lib/powos/src), seed the editable one.
self_phone_bake() {
    _sp_src=$1; _sp_sha=$2; _sp_root=${3:-}
    self_phone_apply "$_sp_src" "$_sp_sha" "$_sp_root" || return 1
    rm -rf "$_sp_root/usr/lib/powos/src" && cp -a "$_sp_src" "$_sp_root/usr/lib/powos/src" || return 1
    self_phone_seed "$_sp_src" "$_sp_root"
}
