#!/system/bin/sh
# app-ca.sh - the App API's LOCAL certificate: generate it once on THIS device, and (an explicit, separate step)
# install it into the system trust store so the on-device capture proxy can read HTTPS from apps the OWNER has
# EXPLICITLY enabled in the App API UI. Owner's phone, owner's apps, owner's accounts - nothing leaves the LAN.
# Unit: units/phone-android/app-ca.json. Run by the Mac wrapper `rooted.sh app-ca [gen|install|status|remove]`
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
#            deletes the local CA key/cert; --dry-run only says what it would remove. Every verb takes --help.
#
# Scope: trusting the CA does NOT by itself route or capture anything. Capture is per-app: only packages the owner
# enabled in the App API are ever routed to the proxy (appcap_proxy.py --app NAME); every other app's traffic passes
# untouched and is not intercepted. SELinux is never touched. Non-root parity: see docs/APP-API.md "Capture on a
# non-rooted device".
set -u

R=/data/powos/root                      # PowOS chroot (has openssl); the Android side may not
AA=/data/powos/app-api                  # Android-side path (NOT visible inside the chroot)
KEY=$AA/ca.key
CRT=$AA/ca.crt
MOD=/data/adb/modules/powos-appca
CN="PowOS App API Local CA"

die() { echo "app-ca: $*" >&2; exit 1; }

# openssl inside the PowOS chroot - keeps the one toolchain. The chroot can't see /data/powos/app-api (only the
# Android side can), so openssl only ever gets chroot-valid paths: it writes into a root-only scratch dir inside the
# chroot ($GEN_IN, seen from Android as $GEN) and reads certs on stdin. The results are then moved into $AA.
GEN_IN=/root/.powos-appca-gen           # chroot path
GEN=$R$GEN_IN                           # the same dir, seen from the Android side
ossl() { chroot "$R" /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/usr/sbin HOME=/root /usr/bin/openssl "$@"; }

gen() {
  [ "$(id -u)" = 0 ] || die "gen needs root (run via rooted.sh app-ca gen)"
  [ -x "$R/usr/bin/openssl" ] || die "no openssl in the PowOS chroot ($R/usr/bin/openssl): is PowOS deployed?"
  ( umask 077; mkdir -p "$AA" ) || die "cannot make $AA"
  chmod 700 "$AA"; chown 0:0 "$AA" 2>/dev/null
  if [ -s "$KEY" ] && [ -s "$CRT" ]; then
    echo "app-ca: local CA already present (keeping it)"
  else
    # 10-year local CA. umask 077 from here on: the key is 0600 from the moment it exists. openssl's stdout/stderr
    # are dropped (they never carry the key, but nothing about the key is ever shown).
    ( umask 077
      rm -rf "$GEN" && mkdir -p "$GEN" || exit 1
      ossl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
        -keyout "$GEN_IN/ca.key" -out "$GEN_IN/ca.crt" -subj "/CN=$CN/O=PowOS/OU=App API local" >/dev/null 2>&1 \
        && [ -s "$GEN/ca.key" ] && [ -s "$GEN/ca.crt" ] \
        && chmod 600 "$GEN/ca.key" \
        && mv -f "$GEN/ca.key" "$KEY" && mv -f "$GEN/ca.crt" "$CRT" )
    rc=$?
    rm -rf "$GEN"
    [ $rc = 0 ] || { rm -f "$KEY" "$CRT"; die "openssl failed in the PowOS chroot ($R); nothing kept"; }
    chown 0:0 "$KEY" "$CRT" 2>/dev/null; chmod 600 "$KEY"; chmod 644 "$CRT"
    echo "app-ca: generated a new local CA (private key stays on this device, 0600 root-only, never printed)"
  fi
  # The only thing we ever show is the public fingerprint, so the owner can confirm it on the device.
  fp=$(ossl x509 -noout -fingerprint -sha256 < "$CRT" 2>/dev/null | sed 's/.*=//')
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
  hash=$(ossl x509 -noout -subject_hash_old < "$CRT" 2>/dev/null) || die "cannot hash the CA cert"
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
  dry="" wipe=""
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      --wipe-key) wipe=1 ;;
      *) usage_of remove >&2; exit 2 ;;
    esac
  done
  if [ -n "$dry" ]; then
    [ -d "$MOD" ] && echo "app-ca: (dry run) would remove the trust module $MOD" \
                  || echo "app-ca: (dry run) no trust module at $MOD; nothing to remove"
    if [ -n "$wipe" ]; then echo "app-ca: (dry run) would wipe the local CA key + cert ($AA)"
    else echo "app-ca: (dry run) would keep the local CA key/cert ($AA)"; fi
    echo "app-ca: (dry run) nothing changed"
    return 0
  fi
  rm -rf "$MOD"
  echo "app-ca: removed the trust module. REBOOT to drop the CA from the trust store."
  if [ -n "$wipe" ]; then
    rm -f "$KEY" "$CRT"
    echo "app-ca: wiped the local CA key + cert too."
  else
    echo "app-ca: kept the local CA key/cert ($AA); add --wipe-key to delete them."
  fi
}

usage_of() {
  case "$1" in
    gen) echo "usage: app-ca.sh gen        make the local CA on this device (key 0600 in $AA, never printed); idempotent" ;;
    install) echo "usage: app-ca.sh install    add the public cert to system trust via a Magisk module (then reboot)" ;;
    status) echo "usage: app-ca.sh status     is the local CA / trust module present" ;;
    remove) echo "usage: app-ca.sh remove [--dry-run] [--wipe-key]   drop the trust module (then reboot); --dry-run changes nothing" ;;
    *) echo "usage: app-ca.sh [gen|install|status|remove [--dry-run] [--wipe-key]]   (VERB --help for one verb)" ;;
  esac
}

# Every verb answers --help/-h without doing anything; a verb that takes no options refuses unknown ones (so a
# stray flag can never fall through into an action).
verb=${1:-status}; [ $# -gt 0 ] && shift
for a in "$@"; do case "$a" in -h|--help|help) usage_of "$verb"; exit 0 ;; esac; done
case "$verb" in
  -h|--help|help) usage_of ""; exit 0 ;;
  gen|install|status) [ $# = 0 ] || { usage_of "$verb" >&2; exit 2; }; "$verb" ;;
  remove) remove "$@" ;;
  *) usage_of "" >&2; exit 2 ;;
esac
