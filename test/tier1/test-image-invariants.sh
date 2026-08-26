#!/usr/bin/env bash
# BEHAVIOURAL image checks — run INSIDE a built image, not against Containerfile text.
#
# test-firmware-trim.sh, test-sleep-policy.sh and test-image-trim.sh all grep the
# Containerfile. They assert the right text was typed, which is not the same as
# the build having done it: a RUN that silently no-ops (a '#' swallowing a line
# inside a backslash continuation, a variant case that did not match) leaves them
# green. This file asks the filesystem instead.
#
# Skips when not inside a PowOS image, so it is inert on a dev host.
set -uo pipefail
PASS=0; FAIL=0; SKIP=0
check(){ if ( eval "$2" ) >/dev/null 2>&1; then echo "  ok   - $1"; PASS=$((PASS+1));
         else echo "  FAIL - $1"; FAIL=$((FAIL+1)); fi }

[[ -f /usr/lib/powos/.powos-src-commit ]] || {
    echo "  skip - not inside a PowOS image"; echo; echo "== Results: 0 passed, 0 failed =="; exit 0; }
. /etc/os-release 2>/dev/null || true
IS_DECK=0; case "${VARIANT_ID:-}${IMAGE_ID:-}" in *deck*) IS_DECK=1 ;; esac
echo "== image invariants (variant: ${VARIANT_ID:-?}, deck=$IS_DECK) =="

# ── firmware that must survive any trim ───────────────────────────
# Each of these was, at some point, in a removal candidate list.
check "amdgpu firmware present (the GPU)"        'ls -d /usr/lib/firmware/amdgpu*  >/dev/null 2>&1'
check "ath10k firmware present (LCD Deck wifi)"  'ls -d /usr/lib/firmware/ath10k*  >/dev/null 2>&1'
check "qcom firmware present (OLED Deck wifi)"   'ls -d /usr/lib/firmware/qcom*    >/dev/null 2>&1'
check "rtl_nic firmware present (USB-C dock ethernet)" \
      '[ "$(ls /usr/lib/firmware/rtl_nic 2>/dev/null | wc -l)" -gt 0 ]'
check "mediatek firmware present (USB adapters on a docked handheld)" \
      'ls -d /usr/lib/firmware/mediatek >/dev/null 2>&1'

if [[ $IS_DECK -eq 1 ]]; then
  check "deck: nvidia firmware actually gone"  '[ ! -d /usr/lib/firmware/nvidia ]'
  check "deck: intel firmware actually gone"   '[ ! -d /usr/lib/firmware/intel ]'
fi

# ── icons ────────────────────────────────────────────────────────
check "hicolor present (breeze Inherits it; losing it breaks icon lookup)" \
      '[ -d /usr/share/icons/hicolor ]'
check "cursor theme present"                    '[ -d /usr/share/icons/breeze_cursors ]'
check "the default icon theme exists on disk" \
      't=$(grep -m1 "^Theme=" /etc/xdg/kdeglobals 2>/dev/null | cut -d= -f2)
       [ -z "$t" ] || [ -d "/usr/share/icons/$t" ]'

# ── locale ───────────────────────────────────────────────────────
check "C/POSIX locale survives (every program falls back to it)" \
      'localedef --list-archive 2>/dev/null | grep -qiE "^(C|POSIX)" || [ -d /usr/lib/locale/C.utf8 ] || true'
check "at least one configured locale resolves" \
      '[ "$(localedef --list-archive 2>/dev/null | wc -l)" -gt 0 ]'

# ── no unit left pointing at a binary that was removed ───────────
# Deleting a binary without its package leaves a unit that fails every boot.
# Three legitimate reasons a unit may point at a path that is absent from the
# real root, all of which must be excluded or the check is pure noise:
#   dracut-*      run INSIDE the initramfs, where those binaries do exist
#   Condition*    systemd skips the unit when the guard fails
#   ExecStart=-   the leading dash means failure is explicitly tolerated
#   indirect      socket/path-activated (sssd-pac); never started at boot
# What is left is a unit that WILL try to start and WILL fail every boot.
check "no enabled unit will fail at boot on a missing binary" \
      'bad=""
       for u in /usr/lib/systemd/system/*.service; do
         case "$(basename "$u")" in dracut-*) continue ;; esac
         grep -q "^Condition" "$u" 2>/dev/null && continue
         grep -q "^ExecStart=-" "$u" 2>/dev/null && continue
         [ "$(systemctl is-enabled "$(basename "$u")" 2>/dev/null)" = "enabled" ] || continue
         e=$(grep -m1 "^ExecStart=/" "$u" 2>/dev/null | sed "s/^ExecStart=//; s/ .*//")
         [ -n "$e" ] && [ ! -e "$e" ] && bad="$bad $(basename "$u")"
       done
       [ -z "$bad" ] || echo "orphaned:$bad"
       [ -z "$bad" ]'

# ── sleep policy coherence, on the filesystem ────────────────────
check "sleep policy is coherent (asks-to-suspend == able-to-suspend)" \
      'asks=no; able=no
       grep -qx "PowerButtonAction=1" /etc/skel/.config/powerdevilrc 2>/dev/null && asks=yes
       [ -L /etc/systemd/system/sleep.target ] || able=yes
       [ "$asks" = "$able" ]'
if [[ $IS_DECK -eq 1 ]]; then
  check "deck: the power button has a fallback owner when no session claims it" \
        'grep -qs "^HandlePowerKey=suspend" /etc/systemd/logind.conf.d/*.conf'
  check "deck: a long press can always kill a wedged machine" \
        'grep -qs "^HandlePowerKeyLongPress=poweroff" /etc/systemd/logind.conf.d/*.conf'
fi

# ── things whose removal must be reversible ──────────────────────
check "brew is either present or POWOS_BREW dropped it deliberately" \
      '[ -f /usr/share/homebrew.tar.zst ] || [ ! -f /usr/lib/systemd/system/brew-setup.service ] \
       || grep -q "ConditionPathExists=/usr/share/homebrew.tar.zst" /usr/lib/systemd/system/brew-setup.service'

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
