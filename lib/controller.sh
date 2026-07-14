#!/bin/bash
# controller.sh - `powos controller`: a permanent, driver-level analog
# stick-drift fixer for ANY joystick/gamepad (Xbox, PS4/PS5/DualSense, DJI,
# generic HID pads).
#
# HOW IT WORKS
#   We set each ABS axis's "flat" (deadzone) value at the evdev/driver level via
#   linuxconsoletools' `evdev-joystick`. Because the deadzone lives BELOW the
#   game — in the kernel input device — Steam and every title see clean, centered
#   sticks with zero per-game config. A user-facing percentage is converted to
#   each axis's own units from its min/max range:
#
#       flat_units = round( pct * (max - min) / 200 )
#
#   (evdev-joystick reports the deadzone as flat / half-range, i.e.
#    flat*200/(max-min); we invert that so the same percentage lands correctly on
#    a 16-bit stick and an 8-bit trigger alike.)
#
# PERSISTENCE  /etc/powos/controllers.conf  (documented key=value, per VID:PID).
# HOTPLUG      a udev rule (60-powos-controller.rules) starts a oneshot
#              (powos-controller@<node>.service) on every joystick plug-in that
#              reapplies the stored deadzone — so it survives replug and reboot.
#
# The kernel forgets the deadzone when the device is unplugged; that's exactly
# why the hotplug reapply exists. See docs/CONTROLLER.md.
#
# Functions here are pure definitions (no side effects on source), so the
# hotplug applier (controller-apply.sh) can `source` this file and reuse the
# low-level apply helpers without dragging in the CLI.
set -uo pipefail

# shellcheck source=/dev/null
source "${POWOS_LIB:-/usr/lib/powos}/common.sh"
POWOS_TAG=controller

# Persistent store. Overridable (POWOS_CONTROLLERS_CONF) for testing.
CTRL_CONF="${POWOS_CONTROLLERS_CONF:-/etc/powos/controllers.conf}"

# Hotplug plumbing install targets. /etc paths are chosen so the feature is
# fully functional and PERMANENT at runtime (both persist across bootc upgrades)
# without needing an image rebuild. If the image ever ships these under
# /usr/lib/{udev/rules.d,systemd/system}, the installed copies win and these are
# skipped as redundant.
CTRL_UNIT="powos-controller@.service"
# Overridable (POWOS_CONTROLLER_*) for testing; default to the real /etc paths.
CTRL_UDEV_RULE="${POWOS_CONTROLLER_UDEV_RULE:-/etc/udev/rules.d/60-powos-controller.rules}"
CTRL_UNIT_DST="${POWOS_CONTROLLER_UNIT_DST:-/etc/systemd/system/$CTRL_UNIT}"

# ── privilege helper ──────────────────────────────────────────────
# Setting an axis flat needs write access to /dev/input/eventN. The logged-in
# desktop user gets that via logind's uaccess ACL; anything else falls back to
# sudo. Config + /etc installs likewise escalate only when needed.
_ctrl_root() { if [[ ${EUID:-$(id -u)} -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# Install SRC → DST with MODE, escalating to sudo only when the destination
# isn't already writable by us (keeps test overrides in /tmp sudo-free).
_ctrl_install_file() {
    local src="$1" dst="$2" mode="${3:-0644}" dir
    dir=$(dirname "$dst")
    if { [[ -e "$dst" && -w "$dst" ]] || { [[ ! -e "$dst" ]] && [[ -w "$dir" ]]; }; }; then
        install -m "$mode" "$src" "$dst"
    else
        _ctrl_root install -D -m "$mode" "$src" "$dst"
    fi
}

# ══════════════════════════════════════════════════════════════════
# Device enumeration & resolution
# ══════════════════════════════════════════════════════════════════

# Emit one line per joystick event node:  node|jsNode|vid|pid|name
# A device counts as a joystick if it has a jsN sibling OR udev tagged it
# ID_INPUT_JOYSTICK. VID/PID are lowercase hex (matches lsusb/udev).
_ctrl_enum() {
    local e n name vid pid js
    for e in /sys/class/input/event*; do
        [[ -e "$e" ]] || continue
        n=$(basename "$e")
        js=$(ls -d "$e/device/js"* 2>/dev/null | head -1); js=${js##*/}
        if [[ -z "$js" ]]; then
            udevadm info -q property -n "/dev/input/$n" 2>/dev/null \
                | grep -q '^ID_INPUT_JOYSTICK=1' || continue
        fi
        name=$(cat "$e/device/name" 2>/dev/null)
        vid=$(tr 'A-Z' 'a-z' < "$e/device/id/vendor" 2>/dev/null)
        pid=$(tr 'A-Z' 'a-z' < "$e/device/id/product" 2>/dev/null)
        printf '%s|%s|%s|%s|%s\n' "$n" "${js:-—}" "$vid" "$pid" "$name"
    done
}

# Resolve a user token (VID:PID, name substring, or js/event node) to the first
# matching enumeration line. Prints node|js|vid|pid|name; returns 1 if no match.
_ctrl_resolve() {
    local q="${1:-}" node js vid pid name ql="${1,,}"
    [[ -n "$q" ]] || return 1
    while IFS='|' read -r node js vid pid name; do
        case "$q" in
            "$node"|"/dev/input/$node") { printf '%s|%s|%s|%s|%s\n' "$node" "$js" "$vid" "$pid" "$name"; return 0; } ;;
            "$js"|"/dev/input/$js")     { printf '%s|%s|%s|%s|%s\n' "$node" "$js" "$vid" "$pid" "$name"; return 0; } ;;
        esac
        [[ "${vid}:${pid}" == "$ql" ]] && { printf '%s|%s|%s|%s|%s\n' "$node" "$js" "$vid" "$pid" "$name"; return 0; }
        [[ -n "$name" && "${name,,}" == *"$ql"* ]] && { printf '%s|%s|%s|%s|%s\n' "$node" "$js" "$vid" "$pid" "$name"; return 0; }
    done < <(_ctrl_enum)
    return 1
}

# ══════════════════════════════════════════════════════════════════
# evdev axis read / write
# ══════════════════════════════════════════════════════════════════

# Read calibration for a node. Emits: idx|min|max|flat|value  per ABS axis.
# `evdev-joystick --showcal` prints the table then BLOCKS reading events, so we
# cap it with `timeout` and keep only the initial dump.
_ctrl_axes() {
    timeout 1 evdev-joystick --showcal "/dev/input/$1" 2>/dev/null | awk '
        /Absolute axis/ {
            idx=""; val=""; min=""; max=""; flat="";
            if (match($0, /\(([0-9]+)\)/,   a)) idx=a[1];
            if (match($0, /value: (-?[0-9]+)/,   v)) val=v[1];
            if (match($0, /min: (-?[0-9]+)/,     m)) min=m[1];
            if (match($0, /max: (-?[0-9]+)/,     M)) max=M[1];
            if (match($0, /flatness: (-?[0-9]+)/,f)) flat=f[1];
            if (idx != "") printf "%s|%s|%s|%s|%s\n", idx, min, max, flat, val;
        }'
}

# Set one axis flat (deadzone units). Uses the uaccess ACL when possible, else
# sudo. evdev-joystick applies the ioctl at startup and exits, so this is quick.
_ctrl_set_axis() {
    local node="$1" idx="$2" flat="$3"
    timeout 3 evdev-joystick --evdev "/dev/input/$node" --axis "$idx" --deadzone "$flat" >/dev/null 2>&1 && return 0
    _ctrl_root timeout 3 evdev-joystick --evdev "/dev/input/$node" --axis "$idx" --deadzone "$flat" >/dev/null 2>&1
}

# True if an axis is a bidirectional analog stick (rests near the center of its
# range), as opposed to a trigger/pedal (rests at min) or hat (range ≤2). Works
# regardless of whether the stick is reported signed (−32768..32767) or unsigned
# (0..65535). A deadzone is meaningful ONLY for these — an evdev "flat" on a
# trigger would dead-band the MIDDLE of its travel, which is wrong.
_ctrl_is_stick() {
    local min="$1" max="$2" val="$3" rng=$(( $2 - $1 ))
    (( rng > 2 )) || return 1
    awk -v v="$val" -v mn="$min" -v mx="$max" \
        'BEGIN{ c=(mn+mx)/2; d=v-c; if(d<0)d=-d; exit !((d*2.0/(mx-mn)) < 0.7) }'
}

# Apply a percentage deadzone to every analog stick axis of a node.
# Returns 0 if at least one axis was set.
_ctrl_apply_pct() {
    local node="$1" pct="$2" idx min max flat val rng applied=0
    while IFS='|' read -r idx min max flat val; do
        [[ -n "$idx" ]] || continue
        _ctrl_is_stick "$min" "$max" "$val" || continue
        rng=$((max - min))
        flat=$(awk -v p="$pct" -v r="$rng" 'BEGIN{printf "%d", (p*r/200)+0.5}')
        _ctrl_set_axis "$node" "$idx" "$flat" && applied=$((applied + 1))
    done < <(_ctrl_axes "$node")
    (( applied > 0 ))
}

# Shared awk fragment: max |value-center| across STICK axes only, as a percent
# of half-range. Reads idx|min|max|flat|value on stdin.
_ctrl_drift_awk() {
    awk -F'|' '
        { rng=$3-$2; if (rng>2) { c=($2+$3)/2; d=$5-c; if(d<0)d=-d; f=d*2.0/rng;
              if (f<0.7 && d*200.0/rng>mx) mx=d*200.0/rng } }
        END { printf "%.1f%%", mx }'
}

# ══════════════════════════════════════════════════════════════════
# Persistence  (/etc/powos/controllers.conf)
# ══════════════════════════════════════════════════════════════════

_ctrl_conf_seed() {
    [[ -f "$CTRL_CONF" ]] && return 0
    local tmp; tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
# PowOS controller deadzone store — managed by `powos controller`.
# Do not edit while a `powos controller` command is running.
#
# One entry set per controller, keyed by USB VID:PID (lowercase hex):
#   deadzone.<vid>:<pid> = <percent>     applied deadzone, e.g. 8
#   name.<vid>:<pid>     = <human name>  informational
#   default.<vid>:<pid>  = <idx:flat,…>  pre-PowOS flats, restored by `clear`
#
# Reapplied on every joystick hotplug by powos-controller@<node>.service.
EOF
    _ctrl_install_file "$tmp" "$CTRL_CONF" 0644
    rm -f "$tmp"
}

# Last value for an exact key (keys contain ':' and '.', so match literally).
_ctrl_conf_get() {
    [[ -r "$CTRL_CONF" ]] || return 0
    awk -v k="$1" 'index($0, k"=")==1 { print substr($0, length(k)+2) }' "$CTRL_CONF" | tail -1
}

# Upsert key=value (value may contain spaces/specials — awk, not sed).
_ctrl_conf_set() {
    local key="$1" val="$2" tmp
    _ctrl_conf_seed
    tmp=$(mktemp)
    awk -v k="$key" -v v="$val" '
        index($0, k"=")==1 && !done { print k"="v; done=1; next }
        { print }
        END { if (!done) print k"="v }
    ' "$CTRL_CONF" > "$tmp"
    _ctrl_install_file "$tmp" "$CTRL_CONF" 0644
    rm -f "$tmp"
}

_ctrl_conf_del() {
    local key="$1" tmp
    [[ -f "$CTRL_CONF" ]] || return 0
    tmp=$(mktemp)
    awk -v k="$key" 'index($0, k"=")==1 { next } { print }' "$CTRL_CONF" > "$tmp"
    _ctrl_install_file "$tmp" "$CTRL_CONF" 0644
    rm -f "$tmp"
}

# Record the device's pre-PowOS flats once, so `clear` can restore the true
# kernel default (per axis) rather than guessing zero.
_ctrl_capture_default() {
    local node="$1" vidpid="$2" idx min max flat pairs=""
    [[ -n "$(_ctrl_conf_get "default.$vidpid")" ]] && return 0
    while IFS='|' read -r idx min max flat _; do
        [[ -n "$idx" ]] || continue
        pairs+="${pairs:+,}$idx:$flat"
    done < <(_ctrl_axes "$node")
    [[ -n "$pairs" ]] && _ctrl_conf_set "default.$vidpid" "$pairs"
}

# ══════════════════════════════════════════════════════════════════
# Hotplug reapply used by the systemd oneshot (and `powos controller apply`)
# ══════════════════════════════════════════════════════════════════

# Reapply the stored deadzone for a single event node (by its live VID:PID).
_ctrl_apply_node() {
    local node="${1##*/}" vid pid pct
    vid=$(tr 'A-Z' 'a-z' < "/sys/class/input/$node/device/id/vendor" 2>/dev/null)
    pid=$(tr 'A-Z' 'a-z' < "/sys/class/input/$node/device/id/product" 2>/dev/null)
    [[ -n "$vid" && -n "$pid" ]] || return 0
    pct=$(_ctrl_conf_get "deadzone.$vid:$pid")
    [[ -n "$pct" ]] || return 0
    _ctrl_apply_pct "$node" "$pct"
}

# Reapply stored deadzones for every currently-connected joystick.
_ctrl_apply_all() {
    local node js vid pid name pct
    while IFS='|' read -r node js vid pid name; do
        pct=$(_ctrl_conf_get "deadzone.$vid:$pid")
        [[ -n "$pct" ]] && _ctrl_apply_pct "$node" "$pct"
    done < <(_ctrl_enum)
}

# ── hotplug plumbing install (idempotent) ─────────────────────────

_ctrl_write_unit() {
    local dst="$1" s
    for s in /usr/lib/systemd/system/powos-controller@.service \
             /var/lib/powos/src/systemd/powos-controller@.service; do
        [[ -f "$s" ]] && { cp "$s" "$dst"; return; }
    done
    cat > "$dst" <<'EOF'
[Unit]
Description=PowOS: reapply saved controller deadzone for /dev/input/%I
After=systemd-udevd.service

[Service]
Type=oneshot
ExecStart=/usr/lib/powos/controller-apply.sh %I
EOF
}

_ctrl_write_rule() {
    local dst="$1" s
    for s in /usr/lib/udev/rules.d/60-powos-controller.rules \
             /etc/powos/udev/60-powos-controller.rules \
             /var/lib/powos/src/config/udev/60-powos-controller.rules; do
        [[ -f "$s" ]] && { cp "$s" "$dst"; return; }
    done
    cat > "$dst" <<'EOF'
# PowOS controller deadzone — reapply saved deadzones on joystick hotplug.
# Managed by `powos controller`. Store: /etc/powos/controllers.conf
ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_JOYSTICK}=="1", TAG+="systemd", ENV{SYSTEMD_WANTS}+="powos-controller@%k.service"
EOF
}

# Ensure the udev rule + oneshot unit exist, so the deadzone is reapplied on
# every future plug-in / reboot. Called after the first deadzone is saved.
_ctrl_ensure_hotplug() {
    local changed=0 tmp
    if ! systemctl cat "$CTRL_UNIT" >/dev/null 2>&1 && [[ ! -f "$CTRL_UNIT_DST" ]]; then
        tmp=$(mktemp); _ctrl_write_unit "$tmp"; _ctrl_install_file "$tmp" "$CTRL_UNIT_DST" 0644; rm -f "$tmp"; changed=1
    fi
    if [[ ! -f "$CTRL_UDEV_RULE" ]] && [[ ! -f /usr/lib/udev/rules.d/60-powos-controller.rules ]]; then
        tmp=$(mktemp); _ctrl_write_rule "$tmp"; _ctrl_install_file "$tmp" "$CTRL_UDEV_RULE" 0644; rm -f "$tmp"; changed=1
    fi
    if (( changed )); then
        # Only reload the live daemons when we wrote to real system paths (skips
        # test overrides pointed at /tmp).
        if [[ "$CTRL_UDEV_RULE" == /etc/* || "$CTRL_UDEV_RULE" == /usr/* ]]; then
            _ctrl_root systemctl daemon-reload 2>/dev/null || true
            _ctrl_root udevadm control --reload 2>/dev/null || true
        fi
        plog "Hotplug reapply installed (udev rule + oneshot service)."
    fi
}

# ══════════════════════════════════════════════════════════════════
# Readouts used by `list`
# ══════════════════════════════════════════════════════════════════

# Currently-applied deadzone as a percentage, taken from the widest-range axis
# (a stick). Prints e.g. "8.0" or "-" if unreadable.
_ctrl_current_pct() {
    _ctrl_axes "$1" | awk -F'|' '
        { rng=$3-$2; if (rng>2 && rng>brng) { brng=rng; bflat=$4 } }
        END { if (brng>0) printf "%.1f", bflat*200.0/brng; else printf "-" }'
}

# Quick idle-drift readout: max |value-center| across stick axes, % of half-range.
_ctrl_idle_drift() {
    _ctrl_axes "$1" | _ctrl_drift_awk
}

# ══════════════════════════════════════════════════════════════════
# Subcommands
# ══════════════════════════════════════════════════════════════════

_ctrl_cmd_list() {
    local any=0 node js vid pid name stored axes now drift
    printf '%b%-8s %-5s %-11s %-7s %-7s %-7s %s%b\n' "$BOLD" \
        "EVENT" "JS" "VID:PID" "SAVED" "NOW" "DRIFT" "CONTROLLER" "$NC"
    while IFS='|' read -r node js vid pid name; do
        any=1
        stored=$(_ctrl_conf_get "deadzone.$vid:$pid")
        axes=$(_ctrl_axes "$node")
        # NOW = currently-applied deadzone, read from the widest-range (stick) axis.
        now=$(printf '%s\n' "$axes" | awk -F'|' '
            { rng=$3-$2; if (rng>2 && rng>brng) { brng=rng; bflat=$4 } }
            END { if (brng>0) printf "%.1f%%", bflat*200.0/brng; else printf "-" }')
        drift=$(printf '%s\n' "$axes" | _ctrl_drift_awk)
        printf '%-8s %-5s %-11s %-7s %-7s %-7s %s\n' \
            "$node" "$js" "$vid:$pid" "${stored:+${stored}%}" "$now" "$drift" "$name"
    done < <(_ctrl_enum)
    if (( ! any )); then
        pwarn "No joysticks/gamepads detected. Plug one in and re-run."
        return 0
    fi
    echo
    echo "Set a deadzone:  powos controller deadzone <device> <pct|auto>"
}

_ctrl_cmd_deadzone() {
    local dev="${1:-}" arg="${2:-}"
    if [[ -z "$dev" || -z "$arg" ]]; then
        perr "usage: powos controller deadzone <device> <pct|auto>"
        return 2
    fi
    local rec node js vid pid name vidpid pct
    rec=$(_ctrl_resolve "$dev") || { perr "No controller matches '$dev'. Try 'powos controller list'."; return 1; }
    IFS='|' read -r node js vid pid name <<<"$rec"
    vidpid="$vid:$pid"

    if [[ "$arg" == auto ]]; then
        pct=$(_ctrl_auto_pct "$node")
        [[ -n "$pct" ]] || { perr "auto-sample failed to read axes."; return 1; }
        plog "Measured idle drift → deadzone ${pct}% (just above the drift)."
    else
        pct="${arg%\%}"
        [[ "$pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { perr "deadzone must be a percent (e.g. 8) or 'auto'."; return 2; }
        awk -v p="$pct" 'BEGIN{exit !(p>=0 && p<=90)}' || { perr "deadzone out of range (0–90%)."; return 2; }
    fi

    _ctrl_capture_default "$node" "$vidpid"
    _ctrl_conf_set "deadzone.$vidpid" "$pct"
    [[ -n "$name" ]] && _ctrl_conf_set "name.$vidpid" "$name"

    if _ctrl_apply_pct "$node" "$pct"; then
        pok "$name ($vidpid): ${pct}% deadzone applied to /dev/input/$node and saved."
    else
        pwarn "Saved ${pct}% for $vidpid, but could not apply to the device now (permissions?)."
    fi
    _ctrl_ensure_hotplug
}

# Sample idle stick axes over ~2s; return a percentage just above the worst drift.
_ctrl_auto_pct() {
    local node="$1" worst=0 i p
    for i in 1 2 3; do
        p=$(_ctrl_axes "$node" | _ctrl_drift_awk | tr -d '%')
        awk -v a="$p" -v b="$worst" 'BEGIN{exit !(a>b)}' && worst="$p"
    done
    # 2-point margin above the measured drift; sane floor/ceiling.
    awk -v m="$worst" 'BEGIN{ x=m+2; if (x<3) x=3; if (x>30) x=30; printf "%d", x+0.5 }'
}

_ctrl_cmd_clear() {
    local dev="${1:-}" rec node js vid pid name vidpid def
    [[ -n "$dev" ]] || { perr "usage: powos controller clear <device>"; return 2; }
    rec=$(_ctrl_resolve "$dev") || { perr "No controller matches '$dev'. Try 'powos controller list'."; return 1; }
    IFS='|' read -r node js vid pid name <<<"$rec"
    vidpid="$vid:$pid"

    def=$(_ctrl_conf_get "default.$vidpid")
    if [[ -n "$def" ]]; then
        local pair idx flat
        IFS=',' read -ra pairs <<<"$def"
        for pair in "${pairs[@]}"; do
            idx="${pair%%:*}"; flat="${pair##*:}"
            [[ "$idx" =~ ^[0-9]+$ ]] && _ctrl_set_axis "$node" "$idx" "$flat"
        done
    fi
    _ctrl_conf_del "deadzone.$vidpid"
    _ctrl_conf_del "name.$vidpid"
    _ctrl_conf_del "default.$vidpid"
    pok "Cleared stored deadzone for $vidpid; flat reset to kernel default."
}

_ctrl_cmd_status() {
    echo -e "${BOLD}Stored controller deadzones${NC}  ($CTRL_CONF)"
    local shown=0
    if [[ -r "$CTRL_CONF" ]]; then
        while IFS='=' read -r k v; do
            [[ "$k" == deadzone.* ]] || continue
            local vp="${k#deadzone.}" nm
            nm=$(_ctrl_conf_get "name.$vp")
            printf '  %-12s %4s%%   %s\n' "$vp" "$v" "$nm"
            shown=1
        done < "$CTRL_CONF"
    fi
    (( shown )) || echo "  (none yet — set one with 'powos controller deadzone <device> <pct>')"

    echo
    echo -e "${BOLD}Hotplug reapply${NC}"
    local rule_state unit_state
    if [[ -f "$CTRL_UDEV_RULE" ]]; then rule_state="installed ($CTRL_UDEV_RULE)"
    elif [[ -f /usr/lib/udev/rules.d/60-powos-controller.rules ]]; then rule_state="installed (image)"
    else rule_state="not installed (set a deadzone to install)"; fi
    if [[ -f "$CTRL_UNIT_DST" ]] || systemctl cat "$CTRL_UNIT" >/dev/null 2>&1; then unit_state="present"; else unit_state="missing (set a deadzone to install)"; fi
    echo "  udev rule:     $rule_state"
    echo "  oneshot unit:  $CTRL_UNIT — $unit_state"
}

_ctrl_help() {
    cat <<EOF
${BOLD}powos controller${NC} — permanent, driver-level analog stick-drift fixer

A deadzone set here lives in the kernel input device, BELOW the game, so Steam
and every title see clean-centered sticks with no per-game tweaking. Works with
any joystick/gamepad (Xbox, PS4/PS5/DualSense, DJI, generic HID).

Usage:
  powos controller list                     Detected controllers + deadzone + drift
  powos controller deadzone <dev> <pct>     Set & persist a deadzone (applies now)
  powos controller deadzone <dev> auto      Measure idle drift, set just above it
  powos controller clear <dev>              Remove stored deadzone (reset to default)
  powos controller status                   Stored config + hotplug unit state

<dev> accepts a VID:PID (e.g. 2ca3:1020), a name substring (e.g. dji), or a
js/event node (e.g. js0 or event2).

Examples:
  powos controller list
  powos controller deadzone 045e:028e 8      # Xbox pad, 8% deadzone
  powos controller deadzone "dualsense" auto # measure & fix a drifting PS5 pad
  powos controller clear js0

Persisted in /etc/powos/controllers.conf and reapplied on every plug-in/reboot.
EOF
}

# ══════════════════════════════════════════════════════════════════
# Dispatch
# ══════════════════════════════════════════════════════════════════
cmd_controller() {
    # This subsystem checks return codes explicitly and relies on `timeout`
    # deliberately killing the blocking `evdev-joystick --showcal` (exit 124).
    # bin/powos runs under `set -e`, which would abort on those expected
    # non-zero statuses, so drop errexit for the duration of the command.
    set +e
    command -v evdev-joystick >/dev/null 2>&1 || {
        perr "evdev-joystick not found (linuxconsoletools). It ships in the base image."
        return 1
    }
    local sub="${1:-list}"; shift 2>/dev/null || true
    case "$sub" in
        list|ls)              _ctrl_cmd_list ;;
        deadzone|dz|set)      _ctrl_cmd_deadzone "$@" ;;
        clear|reset|rm)       _ctrl_cmd_clear "$@" ;;
        status|st)            _ctrl_cmd_status ;;
        apply|reapply)        _ctrl_apply_all ;;   # manual reapply (also the hotplug path)
        help|-h|--help)       _ctrl_help ;;
        *) perr "Unknown: powos controller $sub"; _ctrl_help; return 1 ;;
    esac
}
