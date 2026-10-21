# sf-latency.sh [layer-regex]: (on the phone, root) SurfaceFlinger present-time intervals per matching layer (last ~127 frames): mean/fps, max, frames over 1.5x vsync
P=${1:-powos}
dumpsys SurfaceFlinger --list | sed -E 's/^RequestedLayerState\{//; s/ parentId=.*//; s/ z=.*//; s/\}$//' | grep -iE "$P" | grep -v "Gesture Monitor\|ActivityRecord\|InputSink" | head -10 | while read -r L; do
  dumpsys SurfaceFlinger --latency "$L" | awk -v n="$L" 'NR==1{p=$1} NR>1 && $3>0 && $3<9e18 {if(last){d=($3-last)/1e6; c++; s+=d; if(d>max)max=d; if(d>1.5*p/1e6)j++} last=$3}
    END{if(c>0) printf "%s: frames=%d mean=%.1fms (%.1f fps) max=%.1fms over1.5x_vsync=%d (vsync %.1fms)\n", substr(n,1,80), c, s/c, 1000/(s/c), max, j, p/1e6}'
done
