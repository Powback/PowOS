#!/bin/bash
# lanes: phone emu
# lock-custom.sh (board customize-the-lock-screen): read only - no touch, no setting changed. On the phone after the
# ship (APK + shell):
#   1. the APK answers "lock.locked" (KeyguardManager.isDeviceLocked: the face's long press edits only when false) - a
#      boolean, not "unknown method";
#   2. the store's "lock.face" (lockstyle.ts: clock / backdrop / glance / corners, kept by the face's edit and Settings >
#      lock screen) reads back: null (never edited, the default face) or a whole face.
# The edit itself (long press, picks, the customized face) is the gate's LC1 + the lock-edit / lock-custom scenes.
# Exit 0 pass, 1 fail.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
export T=$here/..  # base.sh's hcall (cdp.sh) reads it
. "$here/base.sh"
step "the APK's lock.locked" 60
v=$(hcall lock.locked '[]' 'v=>String(v)')
case $v in true|false) pass "lock.locked answers $v" ;; *) fail "lock.locked: '$v' (APK without it?)" ;; esac
step "the stored lock face" 60
f=$(hcall store.get '["lock.face"]' 'v=>JSON.stringify(v)')
vb_say "lock.face: $f"
case $f in null|*clock*corners*) pass "lock.face reads back" ;; *) fail "lock.face: '$f'" ;; esac
result "lock screen customization: host method present, stored face readable"
