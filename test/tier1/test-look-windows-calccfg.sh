#!/bin/bash
# board-look-windows.sh calc-density: calccfg reads Calculator's last reported configuration from dumpsys. On the
# Open (Android 14+) it is dumped over lines ("mLastReportedConfigurations:" then mGlobalConfig/mOverrideConfig),
# so the old one-line awk printed blanks and calcfits died on "$2: unbound variable" (11-07 job
# 20261106-220109-6587). Runs calccfg and isxy/near/bsize out of the script against canned dumpsys text.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); S=$ROOT/tools/phone/verify/board-look-windows.sh
pass=0 fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: got '$2', want '$3'"; fi; }
defs=$(sed -n -e '/^calccfg() {/,/|| echo none; }$/p' -e '/^isxy() {/p' -e '/^bsize() {/p' -e '/^near() {/p' "$S")
run() { DUMP=$1 bash -c 'set -u; CALC=com.oneplus.calculator; sh_() { printf "%s\n" "$DUMP"; }; eval "$0"; '"$2" "$defs"; }
cfg='{1.0 ?mcc??mnc [en_CH] ldltr sw%sdp w%sdp h618dp 442dpi nrml hdr winConfig={ mBounds=Rect(177, 331 - 1537, 2039) }}'
new="  * Hist  #1: ActivityRecord{1 u0 com.android.chrome/.Main t1}
      mLastReportedConfigurations:
        mGlobalConfig=$(printf "$cfg" 821 821)
        mOverrideConfig=$(printf "$cfg" 700 700)
  * Hist  #0: ActivityRecord{2 u0 com.oneplus.calculator/com.android.calculator2.Calculator t2}
      mLastReportedConfigurations:
        mGlobalConfig=$(printf "$cfg" 821 821)
        mOverrideConfig=$(printf "$cfg" 492 493)
      CurrentConfiguration=$(printf "$cfg" 1 1)"
old="  * Hist  #0: ActivityRecord{2 u0 com.oneplus.calculator/com.android.calculator2.Calculator t2}
      mLastReportedConfiguration=$(printf "$cfg" 400 410)"
half="  * Hist  #0: ActivityRecord{2 u0 com.oneplus.calculator/com.android.calculator2.Calculator t2}
      mLastReportedConfigurations:
      mLastReportedActivityWindowInfo=x"
ok "multi-line (Android 14+): the override" "$(run "$new" calccfg)" "442 492 493"
ok "one-line (older)" "$(run "$old" calccfg)" "442 400 410"
ok "no fields: none" "$(run "$half" calccfg)" "none"
ok "no Calculator: none" "$(run "  * Hist  #1: ActivityRecord{1 u0 com.android.chrome/.Main t1}" calccfg)" "none"
ok "isxy" "$(run "" 'isxy "12 -3" && echo y; isxy "12" || echo n; isxy "" || echo n; isxy none || echo n')" "$(printf 'y\nn\nn\nn')"
ok "near on empty sizes" "$(run "" 'near "" "10 10" && echo y || echo n')" n
ok "near" "$(run "" 'near "10 10" "12 9" && echo y || echo n')" y
ok "bsize on a short rect" "$(run "" 'bsize "1 2"; echo "[$?]"')" "[1]"
ok "bsize" "$(run "" 'bsize "1 2 11 22"')" "10 20"
echo "Results: $pass passed, $fail failed"
[ $fail = 0 ]
