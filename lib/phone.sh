#!/bin/bash
# PowOS on a phone (the Android app, rooted or not; targets/android): what `powos status` and `powos health` show
# there. The PC sections (layers on a USB drive, RAM overlay, unplug safety) don't exist on a phone; these do -
# the Android link, the kernel features PowOS needs, the GPU, storage, battery, Steam/FEX.
#
# Platform: /etc/powos/platform (written by the rootfs build: phone | vm), or POWOS_PLATFORM from the session.
# Phone state: files the PowOS app keeps in its run dir ($XDG_RUNTIME_DIR: battery "<percent> <charging>",
# network "<type> <signal>").

powos_is_phone() {
    [[ "${POWOS_PLATFORM:-}" == phone ]] || [[ "$(cat /etc/powos/platform 2>/dev/null)" == phone ]]
}

_phone_run() { echo "${XDG_RUNTIME_DIR:-/run/powos-app}"; }

# rooted: PowOS as its own system (Magisk; rooted/powos-session.sh), else the no-root engine (fakeroot, proot-less).
_phone_mode() {
    if [[ -n "${FAKECHROOT_BASE:-}" ]]; then echo "no-root app"
    elif [[ "${POWOS_SESSION_MODE:-}" == rooted ]] || [[ "$(id -u)" != 0 && -d /home/powos ]]; then echo "rooted"
    else echo "unknown"; fi
}

_phone_userns() { unshare -U true 2>/dev/null; }

_phone_adb_state() {
    command -v adb >/dev/null || { echo "no adb"; return; }
    adb -s 127.0.0.1:5555 get-state 2>/dev/null || echo "not connected"
}

_phone_android_windows() {
    local n=0 f
    for f in "$(_phone_run)"/android-windows/*.pid; do
        [[ -f "$f" ]] && kill -0 "$(cat "$f")" 2>/dev/null && n=$((n + 1))
    done
    echo "$n"
}

_phone_fex_rootfs() { sed -n 's/.*"RootFS":"\([^"]*\)".*/\1/p' /usr/share/fex-emu/Config.json 2>/dev/null; }

# The phone's whole status report, instead of bin/powos's _status_* sections (the PC report: layers, USB, ...).
_phone_status() {
    local run bat net
    run=$(_phone_run)
    echo -e "${CYAN}Phone${NC}"
    echo -e "  Mode:       ● $(_phone_mode)"
    echo -e "  Kernel:     $(uname -r)"
    read -r bat_pct bat_chg < "$run/battery" 2>/dev/null && \
        echo -e "  Battery:    ${bat_pct}%$([[ "$bat_chg" == 1 ]] && echo ' (charging)')"
    read -r net sig < "$run/network" 2>/dev/null && echo -e "  Network:    ${net} ${sig:+(${sig}%)}"
    echo ""
    echo -e "${CYAN}Android${NC}"
    echo -e "  adb link:   $(_phone_adb_state)  (Android apps as PowOS windows)"
    echo -e "  Windows:    $(_phone_android_windows) Android app(s) in PowOS windows"
    echo -e "  Taskbar:    $(pgrep -f 'powos-android-tasks$' >/dev/null && echo '● running apps shown' || echo '○ not running')"
    echo ""
    echo -e "${CYAN}System${NC}"
    echo -e "  GPU:        $([[ -e /dev/kgsl-3d0 ]] && echo '● Adreno (KGSL)' || echo '○ none (software rendering)')"
    echo -e "  Namespaces: $(_phone_userns && echo '● available (Steam, Flatpak, containers)' || echo '○ not available (stock kernel or chroot)')"
    echo -e "  Storage:    $(df -h / 2>/dev/null | awk 'NR == 2 {print $4 " free of " $2}')"
    [[ -d /mnt/sdcard/Android ]] && echo -e "  Phone files: /mnt/sdcard ($(df -h /mnt/sdcard 2>/dev/null | awk 'NR == 2 {print $4 " free"}'))"
    echo ""
    echo -e "${CYAN}x86 / Steam${NC}"
    local r; r=$(_phone_fex_rootfs)
    echo -e "  FEX:        $(command -v FEX >/dev/null && echo "● ${r:+RootFS ${r##*/}}" || echo '○ not installed')"
    echo -e "  Steam:      $(command -v steam >/dev/null && echo '● installed' || echo '○ not installed')"
}

# Health probes on a phone (the PC ones - layers, RAM overlay, USB, CacheFS - don't apply).
_HEALTH_PROBES_PHONE=(phone_android phone_kernel phone_gpu phone_storage phone_x86 backup projects containers ai_system)

_health_phone_android() {
    echo -e "${CYAN}Android link${NC}"
    local s; s=$(_phone_adb_state)
    if [[ "$s" == device ]]; then
        echo -e "  ${GREEN}✓${NC} adb to the phone itself: Android apps open as PowOS windows"
    else
        echo -e "  ${YELLOW}○${NC} adb to the phone itself: $s - Android apps open as floating Android windows instead"
        echo -e "      Rooted mode: targets/android/rooted/rooted.sh deploy authorizes PowOS's adb key"
        _health_warning
    fi
    echo ""
}

_health_phone_kernel() {
    echo -e "${CYAN}Kernel${NC}"
    if _phone_userns; then
        echo -e "  ${GREEN}✓${NC} User namespaces (Steam's runtime, Flatpak, rootless containers)"
    else
        echo -e "  ${YELLOW}⚠${NC} No user namespaces: Steam won't start its runtime, no Flatpak/containers"
        echo -e "      Needs the PowOS kernel (targets/native/config/gki/namespaces.config) and PowOS via pivot_root"
        _health_warning
    fi
    echo ""
}

_health_phone_gpu() {
    echo -e "${CYAN}GPU${NC}"
    if [[ -e /dev/kgsl-3d0 ]]; then
        echo -e "  ${GREEN}✓${NC} Adreno via KGSL (Mesa Turnip/freedreno)"
    else
        echo -e "  ${YELLOW}○${NC} No Adreno: software rendering (llvmpipe)"
        _health_warning
    fi
    echo ""
}

_health_phone_storage() {
    echo -e "${CYAN}Storage${NC}"
    local avail; avail=$(df -k / 2>/dev/null | awk 'NR == 2 {print $4}')
    if [[ -n "$avail" ]] && (( avail < 5 * 1024 * 1024 )); then
        echo -e "  ${RED}✗${NC} Less than 5 GiB free for PowOS"
        _health_issue
    else
        echo -e "  ${GREEN}✓${NC} $(df -h / | awk 'NR == 2 {print $4}') free for PowOS"
    fi
    if [[ -d /mnt/sdcard/Android ]]; then
        echo -e "  ${GREEN}✓${NC} Phone files at /mnt/sdcard"
    else
        echo -e "  ${YELLOW}○${NC} Phone files not available (/mnt/sdcard) - unlocked yet? storage permission?"
        _health_warning
    fi
    echo ""
}

_health_phone_x86() {
    echo -e "${CYAN}x86 (FEX) / Steam${NC}"
    local r; r=$(_phone_fex_rootfs)
    if command -v FEX >/dev/null && [[ -d "$r" ]]; then
        echo -e "  ${GREEN}✓${NC} FEX with x86 RootFS ${r##*/}"
    else
        echo -e "  ${YELLOW}○${NC} FEX or its x86 RootFS missing (x86 programs, Steam)"
        _health_warning
    fi
    if command -v steam >/dev/null && [[ -n "$r" ]]; then
        if [[ -e "$r/usr/lib/powos-sysvipc/x86_64/libsysvipc-emu.so" ]]; then
            echo -e "  ${GREEN}✓${NC} Steam, with System V IPC (sysvipc-emu in the RootFS)"
        else
            echo -e "  ${YELLOW}⚠${NC} Steam installed but sysvipc-emu missing from the RootFS (reinstall the steam package)"
            _health_warning
        fi
    fi
    echo ""
}
