#!/bin/bash
# Builds the PowOS Android app (targets/android/app: Omalauncher fork + Andromarchy engine) in android-app-dev's
# builder image. Output: targets/android/out/apk/powos-<variant>.apk
#
# Usage: targets/android/build-app.sh [debug|release]   (default: debug)
#
# - The image's SDK (platform 36, build-tools 35) is copied once into the persistent volume powos-android-sdk,
#   where AGP adds what it needs itself (platform 37, NDK 28.2, CMake). The NDK/CMake host tools are x86_64
#   Linux only; on this arm64 Colima VM they run through Rosetta's binfmt.
# - Gradle's caches live in the persistent volume powos-android-gradle (separate from android-app-dev's own).
# - The debug signing key lives in powos-android-keys (/root/.android): one key across builds, so an update
#   installs over the previous APK instead of failing with INSTALL_FAILED_UPDATE_INCOMPATIBLE.
# - The sources are copied into the container first: building on the macOS bind mount hits VirtioFS
#   ENOMEM (see android-app-dev's notes), and keeps build dirs out of the repo.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VARIANT=${1:-debug}
OUT=$HERE/out/apk
mkdir -p "$OUT"
IMAGE=android-app-dev-android-builder:latest

# Shared Docker disk (live services): the first build adds ~6 GB of SDK/NDK/Gradle caches.
free_gb=$(docker run --rm --entrypoint df "$IMAGE" -BG --output=avail /etc/hostname | tail -1 | tr -dc '0-9')
[ "${free_gb:-0}" -ge 12 ] || { echo "only ${free_gb} GB free on the Docker disk; need 12 GB" >&2; exit 1; }

task=assemble$(tr '[:lower:]' '[:upper:]' <<< "${VARIANT:0:1}")${VARIANT:1}
docker run --rm --cpus 8 --memory 12g --entrypoint /bin/bash \
  -v powos-android-sdk:/sdk -v powos-android-gradle:/root/.gradle -v powos-android-keys:/root/.android \
  -v "$HERE/app:/src:ro" -v "$OUT:/out" -e TASK="$task" -e VARIANT="$VARIANT" "$IMAGE" -c '
    set -euo pipefail
    [ -d /sdk/platforms ] || cp -a /opt/android-sdk/. /sdk/
    yes | /sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=/sdk --licenses >/dev/null 2>&1 || true
    rm -rf /work && cp -a /src /work && cd /work
    printf "sdk.dir=/sdk\n" > local.properties
    ./gradlew --no-daemon -q ":app:$TASK" 2>&1 | tail -40
    apk=$(ls app/build/outputs/apk/$VARIANT/*.apk | head -1)
    cp "$apk" /out/powos-$VARIANT.apk && ls -la /out/powos-$VARIANT.apk'

# Publish to the PowApps store (android-app-dev's output/, served at http://android.pow/apk/): phones install and
# update it from there, on the LAN or over the WireGuard VPN. POWOS_STORE= (empty) skips it.
STORE=${POWOS_STORE-$HOME/Projects/android-app-dev/output}
if [ -n "$STORE" ] && [ -d "$STORE" ]; then
  cp "$OUT/powos-$VARIANT.apk" "$STORE/powos-$VARIANT.apk.tmp"
  mv "$STORE/powos-$VARIANT.apk.tmp" "$STORE/powos-$VARIANT.apk"
  echo "published: http://android.pow/apk/powos-$VARIANT.apk"
fi
