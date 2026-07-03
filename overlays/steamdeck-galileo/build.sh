#!/usr/bin/bash
# Build script for Steam Deck Galileo overlay
# This script is called by the generic build-overlay.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Call the generic build script
exec "${SCRIPT_DIR}/../build-overlay.sh" "steamdeck-galileo"
