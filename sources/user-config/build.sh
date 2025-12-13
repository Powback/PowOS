#!/usr/bin/env bash
# build.sh - Build script for user-config overlay
#
# This allows users to "bake" their own system-wide configurations
# into an immutable overlay.

set -euo pipefail

OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
NAME="${OVERLAY_NAME:-user-config}"

echo "Building: $NAME"

# 1. Structure
mkdir -p "$OUTPUT_DIR/etc"
mkdir -p "$OUTPUT_DIR/usr/local/bin"

# 2. Example: Custom welcome message
cat > "$OUTPUT_DIR/etc/motd" << 'EOF'
Welcome to your Custom PowOS Instance!
Configured via: sources/user-config
EOF

# 3. Example: Custom script
cat > "$OUTPUT_DIR/usr/local/bin/my-script" << 'EOF'
#!/bin/bash
echo "This script persists across reboots because it is in an overlay!"
EOF
chmod +x "$OUTPUT_DIR/usr/local/bin/my-script"

echo "✅ Built: $NAME"
