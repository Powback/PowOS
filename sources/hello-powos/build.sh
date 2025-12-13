#!/usr/bin/env bash
# build.sh - Build script for hello-powos overlay
#
# This is an example overlay that demonstrates the build process.
# It creates a simple shell script that gets overlaid into /usr/bin.
#
# Environment variables provided by overlay-manager.sh:
#   OVERLAY_OUTPUT_DIR - Where to place built files
#   OVERLAY_NAME       - Name of this overlay

set -euo pipefail

OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
NAME="${OVERLAY_NAME:-hello-powos}"

echo "Building: $NAME"
echo "Output:   $OUTPUT_DIR"

# Create directory structure
mkdir -p "$OUTPUT_DIR/usr/bin"
mkdir -p "$OUTPUT_DIR/usr/share/$NAME"

# Create the main binary
cat > "$OUTPUT_DIR/usr/bin/hello-powos" << 'SCRIPT'
#!/usr/bin/env bash
# hello-powos - Example PowOS overlay binary
#
# This script demonstrates that PowOS overlays are working correctly.

VERSION="1.0.0"

case "${1:-}" in
    --version|-v)
        echo "hello-powos $VERSION"
        echo "Part of PowOS - The Container-Native Workstation"
        ;;
    --help|-h)
        cat << EOF
hello-powos - Example PowOS overlay

Usage: hello-powos [OPTIONS]

Options:
    --version, -v    Show version
    --help, -h       Show this help
    --info           Show system info

This binary was installed via PowOS systemd-sysext overlay.
It demonstrates that custom binaries can replace or extend
system files without modifying the immutable base OS.
EOF
        ;;
    --info)
        echo "=== PowOS System Info ==="
        echo "Overlay: hello-powos"
        echo "Binary:  $(realpath "$0" 2>/dev/null || echo "$0")"
        echo ""
        echo "Environment:"
        echo "  POWOS_ROOT: ${POWOS_ROOT:-not set}"
        echo "  POWOS_DEV:  ${POWOS_DEV:-not set}"
        echo ""
        echo "System:"
        echo "  Kernel:  $(uname -r)"
        echo "  OS:      $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
        echo ""
        if command -v systemd-sysext &>/dev/null; then
            echo "Extensions:"
            systemd-sysext status 2>/dev/null || echo "  (not available)"
        fi
        ;;
    *)
        echo "🚀 Hello from PowOS!"
        echo ""
        echo "This message comes from a systemd-sysext overlay."
        echo "The base OS is immutable, but this binary was injected"
        echo "into /usr/bin via the extension system."
        echo ""
        echo "Try: hello-powos --info"
        ;;
esac
SCRIPT

chmod +x "$OUTPUT_DIR/usr/bin/hello-powos" 2>/dev/null || true

# Create a data file to demonstrate /usr/share
cat > "$OUTPUT_DIR/usr/share/$NAME/README" << 'EOF'
PowOS Hello Overlay
===================

This overlay demonstrates the PowOS extension system.

Files installed:
  /usr/bin/hello-powos       - Example binary
  /usr/share/hello-powos/    - Data files

How it works:
  1. Source code lives in ~/powos/sources/hello-powos/
  2. Running 'just build hello-powos' compiles the overlay
  3. Running 'just enable-overlay hello-powos' activates it
  4. The binary appears in /usr/bin without modifying the base OS

To modify:
  1. Edit this build.sh or source files
  2. Run: just build hello-powos
  3. The overlay updates immediately (with systemd-sysext refresh)

To remove:
  1. Run: just disable-overlay hello-powos
  2. The base OS binary (if any) is restored
EOF

echo "✅ Built: $NAME"
echo "   Binary: $OUTPUT_DIR/usr/bin/hello-powos"
echo "   Data:   $OUTPUT_DIR/usr/share/$NAME/"
