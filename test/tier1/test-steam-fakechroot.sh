#!/bin/bash
# test-steam-fakechroot.sh - Tier-1 tests for /usr/bin/steam (targets/android/pkgs/steam/steam) under the no-root
# fakechroot engine (FAKECHROOT_BASE set). razr fold 11-14 "steam doesnt launch": the engine's LD_LIBRARY_PATH (rootfs lib
# dirs by host path) outranked steamui.so's RUNPATH $ORIGIN, so it bound the rootfs's older libSDL3 ("undefined symbol:
# SDL_TryLockJoysticks" -> "Failed to load steamui.so"), and LD_PRELOAD's rootfs paths never loaded. Control: rooted /
# desktop (no FAKECHROOT_BASE) keeps its environment exactly as before.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ST="$SCRIPT_DIR/../../targets/android/pkgs/steam/steam"
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }
echo "== test-steam-fakechroot.sh =="

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed -n '/^sysvipc_preload() {/,/^}/p; /^steam_fakechroot_libs() {/,/^}/p' "$ST" > "$T/fn.sh"
check "both functions are in /usr/bin/steam" "grep -q '^sysvipc_preload()' '$T/fn.sh' && grep -q '^steam_fakechroot_libs()' '$T/fn.sh'"
check "/usr/bin/steam calls them (the client's dir)" \
  "grep -qx 'sysvipc_preload' '$ST' && grep -qx 'steam_fakechroot_libs \"\$S/steamrtarm64\"' '$ST'"
check "... before the client starts" \
  "[ \$(grep -n '^steam_fakechroot_libs \"' '$ST' | cut -d: -f1) -lt \$(grep -n '^exec ./steam' '$ST' | cut -d: -f1) ]"

B=/data/user/0/com.powos.app/files/rootfs
ENGINE_LD=$B/opt/lotfix/arch-glibc:$B/usr/lib:$B/usr/lib/libfakeroot/fakechroot/
ENGINE_PRE=$B/opt/lotfix/android-compat.so:$B/usr/lib/libfakeroot/fakechroot/libfakechroot.so
run() { env -i PATH=/usr/bin:/bin "$@" bash -c ". '$T/fn.sh'; L=/root/.local/share/powos-sysvipc
  sysvipc_preload; steam_fakechroot_libs /root/.local/share/Steam/steamrtarm64
  printf '%s\n' \"LD=\${LD_LIBRARY_PATH-unset}\" \"SYS=\${SYSTEM_LD_LIBRARY_PATH-unset}\" \"PRE=\${LD_PRELOAD-unset}\""; }

out=$(run FAKECHROOT_BASE=$B LD_LIBRARY_PATH=$ENGINE_LD LD_PRELOAD=$ENGINE_PRE)
ld=$(printf '%s\n' "$out" | sed -n 's/^LD=//p'); sys=$(printf '%s\n' "$out" | sed -n 's/^SYS=//p'); pre=$(printf '%s\n' "$out" | sed -n 's/^PRE=//p')
check "no root: the client's dir comes first, by host path (ahead of the rootfs's libSDL3)" \
  "[ '${ld%%:*}' = '$B/root/.local/share/Steam/steamrtarm64' ]"
check "no root: the engine's lib dirs are kept after it" "[ '$ld' = '$B/root/.local/share/Steam/steamrtarm64:$ENGINE_LD' ]"
check "no root: host tools Steam runs get the engine's own path (SYSTEM_LD_LIBRARY_PATH)" "[ '$sys' = '$ENGINE_LD' ]"
check "no root: the x86 sysvipc shims by host path" \
  "case ' $pre ' in *' $B/root/.local/share/powos-sysvipc/i386/libsysvipc-emu.so '*) true;; *) false;; esac \
   && case ' $pre ' in *' $B/root/.local/share/powos-sysvipc/x86_64/libsysvipc-emu.so '*) true;; *) false;; esac"
check "no root: no aarch64 shim (the engine emulates SysV IPC for native programs itself)" "case '$pre' in *aarch64*) false;; *) true;; esac"
check "no root: no rootfs-relative preload left (the loader can't open those)" "! printf '%s\n' $pre | grep -q '^/root/'"
check "no root: the engine's own preloads are kept" "case '$pre' in *' $ENGINE_PRE') true;; *) false;; esac"

# Control: rooted / desktop - exactly the old environment.
out=$(run LD_LIBRARY_PATH=/opt/x)
check "control (no FAKECHROOT_BASE): LD_LIBRARY_PATH untouched" "printf '%s\n' '$out' | grep -qx 'LD=/opt/x'"
check "control: SYSTEM_LD_LIBRARY_PATH stays unset (the client's \${SYSTEM_LD_LIBRARY_PATH-...} falls back)" \
  "printf '%s\n' '$out' | grep -qx 'SYS=unset'"
check "control: all three shims, rootfs paths, as before" \
  "printf '%s\n' '$out' | grep -qx 'PRE=/root/.local/share/powos-sysvipc/aarch64/libsysvipc-emu.so /root/.local/share/powos-sysvipc/i386/libsysvipc-emu.so /root/.local/share/powos-sysvipc/x86_64/libsysvipc-emu.so'"
out=$(run)
check "control: no LD_LIBRARY_PATH stays unset" "printf '%s\n' '$out' | grep -qx 'LD=unset'"
echo "steam-fakechroot: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
