# tools/phone/verify/sf-comp.awk < dumpsys SurfaceFlinger: one line - the layers with blur regions, and the main display's
# HWC layers CLIENT/DEVICE with each CLIENT layer's forced reason (clientType) and whether it has a corner radius.
# ww-resize.sh's record pass (mid-drag). 11-10: the old count took both displays (the idle outer one's stale CLIENT rows).
# The main (active) display's HWC table: "name TYPE" per layer; the Output Layers' forceClientComposition reasons.
/^Display [0-9]+ \(active\) HWC layers:/ {on = 1; next}
/^Display [0-9]+ \(inactive\) HWC layers:/ {on = 0}
on && /^ [^ |-]/ {name = $0; sub(/^ +/, "", name); sub(/ +$/, "", name)}
on && /\|/ && name != "" {split($0, f, "|"); gsub(/ /, "", f[4]); if (f[4] != "") {comp[name] = f[4]; ord[++n] = name; if (f[4] == "CLIENT") c++; else d++}; name = ""}
/^  Layer \[/ {ln = substr($0, index($0, "]") + 2); sub(/#.*/, "", ln)}
/blurRegions.size\(\)=[1-9]/ {b[ln] = 1}
/cornerRadius=< [1-9]/ {r[ln] = 1}
/Output Layer 0x/ {o = $0; sub(/.*\(/, "", o); sub(/\).*/, "", o)}
/forceClientComposition=true/ {match($0, /clientType=[A-Za-z_0-9]+/); why[o] = substr($0, RSTART + 11, RLENGTH - 11)}
END {
  bo = ""; for (k in b) bo = bo " " k
  printf "mid-drag: blur owners:%s; main display HWC CLIENT %d, DEVICE %d", (bo == "" ? " none" : bo), c, d
  for (i = 1; i <= n; i++) if (comp[ord[i]] == "CLIENT") { k = ord[i]; kk = k; sub(/#.*/, "", kk); printf "; CLIENT %s%s%s", k, (why[k] != "" ? " force=" why[k] : ""), (r[kk] ? " rounded" : "") }
  print ""
}
