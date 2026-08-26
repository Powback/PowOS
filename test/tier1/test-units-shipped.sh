#!/bin/bash
# test-units-shipped.sh - units the boot menu depends on must reach the image.
#
# systemd/ holds 17 unit files; the Containerfile COPYs a handful. A unit that
# is not COPYed exists only in /usr/lib/powos/src/systemd (the source snapshot)
# and is never installed, so systemd never sees it.
#
# This shipped as a silent, total failure: install-to-usb.sh writes an "Install
# PowOS to disk" boot entry that appends powos.install=1 and boots
# multi-user.target, and powos-installer.service — the unit whose entire job is
# to run the wizard on that karg — was missing. Choosing the entry booted to a
# blank console. The Safe mode / AI Debug entries were dead the same way.
#
# Only units something else actively depends on are REQUIRED here. The rest are
# reported so the gap stays visible rather than being silently forgotten.
#
# Usage:  bash test/tier1/test-units-shipped.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CF="$ROOT/Containerfile"
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'
PASS=0; FAIL=0
ok()  { echo -e "${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
bad() { echo -e "${RED}✗${NC} $1"; [[ -n "${2:-}" ]] && echo "    $2"; FAIL=$((FAIL+1)); }

# Units that MUST be installed, and why. Each is depended on by something that
# ships to users: a boot-menu entry, or the guided installer's handoff.
declare -A REQUIRED=(
  [powos-installer.service]="the boot menu's 'Install PowOS to disk' entry (powos.install=1) starts nothing without it"
  [powos-safemode.service]="the 'Recovery — Safe mode' and 'AI Debug' entries (powos.mode=) do nothing without it"
  [powos-firstboot.service]="applies the wizard's hostname/user/password/SSH/ramboot/AI/restore choices"
  [powos-variant-retry.service]="retries a GPU-variant switch that had no network at first boot"
)

echo "== units the shipped boot menu depends on =="
for u in "${!REQUIRED[@]}"; do
  if grep -qF "COPY systemd/$u " "$CF"; then
    if grep -qE "systemctl enable +$u" "$CF"; then
      ok "$u is COPYed and enabled"
    else
      bad "$u is COPYed but never enabled" "${REQUIRED[$u]}"
    fi
  else
    bad "$u is NOT copied into the image" "${REQUIRED[$u]}"
  fi
done

# powos-boot-entries must be gated on the live-medium marker, or it also runs on
# an INSTALLED system and adds installer entries to that machine's boot menu.
if grep -q 'ConditionPathExists=/etc/powos/.live-medium' "$ROOT/systemd/powos-boot-entries.service"; then
    ok "powos-boot-entries only runs on a live medium"
else
    bad "powos-boot-entries is not gated on the live-medium marker" \
        "it would add Install/Recovery entries to an installed system's own menu"
fi

# sshd must survive an ostree upgrade.
#
# Bazzite's 81-desktop.preset disables sshd.service, Fedora's 90-default
# enables it, and presets are first-match-wins — so 81 beats 90 and sshd is
# off unless we intervene. Intervening with `systemctl enable` alone is not
# enough: that writes into /etc, which ostree three-way merges on upgrade with
# presets re-applied over it, so remote access can vanish across an update
# silently. A Steam Deck came back from a SteamOS update with no sshd exactly
# this way. Two belts: a preset that sorts ahead of 81, and a wants symlink in
# /usr that no /etc merge can touch.
PRESET="$ROOT/config/systemd-preset/80-powos.preset"
if [[ -f "$PRESET" ]] && grep -qE '^enable sshd\.service' "$PRESET"; then
    ok "a preset sorting ahead of Bazzite's re-enables sshd"
else
    bad "no preset re-enables sshd" "81-desktop.preset disables it and wins"
fi
if grep -qF "COPY config/systemd-preset/" "$CF"; then
    ok "the preset reaches the image"
else
    bad "the preset is never copied into the image"
fi
if grep -qF 'multi-user.target.wants/sshd.service' "$CF"; then
    ok "sshd is also wanted from /usr, out of reach of the /etc merge"
else
    bad "sshd is only enabled via /etc" "an ostree upgrade can merge it away"
fi

# systemd-udev-settle must not run: it is deprecated upstream, ordered before
# sysinit.target, and one unit wanting it makes the entire boot wait for the
# udev queue (+4.6s measured). A Wants= reset drop-in was tried first and did
# not take — verified on a booted medium — so the unit is masked instead.
if grep -q 'systemctl mask systemd-udev-settle.service' "$CF"; then
    ok "systemd-udev-settle is masked in the image"
else
    bad "systemd-udev-settle is not masked" "one Wants= on it stalls sysinit for seconds"
fi

# ublue-os-media-automount must be masked. It runs `findmnt -s --json ...`,
# which exits non-zero when /etc/fstab has nothing to list — and a bootc
# install leaves fstab EMPTY. Its Python does not handle that, so the unit
# fails on every single boot of every PowOS install and sits red in
# `systemctl --failed` forever.
if grep -q 'systemctl mask ublue-os-media-automount.service' "$CF"; then
    ok "ublue-os-media-automount is masked (it crashes on an empty fstab)"
else
    bad "ublue-os-media-automount is not masked" "it fails on every boot"
fi

# A minute of blank, repeatedly-cleared screen on a first boot is
# indistinguishable from a brick — it was reported as a boot loop. Narrate it.
if [[ -f "$ROOT/bin/powos-firstboot-notice" ]] && grep -qF "COPY systemd/powos-firstboot-notice.service" "$CF"; then
    ok "the first boot explains the hardware-setup pause on the console"
else
    bad "nothing narrates the first-boot hardware setup" \
        "a minute of cleared screen then a reboot reads as a boot loop"
fi

# The network wait must be BOUNDED, never removed.
#
# greenboot's health check is ordered after network-online.target and gates
# boot-complete.target, so the desktop waits for it. Removing greenboot's
# network dependency looks like the fix and is a trap: greenboot then runs
# before any network exists, does not pass, and its redboot-auto-reboot
# reboots the machine. Reproduced in a VM with -nic none:
#
#     [  OK  ] Stopped greenboot-healthcheck.service
#     [ 34.75] reboot: Restarting system
#
# and on a Steam Deck away from its wifi it was an endless loop. "Slow when
# offline" must not become "will not boot when offline".
if [[ -d "$ROOT/systemd/greenboot-healthcheck.service.d" ]]; then
    bad "greenboot's network dependency is being overridden" \
        "that causes a reboot loop when the machine has no network"
else
    ok "greenboot keeps its network-online dependency"
fi
NMW="$ROOT/systemd/NetworkManager-wait-online.service.d/10-powos-bound.conf"
if [[ -f "$NMW" ]] && grep -qE 'timeout=[1-9]' "$NMW"; then
    ok "the network wait is bounded by a short nm-online timeout"
else
    bad "the network wait is unbounded" "an offline boot stalls on the default timeout"
fi
# ...and giving up must not be an error. nm-online exits non-zero on timeout,
# so without the "-" prefix the unit goes FAILED on every boot of a device
# with no network — the normal case for a handheld.
if [[ -f "$NMW" ]] && grep -qE '^ExecStart=-' "$NMW"; then
    ok "an offline boot does not leave a FAILED unit behind"
else
    bad "nm-online timing out marks the unit FAILED" \
        "every offline boot reports a failure that is not one"
fi
if grep -qF "COPY systemd/NetworkManager-wait-online.service.d/" "$CF"; then
    ok "the bounded wait reaches the image"
else
    bad "the bounded wait is never copied into the image"
fi

# The plymouth handoff must be time-bounded. plymouth-quit-wait.service ships
# TimeoutSec=0 — infinite — and on this image plymouthd stops answering, so the
# boot stops dead before graphical.target with no display manager and no
# console. Reproduced in QEMU off our own raw image and reported from a Deck.
for pu in plymouth-quit plymouth-quit-wait; do
    dropin="$ROOT/systemd/$pu.service.d/10-powos-timeout.conf"
    if [[ -f "$dropin" ]] && grep -qE '^TimeoutSec=[1-9]' "$dropin"; then
        ok "$pu is time-bounded"
    else
        bad "$pu has no bounded timeout drop-in" "a stuck plymouth hangs the whole boot"
    fi
    if grep -qF "COPY systemd/$pu.service.d/" "$CF"; then
        ok "$pu drop-in reaches the image"
    else
        bad "$pu drop-in is never copied into the image" "the file exists but does nothing"
    fi
done

# No unit that is enabled unconditionally may declare Conflicts= against the
# display manager or the console getty.
#
# Conflicts is resolved when the JOB IS ENQUEUED; ConditionKernelCommandLine is
# checked later, when the job runs. So powos-installer.service — enabled into
# multi-user.target and gated on a karg that is absent on an ordinary boot —
# still enqueued a STOP job for display-manager.service every single boot, and
# systemd resolved the clash by deleting the display manager's start job:
#
#   sddm.service: Fixing conflicting jobs sddm.service/start,sddm.service/stop
#                 by deleting job sddm.service/start
#
# Nothing is logged at normal level. graphical.target goes ACTIVE, the journal
# never mentions sddm, and the machine sits on a console — which is precisely
# what a Steam Deck did, boot after boot, while every symlink on disk looked
# correct. Take the tty from ExecStartPre instead, where it happens only when
# the unit actually runs.
for cu in powos-installer powos-safemode; do
    cunit="$ROOT/systemd/$cu.service"
    if grep -qE '^Conflicts=.*(display-manager|getty@)' "$cunit"; then
        bad "$cu declares Conflicts= against the display manager/getty" \
            "an unconditionally-enabled unit does this on EVERY boot, killing the desktop"
    else
        ok "$cu takes the tty without a boot-wide Conflicts="
    fi
    if grep -qE '^ExecStartPre=.*systemctl stop' "$cunit"; then
        ok "$cu stops the tty holders when it actually runs"
    else
        bad "$cu never stops the tty holders" "the installer would draw underneath a getty"
    fi
done

# The built-in account must get a home directory on a fresh install.
#
# The image bakes in a 'powos' user, but /var is empty on a fresh bootc
# install, so /var/home/powos does not exist. sddm autologins that user into
# gamescope, a session with no home dies with exit code 3, and sddm restarts it
# forever — a black screen with a cursor on a machine that installed perfectly.
# Two independent guards, because firstboot only runs when install.conf made it
# onto the target and a hand-rolled `bootc install` has no such file.
HOMERULE="$ROOT/config/tmpfiles.d/powos-home.conf"
if [[ -f "$HOMERULE" ]] && grep -qE '^d[[:space:]]+/var/home/powos' "$HOMERULE"; then
    ok "a tmpfiles rule creates /var/home/powos on every boot"
else
    bad "nothing guarantees /var/home/powos exists" \
        "the autologin session dies with exit 3 and the screen stays black"
fi
if grep -q 'created missing home directory' "$ROOT/bin/powos-firstboot-apply"; then
    ok "firstboot also creates a missing home for a PRE-EXISTING user"
else
    bad "firstboot only creates a home via useradd -m" \
        "useradd never runs for the baked-in account, so the home is never made"
fi

# powos-firstboot CREATES THE USER ACCOUNT. Two properties decide whether a
# freshly installed machine is usable on its first boot:
#
#   * ordered before the greeter — otherwise the login screen can appear with
#     no account on it, which is what a user sees as "the install failed"; and
#   * not waiting on network-online — a fresh Deck has no wifi configured, so
#     pulling that in spent NetworkManager-wait-online's entire timeout before
#     the account was created, with the greeter already on screen.
FB_UNIT="$ROOT/systemd/powos-firstboot.service"
if grep -qE '^Before=.*display-manager\.service' "$FB_UNIT"; then
    ok "powos-firstboot is ordered before the display manager"
else
    bad "powos-firstboot is not ordered before the display manager" \
        "the greeter can come up before the user account exists"
fi
if grep -qE '^(After|Wants|Requires)=.*network-online\.target' "$FB_UNIT"; then
    bad "powos-firstboot waits on network-online.target" \
        "a first boot with no wifi stalls the whole unit before the user is created"
else
    ok "powos-firstboot does not wait on the network to create the user"
fi
if grep -qE '^TimeoutStartSec=' "$FB_UNIT"; then
    ok "powos-firstboot is time-bounded (the greeter is ordered after it)"
else
    bad "powos-firstboot has no TimeoutStartSec" \
        "anything that hangs in it now delays the desktop indefinitely"
fi

echo ""
echo "== units present in systemd/ but not installed (visibility, not a failure) =="
shopt -s nullglob
unshipped=0
for f in "$ROOT"/systemd/*.service "$ROOT"/systemd/*.timer; do
  u=$(basename "$f")
  [[ -n "${REQUIRED[$u]:-}" ]] && continue
  grep -qF "COPY systemd/$u " "$CF" && continue
  echo -e "  ${YELLOW}not installed${NC}: $u"
  unshipped=$((unshipped+1))
done
[[ $unshipped -eq 0 ]] && echo "  (none)"
echo "  $unshipped unit(s) exist in systemd/ but never reach /usr/lib/systemd/system."
echo "  These are NOT asserted: the ramboot/overlay stack may be driven by the"
echo "  dracut module instead. Review before adding — enabling a unit the image"
echo "  is not set up for is how a boot gets broken."

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
