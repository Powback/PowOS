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
skip(){ echo "  skip - $1"; SKIP=$((SKIP+1)); }

# Only assert against an image built from THIS source.
#
# The guard used to be "am I on PowOS", which is true on a dev box running an
# older build — so the suite asserted today's invariants against yesterday's
# image and failed for the right reason about the wrong artifact. The askpass
# check had already grown its own version of this exemption; this generalises it
# to the whole file.
#
# CI runs this inside the freshly built image, where the commit matches. A
# developer running run-all.sh on their PowOS desktop gets a skip.
[[ -f /usr/lib/powos/.powos-src-commit ]] || {
    echo "  skip - not inside a PowOS image"; echo; echo "== Results: 0 passed, 0 failed =="; exit 0; }
_img_commit=$(cat /usr/lib/powos/.powos-src-commit 2>/dev/null)
_src_commit=$(git -C "$(dirname "${BASH_SOURCE[0]}")/../.." rev-parse HEAD 2>/dev/null || echo "")
if [[ -n "$_src_commit" && "$_img_commit" != "$_src_commit" ]]; then
    echo "  skip - image is ${_img_commit:0:8}, source is ${_src_commit:0:8};"
    echo "         these invariants describe an image built from THIS source."
    echo; echo "== Results: 0 passed, 0 failed =="; exit 0
fi
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

# ── askpass: the dialog must be able to say what it is authenticating ──
#
# The whole fix is a glob-order bet against files the BASE image owns:
#   /etc/profile.d/askpass.sh              -> SUDO_ASKPASS=ksshaskpass
#   /etc/profile.d/kde-openssh-askpass.sh  -> SSH_ASKPASS=ksshaskpass
#   /etc/xdg/plasma-workspace/env/ksshaskpass.sh
# If a base update renames one of those to something sorting after "zz-", or a
# COPY silently lands nothing, the ONLY symptom is the original bad dialog
# coming back — "Unable to parse phrase" and a box that names nothing. So this
# does not grep the Containerfile; it sources the files the way the shell does
# and reads the variable back.
#
# Gated on the image's OWN bundled source snapshot (/usr/lib/powos/src, a
# `git archive HEAD` of the commit that built it), not on the helper's
# presence — gating on the helper would make the whole block vacuous in
# exactly the case it exists to catch. The three states are distinct:
#   src has it, /usr/bin has it   -> assert everything below
#   src has it, /usr/bin does not -> THE BUILD DROPPED IT. Fail loudly.
#   src does not have it          -> booted image predates the feature. Skip.
if [ ! -e /usr/lib/powos/src/bin/powos-askpass ] && [ ! -x /usr/bin/powos-askpass ]; then
  skip "askpass: this image predates powos-askpass (not in its source snapshot)"
else
check "powos-askpass is installed and executable" '[ -x /usr/bin/powos-askpass ]'
# Capture, do NOT pipe into `grep -q`. Under `set -o pipefail` grep exits at the
# first match, the producer is killed mid-write, and the pipeline returns 141
# (SIGPIPE) — so this passed on a fast host and failed inside the image. Same
# trap already fixed once today in test-firstboot-offline.sh.
check "powos-askpass runs and can describe a sudo prompt" \
      'o=$(POWOS_ASKPASS_DRY_RUN=1 /usr/bin/powos-askpass "[sudo] password for x: " 2>&1)
       grep -q "wants to run a command as root" <<< "$o"'
check "after sourcing ALL of /etc/profile.d, SUDO_ASKPASS is powos-askpass" \
      'v=$(env -i bash -c "for i in /etc/profile.d/*.sh; do . \$i >/dev/null 2>&1; done;
                           echo \$SUDO_ASKPASS")
       [ "$v" = "/usr/bin/powos-askpass" ]'
check "after sourcing ALL of /etc/profile.d, SSH_ASKPASS is powos-askpass" \
      'v=$(env -i bash -c "for i in /etc/profile.d/*.sh; do . \$i >/dev/null 2>&1; done;
                           echo \$SSH_ASKPASS")
       [ "$v" = "/usr/bin/powos-askpass" ]'
check "after sourcing the Plasma session env, SSH_ASKPASS is powos-askpass" \
      '[ ! -d /etc/xdg/plasma-workspace/env ] ||
       { v=$(env -i bash -c "for i in /etc/xdg/plasma-workspace/env/*.sh; do . \$i >/dev/null 2>&1; done;
                             echo \$SSH_ASKPASS")
         [ "$v" = "/usr/bin/powos-askpass" ]; }'
check "systemd user units get it too (environment.d drop-in shipped)" \
      'grep -qs "^SUDO_ASKPASS=/usr/bin/powos-askpass$" /usr/lib/environment.d/zz-powos-askpass.conf'
check "no askpass drop-in in either dir sorts after ours" \
      'for d in /etc/profile.d /etc/xdg/plasma-workspace/env; do
         [ -d "$d" ] || continue
         l=$(ls "$d" | grep -i askpass | sort | tail -1)
         [ -z "$l" ] || [ "$l" = "zz-powos-askpass.sh" ] || { echo "loses to $d/$l"; exit 1; }
       done'
# Failing safe is not a nicety here: SUDO_ASKPASS is consulted only by `sudo -A`,
# which is why a broken helper can never cost anyone root.
check "plain sudo still has its own terminal prompt (askpass is -A only)" \
      '[ -x /usr/bin/sudo ]'
fi

# The image must not ask the kernel for overlay features it lacks. metacopy=on
# needs CONFIG_OVERLAY_FS_REDIRECT_DIR; without it containers/storage falls back
# to naive full-tree copying — which is why importing the offline variant off
# the install medium crawls, and why podman commit cost ~27s regardless of what
# changed. Proven on this kernel: Native Overlay Diff false with it, true without.
check "storage.conf does not request metacopy (kernel lacks REDIRECT_DIR)" \
      '[ ! -f /etc/containers/storage.conf ] || ! grep -q "metacopy" /etc/containers/storage.conf'
check "and /etc actually overrides the vendor file" \
      '[ ! -f /usr/share/containers/storage.conf ] \
       || ! grep -q "metacopy=on" /usr/share/containers/storage.conf \
       || [ -f /etc/containers/storage.conf ]'

echo
echo "== Results: $PASS passed, $FAIL failed${SKIP:+, $SKIP skipped} =="
[[ $FAIL -eq 0 ]]
