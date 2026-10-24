#!/bin/bash
# tools/emu/emu.sh: the PowOS emulator lane - a rooted arm64 Android 16 AVD shaped like the OnePlus Open's inner
# screen (2268x2440 at 442 dpi), headless, so window and app checks don't wait for the phone (unit
# units/mac/emu-mac.json; handbook "The emulator lane").
#   emu.sh create          the system image (sdkmanager, in the android-builder image: the Mac has no Java), the AVD,
#                          a cold boot with a writable /system, PowOS as a privileged system app (priv-app + its
#                          privapp-permissions allowlist, as the phone's system module), the test window client, the
#                          settings the phone has (freeform windows), then the snapshot "powos-ready". Re-run = again.
#   emu.sh start           headless from the "powos-ready" snapshot (seconds), then the APK of origin's tip if the
#                          emulator runs another commit (install). Nothing saved on stop: every start is the same.
#   emu.sh stop            the emulator off (the snapshot stays)
#   emu.sh status          running / booted, the commit its APK is from, the disk it uses
#   emu.sh reset           back to the "powos-ready" snapshot now (a running emulator), APK again if needed
#   emu.sh install [REF]   build REF (default origin's tip) with the normal build system (targets/android/tools/
#                          warm-builder.sh, PUBLISH=0: never into android-app-dev/output, which PowApps serves to the
#                          phone) from a clean checkout of it (.claude/worktrees/emu-build) and `adb install -r` it over
#                          the system copy, as the phone's installs go; its commit goes to /data/local/tmp on the emulator
#   emu.sh remove          stop, then delete the AVD, its snapshot and the build checkout (the system image stays)
# Checks run against it with POWOS_DEVICE=emu (tools/phone/adb.sh picks the emulator); the queue's lane:
# `queue.sh add --dev emu <task> <check> ...` runs at once (tools/phone/verify/queue.sh).
# Disk: refuses to create or start below EMU_MIN_FREE_GB (default 25) free - the Mac's watchdog mails at 15 GB, and
# the Colima VM died at 0.5 GB (2026-10-21). Uses ~13.7 GB: the image 4.3 GB + the AVD 9.4 GB (its snapshot holds the 4 GB RAM - the emulator raises less to 4096 MB for this screen; the 6 GB data partition is written whole: EncryptUserData).
# powos-units: deploy host=mac
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$here/../.." && pwd -P)
REPO=$(cd "$(dirname "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)")" && pwd -P)
SDK=${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}
ADB=$SDK/platform-tools/adb
EMU=$SDK/emulator/emulator
AVD=powos-open
PORT=${EMU_PORT:-5584}
SERIAL=emulator-$PORT
IMG_PKG="system-images;android-36;google_apis;arm64-v8a"
IMG_DIR=system-images/android-36/google_apis/arm64-v8a
AVD_HOME=${ANDROID_AVD_HOME:-$HOME/.android/avd}
STATE=$HOME/.cache/powos-emu
BUILD_TREE=$REPO/.claude/worktrees/emu-build
IMAGE=android-app-dev-android-builder:latest
SNAP=powos-ready
COMMIT_FILE=/data/local/tmp/powos-emu-commit
mkdir -p "$STATE"
a() { "$ADB" -s "$SERIAL" "$@"; }
say() { echo "emu: $*"; }
die() { echo "emu: $*" >&2; exit "${2:-1}"; }

# --- guards and state ---------------------------------------------------------------------------------------------
free_gb() { df -g "$HOME" | awk 'NR == 2 {print $4}'; }
space_guard() { local f; f=$(free_gb)
  [ "${f:-0}" -ge "${EMU_MIN_FREE_GB:-25}" ] || die "only ${f} GB free on the Mac (< ${EMU_MIN_FREE_GB:-25} GB): not $1 (the emulator grows; the watchdog mails at 15 GB)" 4; }
running() { a get-state 2>/dev/null | grep -qx device; }
booted() { [ "$(a shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; }
wait_boot() { local i; for i in $(seq "${1:-300}"); do booted && return 0; sleep 1; done; die "no boot within ${1:-300} s (log: $STATE/emulator.log)"; }
emu_commit() { a shell cat "$COMMIT_FILE" 2>/dev/null | tr -d '\r'; }
tip() { git -C "$REPO" fetch -q origin worktree-powos-multiplatform 2>/dev/null; git -C "$REPO" rev-parse origin/worktree-powos-multiplatform; }

# --- the AVD ------------------------------------------------------------------------------------------------------
image() {
  [ -f "$SDK/$IMG_DIR/system.img" ] && return 0
  say "fetching $IMG_PKG (sdkmanager in $IMAGE)"
  docker run --rm -v "$SDK:/sdk" --entrypoint sh "$IMAGE" -c \
    "yes | /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=/sdk '$IMG_PKG' >/dev/null" || die "sdkmanager failed"
  [ -f "$SDK/$IMG_DIR/system.img" ] || die "no $SDK/$IMG_DIR/system.img after sdkmanager"
}
# The Open's inner screen: the display is 2268x2440 portrait (its panel is landscape under it, as on the phone), 442 dpi.
# Written by hand: avdmanager needs a Java the Mac doesn't have, and the file is the whole definition anyway.
avd_files() {
  mkdir -p "$AVD_HOME/$AVD.avd"
  printf 'avd.ini.encoding=UTF-8\npath=%s\npath.rel=avd/%s.avd\ntarget=android-36\n' "$AVD_HOME/$AVD.avd" "$AVD" > "$AVD_HOME/$AVD.ini"
  cat > "$AVD_HOME/$AVD.avd/config.ini" <<EOF
AvdId=$AVD
avd.ini.displayname=PowOS Open (inner screen)
avd.ini.encoding=UTF-8
abi.type=arm64-v8a
hw.cpu.arch=arm64
hw.cpu.ncore=${EMU_CPUS:-4}
hw.ramSize=${EMU_RAM_MB:-4096}
vm.heapSize=512
hw.lcd.width=2268
hw.lcd.height=2440
hw.lcd.density=442
hw.initialOrientation=portrait
hw.keyboard=yes
hw.mainKeys=no
hw.gpu.enabled=yes
hw.gpu.mode=${EMU_GPU:-swiftshader_indirect}
hw.audioInput=no
hw.audioOutput=no
hw.camera.back=none
hw.camera.front=none
hw.gps=no
hw.sensors.orientation=no
image.sysdir.1=$IMG_DIR/
tag.id=google_apis
tag.display=Google APIs
PlayStore.enabled=false
disk.dataPartition.size=${EMU_DATA_GB:-6}G
fastboot.forceColdBoot=no
fastboot.forceFastBoot=yes
showDeviceFrame=no
EOF
}
# boot <extra emulator args...>: headless, in the background, logged.
boot() {
  running && return 0
  say "booting $AVD on $SERIAL"
  "$ADB" start-server >/dev/null 2>&1
  nohup "$EMU" -avd "$AVD" -port "$PORT" -no-window -no-audio -no-boot-anim -writable-system \
    -gpu "${EMU_GPU:-swiftshader_indirect}" -camera-back none -camera-front none "$@" > "$STATE/emulator.log" 2>&1 &
  echo $! > "$STATE/emulator.pid"
  local i; for i in $(seq 120); do running && break; kill -0 "$(cat "$STATE/emulator.pid")" 2>/dev/null || die "the emulator exited: $(tail -5 "$STATE/emulator.log")"; sleep 1; done
  wait_boot 400
}
# halt: the emulator off, and gone (its files closed) before anything touches the AVD; 30 s, then killed.
halt() { local i
  a emu kill >/dev/null 2>&1
  for i in $(seq 30); do pgrep -f -- "-avd $AVD( |$)" >/dev/null || return 0; sleep 1; done
  pkill -9 -f -- "-avd $AVD( |$)"; sleep 1; }
# wait_dev [s]: adb sees the emulator as a device (never adb's own unbounded wait-for-device: it held `start` 20 min on a
# dead emulator, 2026-10-24).
wait_dev() { local i; for i in $(seq "${1:-120}"); do running && return 0; sleep 1; done; die "the emulator isn't an adb device after ${1:-120} s"; }
root_up() { a root >/dev/null 2>&1; sleep 2; wait_dev; wait_boot 120; }

# --- PowOS as the phone has it -------------------------------------------------------------------------------------
# build REF: the APK of REF from the normal build system, into $STATE/apk/<commit>.apk; prints its path.
build() {
  local ref=${1:-} c out apk
  [ -n "$ref" ] && c=$(git -C "$REPO" rev-parse "$ref^{commit}" 2>/dev/null) || c=$(tip)
  [ -n "$c" ] || die "no commit for ${ref:-the origin tip}"
  [ -f "$STATE/apk/$c.apk" ] && { echo "$STATE/apk/$c.apk"; return 0; }
  # A clean checkout of exactly that commit (build-app.sh's rule: only committed code ships), under ~/Projects: the
  # builder mounts only that.
  if [ ! -e "$BUILD_TREE/.git" ]; then git -C "$REPO" worktree add -q --detach "$BUILD_TREE" "$c" >&2 || die "can't make $BUILD_TREE"
  else git -C "$BUILD_TREE" checkout -q --detach -f "$c" >&2 && git -C "$BUILD_TREE" clean -qfd -- shell targets/android/app >&2; fi
  case "$BUILD_TREE" in "$HOME"/Projects/*) ;; *) die "$BUILD_TREE isn't under ~/Projects (the builder mounts only that)" ;; esac
  say "building $(git -C "$REPO" rev-parse --short "$c") (warm builder, PUBLISH=0)" >&2
  out=$(PUBLISH=0 "$ROOT/targets/android/tools/warm-builder.sh" build "/Projects${BUILD_TREE#$HOME/Projects}/targets/android/app" 2>&1) || { echo "$out" | tail -20 >&2; die "the build failed"; }
  apk=$(echo "$out" | sed -n 's/^warm-builder: built \(.*\.apk\) (not published.*/\1/p' | tail -1)
  [ -n "$apk" ] || { echo "$out" | tail -10 >&2; die "the builder named no APK"; }
  mkdir -p "$STATE/apk"; rm -f "$STATE"/apk/*.apk   # one kept: the newest
  docker cp "powos-gradle-warm:$apk" "$STATE/apk/$c.apk" >/dev/null || die "can't copy $apk out of the builder"
  echo "$STATE/apk/$c.apk"
}
# The phone's system module, on the emulator's /system: the APK in /system/priv-app/PowOS and the reviewed allowlist
# (targets/android/system-module/privapp-permissions.txt) as /system/etc/permissions/privapp-permissions-com.powos.app.xml.
# A privileged permission the APK asks for that the list doesn't name is DENIED there (deny-permission: the phone
# doesn't grant it either) - with enforce on, an unlisted one would stop the boot.
priv() {
  local apk=$1 req emupriv allow deny x=$STATE/privapp-permissions-com.powos.app.xml
  req=$(docker run --rm -v "$(dirname "$apk"):/w:ro" --entrypoint /opt/android-sdk/build-tools/35.0.0/aapt2 "$IMAGE" dump permissions "/w/$(basename "$apk")" |
    sed -n "s/^uses-permission: name='\([^']*\)'.*/\1/p" | sort -u)
  emupriv=$(a shell pm list permissions -f 2>/dev/null | tr -d '\r' | awk -F: '/^\+ permission:/{p=$2} /protectionLevel:/ && $2 ~ /privileged/ {print p}' | sort -u)
  allow=$(grep -v '^\s*\(#\|$\)' "$ROOT/targets/android/system-module/privapp-permissions.txt" | sort -u)
  deny=$(comm -23 <(comm -12 <(echo "$req") <(echo "$emupriv")) <(echo "$allow"))
  # powos-units: ~/.cache/powos-emu/privapp-permissions-com.powos.app.xml
  { echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<!-- tools/emu/emu.sh: the PowOS system module'"'"'s allowlist (privapp-permissions.txt) on the emulator. -->'
    echo '<permissions>'; echo '    <privapp-permissions package="com.powos.app">'
    # powos-units: ~/.cache/powos-emu/privapp-permissions-com.powos.app.xml
    echo "$allow" | grep . | sed 's/.*/        <permission name="&"\/>/'
    # powos-units: ~/.cache/powos-emu/privapp-permissions-com.powos.app.xml
    echo "$deny" | grep . | sed 's/.*/        <deny-permission name="&"\/>/'
    echo '    </privapp-permissions>'; echo '</permissions>'; } > "$x"
  say "priv-app: allowlisted $(echo "$allow" | grep -c .), denied (asked, not on the reviewed list) $(echo "$deny" | grep -c .)"
  a remount 2>&1 | grep -qi 'reboot' && { say "first remount: rebooting once"; a reboot; wait_dev; wait_boot 300; root_up; a remount >/dev/null 2>&1; }
  a shell mkdir -p /system/priv-app/PowOS || die "/system isn't writable (remount failed)"
  a push "$apk" /system/priv-app/PowOS/PowOS.apk >/dev/null 2>&1 && a push "$x" /system/etc/permissions/privapp-permissions-com.powos.app.xml >/dev/null 2>&1 || die "push to /system failed"
  a shell 'chmod 644 /system/priv-app/PowOS/PowOS.apk /system/etc/permissions/privapp-permissions-com.powos.app.xml; chcon u:object_r:system_file:s0 /system/priv-app/PowOS /system/priv-app/PowOS/PowOS.apk /system/etc/permissions/privapp-permissions-com.powos.app.xml'
}
# The recents slot (targets/android/system-module/overlays-disabled/recents, the static framework RRO naming PowOS
# config_recentsComponentName): with it PowOS holds the recents role's permissions (MANAGE_ACTIVITY_TASKS: every
# task's window, READ_FRAME_BUFFER ...) as on the phone. Compiled and signed as build-module.sh does (its overlay key).
recents_overlay() {
  local o=$STATE/overlay keys=$HOME/.local/share/powos
  [ -f "$keys/overlay.jks" ] || die "no $keys/overlay.jks (build-module.sh makes it once)"
  rm -rf "$o"; mkdir -p "$o"; cp -R "$ROOT/targets/android/system-module/overlays-disabled/recents" "$o/recents"; cp "$keys/overlay.jks" "$o/"
  docker run --rm -v "$o:/t" --entrypoint bash "$IMAGE" -c 'set -e; B=/opt/android-sdk/build-tools/35.0.0; o=/t/recents
    $B/aapt2 compile --dir $o/res -o $o/res.zip
    $B/aapt2 link -o $o/unsigned.apk -I /opt/android-sdk/platforms/android-36/android.jar --manifest $o/AndroidManifest.xml $o/res.zip
    $B/apksigner sign --ks /t/overlay.jks --ks-pass pass:powos-overlay --ks-key-alias overlay --out /t/PowOS-recents.apk $o/unsigned.apk' >/dev/null || die "the recents overlay didn't build"
  a push "$o/PowOS-recents.apk" /system/product/overlay/PowOS-recents.apk >/dev/null 2>&1 || die "can't push the recents overlay"
  a shell 'chmod 644 /system/product/overlay/PowOS-recents.apk; chcon u:object_r:system_file:s0 /system/product/overlay/PowOS-recents.apk'
}
# su as the phone has it (Magisk grants PowOS root): tools/emu/su.c, built with the NDK the warm builder has.
su_install() {
  local d=$STATE/su; mkdir -p "$d"
  if [ ! -f "$d/su" ] || [ "$here/su.c" -nt "$d/su" ]; then
    "$ROOT/targets/android/tools/warm-builder.sh" start >/dev/null 2>&1 || die "the warm builder (NDK) isn't up"
    docker cp "$here/su.c" powos-gradle-warm:/tmp/powos-emu-su.c >/dev/null
    docker exec powos-gradle-warm sh -c 'cc=$(ls -d /opt/android-sdk/ndk/*/toolchains/llvm/prebuilt/linux-*/bin/aarch64-linux-android30-clang | tail -1); "$cc" -O2 -static -o /tmp/powos-emu-su /tmp/powos-emu-su.c' || die "su.c didn't build"
    docker cp powos-gradle-warm:/tmp/powos-emu-su "$d/su" >/dev/null || die "can't copy su out"
  fi
  a push "$d/su" /system/xbin/su >/dev/null 2>&1 || die "can't push su"
  a shell 'chown root:shell /system/xbin/su; chmod 6755 /system/xbin/su; chcon u:object_r:su_exec:s0 /system/xbin/su'
}
# The phone's settings the window paths need, and SELinux permissive (the phone's Magisk policy lets PowOS's su
# children do what they do; the emulator has no Magisk).
# persist.powos.root=1: the flag rooted.sh sets on the phone (RootMode.java: home made Android's default through su, ...).
# Freeform support is read at boot: set before create's last reboot.
settings_like_phone() {
  a shell 'setprop persist.powos.root 1; settings put global enable_freeform_support 1; settings put global force_resizable_activities 1; settings put global development_settings_enabled 1;
    settings put global window_animation_scale 1; settings put system screen_off_timeout 2147483647; svc power stayon true; locksettings set-disabled true 2>/dev/null; true'
}
# HACK: SELinux permissive on the emulator: its policy has no rules for the PowOS app's su children (the phone's Magisk
# patches them in). Real fix: Magisk (su + sepolicy patches) on the AVD, then enforcing (docs/REMOTE-POWOS.md section 4).
selinux_permissive() { a shell setenforce 0; }
# What the phone's user granted PowOS over time: every runtime permission it asks for, drawing over apps (the window
# frames, edge handles: TYPE_APPLICATION_OVERLAY), all files. And the AVD's own launcher off: no longer the recents
# app, it crash-loops ("Application Error" over home); Android System Intelligence's language-pack download page came up
# in front of the checks. Idempotent: at every start (installs keep grants anyway).
grants_like_phone() {
  a shell 'for p in $(dumpsys package com.powos.app | sed -n "s/^ *\(android\.permission\.[A-Z_]*\): granted=false.*/\1/p" | sort -u); do pm grant com.powos.app $p 2>/dev/null; done
    appops set com.powos.app SYSTEM_ALERT_WINDOW allow; appops set com.powos.app MANAGE_EXTERNAL_STORAGE allow; appops set com.powos.app GET_USAGE_STATS allow
    pm disable-user --user 0 com.google.android.apps.nexuslauncher >/dev/null 2>&1
    pm disable-user --user 0 com.google.android.as >/dev/null 2>&1; true'
}
testwin() {
  local apk; apk=$("$here/testwin/build.sh") || die "the test window client didn't build"
  a install -r "$apk" >/dev/null || die "the test window client didn't install"
}
install() {
  local apk c; apk=$(build "${1:-}") || exit 1; c=$(basename "$apk" .apk)
  a install -r -d "$apk" >/dev/null 2>"$STATE/install.err" || die "adb install failed: $(cat "$STATE/install.err")"
  # powos-units: ~/.android/avd/powos-open.avd/*
  a shell "echo $c > $COMMIT_FILE"
  a shell 'pm enable com.powos.app/andro.marchy.HomeShell >/dev/null 2>&1; cmd package set-home-activity --user 0 com.powos.app/andro.marchy.HomeShell >/dev/null 2>&1; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null'
  say "PowOS from $(git -C "$REPO" rev-parse --short "$c") installed ($(a shell dumpsys package com.powos.app | tr -d '\r' | grep -m1 -o 'versionCode=[0-9]*'))"
}
# home_ready: home's page booted (window.__powosAlive, as ship-apk waits for) - right after an install or a snapshot
# load the page takes 10-20 s on the software renderer, and a check started before read errors as home's state (the
# layout hash at its start was an error's, "home layout CHANGED", 2026-10-24). 120 s at most.
home_ready() { local i
  for i in $(seq 60); do
    [ "$(POWOS_DEVICE=emu CDP_TIMEOUT_S=5 "$ROOT/tools/phone/cdp.sh" eval home 'String(window.__powosAlive)' 2>/dev/null | tr -d '"\r')" = true ] && return 0
    sleep 2; done
  say "home's page didn't answer within 120 s"; return 1; }
# up_to_date: the APK of origin's tip (or EMU_COMMIT) on the emulator.
up_to_date() { local want=${EMU_COMMIT:-$(tip)}; [ "$(emu_commit)" = "$want" ] || install "$want"; }

case "${1:-}" in
create)
  space_guard "creating the AVD"
  image; halt
  rm -rf "$AVD_HOME/$AVD.avd"; avd_files
  boot -no-snapshot-load -no-snapshot-save
  root_up
  # The first remount on a fresh AVD turns verity off and needs a reboot.
  a remount 2>&1 | grep -qi reboot && { say "remount: rebooting once (verity off)"; a reboot; wait_dev; wait_boot 300; root_up; a remount >/dev/null 2>&1; }
  su_install
  apk=$(build "${2:-}") || exit 1
  priv "$apk"; recents_overlay; settings_like_phone
  say "rebooting with PowOS as a system app"; a reboot; wait_dev; wait_boot 300; root_up
  # powos-units: ~/.android/avd/powos-open.avd/*
  a shell "echo $(basename "$apk" .apk) > $COMMIT_FILE"
  selinux_permissive; grants_like_phone; testwin
  a shell 'pm enable com.powos.app/andro.marchy.HomeShell >/dev/null 2>&1; cmd package set-home-activity --user 0 com.powos.app/andro.marchy.HomeShell >/dev/null 2>&1; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null'
  sleep 20   # home's first boot (shell unpacked, pages up) into the snapshot
  a emu avd snapshot save "$SNAP" | tr -d '\r' | grep -v '^OK$'
  say "created: snapshot $SNAP ($(du -sh "$AVD_HOME/$AVD.avd" | cut -f1)); stop: emu.sh stop"
  ;;
start)
  [ -f "$AVD_HOME/$AVD.avd/config.ini" ] || die "no AVD: emu.sh create" 2
  # A wedged emulator (system_server killed by its watchdog in a loop: its renderer stuck in
  # HardwareRenderer.setStopped, "Can't find service: package", 2026-10-24 04:29) answers adb but not as Android:
  # its package service is asked first, and a dead one is stopped and started again from the snapshot.
  if pgrep -f -- "-avd $AVD( |$)" >/dev/null && { ! running || ! a shell cmd package path com.powos.app >/dev/null 2>&1; }; then
    say "the emulator runs but Android doesn't answer (wedged or offline) - starting again from $SNAP"; halt; fi
  if ! running; then space_guard "starting"; boot -snapshot "$SNAP" -no-snapshot-save; fi
  root_up; selinux_permissive
  up_to_date; grants_like_phone
  if ! home_ready; then say "starting again from $SNAP"; halt; boot -snapshot "$SNAP" -no-snapshot-save; root_up; selinux_permissive
    up_to_date; grants_like_phone; home_ready || die "home's page doesn't come up on the emulator ($STATE/emulator.log)"; fi
  say "up on $SERIAL (POWOS_DEVICE=emu)"
  ;;
stop) if running || pgrep -f -- "-avd $AVD( |$)" >/dev/null; then halt; say "stopped"; else say "not running"; fi ;;
status)
  if running; then echo "running on $SERIAL, booted=$(booted && echo yes || echo no), PowOS from $(emu_commit | cut -c1-9)"; else echo "not running"; fi
  echo "disk: AVD $(du -sh "$AVD_HOME/$AVD.avd" 2>/dev/null | cut -f1), image $(du -sh "$SDK/$IMG_DIR" 2>/dev/null | cut -f1), Mac free $(free_gb) GB"
  ;;
reset)
  running || exec "$0" start
  a emu avd snapshot load "$SNAP" | tr -d '\r' | grep -v '^OK$'; wait_dev; wait_boot 120; root_up; selinux_permissive; up_to_date; grants_like_phone; home_ready
  say "reset to $SNAP"
  ;;
install) running || die "not running: emu.sh start" 2; root_up; install "${2:-}"; grants_like_phone; home_ready ;;
remove)
  halt
  rm -rf "$AVD_HOME/$AVD.avd" "$AVD_HOME/$AVD.ini" "$STATE"
  [ -e "$BUILD_TREE/.git" ] && git -C "$REPO" worktree remove --force "$BUILD_TREE"
  say "removed the AVD, its snapshot, $STATE and the build checkout (system image kept: $SDK/$IMG_DIR)"
  ;;
*) sed -n 2,22p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
