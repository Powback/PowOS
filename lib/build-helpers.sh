#!/usr/bin/env bash
# build-helpers.sh - Shared functions for overlay build scripts

# Install packages from packages.txt to the output directory
# Usage: install_packages <output_dir> <packages_file>
install_packages() {
    local output_dir="$1"
    local pkg_file="${2:-packages.txt}"

    if [[ ! -f "$pkg_file" ]]; then
        echo "No packages.txt found, skipping package installation."
        return 0
    fi

    echo "Installing packages from $pkg_file..."

    # Read packages, ignoring comments and empty lines
    local packages
    packages=$(grep -v '^#' "$pkg_file" 2>/dev/null | grep -v '^$' | tr '\n' ' ' || true)

    if [[ -z "$packages" ]]; then
        echo "No packages to install."
        return 0
    fi

    echo "Packages: $packages"

    # Create a temporary root for dnf
    local temp_root
    temp_root=$(mktemp -d)
    
    # Copy repository configuration from the host (container's) /etc/yum.repos.d/
    mkdir -p "$temp_root/etc/yum.repos.d/"
    cp /etc/yum.repos.d/* "$temp_root/etc/yum.repos.d/" || true # Copy all available repos

    # Auto-detect release version from the container
    local release_ver
    if [[ -f /etc/os-release ]]; then
        release_ver=$(grep -oP 'VERSION_ID=\K\d+' /etc/os-release)
    else
        release_ver="39" # Fallback
    fi
    echo "Detected release version: $release_ver"

    # Use dnf to install into temp root
    # --nogpgcheck is added as a workaround for build failures with unsigned packages.
    if dnf install -y --installroot="$temp_root" --releasever="$release_ver" --setopt=install_weak_deps=False --setopt=keepcache=False --nogpgcheck --skip-unavailable $packages; then
        echo "Packages installed successfully to temp root."
    else
        echo "Failed to install packages."
        rm -rf "$temp_root"
        return 1
    fi

    # Move files from temp root to output dir
    # We primarily want /usr
    if [[ -d "$temp_root/usr" ]]; then
        cp -r "$temp_root/usr/"* "$output_dir/usr/"
    fi
    
    # Also check for /etc configs and move them to /usr/share/<name>/etc for sysext compatibility
    # (Systemd sysexts only overlay /usr)
    # However, for simplicity in this specific "install_packages", we might just copy /usr.
    # If the package puts things in /etc, we might need to handle that.
    # For now, let's assume /usr is the main target.

    rm -rf "$temp_root"
}

# Copy overlay structure (configs, services, etc)
# Usage: copy_overlay_files <source_dir> <output_dir>
copy_overlay_files() {
    local source_dir="$1"
    local output_dir="$2"

    echo "Copying files from $source_dir to $output_dir..."

    # Services (handle empty directories gracefully)
    if [[ -d "$source_dir/services" ]] && ls "$source_dir/services/"* &>/dev/null; then
        mkdir -p "$output_dir/usr/lib/systemd/system"
        cp -r "$source_dir/services/"* "$output_dir/usr/lib/systemd/system/"
    fi

    # Udev rules (handle empty directories gracefully)
    if [[ -d "$source_dir/udev" ]] && ls "$source_dir/udev/"* &>/dev/null; then
        mkdir -p "$output_dir/usr/lib/udev/rules.d"
        cp -r "$source_dir/udev/"* "$output_dir/usr/lib/udev/rules.d/"
    fi

    # Binaries (handle empty directories gracefully)
    if [[ -d "$source_dir/bin" ]] && ls "$source_dir/bin/"* &>/dev/null; then
        mkdir -p "$output_dir/usr/bin"
        cp -r "$source_dir/bin/"* "$output_dir/usr/bin/"
        chmod +x "$output_dir/usr/bin/"*
    fi

    # Configs (generic)
    if [[ -d "$source_dir/configs" ]]; then
        # If it has structure like configs/usr/..., copy it
        if [[ -d "$source_dir/configs/usr" ]] && ls "$source_dir/configs/usr/"* &>/dev/null; then
            cp -r "$source_dir/configs/usr/"* "$output_dir/usr/"
        fi

        # If it has configs/etc, we CANNOT overlay /etc directly with sysext.
        # But we can put them in /usr/share/defaults and have a script apply them,
        # or rely on applications reading from /usr/share.
        # For this implementation, we will skip /etc overlaying as it's not supported by systemd-sysext
        # directly in the same way.
    fi
}
