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
#   sandbox-bundle  build only the manager sandbox's tarball deploy pushes (deps from its lock; no phone)
#   module <zip>  stage the PowOS system module (system-module/build-module.sh's zip) in Magisk: on at the next reboot
# install, deploy and module take --note "what changed, for the user" (required): the phone's quiet "update applied"
# notification (tools/deploy-note.sh) - or --silent for a change the user can't see (only comms' quiet log).
# Everything lives in /data/powos (+ /data/adb/service.d/powos.sh). Removing PowOS = deleting those.
# powos-units: deploy - what this installs on the phone is checked against units/ (test/tier1/test-units-registry.py)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NOTE="" SILENT="" ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in --silent) SILENT=1; shift ;; --note) NOTE=${2:-}; shift 2 || shift ;; --note=*) NOTE=${1#--note=}; shift ;; *) ARGS+=("$1"); shift ;; esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
case "${1:-}" in
  install|deploy|module)
    [ -n "${NOTE// }" ] || [ -n "$SILENT" ] || { echo "rooted.sh: --note \"what changed, for the user\" is required (the phone's update notification)" >&2; exit 2; } ;;
esac
# After a deploy: the phone's "update applied" notification (batched: install's own deploy makes the same one).
noted() { ADB=adb "$HERE/../tools/deploy-note.sh" ${SILENT:+--silent} "${NOTE:-rooted deploy}"; }
ROOTFS=${ROOTFS:-$HERE/../out/powos-rootfs.tar.gz}

# The sandbox's tarball for the phone (deploy, below): lib/ai/sandbox without its local node_modules, plus the deps
# from its lock, built once per lock hash under ~/.cache/powos-sandbox (under $HOME: tools/phone/bin/adb pushes only
# from there). Prints the tarball's path; fails (nothing printed) when the deps don't build.
sandbox_bundle() {
  local src="$HERE/../../../lib/ai/sandbox" c="$HOME/.cache/powos-sandbox" h dep st
  h=$(shasum -a 256 < "$src/package-lock.json" | cut -c1-16)
  dep=$c/deps-$h
  if [ ! -f "$dep/node_modules/.powos-lock" ]; then
    rm -rf "$dep" "$dep.tmp" && mkdir -p "$dep.tmp"
    cp "$src/sandbox.sh" "$src/package.json" "$src/package-lock.json" "$dep.tmp/"
    bash "$dep.tmp/sandbox.sh" setup >&2 || { rm -rf "$dep.tmp"; return 1; }
    mv "$dep.tmp" "$dep"
  fi
  st=$c/stage
  rm -rf "$st" && mkdir -p "$st/sandbox"
  (cd "$src" && find . -name node_modules -prune -o -type f -print | sed 's|^\./||' \
    | COPYFILE_DISABLE=1 tar -cf - --no-xattrs -T -) | tar -xf - -C "$st/sandbox" || return 1
  cp -R "$dep/node_modules" "$st/sandbox/node_modules" || return 1
  COPYFILE_DISABLE=1 tar -czf "$c/powos-sandbox.tar.gz" --no-xattrs --uid 0 --gid 0 -C "$st" sandbox || return 1
  rm -rf "$st"
  echo "$c/powos-sandbox.tar.gz"
}
if [ "${1:-}" = sandbox-bundle ]; then
  # Build the sandbox's tarball only (what deploy pushes; no phone needed): a dry run of that part of the deploy.
  t=$(sandbox_bundle) && echo "$t ($(du -h "$t" | cut -f1), $(tar -tzf "$t" | grep -c .) entries)"; exit $?
fi

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
  "$0" deploy ${SILENT:+--silent} --note "$NOTE"
  echo "installed: /data/powos/root ($(asu 'du -sh /data/powos/root' | awk '{print $1}')), boot service in /data/adb/service.d" ;;
deploy)
  # A phone check holds the verify lock (~/.cache/powos-verify.lock): a deploy can restart the session under it and
  # void the check (04:27:52: td-launch's launch was lost, friction f19). Wait up to 10 min for a lock fresher than
  # 10 min, as ship-apk does; DEPLOY_NOW=1 skips the wait (an urgent fix).
  vl="$HOME/.cache/powos-verify.lock"
  if [ -z "${DEPLOY_NOW:-}" ]; then
    for _ in $(seq 40); do
      [ -d "$vl" ] && [ $(( $(date +%s) - $(stat -f %m "$vl" 2>/dev/null || stat -c %Y "$vl") )) -lt 600 ] || break
      echo "rooted.sh deploy: waiting for the phone check ($(cat "$vl/who" 2>/dev/null)) to finish"; sleep 15
    done
  fi
  # One deploy at a time: two at once raced on /data/local/tmp ("install: bad .../powos-open-task", 05:36, friction f20).
  dl="$HOME/.cache/powos-deploy.lock"
  for _ in $(seq 60); do mkdir "$dl" 2>/dev/null && break
    [ $(( $(date +%s) - $(stat -f %m "$dl" 2>/dev/null || stat -c %Y "$dl") )) -gt 600 ] && { rm -rf "$dl"; continue; }
    echo "rooted.sh deploy: another deploy is running - waiting"; sleep 5; done
  trap 'rm -rf "$dl"' EXIT
  # The rooted-mode scripts (also part of install): the boot/mount script, the desktop session the PowOS app starts
  # (powos-session.sh -> /usr/bin/powos-rooted-session inside PowOS), and the flag the app checks
  # (persist.powos.root=1, set with Magisk's resetprop - readable without a root prompt).
  for f in powos-start.sh powos-session.sh powos-run.sh powos-rooted-session powos-deploy.sh powos-appdata.sh \
    powos-idle-sysupdate.sh powos-units.sh powos-vpn-keep.sh; do
    adb push -q "$HERE/$f" "/data/local/tmp/$f"
  done
  for f in powos-android-app powos-android-tasks powos-android-tasks.desktop powos-padd powos-focus-watch powos-apps-export \
    powos-apps-watch powos-apps-watch.desktop powos-plasma-bridge powos-plasma-bridge.desktop powos-open-task powos-ime-bridge powos-ime-bridge.desktop \
    powos-output-scale android-nm; do
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
  # App API's runtime (tools/app-api, unit app-api): the specs' tools + appcap_serve.py, the App API app's local service.
  adb shell rm -rf /data/local/tmp/powos-app-api && adb shell mkdir -p /data/local/tmp/powos-app-api/examples /data/local/tmp/powos-app-api/sample
  adb push -q "$HERE"/../../../tools/app-api/*.py /data/local/tmp/powos-app-api/
  adb push -q "$HERE"/../../../tools/app-api/examples/*.appcap.json /data/local/tmp/powos-app-api/examples/
  # "+ add app"'s import sample (appcap_add.py, POST /draft/import {sample}).
  adb push -q "$HERE"/../../../tools/app-api/sample/*.openapi.json /data/local/tmp/powos-app-api/sample/
  # The manager (lib/ai/manager: PowOS AI's chat runs a turn of it per message, so a new one takes the next turn).
  adb shell rm -rf /data/local/tmp/powos-manager
  adb push -q "$HERE/../../../lib/ai/manager" /data/local/tmp/powos-manager
  # The manager's TypeScript sandbox (lib/ai/sandbox, unit ai-sandbox): its sources plus its deps, which stay inside
  # the app (never on the phone's host). The deps are built HERE from its lock (package-lock.json: quickjs-emscripten +
  # typescript, JavaScript and WebAssembly only - the same files on arm64; no install scripts) by the sandbox's own
  # `setup` (npm ci --ignore-scripts, stamped with the lock's hash), once per lock into ~/.cache/powos-sandbox/<hash>,
  # and go over as one tarball (thousands of small files). The phone has no npm; PowOS's bun runs it.
  adb shell rm -f /data/local/tmp/powos-sandbox.tar.gz
  if sbx_tgz=$(sandbox_bundle); then adb push -q "$sbx_tgz" /data/local/tmp/powos-sandbox.tar.gz
  else echo "rooted.sh: the sandbox's deps didn't build (above) - the sandbox not updated"; fi
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
  # The desktop's Xwayland (pkgs/xwayland-kgsl: Xwayland on KGSL + our fixes): build-pkgs.sh xwayland-kgsl.
  xwl=$("$HERE/../tools/newest-pkgs.sh" "$HERE/../out/pkgs" xwayland-kgsl)
  if [ -n "$xwl" ]; then adb push -q "$xwl" "/data/local/tmp/powos-apps/${xwl##*/}"
  else echo "rooted.sh: no xwayland-kgsl package (targets/android/build-pkgs.sh xwayland-kgsl) - Xwayland not updated"; fi
  # KWin with the Anland backend (pkgs/kwin; build-pkgs.sh kwin builds it on PowOS's rootfs).
  kw=$("$HERE/../tools/newest-pkgs.sh" "$HERE/../out/pkgs" kwin)
  if [ -n "$kw" ]; then adb push -q "$kw" "/data/local/tmp/powos-apps/${kw##*/}"
  else echo "rooted.sh: no kwin package (targets/android/build-pkgs.sh kwin) - KWin not updated"; fi
  # The module every composed widget runs (apps/composed; apps/build.sh composed): its source, wasm, stamp, bindings.
  cmp=$HERE/../../../apps/composed
  adb shell mkdir -p /data/local/tmp/powos-apps/composed
  adb push -q "$cmp/module" /data/local/tmp/powos-apps/composed/module
  if [ -f "$cmp/out/module.wasm" ]; then
    for f in module.wasm .module.sha bindings; do adb push -q "$cmp/out/$f" /data/local/tmp/powos-apps/composed/; done
  else echo "rooted.sh: no apps/composed/out/module.wasm (apps/build.sh composed) - compositions build their module"; fi
  reg=$HERE/../../../apps/registry/out/module.wasm
  if [ -f "$reg" ]; then adb push -q "$reg" /data/local/tmp/powos-apps/registry.wasm
  else echo "rooted.sh: no apps/registry/out/module.wasm (apps/build.sh registry) - the registry not updated"; fi
  # The whole source as the update payload (git archive HEAD, like the rootfs build): powos-deploy.sh seeds
  # /var/lib/powos/src from it ONLY when absent, so a phone installed before source was baked gets attached without a
  # reinstall. An existing tree (the user's edits, git state) is never touched; `powos self update` moves it.
  src_tar=$(mktemp "${TMPDIR:-/tmp}/powos-src.XXXXXX") && git -C "$HERE/../../.." archive HEAD > "$src_tar" &&
    adb push -q "$src_tar" /data/local/tmp/powos-src.tar && git -C "$HERE/../../.." rev-parse HEAD > "$src_tar" &&
    adb push -q "$src_tar" /data/local/tmp/powos-src.rev; rm -f "$src_tar"
  adb push -q "$HERE/../../../lib/self-phone.sh" /data/local/tmp/self-phone.sh
  # The units: what this deploy installs and runs, with owner, purpose, limits and how to remove it (units/phone,
  # units/phone-android; lib/apps/powos-units). powos-deploy.sh registers them on both sides.
  adb shell rm -rf /data/local/tmp/powos-units
  adb push -q "$HERE/../../../units" /data/local/tmp/powos-units
  # The ship gate's secret + url (tools/phone/ship-gate.py on the Mac, ship-deploy.sh gate-install makes the secret):
  # pushed as FILES (never on a command line), installed by powos-deploy.sh only when missing/different, then removed.
  adb shell rm -f /data/local/tmp/ship-gate.secret /data/local/tmp/ship-gate.conf
  gs=$HOME/.config/powos/ship-gate.secret
  if [ -s "$gs" ]; then
    adb push -q "$gs" /data/local/tmp/ship-gate.secret
    gc=$(mktemp "${TMPDIR:-/tmp}/powos-gate.XXXXXX") && echo "url=${POWOS_SHIP_GATE_URL:-http://192.168.50.99:7433}" > "$gc" &&
      adb push -q "$gc" /data/local/tmp/ship-gate.conf; rm -f "$gc"
  else echo "rooted.sh: no $gs (tools/phone/ship-deploy.sh gate-install makes it) - the phone's ship gate not configured"; fi
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
  sed -n '2,19p' "$0"; exit 1 ;;
esac
