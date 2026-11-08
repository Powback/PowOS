#!/system/bin/sh
# powos adb-key self-heal (added 2026-11-08 by the PowOS manager, user decision 11-08).
# GUARD: restores ONLY the Mac's adb public key, and ONLY if its key material is missing from
# /data/misc/adb/adb_keys. Append-only: never removes, rewrites, or reorders any other key.
# Idempotent and safe to run at boot and on a timer. Fixes the 11-08 outage where the phone
# dropped the Mac's key and blocked all phone work for ~8h.
KEYFILE=/data/misc/adb/adb_keys
STATE=/data/powos/state/adb-key-heal.log
# The ONE key this heal is allowed to restore (Mac: ~/.android/adbkey.pub, macback@macback.local).
MAC_KEY='QAAAAEcBdluJp9w2INBRFwmlCOA+4RhGAfUfLzCNwQr+y31NkbcP+OcEwR/MsZ6cLl9sE67OUtnVNAA+SSvr7yPD2Fim0nlPmYCwmmkyTjM+gOZvoTWn/w5gh7y4jCQdL7A8/r5HS2acnXyaO92uH9QvNqtDOfBOpPp/la8OiOZZwb3DboCyYCIXXUZY9V40x2Uzsdx/NQOvYhZ8Vuzwc1BWO3FsyDEB7UrR7XgPx9ridsEwWPyrxTBG1kAKgt0q0KzS4KOqTITFwKrkg6LcHe6m8D5equNs5QvdgaIEt5GLpOWyuKsApMaU9sRP7sUG5h4Z+gUjoqTHHGIkts6e21x2hFcpwTSvJB/rAx1b/GH3cM/KHNhacyRAR8hAFbTJvhQ5+wdiLLRtjvGtdNNKTavFpcFSyMmbhssPwuVjNnXkDU0Mnd2G75QeFL1Azq6giqYz5BRbGtFIQdkLhfOY92xKCTzEoUzXxsDshFJC604h4kytnUxHKksbbbEpiCqxj76DIM5Bb2mSvKHwvRjpvoCfjM3vxO5l/sEJt53LHyn5vqRLBYzzVKoDVMnW6yHuHUpSCreOKI7S3mvqpjr7540teT5U+hzhetHofW+LIavRzyTCxdx+TEPs9AIo6jD7eeXmN8l9np/QXB+dpxcB+fpQAZMp8QnTwLYOEM71MwjiSGVKdc+qaAEAAQA= macback@macback.local'
# Presence check uses ONLY the key material (first field) so a differing trailing comment still counts as present.
MAC_MATERIAL=${MAC_KEY%% *}
mkdir -p /data/powos/state
# If the key material is already present, do nothing (idempotent).
if [ -f "$KEYFILE" ] && grep -qF "$MAC_MATERIAL" "$KEYFILE" 2>/dev/null; then
  exit 0
fi
# Restore (append only). Create the file/dir with adbd's expected owner/perms/context if missing.
mkdir -p /data/misc/adb 2>/dev/null
printf '%s\n' "$MAC_KEY" >> "$KEYFILE"
chown system:shell "$KEYFILE" 2>/dev/null
chmod 0640 "$KEYFILE" 2>/dev/null
chcon u:object_r:adb_keys_file:s0 "$KEYFILE" 2>/dev/null || restorecon "$KEYFILE" 2>/dev/null
echo "$(date '+%F %T') restored Mac adb key (was missing)" >> "$STATE"
