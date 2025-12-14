#!/usr/bin/env bash
# fetch.sh - Fetch KDE application sources
#
# Usage:
#   ./fetch.sh           # Fetch all apps
#   ./fetch.sh dolphin   # Fetch just Dolphin

set -euo pipefail

SRC_DIR="$(dirname "$0")"
source "$SRC_DIR/source.conf"

UPSTREAM_DIR="$SRC_DIR/upstream"
mkdir -p "$UPSTREAM_DIR"

# Map apps to their KDE Invent categories
declare -A APP_CATEGORIES=(
    [dolphin]="system"
    [gwenview]="graphics"
    [spectacle]="graphics"
    [ark]="utilities"
    [konsole]="utilities"
    [kate]="utilities"
    [okular]="graphics"
)

fetch_app() {
    local app="$1"
    local category="${APP_CATEGORIES[$app]:-system}"
    local app_dir="$UPSTREAM_DIR/$app"

    if [[ -d "$app_dir" ]]; then
        echo "  ✓ $app (already fetched)"
        return 0
    fi

    echo "  Fetching $app..."
    git clone --depth 1 "$KDE_INVENT_URL/$category/$app.git" "$app_dir" 2>/dev/null || \
    git clone --depth 1 "$KDE_INVENT_URL/system/$app.git" "$app_dir" 2>/dev/null || \
    git clone --depth 1 "$KDE_INVENT_URL/utilities/$app.git" "$app_dir" || {
        echo "  ✗ Failed to fetch $app"
        return 1
    }
    echo "  ✓ $app"
}

if [[ $# -gt 0 ]]; then
    # Fetch specific app(s)
    for app in "$@"; do
        fetch_app "$app"
    done
else
    # Fetch all apps
    echo "Fetching KDE applications..."
    for app in $KDE_APPS; do
        fetch_app "$app"
    done
fi

echo ""
echo "✅ KDE sources ready in: $UPSTREAM_DIR"
