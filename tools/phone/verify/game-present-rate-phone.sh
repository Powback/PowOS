# lanes: phone
# game-present-rate-phone.sh <secs> <appid> <outdir>: (on the phone, root; game-present-rate.sh pushes and starts it)
# one sample about every second for <secs> s, one line each in <outdir>/samples:
#   <ms since <outdir>/t0 (epoch s)> alive=<0|1> front=<0|1> presents=<n> layer=<name>
# alive = the game's Steam launch chain (SteamLaunch AppId=<appid>) is there; front = Android's top resumed activity is
# a Linux window task (PowosWindowActivity) - home's web windows count too (layer powos-ww-<id>-linux, front = home);
# presents = the most NEW buffers SurfaceFlinger presented since the previous sample on any one layer that can carry
# the game's frames (a window task's BLAST layer, a Linux web window's [BBQ] powos-ww-<id>-linux, powos-direct), so an
# idle Steam window beside the game never hides the game's stall. Layers are looked up again every sample: a fold or
# a resize gives the task a new BLAST layer. <outdir>/kwin.txt: KWin's + Xwayland's lines of the run (window task
# frames / Xwayland KGSL / (EE) BUG), which say at which stage a stall sat.
secs=$1 app=$2 out=$3
mkdir -p "$out"; rm -f "$out"/samples "$out"/p.*
LOG=/data/powos/root/run/powos-app/hyprland.log
l0=$(wc -l < "$LOG" 2>/dev/null || echo 0)
# ms since the start: mksh's arithmetic is 32-bit, so epoch ms (date +%s%N / 1e6) wraps - the sample loop never ended.
B=$(date +%s)
ms() { set -- $(date "+%s %N"); n=${2#"${2%%[1-9]*}"}; echo $(( ($1 - B) * 1000 + ${n:-0} / 1000000 )); }  # %N without leading 0s: not octal
echo "$B" > "$out/t0"; end=$(( secs * 1000 ))
while [ "$(ms)" -lt "$end" ]; do
  t=$(ms)
  # the reaper's pid is kept: a pgrep -f scan takes up to 1.4 s on the phone (half the sample interval)
  [ -n "${rp:-}" ] && [ -d "/proc/$rp" ] || rp=$(pgrep -f "SteamLaunch AppId=$app" | head -1)
  alive=0; [ -n "$rp" ] && alive=1
  top=$(dumpsys activity activities | grep -m1 topResumedActivity)
  best=0 bl=-
  dumpsys SurfaceFlinger --list | sed -E 's/^RequestedLayerState\{//; s/ parentId=.*//; s/ z=.*//; s/\}$//' \
    | grep -E "PowosWindowActivity|\[BBQ\] powos-ww-[0-9]+-linux|powos-direct" \
    | grep -vE "Gesture Monitor|ActivityRecord|InputSink|animation-leash|^Bounds for|^Background for" > "$out/layers"
  while read -r L; do
    k=$(echo "$L" | md5sum | cut -c1-12)
    dumpsys SurfaceFlinger --latency "$L" | awk 'NF==3 && $3>0 && $3<9e18 {print $3}' > "$out/p.$k.now"
    if [ -f "$out/p.$k" ]; then c=$(grep -cvxFf "$out/p.$k" "$out/p.$k.now"); else c=0; fi
    mv "$out/p.$k.now" "$out/p.$k"
    [ "$c" -gt "$best" ] && { best=$c; bl=$(echo "$L" | tr ' ' '_'); }
  done < "$out/layers"
  # in front: the game's window task, or home with a Linux web window's layer (the game in a web window)
  case $top in *PowosWindowActivity*) front=1 ;; *com.powos.app*) grep -q "powos-ww-" "$out/layers" && front=1 || front=0 ;; *) front=0 ;; esac
  echo "$t alive=$alive front=$front presents=$best layer=$bl" >> "$out/samples"
  w=$(( t + 1000 - $(ms) )); [ "$w" -gt 999 ] && w=999; [ "$w" -gt 0 ] && sleep "0.$(printf %03d "$w")"  # every 1 s (a sample takes ~0.4 s)
done
tail -n +"$((l0 + 1))" "$LOG" | grep -aE "window task [0-9]+ (frames|live|in the background)|Xwayland KGSL|\(EE\) BUG|failed to import KGSL|consumer (dis|re)connected" > "$out/kwin.txt"
rm -f "$out"/p.* "$out/layers"; chmod -R 755 "$out"
