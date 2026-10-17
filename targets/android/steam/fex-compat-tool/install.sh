#!/bin/bash
# Puts out/usr/bin/{FEX,FEXServer,FEXServerManager} (Valve's FEX commit + the futex_waitv probe, see build.sh) into the phone's Steam
# FEX tool. All three from one build: they talk to each other, and a mixed set failed ("Failure to setup client").
#
# HACK: this overwrites files Steam manages (steamapps/common/FEX-Emu/usr/bin/). Steam ignores custom tools for its
# "fex" emulation layer, so there is no supported place for our build. A Steam update of the tool puts Valve's binary
# back (games are slow again: re-run build.sh + this). Real fix: the probe upstream in FEX and in Valve's tool; then
# delete this directory. Valve's originals stay next to them as <name>.valve; --restore puts them back.
#
# Usage: targets/android/steam/fex-compat-tool/install.sh [--restore]   (phone over adb, ANDROID_SERIAL as usual)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
COMMIT=$(sed -n 's/^COMMIT=\${COMMIT:-\([0-9a-f]*\)}.*/\1/p' "$HERE/build.sh")
T=/data/powos/root/home/powos/.local/share/Steam/steamapps/common/FEX-Emu
S=$(mktemp)
if [ "${1:-}" = --restore ]; then
  cat > "$S" <<EOF
set -e
for b in FEX FEXServer FEXServerManager; do
  [ -f $T/usr/bin/\$b.valve ] || continue
  cp -p $T/usr/bin/\$b.valve $T/usr/bin/\$b.new && mv $T/usr/bin/\$b.new $T/usr/bin/\$b && echo "restored Valve's \$b"
done
EOF
else
  [ -f "$HERE/out/usr/bin/FEX" ] || { echo "no out/usr/bin/FEX: run build.sh first" >&2; exit 1; }
  for b in FEX FEXServer FEXServerManager; do adb push -q "$HERE/out/usr/bin/$b" /data/local/tmp/$b.powos; done
  cat > "$S" <<EOF
set -e
# Only over the exact Valve build ours was made from: another commit may differ in the FEX<->FEXServer protocol.
grep -q "$COMMIT" $T/VERSIONS.txt || { echo "Valve's tool is no longer $COMMIT (\$(grep describe $T/VERSIONS.txt)): rebuild with COMMIT=<its sha>"; exit 1; }
o=\$(stat -c %u:%g $T/usr/bin/FEX)
for b in FEX FEXServer FEXServerManager; do
  # Back up Valve's binary once (never overwrite the backup with ours).
  [ -f $T/usr/bin/\$b.valve ] || cp -p $T/usr/bin/\$b $T/usr/bin/\$b.valve
  # New file + rename: running games keep their mapped binary (a plain cp fails with "Text file busy").
  cp /data/local/tmp/\$b.powos $T/usr/bin/\$b.new && chown \$o $T/usr/bin/\$b.new && chmod 755 $T/usr/bin/\$b.new
  mv $T/usr/bin/\$b.new $T/usr/bin/\$b && rm -f /data/local/tmp/\$b.powos
  echo "installed \$b: \$(md5sum $T/usr/bin/\$b | cut -c1-12) (Valve's: \$(md5sum $T/usr/bin/\$b.valve | cut -c1-12))"
done
EOF
fi
"$HERE/../../rooted/rooted.sh" android "$S"
rm -f "$S"
