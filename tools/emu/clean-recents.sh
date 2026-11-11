#!/bin/bash
# tools/emu/clean-recents.sh: the EMULATOR's recents emptied for a check that needs a task-free device (`# needs:
# clean-recents`, run by queue-emu.sh before such a job; emu.sh clean-recents). Removes every recent task except
# PowOS's own (com.powos.app: home, lock) and Android's FallbackHome - live or left over by an earlier check.
# EMULATOR ONLY, by construction: refuses (exit 2, nothing sent but the two reads) unless the target serial is an
# emulator's (emulator-<port>) AND the device itself says it is one (ro.kernel.qemu / ro.boot.qemu = 1). The real phone
# (a TLS/IP serial, no qemu property) can never reach the remove. ADB / SERIAL: the emulator's (emu.sh sets them;
# tier1 stubs them).
set -uo pipefail
ADB=${ADB:?ADB: the adb binary}
SERIAL=${SERIAL:?SERIAL: the emulator serial}
[[ "$SERIAL" =~ ^emulator-[0-9]+$ ]] || { echo "clean-recents: refused - $SERIAL is not an emulator serial (emulator lane only)" >&2; exit 2; }
q=$("$ADB" -s "$SERIAL" shell 'echo "$(getprop ro.kernel.qemu)$(getprop ro.boot.qemu)"' 2>/dev/null | tr -d '\r')
case "$q" in *1*) ;; *) echo "clean-recents: refused - $SERIAL doesn't say it is an emulator (ro.kernel.qemu/ro.boot.qemu: '$q')" >&2; exit 2 ;; esac
# "<task id> <component>" per recent task (header id, then its mActivityComponent).
tasks=$("$ADB" -s "$SERIAL" shell dumpsys activity recents 2>/dev/null | tr -d '\r' |
  awk '/\* Recent #[0-9]+: Task\{/{ if (id != "") print id, c; match($0, / #[0-9]+ /); id = substr($0, RSTART + 2, RLENGTH - 3); c = "?" }
       /^ *mActivityComponent=/{ c = $0; sub(/^ *mActivityComponent=/, "", c) }
       /Visible recent tasks/{ exit }
       END{ if (id != "") print id, c }')
n=0
while read -r id comp; do
  [ -n "$id" ] || continue
  case "$comp" in com.powos.app/*|com.android.settings/.FallbackHome|com.android.settings/com.android.settings.FallbackHome) continue ;; esac
  "$ADB" -s "$SERIAL" shell "am stack remove $id" >/dev/null 2>&1
  echo "clean-recents: removed task $id ($comp)"; n=$((n + 1))
done <<<"$tasks"
echo "clean-recents: $n task(s) removed on $SERIAL"
