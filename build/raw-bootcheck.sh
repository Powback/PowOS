#!/usr/bin/env bash
# build/raw-bootcheck.sh <disk-image-or-device>
#
# STATIC bootability check: a ~10 second read of the artifact that asks the
# questions the 4-minute QEMU gate answers, minus the ones only a running kernel
# can answer.
#
# It exists because making the QEMU gate conditional creates a gap, and the
# thing that fell through the last gap was specific and detectable:
#
#   An initramfs regenerated WITHOUT ostree support boots nothing while looking
#   like a perfect trim. Every metadata check passed — the image got smaller,
#   the commit matched, the boot entries were all there — and the stick would
#   not boot.
#
# So this checks the artifact for exactly that class of fault: an initramfs that
# cannot switch root, a boot entry pointing at a kernel or initrd that is not
# there, and an entry with no ostree= argument to switch root TO. It is not a
# substitute for the gate. It runs on EVERY freshly built raw, gate or no gate,
# so a skipped gate is never a completely unexamined artifact.
set -uo pipefail
S() {
    # Prime the credential cache with its own stdin, then run with -n so the
    # caller's stdin reaches the command. See build/cycle-lib.sh for the bug
    # the obvious `echo pass | sudo -S "$@"` form causes.
    sudo -n true 2>/dev/null || echo "${POWOS_SUDO_PASS:-powos}" | sudo -S -v 2>/dev/null
    sudo -n "$@" 2>/dev/null
}
src="${1:?usage: raw-bootcheck.sh <image|device>}"
P=0; F=0
pass(){ echo "    ok   - $1"; P=$((P+1)); }
fail(){ echo "    FAIL - $1"; F=$((F+1)); }

loop=""
if [[ -b "$src" ]]; then dev="$src"
else loop=$(S losetup -Pf --show "$src") || { echo "bootcheck: cannot attach $src" >&2; exit 1; }
     sleep 1; dev="$loop"; fi
cleanup(){ S umount "$mb" 2>/dev/null; S umount "$mr" 2>/dev/null
           rmdir "$mb" "$mr" 2>/dev/null; [[ -n "$loop" ]] && S losetup -d "$loop"; }
mb=$(mktemp -d); mr=$(mktemp -d); trap cleanup EXIT

bootp=$(S lsblk -nro NAME,LABEL "$dev" | awk '$2=="boot"{print "/dev/"$1; exit}')
rootp=$(S lsblk -nro NAME,LABEL "$dev" | awk '$2=="root"{print "/dev/"$1; exit}')
[[ -n "$bootp" ]] || { echo "bootcheck: no boot partition" >&2; exit 1; }
[[ -n "$rootp" ]] || { echo "bootcheck: no root partition" >&2; exit 1; }
S mount -o ro "$bootp" "$mb" || { echo "bootcheck: cannot mount boot" >&2; exit 1; }
S mount -o ro "$rootp" "$mr" || { echo "bootcheck: cannot mount root" >&2; exit 1; }

# ── boot entries point at things that exist ───────────────────────
n=$(S bash -c "ls $mb/loader/entries/*.conf 2>/dev/null | wc -l")
[[ "$n" -ge 1 ]] && pass "$n boot loader entries present" || fail "no boot loader entries"
bad_k=0; bad_o=0
while read -r conf; do
    [[ -z "$conf" ]] && continue
    for kind in linux initrd; do
        pth=$(S grep -m1 "^$kind " "$conf" 2>/dev/null | awk '{print $2}')
        [[ -z "$pth" ]] && continue
        S test -s "$mb$pth" || bad_k=$((bad_k+1))
    done
    # An entry with no ostree= has nothing to switch root TO. On an ostree
    # system that is not a boot, it is an emergency shell.
    S grep -q '^options .*ostree=' "$conf" || bad_o=$((bad_o+1))
done < <(S bash -c "ls $mb/loader/entries/*.conf 2>/dev/null")
[[ $bad_k -eq 0 ]] && pass "every entry's kernel and initrd exist and are non-empty" \
                   || fail "$bad_k kernel/initrd references missing or empty"
[[ $bad_o -eq 0 ]] && pass "every entry carries an ostree= deployment argument" \
                   || fail "$bad_o entries have no ostree= argument"

# ── exactly one deployment, stamped ───────────────────────────────
depl=$(S bash -c "ls -d $mr/root/ostree/deploy/*/deploy/*.[0-9] $mr/ostree/deploy/*/deploy/*.[0-9] 2>/dev/null | head -1")
[[ -n "$depl" ]] && pass "ostree deployment found" || fail "no ostree deployment"
S test -s "$depl/usr/lib/powos/.powos-src-commit" \
    && pass "deployment carries a source-commit stamp" \
    || fail "deployment has no source-commit stamp"

# ── THE regression: an initramfs that cannot switch root ──────────
img=$(S bash -c "ls $mb/ostree/*/initramfs*  $mb/loader/*/initramfs* 2>/dev/null | head -1")
[[ -z "$img" ]] && img=$(S bash -c "ls $depl/usr/lib/modules/*/initramfs.img 2>/dev/null | head -1")
if [[ -z "$img" ]]; then
    fail "no initramfs image located to inspect"
elif ! command -v lsinitrd >/dev/null 2>&1; then
    echo "    skip - lsinitrd not on this host; cannot inspect the initramfs"
else
    lst=$(S lsinitrd "$img" 2>/dev/null)
    grep -q ostree-prepare-root <<<"$lst" \
        && pass "initramfs contains ostree-prepare-root (it can switch root)" \
        || fail "initramfs has NO ostree-prepare-root — THIS IS THE STICK THAT WOULD NOT BOOT"
    for need in plymouthd amdgpu; do
        grep -q "$need" <<<"$lst" && pass "initramfs contains $need" \
                                  || fail "initramfs missing $need"
    done
fi

echo "    == bootcheck: $P passed, $F failed =="
[[ $F -eq 0 ]]
