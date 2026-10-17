#!/bin/bash
# powos android - PowOS on a phone talks to Android: its apps, what runs, notifications, the screen.
#
# The other half of PowOS on Android (targets/android): the PowOS app shows PowOS in Android; this shows Android
# to PowOS - to the user's shell and, through `powos help` (agents' prompts are generated from it), to PowOS AI.
#
# How: adb to the phone itself (127.0.0.1:5555 - rooted mode authorizes PowOS's adb key; the same link
# powos-android-app and powos-android-tasks use). Android's apps as PowOS knows them: the android-<package>.desktop
# entries the PowOS app writes (its drawer, the taskbar, the start menu).

_ANDROID_DEV=127.0.0.1:5555

_android_need() {
    if ! command -v adb >/dev/null 2>&1; then
        echo "powos android: no adb (only on a phone running PowOS, rooted mode)" >&2
        return 1
    fi
    if [[ "$(adb -s "$_ANDROID_DEV" get-state 2>/dev/null)" != device ]]; then
        echo "powos android: no link to Android (adb $_ANDROID_DEV; rooted mode only)" >&2
        return 1
    fi
}

_android_sh() { adb -s "$_ANDROID_DEV" shell "$@"; }

# android-<package>.desktop entries: "<package>\t<name>" per app, sorted by name.
_android_apps() {
    local dirs d f
    dirs="${XDG_RUNTIME_DIR:-/run/powos-app}/share:${XDG_DATA_HOME:-$HOME/.local/share}:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    local IFS=:
    for d in $dirs; do
        for f in "$d"/applications/android-*.desktop; do
            [[ -f "$f" ]] || continue
            local pkg name
            pkg=$(basename "$f" .desktop); pkg=${pkg#android-}
            name=$(sed -n 's/^Name=//p' "$f" | head -1)
            printf '%s\t%s\n' "$pkg" "${name:-$pkg}"
        done
    done | sort -t$'\t' -k2,2f -u
}

# A package from a package name or an app's name (case-insensitive; a unique prefix will do).
_android_resolve() {
    local want=$1 apps line
    apps=$(_android_apps)
    line=$(awk -F'\t' -v w="$want" '$1 == w' <<<"$apps" | head -1)
    [[ -n "$line" ]] || line=$(awk -F'\t' -v w="$(tr '[:upper:]' '[:lower:]' <<<"$want")" 'tolower($2) == w' <<<"$apps" | head -1)
    if [[ -z "$line" ]]; then
        local matches
        matches=$(awk -F'\t' -v w="$(tr '[:upper:]' '[:lower:]' <<<"$want")" 'index(tolower($2), w) == 1' <<<"$apps")
        [[ $(grep -c . <<<"$matches") == 1 ]] && line=$matches
    fi
    if [[ -z "$line" ]]; then
        # Not in the drawer (no launcher entry yet): a package name passes through as it is.
        [[ "$want" == *.* ]] && { echo "$want"; return 0; }
        echo "powos android: no app '$want' (powos android apps lists them)" >&2
        return 1
    fi
    cut -f1 <<<"$line"
}

android_help() {
    cat <<'EOF'
powos android - Android, from PowOS (on a phone running PowOS, rooted mode)

  powos android apps                  Android's apps: package and name
  powos android open <app> [--full]   Open an app (package or name) as a PowOS window; --full: on the phone's
                                      screen, full screen (leaving PowOS)
  powos android running               Apps running on the phone: task id, display, package
  powos android notifications         The phone's notifications: app, title, text
  powos android notify <title> [text] Post a notification on the phone
  powos android screenshot [file]     The phone's screen as a PNG (default: ./android-<time>.png)
  powos android help                  This help

Window buttons do the rest: maximize on a PowOS window makes it its own Android task (Recents, split screen);
on an Android app's window it hands the app back to Android, full screen.
EOF
}

cmd_android() {
    local verb=${1:-help}
    shift || true
    case "$verb" in
        apps)
            _android_apps | awk -F'\t' '{ printf "%-40s %s\n", $1, $2 }'
            ;;
        open)
            local app="" full=0
            for a in "$@"; do
                case "$a" in
                    --full) full=1 ;;
                    *) app=$a ;;
                esac
            done
            [[ -n "$app" ]] || { echo "usage: powos android open <app> [--full]" >&2; return 2; }
            local pkg; pkg=$(_android_resolve "$app") || return 1
            if (( full )); then
                _android_need || return 1
                _android_sh monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null
            else
                local name; name=$(awk -F'\t' -v p="$pkg" '$1 == p { print $2 }' <<<"$(_android_apps)")
                setsid -f powos-android-app "$pkg" "${name:-$pkg}" >/dev/null 2>&1 </dev/null
            fi
            ;;
        running)
            _android_need || return 1
            _android_sh am stack list | awk '
                /RootTask id=/ { match($0, /displayId=[0-9]+/); disp = substr($0, RSTART + 10, RLENGTH - 10) }
                /taskId=/ {
                    match($0, /taskId=[0-9]+/); id = substr($0, RSTART + 7, RLENGTH - 7)
                    match($0, /: [^\/ ]+\//); pkg = substr($0, RSTART + 2, RLENGTH - 3)
                    vis = ($0 ~ /visible=true/) ? "visible" : ""
                    if (pkg != "") printf "%-8s display %-4s %-40s %s\n", id, disp, pkg, vis
                }'
            ;;
        notifications)
            _android_need || return 1
            # Active notifications (not the history): package, title, text, one per line.
            _android_sh dumpsys notification --noredact | awk '
                /^ *NotificationRecord\(/ { if (pkg != "") print pkg "\t" title "\t" text; pkg = ""; title = ""; text = ""
                                            if (match($0, /pkg=[^ ]+/)) pkg = substr($0, RSTART + 4, RLENGTH - 4) }
                /^ *Notification History/ { exit }
                /android\.title=/ && title == "" { sub(/.*android\.title=[A-Za-z]* \(/, ""); sub(/\)$/, ""); title = $0 }
                /android\.text=/ && text == "" { sub(/.*android\.text=[A-Za-z]* \(/, ""); sub(/\)$/, ""); text = $0 }
                END { if (pkg != "") print pkg "\t" title "\t" text }' |
                awk -F'\t' '$2 != "" || $3 != "" { printf "%-32s %s%s%s\n", $1, $2, ($2 != "" && $3 != "") ? " - " : "", $3 }'
            ;;
        notify)
            _android_need || return 1
            local title=${1:-} text=${2:-}
            [[ -n "$title" ]] || { echo "usage: powos android notify <title> [text]" >&2; return 2; }
            [[ -n "$text" ]] || { text=$title; title="PowOS"; }
            # cmd notification posts as Android's shell; the tag keeps one entry per title.
            local q_title q_text
            printf -v q_title '%q' "$title"; printf -v q_text '%q' "$text"
            _android_sh "cmd notification post -S bigtext -t $q_title powos-$RANDOM $q_text" >/dev/null
            ;;
        screenshot)
            _android_need || return 1
            local file=${1:-./android-$(date +%Y%m%d-%H%M%S).png}
            adb -s "$_ANDROID_DEV" exec-out screencap -p > "$file" && echo "$file"
            ;;
        help|--help|-h)
            android_help
            ;;
        *)
            echo "powos android: unknown command '$verb'" >&2
            android_help >&2
            return 2
            ;;
    esac
}
