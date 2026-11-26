#!/usr/bin/env bash
# Additive Android client target. Never consumes the mutable Linux layer checkout.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
source "$here/source.conf"
src="$here/upstream/android-$ANDROID_CLIENT_REV"
stage="$root/targets/android/app/engine/powstream-native"
# The staged output of this pinned revision, once built, from the Mac-side build-inputs cache (tools/agents/
# build-inputs-cache.sh, keyed by the revision): a fresh worktree took ~4 min here (clone + the Rust job) for bytes
# every checkout of this rev gets identically, and agents hand-copied them between worktrees instead (11-25).
# Extracted from a tar (new files), so nothing written here can reach the cached blob through a hardlink.
# POWSTREAM_NO_CACHE=1 builds from source anyway (and refreshes the cache).
bic="$root/tools/agents/build-inputs-cache.sh" key="powstream-native/$ANDROID_CLIENT_REV.tar"
if [ -z "${POWSTREAM_NO_CACHE:-}" ] && [ -x "$bic" ]; then
    t=$(mktemp -d)
    if "$bic" get "$key" "$t/n.tar" >/dev/null 2>&1; then
        rm -rf "$stage" && mkdir -p "$stage" && tar -xf "$t/n.tar" -C "$stage"
        rm -rf "$t"
        if [ "$(cat "$stage/include/powstream-source-revision" 2>/dev/null)" = "$ANDROID_CLIENT_REV" ] &&
           [ -s "$stage/arm64-v8a/libpowstream_client_core.so" ] && [ -s "$stage/include/powstream_client_core.h" ]; then
            echo "powstream: staged $ANDROID_CLIENT_REV from the build-inputs cache ($key)"; exit 0
        fi
        echo "powstream: cached $key is incomplete - building from source" >&2
    fi
    rm -rf "$t"
fi
# The pinned rev comes from the local checkout when it has it (source.conf: local preferred). The private GitHub
# repo over https needs credentials the launchd ship-runner never has: 11-18 every APK ship failed rc 5 at this
# clone ("could not read Username for 'https://github.com'"). The checkout is only read (clone --no-local copies
# objects; its working tree is never touched), so the mutable Linux dev checkout stays independent.
from=$UPSTREAM_URL
git -C "$LOCAL_CHECKOUT" cat-file -e "$ANDROID_CLIENT_REV^{commit}" 2>/dev/null && from=$LOCAL_CHECKOUT
if [ ! -d "$src/.git" ]; then
    git clone --no-local "$from" "$src"
fi
git -C "$src" cat-file -e "$ANDROID_CLIENT_REV^{commit}" 2>/dev/null || git -C "$src" fetch "$from" "$ANDROID_CLIENT_REV"
[ -z "$(git -C "$src" status --porcelain --untracked-files=no)" ] || { echo 'Dirty PowStream source refused' >&2; exit 1; }
git -C "$src" checkout --detach "$ANDROID_CLIENT_REV"
[ "$(git -C "$src" rev-parse HEAD)" = "$ANDROID_CLIENT_REV" ]
[ -z "$(git -C "$src" status --porcelain --untracked-files=no)" ] || { echo 'Dirty PowStream source refused' >&2; exit 1; }
# The canonical PowStream job normally finds fleet repos relative to its git common dir.
export POW_JOB_RUNNER="$root/tools/jobs/job.sh"
export POW_COMPOSE_WRAPPER="${POW_COMPOSE_WRAPPER:-$HOME/Projects/PowStation/bin/pow-compose}"
export POW_JOB_CONTEXT=pow58 ANDROID_API=29
bash "$src/scripts/build-rust.sh" --android-client-core
out="$src/target/aarch64-linux-android/release"
mkdir -p "$stage/arm64-v8a" "$stage/include"
# Original SONAME and authoritative header, generated only by the pinned source build.
cp "$out/libpowstream_client_core.so" "$stage/arm64-v8a/"
cp "$out/powstream_client_core.h" "$stage/include/"
printf '%s\n' "$ANDROID_CLIENT_REV" > "$stage/include/powstream-source-revision"
# Into the cache for the next checkout of this revision (best-effort: a full disk only costs the next one a build).
if [ -x "$bic" ]; then
    t=$(mktemp -d)
    tar -cf "$t/n.tar" -C "$stage" arm64-v8a/libpowstream_client_core.so include/powstream_client_core.h include/powstream-source-revision &&
        "$bic" put "$t/n.tar" "$key" >/dev/null || echo "powstream: couldn't cache $key (next checkout builds again)" >&2
    rm -rf "$t"
fi
