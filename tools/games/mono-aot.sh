#!/bin/bash
# tools/games/mono-aot.sh fetch|build|push|all <appid> - Mono AOT images for a legacy-Mono Unity game, built OFF the phone.
#
# WHY: ~8 s of Broforce's tap->frame is Unity/Mono init + first scene; under FEX every method Mono JITs is fresh
# anonymous code FEX compiles again each launch. AOT images are file-backed x86-64 code (FEX's DiskCache keeps it) and
# skip Mono's JIT (docs/research/broforce-engine-init.md, lever 2, with the feasibility evidence).
#
#   fetch  copies the game's <X>_Data/Managed + <X>_Data/Mono from the phone (read-only tar) to the NAS
#   build  on .58 (podman): the game's OWN mono.dll under Wine AOT-compiles every Managed/*.dll, mingw links each into
#          <asm>.dll.dll, + images.tsv (image path, source assembly sha256, GUID)   (tools/games/mono-aot/build.sh)
#   push   copies images + images.tsv into the phone's per-game store ~/.local/share/powos/mono-aot/<appid>/ (the game
#          dir is not touched; `powos game <appid> aot on|off` places/removes the images there)
#   all    fetch + build + push
# Big files live on the NAS: $MONO_AOT_CDN/<appid>/{game,build} (default /mnt/nas/cdn/powos/mono-aot), via .58.
# Only the default Steam library on the phone (steamapps/common/<installdir>).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
verb=${1:-}; app=${2:-}
[[ "$verb" =~ ^(fetch|build|push|all)$ && "$app" =~ ^[0-9]+$ ]] || { sed -n '2,16p' "$0" >&2; exit 2; }
HOST=${MONO_AOT_HOST:-powos@192.168.50.58}
CDN=${MONO_AOT_CDN:-/mnt/nas/cdn/powos/mono-aot}/$app
SERIAL=${PHONE_SERIAL:-${POWOS_PHONE_ADDR:-10.13.13.7:5555}}
PHOME=/data/powos/root/home/powos
STEAM=$PHOME/.local/share/Steam
IMG=localhost/powos-mono-aot:1
adb() { docker exec -i powos-vadb adb -s "$SERIAL" "$@"; }
rsh() { ssh -o BatchMode=yes "$HOST" "$@"; }

fetch() {
  local dir
  dir=$(adb exec-out su -c "sed -n 's/.*\"installdir\"[[:space:]]*\"\\(.*\\)\".*/\\1/p' $STEAM/steamapps/appmanifest_$app.acf" | tr -d '\r')
  [ -n "$dir" ] || { echo "mono-aot: appid $app isn't installed in the phone's default Steam library" >&2; exit 1; }
  adb exec-out su -c "ls -d '$STEAM/steamapps/common/$dir'/*_Data/Mono/EmbedRuntime/mono.dll" >/dev/null 2>&1 ||
    { echo "mono-aot: $dir has no <X>_Data/Mono/EmbedRuntime/mono.dll (not legacy-Mono Unity)" >&2; exit 1; }
  echo "fetch: $dir -> $HOST:$CDN/game"
  rsh "rm -rf '$CDN/game' && mkdir -p '$CDN/game'"
  adb exec-out su -c "cd '$STEAM/steamapps/common/$dir' && tar cf - *_Data/Managed *_Data/Mono" | rsh "tar xf - -C '$CDN/game'"
}

build() {
  local t=/tmp/powos-mono-aot-$app
  rsh "rm -rf $t && mkdir -p $t"
  scp -q "$HERE/mono-aot/Containerfile" "$HERE/mono-aot/loader.c" "$HERE/mono-aot/build.sh" "$HOST:$t/"
  rsh "podman image exists $IMG || podman build -q -t $IMG -f $t/Containerfile $t" >/dev/null
  rsh "podman run --rm --security-opt label=disable -v $t:/t:ro -v '$CDN/game':/g:ro -v '$CDN':/o $IMG /t/build.sh /g /o/build.new ${MONO_AOT_JOBS:-12} && rm -rf '$CDN/build' && mv '$CDN/build.new' '$CDN/build'; rc=\$?; rm -rf $t; exit \$rc"
}

push() {
  local st=$PHOME/.local/share/powos/mono-aot/$app own
  own=$(adb exec-out su -c "stat -c %u:%g $PHOME" | tr -d '\r')
  echo "push: $HOST:$CDN/build -> phone $st (owner $own)"
  rsh "tar cf - -C '$CDN/build' images images.tsv" |
    adb exec-in su -c "rm -rf '$st.new' && mkdir -p '$st.new' && tar xf - -C '$st.new' && chown -R $own '$st.new' && rm -rf '$st/images' '$st/images.tsv' && mkdir -p '$st' && mv '$st.new/images' '$st.new/images.tsv' '$st/' && rmdir '$st.new' && chown $own '$st' '$(dirname "$st")'"
  echo "push: done; turn it on with: powos game $app aot on"
}

case $verb in
  fetch) fetch ;; build) build ;; push) push ;;
  all) fetch; build; push ;;
esac
