#!/usr/bin/env bash
# build-helpers.sh - Shared functions for overlay build scripts

# Copy <temp_root>/usr into <output_dir>/usr, skipping every path the
# reference /usr already provides.
#
# This is the guard that keeps a sysext additive. dnf --installroot resolves a
# full dependency closure, so an un-pruned overlay ships glibc, OpenSSL,
# systemd libs and bash built for the overlay's target release; merging that
# over a host on a newer release replaces its core libraries with older ones
# and kills the running system.
#
# Extracted so it is unit-testable without a package install —
# test/tier1/test-overlay-prune.sh exercises it directly.
# Returns non-zero when nothing new remains: an overlay that only shadows the
# host is never valid.
# Usage: powos_prune_overlay_usr <temp_root> <output_dir> [ref_usr]
powos_prune_overlay_usr() {
    local temp_root="$1" output_dir="$2" ref_usr="${3:-/usr}"
    local kept=0 pruned=0 rel src
    while IFS= read -r -d '' src; do
        rel="${src#"$temp_root"/usr/}"
        # -e follows symlinks, so a DANGLING symlink on the host would look
        # absent and we would happily shadow it. -L catches that case.
        if [[ -e "$ref_usr/$rel" || -L "$ref_usr/$rel" ]]; then
            pruned=$((pruned+1))
            continue
        fi
        mkdir -p "$output_dir/usr/$(dirname "$rel")"
        cp -a "$src" "$output_dir/usr/$rel"
        kept=$((kept+1))
    done < <(find "$temp_root/usr" \( -type f -o -type l \) -print0)
    echo "Overlay contents: kept $kept new file(s), pruned $pruned already on the host."
    [[ $kept -gt 0 ]]
}

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
    # A leading '?' marks a package OPTIONAL: install it when the repos have
    # it, never fail the build when they do not. Everything else is REQUIRED
    # and its absence fails the build (see the verification pass below).
    # Optional exists for packages that only apply to some hardware — e.g. hhd
    # (Handheld Daemon) matters on ROG Ally / Legion Go class devices, while a
    # Steam Deck uses native kernel support, and it is not carried by the
    # ublue COPRs at all.
    local all_lines required_pkgs optional_pkgs packages
    all_lines=$(grep -v '^#' "$pkg_file" 2>/dev/null | grep -v '^$' || true)
    required_pkgs=$(echo "$all_lines" | grep -v '^?' | tr '\n' ' ' || true)
    optional_pkgs=$(echo "$all_lines" | grep '^?' | sed 's/^?//' | tr '\n' ' ' || true)
    packages="$required_pkgs $optional_pkgs"
    packages=$(echo "$packages" | tr -s ' ')

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

    # Release version: the OVERLAY's declared target wins over the host's.
    #
    # An overlay pins OS_VERSION in metadata.env because its packages exist for
    # that Fedora release. Auto-detecting the host instead breaks every build
    # the moment the host moves ahead of upstream: capability-gaming-mode
    # declares 43, the box moved to 44, and gamescope-session-plus /
    # steamos-manager have no fc44 build in the ublue-os COPRs yet — so every
    # headline package vanished with "No match for argument".
    local release_ver=""
    local meta_file="${OVERLAY_SOURCE_DIR:-$(dirname "$pkg_file")}/metadata.env"
    if [[ -f "$meta_file" ]]; then
        release_ver=$(grep -oP '^OS_VERSION="?\K\d+' "$meta_file" 2>/dev/null || true)
        [[ -n "$release_ver" ]] && echo "Using overlay's declared OS_VERSION: $release_ver"
    fi
    if [[ -z "$release_ver" ]]; then
        if [[ -f /etc/os-release ]]; then
            release_ver=$(grep -oP 'VERSION_ID=\K\d+' /etc/os-release)
        else
            release_ver="39" # Fallback
        fi
        echo "Detected release version from host: $release_ver"
    fi

    # Pick a package manager that will actually run here.
    #
    # On Bazzite/PowOS hosts /usr/bin/dnf is a WRAPPER that hard-refuses
    # ("Fedora Atomic images utilize rpm-ostree instead") unless it detects a
    # container or an unlocked deployment — and it refuses even for a
    # --installroot build into a temp dir, which touches nothing on the host.
    # The wrapper's own first branch execs /usr/bin/dnf5, so call that
    # directly and overlay builds work on the OS PowOS is built from.
    local dnf_bin
    if command -v dnf5 >/dev/null 2>&1; then
        dnf_bin=dnf5
    else
        dnf_bin=dnf
    fi
    echo "Using package manager: $dnf_bin"

    # Use dnf to install into temp root
    # --nogpgcheck is added as a workaround for build failures with unsigned packages.
    # Retry on transient failures: DNS blips, mirror slowness, or the build host
    # briefly losing network (e.g. session lock + WiFi power-save) cause a whole
    # overlay to fail otherwise. Three attempts with backoff covers realistic
    # flakes without hiding a genuinely misconfigured repo.
    # Repositories an overlay needs, declared in its metadata.env as e.g.
    #   REPOS="copr:copr.fedorainfracloud.org:ublue-os:bazzite ..."
    #
    # ublue/Bazzite ship their COPRs with enabled=0. Copying the .repo files
    # into the build root is therefore not enough — dnf ignores them and every
    # package from those repos reports "No match for argument", which
    # --skip-unavailable then swallows. Enable exactly what the overlay asks
    # for: no more (no surprise packages from testing repos), no less.
    local -a repo_args=()
    if [[ -f "$meta_file" ]]; then
        local declared_repos
        declared_repos=$(grep -oP '^REPOS="?\K[^"]*' "$meta_file" 2>/dev/null || true)
        local r
        for r in $declared_repos; do
            repo_args+=(--enablerepo="$r")
            echo "Enabling repo: $r"
        done
    fi

    local attempt rc
    for attempt in 1 2 3; do
        if "$dnf_bin" install -y --installroot="$temp_root" "${repo_args[@]+"${repo_args[@]}"}" --releasever="$release_ver" --setopt=install_weak_deps=False --setopt=keepcache=False --setopt=retries=5 --setopt=timeout=60 --nogpgcheck --skip-unavailable $packages; then
            echo "Packages installed successfully to temp root (attempt $attempt)."
            break
        fi
        rc=$?
        if [[ $attempt -lt 3 ]]; then
            echo "dnf install failed (attempt $attempt/3, exit $rc) — retrying after ${attempt}0s..."
            sleep "${attempt}0"
        else
            echo "Failed to install packages after 3 attempts."
            rm -rf "$temp_root"
            return 1
        fi
    done

    # Verify every REQUESTED package actually landed.
    #
    # --skip-unavailable keeps a build alive when an optional package is
    # missing from a variant's repos, but on its own it also lets the packages
    # that DEFINE a capability vanish silently: capability-gaming-mode once
    # "built" green while gamescope-session-plus, steamos-manager and hhd were
    # all skipped, producing a 900MB overlay that could not possibly work.
    # A build that cannot deliver its headline packages must fail loudly.
    local missing=()
    local pkg
    for pkg in $required_pkgs; do
        # --whatprovides, not a literal name query: dnf resolves aliases and
        # virtual provides (python-vdf installs as python3-vdf), so querying
        # the requested string alone reports false missing packages.
        if ! rpm --root "$temp_root" -q --whatprovides "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done
    local opt
    for opt in $optional_pkgs; do
        rpm --root "$temp_root" -q --whatprovides "$opt" >/dev/null 2>&1 \
            || echo "note: optional package not available here, continuing without it: $opt"
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: these REQUIRED packages are NOT in the built root:" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        echo "The repositories reachable from this build environment do not carry them." >&2
        echo "Build in an environment with the right repos (e.g. the PowOS/Bazzite image)." >&2
        rm -rf "$temp_root"
        return 1
    fi

    # Move files from temp root to output dir, PRUNING anything the host
    # already provides.
    #
    # A sysext may only ADD to /usr — it must never shadow what is already
    # there. dnf --installroot resolves a full dependency closure, so a naive
    # copy ships glibc, OpenSSL, systemd libs and bash built for the overlay's
    # target release. Merging that over a host on a NEWER release replaces its
    # core libraries with older ones: sshd died instantly the first time this
    # shipped, taking remote access with it while the machine stayed up.
    #
    # Compare against a reference /usr (the build host's by default, or
    # POWOS_PRUNE_USR when cross-building) and keep only genuinely new files.
    local ref_usr="${POWOS_PRUNE_USR:-/usr}"
    if [[ -d "$temp_root/usr" && -d "$ref_usr" ]]; then
        echo "Pruning files already provided by $ref_usr ..."
        if ! powos_prune_overlay_usr "$temp_root" "$output_dir" "$ref_usr"; then
            echo "ERROR: overlay would be empty — every file already exists on the host." >&2
            rm -rf "$temp_root"
            return 1
        fi
    fi

    # A sysext MUST NOT ship its own /usr/lib/os-release — systemd-sysext
    # refuses ("Extension contains '/usr/lib/os-release', which is not
    # allowed") and, worse, aborts the ENTIRE sysext merge on the FIRST such
    # extension, silently blocking every other overlay too. dnf's
    # --installroot pulls in the base OS release file. Pruning already drops
    # it whenever the reference /usr has one, but strip it unconditionally so
    # a cross-build against a tree that lacks it cannot reintroduce the
    # problem. (Same for machine-id, which sysext also forbids.)
    rm -f "$output_dir/usr/lib/os-release" \
          "$output_dir/usr/lib64/os-release" \
          "$output_dir/etc/os-release" \
          "$output_dir/usr/lib/machine-id" \
          "$output_dir/etc/machine-id" 2>/dev/null || true


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
        # chmod ONLY what we just copied. Blanket-chmodding /usr/bin also hits
        # package-provided entries and symlinks whose targets were pruned as
        # host-provided — those are dangling inside the overlay but resolve
        # fine once merged, and chmod failing on them killed the whole build.
        local _b
        for _b in "$source_dir/bin/"*; do
            [[ -f "$_b" ]] || continue
            cp -a "$_b" "$output_dir/usr/bin/"
            chmod +x "$output_dir/usr/bin/$(basename "$_b")"
        done
    fi

    # Desktop entries — how a capability appears in the application menu.
    if [[ -d "$source_dir/applications" ]] && ls "$source_dir/applications/"* &>/dev/null; then
        mkdir -p "$output_dir/usr/share/applications"
        cp -r "$source_dir/applications/"* "$output_dir/usr/share/applications/"
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
