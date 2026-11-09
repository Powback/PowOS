#!/system/bin/sh
# app-ca.sh - the App API's LOCAL certificate: generate it once on THIS device, and (an explicit, separate step)
# install it into the system trust store so the on-device capture proxy can read HTTPS from apps the OWNER has
# EXPLICITLY enabled in the App API UI. Owner's phone, owner's apps, owner's accounts - nothing leaves the LAN.
# Unit: units/phone-android/app-ca.json. Run by the Mac wrapper `rooted.sh app-ca [install|status|remove]`
# (pushed + run as root on the Android side via Magisk). Not from the Mac directly; the owner runs it, present.
#
# What it is, in three parts, each a deliberate act:
#   gen      make the local CA (private key + cert) on this device. The PRIVATE KEY stays at
#            /data/powos/app-api/ca.key (0600), is never printed, never logged, never copied off the device, and is
#            never put in the Magisk module (only the public cert is). Idempotent: an existing key is kept.
#   install  (needs root) add ONLY the public cert to the system trust store, via a Magisk module that overlays the
#            cacerts dir at boot. This is the step that changes what the device trusts - it is this command, printed
#            and followed by a reboot, never a silent side effect of anything else. Android 7+ apps ignore user-store
#            CAs, which is why system trust needs root + a module here.
#   remove   drop the module (+ reboot) so the trust store reverts fully. Keeps nothing. Optionally --wipe-key also
#            deletes the local CA key/cert.
#
# Scope: trusting the CA does NOT by itself route or capture anything. Capture is per-app: only packages the owner
# enabled in the App API are ever routed to the proxy (appcap_proxy.py --app NAME); every other app's traffic passes
# untouched and is not intercepted. SELinux is never touched. Non-root parity: see docs/APP-API.md "Capture on a
# non-rooted device".
set -u

R=/data/powos/root                      # PowOS chroot (has openssl); the Android side may not
AA=/data/powos/app-api                  # shared path, same on the Android side and inside the chroot
KEY=$AA/ca.key
CRT=$AA/ca.crt
MOD=/data/adb/modules/powos-appca
CN="PowOS App API Local CA"

die() { echo "app-ca: $*" >&2; exit 1; }

# openssl inside the PowOS chroot - keeps the one toolchain and never writes the key outside $AA.
ossl() { chroot "$R" /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/usr/sbin HOME=/root /usr/bin/openssl "$@"; }

gen() {
  mkdir -p "$AA" || die "cannot make $AA"
  chmod 700 "$AA"
  if [ -s "$KEY" ] && [ -s "$CRT" ]; then
    echo "app-ca: local CA already present (keeping it)"
  else
    # 10-year local CA. The key never leaves this block's redirect into $KEY; stdout/stderr never carry it.
    ( umask 077
      ossl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
        -keyout "$KEY" -out "$CRT" -subj "/CN=$CN/O=PowOS/OU=App API local" ) >/dev/null 2>&1 \
      || die "openssl failed (is PowOS deployed? chroot $R)"
    chmod 600 "$KEY"; chmod 644 "$CRT"
    echo "app-ca: generated a new local CA (private key stays on this device, 0600, never printed)"
  fi
  # The only thing we ever show is the public fingerprint, so the owner can confirm it on the device.
  fp=$(ossl x509 -in "$CRT" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')
  echo "app-ca: CA cert  $CRT  (public)"
  echo "app-ca: SHA-256  $fp"
}

# The system-trust directory Android actually reads. Newer Android serves CA trust from the conscrypt apex; older
# builds from /system/etc/security/cacerts. We mirror whichever exists so apps see the same set + our one CA.
src_cacerts() {
  for d in /apex/com.android.conscrypt/cacerts /system/etc/security/cacerts; do
    [ -d "$d" ] && { echo "$d"; return; }
  done
}

install() {
  [ "$(id -u)" = 0 ] || die "install needs root (run via rooted.sh app-ca install)"
  [ -s "$CRT" ] || gen
  SRC=$(src_cacerts); [ -n "$SRC" ] || die "no system cacerts dir found"
  hash=$(ossl x509 -in "$CRT" -noout -subject_hash_old 2>/dev/null) || die "cannot hash the CA cert"
  [ -n "$hash" ] || die "empty cert hash"

  # Build the module: a tmpfs copy of the real trust dir + our one public cert, bind-mounted at boot. Only the
  # PUBLIC cert is ever written here - never the key.
  rm -rf "$MOD"
  mkdir -p "$MOD" || die "cannot create module dir (is Magisk present?)"
  cat > "$MOD/module.prop" <<EOF
id=powos-appca
name=PowOS App API Local CA
version=1
versionCode=1
author=owner
description=Adds the owner's local App API CA to the system trust store (enabled apps' HTTPS capture). Public cert only.
EOF
  mkdir -p "$MOD/powos"
  cp "$CRT" "$MOD/powos/ca.crt" || die "cannot stage the public cert"
  echo "$hash.0" > "$MOD/powos/hash.txt"

  # post-fs-data.sh: assemble trust = (real system trust) + (our CA), on a tmpfs, then bind it over $SRC. No system
  # partition is modified; a reboot without the module reverts everything.
  cat > "$MOD/post-fs-data.sh" <<'EOF'
#!/system/bin/sh
MODDIR=${0%/*}
SRC=""
for d in /apex/com.android.conscrypt/cacerts /system/etc/security/cacerts; do
  [ -d "$d" ] && { SRC="$d"; break; }
done
[ -n "$SRC" ] || exit 0
TMP=/data/adb/powos/appca-trust
rm -rf "$TMP"; mkdir -p "$TMP"
cp -f "$SRC"/* "$TMP"/ 2>/dev/null
h=$(cat "$MODDIR/powos/hash.txt" 2>/dev/null)
[ -n "$h" ] && cp -f "$MODDIR/powos/ca.crt" "$TMP/$h"
chmod 644 "$TMP"/* 2>/dev/null
chown 0:0 "$TMP"/* 2>/dev/null
# Mirror SELinux labels from the real dir so apps can read the overlaid files.
sctx=$(ls -Zd "$SRC" 2>/dev/null | awk '{print $1}')
[ -n "$sctx" ] && chcon -R "$sctx" "$TMP" 2>/dev/null
mount -o bind "$TMP" "$SRC"
# The conscrypt apex is also mounted per-process-namespace on some builds; re-bind in the system_server ns if present.
EOF
  chmod 755 "$MOD/post-fs-data.sh"

  echo "app-ca: module installed at $MOD (public cert $hash.0 into $SRC)"
  echo "app-ca: REBOOT to make the device trust the local CA:  rooted.sh run reboot   (or reboot the phone)"
  echo "app-ca: this only adds the CA to the trust store; it does NOT route or capture any app on its own."
}

status() {
  [ -s "$CRT" ] && echo "app-ca: local CA present ($CRT; key $( [ -s "$KEY" ] && echo on-device || echo MISSING))" \
                || echo "app-ca: no local CA yet (run: rooted.sh app-ca gen)"
  [ -d "$MOD" ] && echo "app-ca: trust module installed ($MOD) - active after a reboot" \
                || echo "app-ca: trust module NOT installed (run: rooted.sh app-ca install)"
}

remove() {
  rm -rf "$MOD"
  echo "app-ca: removed the trust module. REBOOT to drop the CA from the trust store."
  if [ "${1:-}" = --wipe-key ]; then
    rm -f "$KEY" "$CRT"
    echo "app-ca: wiped the local CA key + cert too."
  else
    echo "app-ca: kept the local CA key/cert ($AA); add --wipe-key to delete them."
  fi
}

case "${1:-status}" in
  gen) gen ;;
  install) install ;;
  status) status ;;
  remove) remove "${2:-}" ;;
  *) echo "usage: app-ca.sh [gen|install|status|remove [--wipe-key]]"; exit 2 ;;
esac
