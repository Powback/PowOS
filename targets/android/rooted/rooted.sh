#!/bin/bash
# PowOS alongside Android on a ROOTED phone (Magisk), driven from the Mac over adb. Not the no-root app: PowOS's
# own Linux system runs with root on the phone's kernel, with the real GPU (Turnip on KGSL).
#   install   push targets/android/out/powos-rootfs.tar.gz, unpack to /data/powos/root, install the boot service
#   deploy    (re)install the rooted-mode scripts + the app's rooted-mode flag (part of install; rerun after
#             changing rooted/*): boot service, desktop session (powos-session.sh, powos-rooted-session)
#   start     mount + start PowOS now (rooted/powos-start.sh; also runs at every boot via Magisk)
#   shell     root shell inside PowOS
#   check     what works: PowOS CLI, systemd-free services, GPU (vulkaninfo through Turnip)
#   log       /data/powos/start.log
#   run CMD   one command inside PowOS (no pipes: they would run in Android's shell)
#   system [status|stop|off|on]   PowOS's system tier (SpacetimeDB under the supervisor, the uid-locked port)
#   wifi      adb over Wi-Fi (port 5555, kept across reboots): unplug the cable
#   widevine-l3 [remove]   Netflix etc. in SD on the unlocked phone (targets/native/widevine-l3.sh)
#   module <zip>  stage the PowOS system module (system-module/build-module.sh's zip) in Magisk: on at the next reboot
# install, deploy and module take --note "what changed, for the user" (required): the phone's quiet "update applied"
# notification (tools/deploy-note.sh).
# Everything lives in /data/powos (+ /data/adb/service.d/powos.sh). Removing PowOS = deleting those.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NOTE="" ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in --note) NOTE=${2:-}; shift 2 || shift ;; --note=*) NOTE=${1#--note=}; shift ;; *) ARGS+=("$1"); shift ;; esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
case "${1:-}" in
  install|deploy|module)
    [ -n "${NOTE// }" ] || { echo "rooted.sh: --note \"what changed, for the user\" is required (the phone's update notification)" >&2; exit 2; } ;;
esac
# After a deploy: the phone's "update applied" notification (batched: install's own deploy makes the same one).
noted() { ADB=adb "$HERE/../tools/deploy-note.sh" "$NOTE"; }
ROOTFS=${ROOTFS:-$HERE/../out/powos-rootfs.tar.gz}

# Magisk's su: on PATH once Magisk finished its setup, always at /debug_ramdisk/su while it runs.
SU=$(adb shell 'command -v su || echo /debug_ramdisk/su' | tr -d '\r')
asu() { adb shell "$SU -c '$1'"; }
in_powos() { asu "chroot /data/powos/root /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/usr/sbin HOME=/root TERM=xterm-256color /bin/bash -lc \"$1\""; }

case "${1:-}" in
install)
  [ -f "$ROOTFS" ] || { echo "no $ROOTFS (targets/android/build-rootfs.sh)"; exit 1; }
  asu id | grep -q uid=0 || { echo "no root (Magisk)"; exit 1; }
  want=$(awk '{print $1}' "$ROOTFS.sha256")
  adb push "$ROOTFS" /data/local/tmp/powos-rootfs.tar.gz
  got=$(asu "sha256sum /data/local/tmp/powos-rootfs.tar.gz" | awk '{print $1}')
  [ "$want" = "$got" ] || { echo "CHECKSUM MISMATCH after push"; exit 1; }
  asu "mkdir -p /data/powos/root && tar -xzpf /data/local/tmp/powos-rootfs.tar.gz -C /data/powos/root --numeric-owner && rm /data/local/tmp/powos-rootfs.tar.gz"
  "$0" deploy --note "$NOTE"
  echo "installed: /data/powos/root ($(asu 'du -sh /data/powos/root' | awk '{print $1}')), boot service in /data/adb/service.d" ;;
deploy)
  # The rooted-mode scripts (also part of install): the boot/mount script, the desktop session the PowOS app starts
  # (powos-session.sh -> /usr/bin/powos-rooted-session inside PowOS), and the flag the app checks
  # (persist.powos.root=1, set with Magisk's resetprop - readable without a root prompt).
  for f in powos-start.sh powos-session.sh powos-run.sh powos-rooted-session powos-deploy.sh powos-appdata.sh \
    powos-idle-sysupdate.sh; do
    adb push -q "$HERE/$f" "/data/local/tmp/$f"
  done
  for f in powos-android-app powos-android-tasks powos-android-tasks.desktop powos-padd powos-focus-watch powos-apps-export \
    powos-open-task; do
    adb push -q "$HERE/../session/$f" "/data/local/tmp/$f"
  done
  # PowOS's own scripts the phone's features rely on (shipped in the PowOS image - a rootfs from an older image
  # lacks their fixes): the start button's app grid, and the terminals' tmux shell (the launcher's terminal tiles).
  adb push -q "$HERE/../../../bin/powos-panel-phone" /data/local/tmp/powos-panel-phone
  adb push -q "$HERE/../../../desktop/autostart/powos-panel-phone.desktop" /data/local/tmp/powos-panel-phone.desktop
  adb push -q "$HERE/../../../lib/powos-tmux-shell" /data/local/tmp/powos-tmux-shell
  adb push -q "$HERE/../../../config/etc/profile.d/60-powos-picker-key.sh" /data/local/tmp/60-powos-picker-key.sh
  # The Agents view's reporter (lib/ai/agents: the hook, powos-agentsd, the hooks' settings) and comms writing its
  # feed (lib/ai/comms/comms-mcp.py).
  adb shell rm -rf /data/local/tmp/powos-agents
  adb push -q "$HERE/../../../lib/ai/agents" /data/local/tmp/powos-agents
  adb push -q "$HERE/../../../lib/ai/comms/comms-mcp.py" /data/local/tmp/comms-mcp.py
  adb push -q "$HERE/../pkgs/fex-emu/Config.json" /data/local/tmp/fex-Config.json
  adb push -q "$HERE/../pkgs/fex-emu/thunks.json" /data/local/tmp/fex-thunks.json
  adb shell rm -rf /data/local/tmp/powos-plasma
  adb push -q "$HERE/../session/plasma" /data/local/tmp/powos-plasma
  # PowOS's desktop widgets (desktop/plasmoid; the image ships them - a rootfs from an older image lacks their fixes).
  adb shell rm -rf /data/local/tmp/powos-plasmoids
  adb push -q "$HERE/../../../desktop/plasmoid" /data/local/tmp/powos-plasmoids
  # PowOS apps (docs/POWOS-APPS-FEASIBILITY.md): the runtime switch, the system tier's supervisor, the app CLI and the
  # service manifests (lib/apps), the CLI's front doors (bin/powos, lib/config.sh), SpacetimeDB (our package of the
  # official binaries, build-pkgs.sh spacetimedb-bin) and the app registry's module (apps/build.sh registry).
  adb shell rm -rf /data/local/tmp/powos-apps
  adb push -q "$HERE/../../../lib/apps" /data/local/tmp/powos-apps
  adb push -q "$HERE/../../../bin/powos" /data/local/tmp/powos-apps/powos
  adb push -q "$HERE/../../../lib/config.sh" /data/local/tmp/powos-apps/config.sh
  # The patched source build (pkgs/spacetimedb) when there is one, else the official binaries (pkgs/spacetimedb-bin).
  stdb=$("$HERE/../tools/newest-pkgs.sh" "$HERE/../out/pkgs" spacetimedb)
  [ -n "$stdb" ] || stdb=$("$HERE/../tools/newest-pkgs.sh" "$HERE/../out/pkgs" spacetimedb-bin)
  if [ -n "$stdb" ]; then adb push -q "$stdb" "/data/local/tmp/powos-apps/${stdb##*/}"
  else echo "rooted.sh: no spacetimedb package (targets/android/build-pkgs.sh spacetimedb) - SpacetimeDB not updated"; fi
  reg=$HERE/../../../apps/registry/out/module.wasm
  if [ -f "$reg" ]; then adb push -q "$reg" /data/local/tmp/powos-apps/registry.wasm
  else echo "rooted.sh: no apps/registry/out/module.wasm (apps/build.sh registry) - the registry not updated"; fi
  asu "sh /data/local/tmp/powos-deploy.sh; rm -f /data/local/tmp/powos-deploy.sh"
  noted ;;
module)
  # The system module (system-module/build-module.sh): staged in Magisk, on from the next reboot.
  [ -f "${2:-}" ] || { echo "usage: rooted.sh module <powos-system-module.zip> --note \"...\""; exit 1; }
  adb push -q "$2" /data/local/tmp/powos-system-module.zip
  asu "magisk --install-module /data/local/tmp/powos-system-module.zip; rm -f /data/local/tmp/powos-system-module.zip"
  NOTE="$NOTE (after a restart)" noted ;;
start)
  asu "sh /data/powos/powos-start.sh"; asu "tail -5 /data/powos/start.log" ;;
shell)
  exec adb shell -t "$SU -c 'chroot /data/powos/root /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/usr/sbin HOME=/root TERM=xterm-256color /bin/bash -l'" ;;
check)
  in_powos "cat /etc/powos/platform; uname -a; powos version 2>&1 | head -3"
  in_powos "ls -la /dev/kgsl-3d0 /dev/dma_heap 2>&1 | head -5"
  # Filtered here: a pipe inside the command would be run by Android's shell, not inside PowOS.
  in_powos "vulkaninfo --summary" 2>&1 | grep -E "deviceName|driverName|driverInfo|apiVersion|ERROR" | head -8 ;;
log)
  asu "cat /data/powos/start.log" ;;
run)
  shift; in_powos "$*" ;;
system)
  # The system tier (powos-start.sh: SpacetimeDB and other services under the supervisor, outside the desktop
  # session). status | stop (until the next boot or session) | off (stopped, and not started at boot) | on.
  case ${2:-status} in
    status) asu "cat /data/powos/root/run/powos-system/status.json 2>/dev/null || echo not running; echo; iptables -w -S powos-local 2>/dev/null; tail -5 /data/powos/root/var/log/powos/supervisor.log 2>/dev/null" ;;
    stop) asu 'kill $(cat /data/powos/root/run/powos-system/supervisor.pid) && echo stopped' ;;
    off) asu 'touch /data/powos/system-tier.off; kill $(cat /data/powos/root/run/powos-system/supervisor.pid) 2>/dev/null; echo "off (rooted.sh system on)"' ;;
    on) asu 'rm -f /data/powos/system-tier.off; sh /data/powos/powos-start.sh; tail -3 /data/powos/start.log' ;;
    *) echo "rooted.sh system status|stop|off|on"; exit 1 ;;
  esac ;;
android)
  # A script as root on the Android side (outside PowOS): pushed, then run with Magisk's su.
  [ -f "${2:-}" ] || { echo "usage: rooted.sh android <script>"; exit 1; }
  adb push "$2" /data/local/tmp/rooted-android.sh >/dev/null
  asu "sh /data/local/tmp/rooted-android.sh" ;;
wifi)
  # adbd keeps listening on 5555 after reboots (persist.adb.tcp.port); adb still asks the phone to authorize a new
  # computer, as over USB.
  ip=$(adb shell ip -4 addr show wlan0 | awk '/inet /{sub("/.*", "", $2); print $2}')
  asu "setprop persist.adb.tcp.port 5555"
  adb tcpip 5555 && sleep 2 && adb connect "$ip:5555"
  echo "unplug USB, or: export ANDROID_SERIAL=$ip:5555" ;;
widevine-l3)
  # Netflix etc. in SD on the unlocked phone (Widevine L1 can't be provisioned): see targets/native/widevine-l3.sh.
  if [ "${2:-}" = remove ]; then
    asu "rm -f /data/adb/post-fs-data.d/widevine-l3.sh; umount /odm/lib64/liboemcrypto.so; pkill -f android.hardware.drm-service.widevine"
    echo "removed (Widevine back to L1 attempts)"
  else
    adb push -q "$HERE/../../native/widevine-l3.sh" /data/local/tmp/widevine-l3.sh
    asu "mkdir -p /data/adb/post-fs-data.d && install -m 755 /data/local/tmp/widevine-l3.sh /data/adb/post-fs-data.d/widevine-l3.sh && sh /data/adb/post-fs-data.d/widevine-l3.sh now"
    echo "Widevine L3 forced (now and at every boot)"
  fi ;;
*)
  sed -n '2,18p' "$0"; exit 1 ;;
esac
