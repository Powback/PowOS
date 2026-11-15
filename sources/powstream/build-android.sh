#!/usr/bin/env bash
# Additive Android client target. Never consumes the mutable Linux layer checkout.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
source "$here/source.conf"
src="$here/upstream/android-$ANDROID_CLIENT_REV"
if [ ! -d "$src/.git" ]; then
    git clone "$UPSTREAM_URL" "$src"
fi
git -C "$src" cat-file -e "$ANDROID_CLIENT_REV^{commit}" 2>/dev/null || git -C "$src" fetch origin "$ANDROID_CLIENT_REV"
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
stage="$root/targets/android/app/engine/powstream-native"
mkdir -p "$stage/arm64-v8a" "$stage/include"
# Original SONAME and authoritative header, generated only by the pinned source build.
cp "$out/libpowstream_client_core.so" "$stage/arm64-v8a/"
cp "$out/powstream_client_core.h" "$stage/include/"
printf '%s\n' "$ANDROID_CLIENT_REV" > "$stage/include/powstream-source-revision"
