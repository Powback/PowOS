#!/usr/bin/env bash
# Builds the PowOS system module: a Magisk module that installs the PowOS app as a privileged system app
# (/system/priv-app, systemless), the first step to PowOS filling the phone's system UI slots (docs/NATIVE-SYSTEM-UI.md).
#
#   build-module.sh [--priv-app] [--slot NAME]... [--apk powos.apk] [--refresh-perms] [--check-signer]
#
# Without --priv-app the module carries only the slots' overlays (overlays/): the app stays an ordinary app. As a
# privileged app (priv_app) PowOS may not create or connect to socket files in its own data (no sock_file rules for
# privapp_data_file on this phone); the rooted session's sockets on the app's side are abstract ones since 2026-10-19,
# so --priv-app runs the session too (docs/NATIVE-SYSTEM-UI.md, "priv_app and sockets").
#
# - The APK is the release build (targets/android/build-app.sh's output): the same one the phone has installed, signed
#   with the same key - a system copy signed otherwise would make Android drop the installed app and its data
#   (the Linux session included). --check-signer compares the two certificates on the connected phone first.
# - The privileged permissions it requests go into its privapp-permissions allowlist. The phone enforces that list
#   (ro.control_privapp_permissions=enforce): one missing and Android won't boot. So the build fails if any requested
#   permission that's privileged (privileged-perms.txt: the phone's own list, --refresh-perms reads it again) isn't
#   on the list: privapp-permissions.txt, reviewed by hand - each entry is a power the app gets.
# - overlays/<slot>/: one resource overlay per system UI slot (config_dozeComponent, ...). Static, as the system server
#   only takes immutable framework overlays: each is on while the module is (off: disable it in Magisk, reboot).
#   Signed with a key of their own (~/.local/share/powos/overlay.jks, made once; not the app's). overlays-disabled/
#   keeps slots that aren't shipped: doze (PowOS as the screen-off display) felt laggy on the phone and was reverted.
#   --slot NAME ships one of those too, for trying it on the phone before it moves to overlays/. The recents slot
#   (PowOS as the recents provider: switcher, shade) needs --priv-app: SystemUI binds only a system package's service.
# - module/: the boot watchdog (post-fs-data.sh counts boots, service.sh clears the count once Android is up; two
#   that never finish and the module disables itself), and load-kernel-modules.sh: the containers kernel's nftables
#   modules (kernel/out/modules, when built), insmodded at boot in the background (docs/PHONE-KERNEL-CONTAINERS.md §9).
#
# Output: ~/Projects/android-app-dev/output/powos-system-module.zip (install: magisk --install-module, reboot).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
APK=~/Projects/android-app-dev/output/powos.apk
OUT=~/Projects/android-app-dev/output/powos-system-module.zip
PHONE=${ANDROID_SERIAL:-192.168.50.239:5555}
IMAGE=android-app-dev-android-builder:latest
AAPT2=/opt/android-sdk/build-tools/35.0.0/aapt2
APKSIGNER=/opt/android-sdk/build-tools/35.0.0/apksigner
refresh=0 signer=0 priv=0 slots=()
while [ $# -gt 0 ]; do
    case $1 in
        --apk) APK=$2; shift ;;
        --priv-app) priv=1 ;;
        --slot) slots+=("$2"); shift ;;
        --refresh-perms) refresh=1 ;;
        --check-signer) signer=1 ;;
        *) echo "build-module.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
for slot in ${slots[@]+"${slots[@]}"}; do
    [ -d "$HERE/overlays-disabled/$slot" ] || { echo "build-module.sh: no slot $slot in overlays-disabled/" >&2; exit 2; }
done
if [ $priv = 0 ] && { [ -d "$HERE/overlays/recents" ] || [[ " ${slots[*]-} " == *" recents "* ]]; }; then
    echo "build-module.sh: the recents slot needs --priv-app (SystemUI binds only a system package's QUICKSTEP_SERVICE; without it the overview button and gestures do nothing)" >&2
    exit 2
fi
[ -f "$APK" ] || { echo "build-module.sh: no APK at $APK (targets/android/build-app.sh builds it)" >&2; exit 1; }
APK=$(cd "$(dirname "$APK")" && pwd)/$(basename "$APK")

# Android's SDK tools, from the image the app is built with.
sdk() { docker run --rm --entrypoint "$1" -v "$(dirname "$APK"):/w:ro" -v "$WORK:/t" "$IMAGE" "${@:2}"; }
# Under home: the Mac's Docker (Colima) only shares that.
mkdir -p ~/.cache && WORK=$(mktemp -d ~/.cache/powos-module.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

if [ $refresh = 1 ]; then
    adb -s "$PHONE" shell pm list permissions -f |
        awk -F: '/^\+ permission:/{p=$2} /protectionLevel:/ && $2 ~ /privileged/ {print p}' | sort -u > "$HERE/privileged-perms.txt"
    echo "privileged permissions on the phone: $(wc -l < "$HERE/privileged-perms.txt")"
fi
[ -s "$HERE/privileged-perms.txt" ] || { echo "build-module.sh: no privileged-perms.txt (--refresh-perms with the phone connected)" >&2; exit 1; }

sdk "$AAPT2" dump permissions "/w/$(basename "$APK")" | sed -n "s/^uses-permission: name='\([^']*\)'.*/\1/p" | sort -u > "$WORK/requested"
version=$(sdk "$AAPT2" dump badging "/w/$(basename "$APK")" | sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p" | head -1)
[ -n "$version" ] && [ -s "$WORK/requested" ] || { echo "build-module.sh: can't read $APK" >&2; exit 1; }

# The allowlist, as reviewed; the build stops on anything privileged the APK asks for beyond it.
{ grep -v '^\s*\(#\|$\)' "$HERE/privapp-permissions.txt" || true; } | sort -u > "$WORK/allow"
missing=$(comm -23 <(comm -12 "$WORK/requested" "$HERE/privileged-perms.txt") "$WORK/allow")
if [ -n "$missing" ]; then
    echo "build-module.sh: privileged permissions requested but not in privapp-permissions.txt (Android wouldn't boot):" >&2
    echo "$missing" >&2
    exit 1
fi

if [ $signer = 1 ]; then
    installed=$(adb -s "$PHONE" shell pm path com.powos.app | sed -n 's/^package://p' | head -1 | tr -d '\r')
    adb -s "$PHONE" pull -q "$installed" "$WORK/installed.apk"
    cert() { sdk "$APKSIGNER" verify --print-certs "$1" | sed -n 's/.*certificate SHA-256 digest: //p' | head -1; }
    ours=$(cert "/w/$(basename "$APK")")
    theirs=$(cert /t/installed.apk)
    [ -n "$ours" ] && [ "$ours" = "$theirs" ] || { echo "build-module.sh: signer differs from the installed app ($ours vs $theirs) - its data would be dropped" >&2; exit 1; }
    echo "signer matches the installed app: $ours"
fi

M=$WORK/module
mkdir -p "$M"
if [ $priv = 1 ]; then
mkdir -p "$M/system/priv-app/PowOS" "$M/system/etc/permissions"
cp "$APK" "$M/system/priv-app/PowOS/PowOS.apk"
{
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<!-- Generated by targets/android/system-module/build-module.sh: what the PowOS app may hold as a privileged app. -->'
    echo '<permissions>'
    echo '    <privapp-permissions package="com.powos.app">'
    sed 's/.*/        <permission name="&"\/>/' "$WORK/allow"
    echo '    </privapp-permissions>'
    echo '</permissions>'
} > "$M/system/etc/permissions/privapp-permissions-com.powos.app.xml"
fi
cp "$HERE/module/post-fs-data.sh" "$HERE/module/service.sh" "$HERE/module/load-kernel-modules.sh" "$M/"
# What the module installs and runs, as units (lib/apps/powos-units: `powos units` on the phone's Android side reads
# /data/adb/modules/*/powos-units/*.json): the module registers itself, and goes with itself.
mkdir -p "$M/powos-units" && cp "$HERE/../../../units/system-module/"*.json "$M/powos-units/"
# The containers kernel's nftables modules (kernel/build-containers-kernel.sh's out/modules), loaded at boot by
# load-kernel-modules.sh; refused cleanly by any other kernel. Not built: the module just doesn't carry them.
KM=$HERE/../kernel/out/modules
if [ -f "$KM/load-order.txt" ]; then
    mkdir -p "$M/kernel-modules"
    cp "$KM/load-order.txt" "$M/kernel-modules/"
    for m in $(cat "$KM/load-order.txt"); do cp "$KM/$m" "$M/kernel-modules/"; done
fi

# The slots' overlays: compiled, linked against the platform, signed.
KEYS=~/.local/share/powos
mkdir -p "$KEYS" "$M/system/product/overlay" "$WORK/overlays"
shopt -s nullglob  # no overlays at all is fine: the module is then the priv-app (or just the watchdog)
for dir in "$HERE"/overlays/*/; do cp -R "$dir" "$WORK/overlays/"; done
for slot in ${slots[@]+"${slots[@]}"}; do cp -R "$HERE/overlays-disabled/$slot" "$WORK/overlays/"; done
[ -f "$KEYS/overlay.jks" ] || {
    sdk keytool -genkeypair -keystore /t/overlay.jks -storepass powos-overlay -keypass powos-overlay -alias overlay \
        -keyalg RSA -keysize 2048 -validity 36500 -dname "CN=PowOS system overlays" >/dev/null 2>&1
    cp "$WORK/overlay.jks" "$KEYS/overlay.jks"
}
cp "$KEYS/overlay.jks" "$WORK/overlay.jks"
for dir in "$WORK"/overlays/*/; do
    slot=$(basename "$dir")
    o=/t/overlays/$slot
    sdk "$AAPT2" compile --dir "$o/res" -o "$o/res.zip"
    sdk "$AAPT2" link -o "$o/unsigned.apk" -I /opt/android-sdk/platforms/android-36/android.jar --manifest "$o/AndroidManifest.xml" "$o/res.zip"
    sdk "$APKSIGNER" sign --ks /t/overlay.jks --ks-pass pass:powos-overlay --ks-key-alias overlay --out "$o/overlay.apk" "$o/unsigned.apk"
    cp "$dir/overlay.apk" "$M/system/product/overlay/PowOS-$slot.apk"
done
cat > "$M/module.prop" <<PROP
id=powos-system
name=PowOS system
version=$version
versionCode=$version
author=PowOS
description=PowOS's system UI slots (overlays: the screen-off display, ...)$([ $priv = 1 ] && echo ", and the PowOS app as a privileged system app"). Turns itself off after two boots that don't finish.
PROP
rm -f "$OUT"
(cd "$M" && zip -qr "$OUT" .)
echo "$OUT: PowOS $version, priv-app: $([ $priv = 1 ] && echo yes || echo no), allowlisted: $(tr '\n' ' ' < "$WORK/allow"), overlays: $(ls "$M/system/product/overlay" | tr '\n' ' ')"
