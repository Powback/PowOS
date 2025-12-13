#!/bin/bash
# PowOS Build Structure Validation Script
# Verifies that all required files are in place before building

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() { echo -e "${BLUE}=== $1 ===${NC}"; }
print_ok() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }

errors=0
warnings=0

print_header "Validating PowOS Build Structure"
echo

# Check Containerfiles
print_header "Containerfiles"
for file in Containerfile.base-common Containerfile.mesa Containerfile.nvidia; do
    if [ -f "$file" ]; then
        print_ok "$file exists"
    else
        print_error "$file missing"
        ((errors++))
    fi
done
echo

# Check build_files directory
print_header "Build Scripts"
required_scripts=(
    "cleanup"
    "install-kernel"
    "install-firmware"
    "install-nvidia"
    "ghcurl"
    "dnf5-setopt"
    "dnf5-search"
    "image-info"
    "build-initramfs"
    "finalize"
)

for script in "${required_scripts[@]}"; do
    path="build_files/$script"
    if [ -f "$path" ]; then
        print_ok "$script"
    else
        print_error "$script missing"
        ((errors++))
    fi
done
echo

# Check system_files directories
print_header "System Files"
required_dirs=(
    "system_files/shared"
    "system_files/nvidia/shared"
    "system_files/overrides"
)

for dir in "${required_dirs[@]}"; do
    if [ -d "$dir" ]; then
        count=$(find "$dir" -type f | wc -l)
        print_ok "$dir ($count files)"
    else
        print_error "$dir missing"
        ((errors++))
    fi
done
echo

# Check for COPY paths in Containerfiles
print_header "COPY Path Verification"
all_paths=(
    "system_files/shared"
    "build_files/cleanup"
    "build_files/install-kernel"
    "build_files/ghcurl"
    "build_files/dnf5-setopt"
    "build_files/dnf5-search"
    "build_files/install-firmware"
    "build_files/image-info"
    "build_files/build-initramfs"
    "build_files/finalize"
    "system_files/overrides"
    "system_files/nvidia/shared"
    "build_files/install-nvidia"
)

for path in "${all_paths[@]}"; do
    if [ -e "$path" ]; then
        print_ok "$path"
    else
        print_error "$path missing"
        ((errors++))
    fi
done
echo

# Check for podman/docker
print_header "Container Runtime"
if command -v podman &> /dev/null; then
    print_ok "podman found ($(podman --version))"
elif command -v docker &> /dev/null; then
    print_ok "docker found ($(docker --version))"
    print_warning "Using docker instead of podman"
    ((warnings++))
else
    print_error "Neither podman nor docker found"
    print_error "Install podman: sudo dnf install podman"
    ((errors++))
fi
echo

# Check disk space
print_header "Disk Space"
available=$(df -BG . | tail -1 | awk '{print $4}' | sed 's/G//')
if [ "$available" -gt 20 ]; then
    print_ok "$available GB available (recommended: 20GB+)"
else
    print_warning "Only $available GB available (recommended: 20GB+)"
    ((warnings++))
fi
echo

# Summary
print_header "Validation Summary"
if [ $errors -eq 0 ]; then
    print_ok "All required files present"
    if [ $warnings -eq 0 ]; then
        echo -e "${GREEN}Ready to build!${NC}"
        echo
        echo "To build images:"
        echo "  bash build.sh mesa      # Build Mesa variant"
        echo "  bash build.sh nvidia    # Build NVIDIA variant"
        echo "  bash build.sh all       # Build both variants"
    else
        echo -e "${YELLOW}Build possible but with $warnings warning(s)${NC}"
    fi
    exit 0
else
    print_error "Validation failed with $errors error(s) and $warnings warning(s)"
    echo
    echo "Please ensure all required files are copied from bazzite-fork:"
    echo "  cp -r ../bazzite-fork/build_files/* build_files/"
    echo "  cp -r ../bazzite-fork/system_files/desktop/shared/* system_files/shared/"
    echo "  cp -r ../bazzite-fork/system_files/nvidia/shared/* system_files/nvidia/shared/"
    echo "  cp -r ../bazzite-fork/system_files/overrides/* system_files/overrides/"
    exit 1
fi
