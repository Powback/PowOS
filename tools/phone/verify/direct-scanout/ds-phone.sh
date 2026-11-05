# ds-phone.sh <dir> <layerStack> <displayId> <tag> [dstest args...]: (on the phone, root; direct-scanout.sh pushes it)
# runs DsTest under app_process and captures SurfaceFlinger's state + the display at its markers:
#   SHOWN      -> <tag>.sf-shown.txt (dumpsys SurfaceFlinger), <tag>.shown.raw / .png (screencap of that display)
#   FLIPPING   -> <tag>.sf-flip.txt one second into the A/B flips
#   SHOWN_END  -> <tag>.end.raw
D=$1; LS=$2; DID=$3; TAG=$4; shift 4
cd "$D" || exit 2
rm -f "$TAG".*
T0=$(date +"%m-%d %H:%M:%S.000")   # logcat since here (never logcat -c: the log is everyone's)
CLASSPATH=$D/dstest.dex app_process /system/bin DsTest "$D/libdstest.so" "$LS" "$@" > "$TAG.log" 2>&1 & p=$!
waitfor() { i=0; while ! grep -qx "$1" "$TAG.log"; do kill -0 $p 2>/dev/null || return 1; i=$((i+1)); [ $i -gt 300 ] && return 1; sleep 0.05; done; }
waitfor SHOWN && { dumpsys SurfaceFlinger > "$TAG.sf-shown.txt"; screencap -d "$DID" > "$TAG.shown.raw"; screencap -d "$DID" -p > "$TAG.shown.png"; }
waitfor FLIPPING && { sleep 1; dumpsys SurfaceFlinger > "$TAG.sf-flip.txt"; }
waitfor SHOWN_END && screencap -d "$DID" > "$TAG.end.raw"
wait $p; echo "rc=$?" >> "$TAG.log"
logcat -d -T "$T0" 2>/dev/null | grep -iE "gralloc|mapper|qdmeta|AHardwareBuffer|GraphicBuffer|BufferMapper|HWC|SDM|DsTest|powos-ds" | tail -60 > "$TAG.logcat.txt"
