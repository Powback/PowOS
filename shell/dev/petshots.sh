#!/bin/bash
# The pet's states, rendered headless for review (shell/dev/petshots.mjs): a close-up per state + sheet.png in OUT.
#   shell/dev/petshots.sh [OUT]     OUT under $HOME (Colima mounts only the home folder); default ~/.cache/powos-petshots
#   env: PET_THEME, PET_STATES, PET_SCALE, PET_PERCH (see petshots.mjs). Then put OUT/sheet.png in
#   /home/powos/pet-review/<step>/ on the phone (tools/phone/adb.sh push + root.sh, chowned to the app) for the manager.
set -euo pipefail
dev=$(cd "$(dirname "$0")" && pwd)
out=${1:-$HOME/.cache/powos-petshots}
mkdir -p "$out"
out=$(cd "$out" && pwd)
# The shell as the working tree has it (node_modules left out), in a copy the container reads.
work=$(mktemp -d "$HOME/.cache/powos-petshots-shell.XXXXXX")
trap 'rm -rf "$work"' EXIT
(cd "$dev/.." && tar --exclude ./node_modules -cf - .) | tar -xf - -C "$work"
docker run --rm --platform linux/arm64 --shm-size 512m -v "$work:/shell:ro" -v "$dev/petshots.mjs:/usr/src/app/petshots.mjs:ro" \
  -v "$out:/out" ${PET_THEME:+-e PET_THEME="$PET_THEME"} ${PET_STATES:+-e PET_STATES="$PET_STATES"} ${PET_SCALE:+-e PET_SCALE="$PET_SCALE"} \
  ${PET_PERCH:+-e PET_PERCH="$PET_PERCH"} -w /usr/src/app --entrypoint node zenika/alpine-chrome:with-puppeteer petshots.mjs
echo "petshots: $out/sheet.png"
