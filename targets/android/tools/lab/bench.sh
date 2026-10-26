#!/bin/bash
# Compares the x86 paths for Windows programs on ARM64, inside the lab container (tools/lab/README in the
# Android README's "Windows games" section) or on the phone (tools/device-test.sh runs the same script).
#   bench.sh <wintest dir> <results file>
# Paths (each skipped when its pieces are missing):
#   a64-native   aarch64 Proton, arm64 build of the program        (no emulation: the ceiling)
#   a64-ec       aarch64 Proton, x86_64 program, FEX ARM64EC       (Proton 11 ARM64 / Steam Frame path)
#   a64-wow      aarch64 Proton, i686 program, FEX WoW64
#   box-x64      x86_64 Proton, all of Wine under box64 (x86_64 program)
#   box-x86      x86_64 Proton, i686 program, BOX32
#   hang-ec      Hangover wine, x86_64 program, FEX ARM64EC
#   hang-wowbox  Hangover wine, i686 program, box64's wowbox64.dll
#   hang-wowfex  Hangover wine, i686 program, FEX's libwow64fex.dll
# Env: PROTON_A64, PROTON_X64 (dist dirs), HANGOVER (dir with usr/bin/wine), BOX_PRELOAD (lab x86 exec hook,
# unset on the phone where the engine does it), REPS (startup repetitions, default 3).
set -u
T=$1 OUT=$2
REPS=${REPS:-3}
: > "$OUT"
export WINTEST_LOG=$OUT.tmp DISPLAY=${DISPLAY:-:1} PROTON_NO_FSYNC=${PROTON_NO_FSYNC:-1}
BASE=${BENCH_DIR:-/tmp/powos-bench}
mkdir -p "$BASE/steam"

now() { date +%s.%N; }
# The lab's x86 exec hook goes in front of LD_PRELOAD; with none, LD_PRELOAD stays as it is (on the phone it
# carries the runtime itself: android-compat.so + fakechroot).
pl() { [ -n "${1:-}" ] && echo "$1${LD_PRELOAD:+:$LD_PRELOAD}" || echo "${LD_PRELOAD:-}"; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }'; }

run_proton() { # name dist exe preload
  local name=$1 dist=$2 exe=$3 pre=${4:-}
  [ -x "$dist/proton" ] && [ -f "$exe" ] || { echo "$name SKIPPED" >> "$OUT"; return; }
  export STEAM_COMPAT_DATA_PATH=$BASE/pfx-$(basename "$dist") STEAM_COMPAT_CLIENT_INSTALL_PATH=$BASE/steam \
         UMU_ID=umu-0 SteamGameId=bench
  mkdir -p "$STEAM_COMPAT_DATA_PATH"
  LD_PRELOAD=$(pl "$pre") python3 "$dist/proton" run "$exe" nop >/dev/null 2>&1   # prefix creation / warm-up
  local s times=()
  for _ in $(seq "$REPS"); do
    s=$(now); LD_PRELOAD=$(pl "$pre") python3 "$dist/proton" run "$exe" nop >/dev/null 2>&1; times+=("$(since "$s")")
  done
  rm -f "$WINTEST_LOG"
  LD_PRELOAD=$(pl "$pre") python3 "$dist/proton" run "$exe" >/dev/null 2>&1
  # Wine alone (no Proton script): the prefix Proton made, its wine binary directly.
  local wt=()
  for _ in $(seq "$REPS"); do
    s=$(now); WINEPREFIX=$STEAM_COMPAT_DATA_PATH/pfx LD_PRELOAD=$(pl "$pre") "$dist/files/bin/wine" "$exe" nop >/dev/null 2>&1; wt+=("$(since "$s")")
  done
  echo "$name startup_s ${times[*]}  wine_only_s ${wt[*]}" >> "$OUT"
  sed "s/^cpubench [^ ]*/$name/" "$WINTEST_LOG" >> "$OUT" 2>/dev/null || echo "$name FAILED" >> "$OUT"
}

run_hangover() { # name exe hodll
  local name=$1 exe=$2 hodll=${3:-} wine=${HANGOVER:-}/usr/bin/wine
  [ -x "$wine" ] && [ -f "$exe" ] || { echo "$name SKIPPED" >> "$OUT"; return; }
  export WINEPREFIX=$BASE/pfx-hangover WINEDEBUG=-all
  # No wine-mono/gecko download dialogs (they block wineboot without a user).
  [ -d "$WINEPREFIX/drive_c/windows/syswow64" ] || { WINEDLLOVERRIDES="mscoree,mshtml=" "$wine" wineboot -i >/dev/null 2>&1; "${wine%/*}/wineserver" -w; }
  local s times=()
  for _ in $(seq "$REPS"); do
    s=$(now); HODLL=$hodll "$wine" "$exe" nop >/dev/null 2>&1; times+=("$(since "$s")")
  done
  rm -f "$WINTEST_LOG"
  HODLL=$hodll "$wine" "$exe" >/dev/null 2>&1
  echo "$name startup_s ${times[*]}" >> "$OUT"
  sed "s/^cpubench [^ ]*/$name/" "$WINTEST_LOG" >> "$OUT" 2>/dev/null || echo "$name FAILED" >> "$OUT"
}

run_proton a64-native "${PROTON_A64:-}" "$T/aarch64/cpubench.exe"
run_proton a64-ec "${PROTON_A64:-}" "$T/x86_64/cpubench.exe"
run_proton a64-wow "${PROTON_A64:-}" "$T/i686/cpubench.exe"
run_proton box-x64 "${PROTON_X64:-}" "$T/x86_64/cpubench.exe" "${BOX_PRELOAD:-}"
run_proton box-x86 "${PROTON_X64:-}" "$T/i686/cpubench.exe" "${BOX_PRELOAD:-}"
run_hangover hang-ec "$T/x86_64/cpubench.exe"
run_hangover hang-wowbox "$T/i686/cpubench.exe" wowbox64.dll
run_hangover hang-wowfex "$T/i686/cpubench.exe" libwow64fex.dll
rm -f "$WINTEST_LOG"
cat "$OUT"
