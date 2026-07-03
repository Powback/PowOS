#!/usr/bin/env bash
# validate.sh - one command to validate PowOS, staged from cheap to expensive.
#
# Run this on a Linux box with virtualization (a real PC, a Steam Deck, or WSL2
# with nested KVM). It walks the whole ladder and tells you exactly what passed,
# what needs hardware, and what's still a manual check.
#
#   ./build/validate.sh              # tiers 1-2 (fast: unit + loop-device e2e)
#   ./build/validate.sh --build      # + build the image (slow, needs podman)
#   ./build/validate.sh --boot       # + QEMU boot smoke test (needs image + KVM)
#   ./build/validate.sh --all        # everything
#
# Each stage skips (not fails) when its prerequisites are missing, so partial
# environments still get useful signal. Manual boot-menu / installer / dual-boot
# checks that can't be automated are listed at the end (see INSTALL-VALIDATION.md).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT" || { echo "cannot cd to $ROOT"; exit 1; }

G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; C='\033[0;36m'; B='\033[1m'; D='\033[2m'; N='\033[0m'
STAGE_PASS=0; STAGE_FAIL=0; STAGE_SKIP=0
step()  { echo; echo -e "${B}${C}══ $* ══${N}"; }
good()  { echo -e "  ${G}PASS${N} $*"; STAGE_PASS=$((STAGE_PASS+1)); }
fail()  { echo -e "  ${R}FAIL${N} $*"; STAGE_FAIL=$((STAGE_FAIL+1)); }
skip()  { echo -e "  ${Y}SKIP${N} $*"; STAGE_SKIP=$((STAGE_SKIP+1)); }

DO_BUILD=0; DO_BOOT=0
for a in "$@"; do case "$a" in
    --build) DO_BUILD=1 ;;
    --boot)  DO_BOOT=1 ;;
    --all)   DO_BUILD=1; DO_BOOT=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $a"; exit 1 ;;
esac; done

run_test() { # name  command...
    local name="$1"; shift
    if "$@" >/tmp/powos-validate.log 2>&1; then good "$name"
    else fail "$name  ${D}(tail:)${N}"; tail -5 /tmp/powos-validate.log | sed 's/^/      /'; fi
}

# ── Tier 1: unit tests (no root, no hardware) ─────────────────────
step "Tier 1 — unit tests"
for t in test-install-system test-vm test-variant-select test-base \
         test-hardware-detect test-pinstall test-overlay; do
    if [[ -f "test/tier1/$t.sh" ]]; then run_test "$t" bash "test/tier1/$t.sh"; else skip "$t (missing)"; fi
done
if command -v python3 >/dev/null; then
    for t in test-layer-sync test-cachefs; do
        if [[ -f "test/tier1/$t.py" ]]; then run_test "$t" python3 "test/tier1/$t.py"; else skip "$t (missing)"; fi
    done
else skip "python tests (no python3)"; fi

# ── update-self + loop-device e2e (need root/privileged) ──────────
step "Tier 1.5 — real deploy + disk (need root)"
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    run_test "update-self deploy loop" bash test/tier1/test-update-self.sh
    if command -v losetup >/dev/null && command -v mkfs.ntfs >/dev/null; then
        run_test "installer disk ops (loop device)" bash test/e2e/test-installer-disk.sh
    else skip "installer disk ops (need util-linux + ntfsprogs)"; fi
else
    skip "update-self + disk ops (re-run with sudo to include these)"
fi

# ── Build the image ───────────────────────────────────────────────
IMG="build/output/powos.raw"
if [[ $DO_BUILD -eq 1 ]]; then
    step "Tier 2 — build live image"
    if command -v podman >/dev/null; then
        run_test "build-iso.sh live-usb" bash build/build-iso.sh live-usb
    else skip "build (podman not installed)"; fi
fi

# ── QEMU boot smoke test ──────────────────────────────────────────
if [[ $DO_BOOT -eq 1 ]]; then
    step "Tier 3 — QEMU boot smoke test"
    if [[ ! -e /dev/kvm ]]; then skip "QEMU boot (no /dev/kvm — needs a virtualization-capable Linux)"
    elif [[ ! -f "$IMG" ]]; then skip "QEMU boot (no image — run with --build first)"
    elif ! command -v qemu-system-x86_64 >/dev/null; then skip "QEMU boot (qemu-kvm not installed)"
    else run_test "QEMU boot (ramboot/profile/layer-sync/rollback)" bash test/e2e/test-qemu-boot.sh; fi
fi

# ── Summary + the manual checklist ────────────────────────────────
step "Summary"
echo -e "  ${G}$STAGE_PASS passed${N}   ${R}$STAGE_FAIL failed${N}   ${Y}$STAGE_SKIP skipped${N}"
echo
echo -e "  ${B}Still MANUAL (can't be automated here) — see test/e2e/INSTALL-VALIDATION.md:${N}"
echo "    • Boot the USB → menu shows PowOS Live + Install PowOS + variant entries"
echo "    • sudo powos install-system --dry-run  → sane plan, changes nothing"
echo "    • Dual-boot alongside a real Windows install"
echo "    • sudo powos vm windows                → Windows actually boots as a guest"
echo "    • powos base switch <name>; reboot     → boots the selected base"
echo
[[ $STAGE_FAIL -eq 0 ]]
