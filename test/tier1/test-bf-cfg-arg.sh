#!/bin/bash
# bf-pacing.sh / bf-checker.sh take cfg:<x86|arm64> as their first argument (bf-lib.sh cfg_take): it must never reach
# the mode list. Job 20261105-080814-44232 ran a bf-pacing without cfg_take: "unknown mode cfg:arm64", then
# bf-frames.py opened the mode folder OUT/cfg:arm64 (FileNotFoundError). Checks cfg_take itself and that both scripts
# call it before their mode loop and before anything uses "$@" / "$*".
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); V=$ROOT/tools/phone/verify
pass=0 fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: got '$2', want '$3'"; fi; }
# /bin/bash on the Mac is 3.2: an empty "${CFG_ARGS[@]}" under set -u is "unbound variable" (cfg:arm64 alone).
SH=/bin/bash; [ -x "$SH" ] || SH=bash
take() { "$SH" -c 'set -u; BF_ADB=/bin/true . "$0"; cfg_take "$@"; set -- ${CFG_ARGS[@]+"${CFG_ARGS[@]}"}; [ $# -gt 0 ] || set -- base; echo "${CFG_TO:--}|$*"' "$V/bf-lib.sh" "$@"; }
ok "cfg + mode" "$(take cfg:arm64 base)" "arm64|base"
ok "cfg + modes" "$(take cfg:x86 base cap60)" "x86|base cap60"
ok "cfg alone" "$(take cfg:arm64)" "arm64|base"
ok "no cfg" "$(take base fifo)" "-|base fifo"
ok "nothing" "$(take)" "-|base"
ok "cfg after a mode" "$(take base cfg:arm64)" "arm64|base"
# gus:K=V (Unreal GameUserSettings.ini keys for the check, abzu-fps 2026-11-07): taken out like cfg:, never a mode.
gtake() { "$SH" -c 'set -u; BF_ADB=/bin/true . "$0"; cfg_take "$@"; gus_take ${CFG_ARGS[@]+"${CFG_ARGS[@]}"}; set -- ${GUS_ARGS[@]+"${GUS_ARGS[@]}"}; [ $# -gt 0 ] || set -- base; echo "${CFG_TO:--}|${GUS:--}|$*"' "$V/bf-lib.sh" "$@"; }
ok "gus + mode" "$(gtake gus:ResolutionScale=SCALE_75 base)" "-|ResolutionScale=SCALE_75|base"
ok "gus alone" "$(gtake gus:A=1,B=2)" "-|A=1,B=2|base"
ok "gus + cfg + modes" "$(gtake base cfg:arm64 gus:A=1 env:X=1)" "arm64|A=1|base env:X=1"
ok "no gus" "$(gtake base)" "-|-|base"
ok "gus refuses a quote" "$("$SH" -c 'BF_ADB=/bin/true . "$0"; pill() { :; }; GUS="A=1'"'"';rm"; gus_set' "$V/bf-lib.sh" | grep -c 'only')" 1
t=$(grep -nF 'gus_take "$@"' "$V/bf-pacing.sh" | head -1 | cut -d: -f1); u=$(grep -nE '^for mode in "\$@"' "$V/bf-pacing.sh" | head -1 | cut -d: -f1)
ok "bf-pacing takes gus: before its modes" "$([ -n "$t" ] && [ -n "$u" ] && [ "$t" -lt "$u" ] && echo yes || echo no)" yes
ok "bf-pacing restores gus" "$(grep -c 'gus_restore' "$V/bf-pacing.sh")" 1
for s in bf-pacing.sh bf-checker.sh; do
  t=$(grep -nF 'cfg_take "$@"; set -- ${CFG_ARGS[@]+"${CFG_ARGS[@]}"}' "$V/$s" | head -1 | cut -d: -f1)
  u=$(grep -nE '^for (mode|v) in "\$@"|bf-frames.py|bf-checker.py|\$\*' "$V/$s" | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)
  ok "$s takes cfg: first" "$([ -n "$t" ] && [ -n "$u" ] && [ "$t" -lt "$u" ] && echo yes || echo "no (cfg_take line ${t:-none}, first use ${u:-none})")" yes
  ok "$s restores cfg" "$(grep -c 'cfg_restore' "$V/$s")" 1
done
echo "Results: $pass passed, $fail failed"
[ $fail = 0 ]
