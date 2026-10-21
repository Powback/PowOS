#!/bin/bash
# Review images to the phone, for the manager to look at before a push: /home/powos/design-qa/ inside PowOS
# (/data/powos/root/home/powos/design-qa, owned by the PowOS user 10359).
#   tools/phone/review-image.sh FILE...
# Copies through the VPN's adb (the wireguard container), $POWOS_PHONE_ADDR or 10.13.13.7:5555. Files under $HOME.
set -euo pipefail
[ $# -gt 0 ] || { sed -n '2,6p' "$0"; exit 1; }
addr=${POWOS_PHONE_ADDR:-10.13.13.7:5555}
for f in "$@"; do
  p=$(cd "$(dirname "$f")" && pwd)/$(basename "$f"); b=$(basename "$f")
  docker run --rm --network container:wireguard -v "$HOME/.android:/root/.android" -v "$p:/x/$b:ro" -e S="$addr" -e B="$b" \
    android-app-dev-android-builder:latest bash -c 'adb connect $S >/dev/null 2>&1; adb -s $S push -q "/x/$B" "/data/local/tmp/dqa-$B" &&
      adb -s $S shell "su -c \"mkdir -p /data/powos/root/home/powos/design-qa && mv /data/local/tmp/dqa-$B /data/powos/root/home/powos/design-qa/$B && chown -R 10359:10359 /data/powos/root/home/powos/design-qa\"" &&
      echo "on phone: /home/powos/design-qa/$B"'
done
