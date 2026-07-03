#!/usr/bin/env bash
# HomeFS Installation Script

set -euo pipefail

INSTALL_DIR="/usr/local/lib/homefs"
BIN_DIR="/usr/local/bin"
CONFIG_DIR="/etc/homefs"
SYSTEMD_DIR="/etc/systemd/system"
UDEV_DIR="/etc/udev/rules.d"

echo "Installing HomeFS..."

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)"
   exit 1
fi

# Install Python dependencies
echo "Installing Python dependencies..."
pip3 install -r requirements.txt

# Install HomeFS library
echo "Installing HomeFS library..."
mkdir -p "$INSTALL_DIR"
cp -r *.py "$INSTALL_DIR/"

# Install CLI
echo "Installing CLI..."
ln -sf "$INSTALL_DIR/cli.py" "$BIN_DIR/homefs"
chmod +x "$BIN_DIR/homefs"

# Install configuration
echo "Installing configuration..."
mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/config.json" ]]; then
    cp config.example.json "$CONFIG_DIR/config.json"
    echo "Created default config at $CONFIG_DIR/config.json"
    echo "Please edit this file with your USB UUID"
fi

# Install systemd services
echo "Installing systemd services..."
cp ../../systemd/powos-homefs.service "$SYSTEMD_DIR/"
cp ../../systemd/powos-homefs-sync.service "$SYSTEMD_DIR/"
cp ../../systemd/powos-usb-monitor.service "$SYSTEMD_DIR/"
systemctl daemon-reload

# Install udev rules
echo "Installing udev rules..."
cp ../../config/udev/99-homefs-usb.rules "$UDEV_DIR/"
udevadm control --reload-rules

# Create runtime directories
mkdir -p /var/lib/homefs
mkdir -p /var/run/homefs

echo ""
echo "✓ HomeFS installed successfully!"
echo ""
echo "Next steps:"
echo "1. Edit /etc/homefs/config.json with your USB UUID"
echo "2. Find your USB UUID: blkid /dev/sdX2"
echo "3. Update USB UUID in config"
echo "4. Enable service: systemctl enable powos-homefs@YOUR-UUID.service"
echo "5. Start service: systemctl start powos-homefs@YOUR-UUID.service"
echo ""
echo "Or mount manually: homefs mount /dev/sdb2 /home"
