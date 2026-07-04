# PowOS - Based on Bazzite
#
# Base image is a build ARG so you can target your GPU. The default is the
# NVIDIA proprietary-driver desktop variant. Override with:
#   podman build --build-arg BASE_IMAGE=<image> ...
# or set POWOS_BASE_IMAGE before ./build/build-iso.sh.
#
# Common choices:
#   ghcr.io/ublue-os/bazzite-nvidia-open:stable  NVIDIA open modules (DEFAULT; Turing/GTX-16+ & RTX)
#   ghcr.io/ublue-os/bazzite-nvidia:stable       NVIDIA proprietary/closed (older cards: Maxwell/Pascal)
#   ghcr.io/ublue-os/bazzite:stable              AMD / Intel GPUs
# NOTE: the GPU driver stack is fixed by this image; hardware profiles tune
# settings but cannot swap nvidia<->amd at boot. Pick the image for your GPU.
# Open is default (better for RTX / GTX-16 and required for 50-series). Older
# NVIDIA (GTX 900/1000 = Maxwell/Pascal) needs the closed variant.
ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite-nvidia-open:stable
FROM ${BASE_IMAGE}

ENV POWOS_ROOT=/var/lib/powos
ENV TERM=xterm

LABEL org.opencontainers.image.title="PowOS"

# PowOS directories
RUN mkdir -p /var/lib/powos/{extensions,overlays,state} \
    /var/lib/extensions /etc/powos /usr/lib/powos /run/powos

# Fix Terra repos - disable GPG check (osbuild can't verify signatures)
# Keep repos for updates, packages still come from trusted Bazzite upstream
RUN sed -i 's/gpgcheck=1/gpgcheck=0/g' /etc/yum.repos.d/terra*.repo 2>/dev/null || true && \
    sed -i 's/repo_gpgcheck=1/repo_gpgcheck=0/g' /etc/yum.repos.d/terra*.repo 2>/dev/null || true

# Ensure dnf is configured for build
RUN dnf makecache || true

# Install dependencies
# Note: Bazzite doesn't have /usr/local by default, create it first
RUN dnf install -y python3 python3-pip rsync fuse fuse-libs && \
    rm -f /usr/local 2>/dev/null || true && \
    mkdir -p /usr/local/lib /usr/local/bin && \
    pip3 install --break-system-packages psutil rich fusepy && \
    dnf clean all

# ═══════════════════════════════════════════════════════════════════
# Container Runtime: Podman + Distrobox
# ═══════════════════════════════════════════════════════════════════
# Podman is daemonless, rootless-capable, and native to Fedora
# Distrobox creates mutable dev containers on top of immutable base
RUN dnf install -y \
        podman \
        podman-docker \
        buildah \
        skopeo \
        containernetworking-plugins \
        slirp4netns \
        fuse-overlayfs \
        crun \
    && dnf clean all

# Install Distrobox (latest from git for best features)
RUN curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix /usr/local

# Configure Podman for rootless operation
RUN mkdir -p /etc/containers && \
    echo 'unqualified-search-registries = ["docker.io", "ghcr.io", "quay.io"]' > /etc/containers/registries.conf.d/00-powos.conf

# Create storage config for rootless Podman
RUN mkdir -p /etc/containers/storage.conf.d && \
    printf '[storage]\ndriver = "overlay"\n\n[storage.options.overlay]\nmount_program = "/usr/bin/fuse-overlayfs"\n' > /etc/containers/storage.conf.d/00-powos.conf

# Enable lingering for powos user (allows user services to run at boot)
RUN mkdir -p /var/lib/systemd/linger && \
    touch /var/lib/systemd/linger/powos

# Create the powos user IMAGE-SIDE and enable sshd.
# Previously the user was created only by the Docker entrypoint (powos-boot),
# which never runs on a real/QEMU boot of the bootc image — so the live image
# had no login user and no SSH daemon at all. Credentials match the documented
# live login in CLAUDE.md (powos/powos) and are required by the e2e QEMU tier
# (test/e2e/test-qemu-boot.sh logs in over SSH as powos/powos and uses
# `sudo -S` with that password — the user is in wheel, no NOPASSWD rule).
# openssh-server ships with the Bazzite base; the rpm guard is just defensive.
RUN rpm -q openssh-server >/dev/null 2>&1 || { dnf install -y openssh-server && dnf clean all; } && \
    { id powos >/dev/null 2>&1 || useradd -m -G wheel -u 1000 powos; } && \
    echo "powos:powos" | chpasswd && \
    systemctl enable sshd.service

# Copy PowOS boot system
COPY lib/common.sh /usr/lib/powos/
COPY lib/boot/ /usr/lib/powos/boot/
COPY lib/hardware-detect.sh /usr/lib/powos/
COPY lib/overlay-manager.sh /usr/lib/powos/
COPY lib/dev-commands.sh /usr/lib/powos/
COPY lib/mobile.sh /usr/lib/powos/
COPY lib/sync.sh /usr/lib/powos/
COPY lib/backup.sh /usr/lib/powos/
COPY lib/install-system.sh /usr/lib/powos/
COPY lib/vm.sh /usr/lib/powos/
COPY lib/base.sh /usr/lib/powos/
COPY lib/boot-manager.sh /usr/lib/powos/
COPY lib/games.sh /usr/lib/powos/
COPY lib/ramboot.sh /usr/lib/powos/
COPY lib/doctor.sh /usr/lib/powos/
COPY lib/windows.sh /usr/lib/powos/
COPY lib/cuda.sh /usr/lib/powos/
COPY lib/driver.sh /usr/lib/powos/
COPY lib/registry.sh /usr/lib/powos/
COPY lib/gpu.sh /usr/lib/powos/
COPY lib/build-image.sh /usr/lib/powos/
COPY lib/upgrade.sh /usr/lib/powos/
COPY lib/reload.sh /usr/lib/powos/
COPY lib/overview.sh /usr/lib/powos/
COPY lib/services.sh /usr/lib/powos/
COPY lib/install-router.sh /usr/lib/powos/
COPY lib/uninstall.sh /usr/lib/powos/
COPY lib/config.sh /usr/lib/powos/
COPY lib/build-helpers.sh /var/lib/powos/lib/
COPY bazzite/system_files/ /tmp/bazzite/system_files/
COPY sources/ /var/lib/powos/sources/
COPY bin/powos-boot /usr/bin/
COPY bin/powos /usr/bin/
COPY bin/pinstall /usr/bin/
COPY bin/premove /usr/bin/
COPY config/ /etc/powos/
COPY systemd/powos-* /usr/lib/powos/
# Exec bits can be stripped by Windows checkouts (see repo history) — the
# boot-chain units ExecStart these directly, so force them executable.
RUN chmod +x /usr/lib/powos/powos-init /usr/lib/powos/powos-hardware-detect \
    /usr/lib/powos/powos-overlay-load /usr/lib/powos/powos-hydrate

# Copy RAM overlay system (for OS)
COPY lib/ramfs/ /usr/lib/powos/ramfs/

# Copy CacheFS (lazy-loading filesystem for user data)
COPY lib/cachefs/ /usr/lib/powos/cachefs/

# Copy AI Agent System
COPY lib/ai/ /usr/lib/powos/ai/
COPY config/ai/ /etc/powos/ai/

# Desktop widgets (KDE Plasma 6 plasmoids) — e.g. PowOS Overview panel,
# which renders `powos overview --json` + `powos services --json` on the desktop.
COPY desktop/plasmoid/ /usr/share/plasma/plasmoids/

# ═══════════════════════════════════════════════════════════════════
# PowOS Welcome (first-run onboarding) + "Install PowOS" desktop entry
# ═══════════════════════════════════════════════════════════════════
# powos-welcome: kdialog menu (terminal fallback) for first steps — default-
# password warning, install-to-disk (live boots) / update check (installed),
# games partition, Steam wiring, Windows setup, cloud backup. The autostart
# entry self-disables via the per-user ~/.config/powos/welcome-done marker.
COPY bin/powos-welcome /usr/bin/
COPY desktop/welcome/powos-welcome.desktop /usr/share/applications/
COPY desktop/welcome/powos-install.desktop /usr/share/applications/
COPY desktop/welcome/powos-welcome-autostart.desktop /etc/xdg/autostart/powos-welcome.desktop
# Put the "Install PowOS" icon on the live desktop: the powos user already
# exists image-side (created above), so /etc/skel alone wouldn't reach it.
# chmod +x on .desktop files = freedesktop launcher-trust hint.
RUN chmod +x /usr/bin/powos-welcome && \
    mkdir -p /etc/skel/Desktop /home/powos/Desktop && \
    cp /usr/share/applications/powos-install.desktop /etc/skel/Desktop/ && \
    cp /usr/share/applications/powos-install.desktop /home/powos/Desktop/ && \
    chmod +x /etc/skel/Desktop/powos-install.desktop /home/powos/Desktop/powos-install.desktop && \
    chown -R 1000:1000 /home/powos/Desktop

# Install dracut module for full RAM boot
# This allows the entire OS to run from RAM, USB can be unplugged
COPY lib/dracut/90powos-ramboot/ /usr/lib/dracut/modules.d/90powos-ramboot/
RUN chmod +x /usr/lib/dracut/modules.d/90powos-ramboot/*.sh

# Install systemd services
COPY systemd/powos-ramboot-init.service /usr/lib/systemd/system/
COPY systemd/powos-layer-sync.service /usr/lib/systemd/system/
COPY systemd/powos-cachefs-sync.service /usr/lib/systemd/system/
COPY systemd/powos-installer.service /usr/lib/systemd/system/
COPY systemd/powos-hwinfo.service /usr/lib/systemd/system/
# Boot-time init chain: powos-init writes /run/powos/environment, hardware
# detection (Chameleon Boot) picks the profile, overlay loads sysexts,
# hydrate runs once. These were previously copied only as loose files under
# /usr/lib/powos and never enabled — so no hardware detection or sysext
# loading ever ran on a real image.
COPY systemd/powos-init.service /usr/lib/systemd/system/
COPY systemd/powos-hardware.service /usr/lib/systemd/system/
COPY systemd/powos-overlay.service /usr/lib/systemd/system/
COPY systemd/powos-hydrate.service /usr/lib/systemd/system/
# Clears the RAM-boot self-heal counter once a boot succeeds (see
# lib/dracut/90powos-ramboot/ramboot-setup.sh).
COPY systemd/powos-ramboot-healthy.service /usr/lib/systemd/system/
# Recovery: Safe mode / AI Debug console (fires on the powos.mode= karg from the
# Recovery boot-menu entries). powos-safemode runs the recovery menu / AI doctor.
COPY bin/powos-safemode /usr/bin/
COPY systemd/powos-safemode.service /usr/lib/systemd/system/
# A failed enable must fail the build — no 2>/dev/null || true.
RUN chmod +x /usr/bin/powos-safemode && \
    systemctl enable powos-ramboot-init.service powos-layer-sync.service \
        powos-cachefs-sync.service powos-installer.service \
        powos-hwinfo.service powos-ramboot-healthy.service \
        powos-safemode.service \
        powos-init.service powos-hardware.service powos-overlay.service \
        powos-hydrate.service

# Rebuild initramfs with our dracut module
# This embeds the RAM overlay setup into the boot process.
# bootc boots /usr/lib/modules/<kver>/initramfs.img (NOT /boot), so write
# there explicitly (same pattern as containers/build_files/build-initramfs).
# A failed rebuild must fail the image build — a silently stale initramfs
# means ramboot never activates on real hardware.
RUN KVER="$(ls /lib/modules/ | head -1)" && \
    dracut --force --no-hostonly --reproducible --zstd \
        --add ostree --add fido2 --add powos-ramboot \
        --kver "$KVER" "/usr/lib/modules/$KVER/initramfs.img" && \
    chmod 0600 "/usr/lib/modules/$KVER/initramfs.img"

# Install bootc kernel arguments for RAM boot
# These tell the kernel to enable our RAM overlay at boot
RUN mkdir -p /usr/lib/bootc/kargs.d
COPY config/bootc/kargs.d/ /usr/lib/bootc/kargs.d/

# ── Always-visible boot menu (safety net) ─────────────────────────
# A boot-path change that bricks boot must be recoverable in seconds: show the
# GRUB menu for 5s on every boot so you can always pick the PREVIOUS deployment
# (bootc keeps it) or edit kargs. Menu-visibility only — does NOT change what
# boots by default. Sets both the /etc/default/grub knobs and the grubenv var
# uBlue/Bazzite uses to auto-hide the menu.
# NOTE: like every boot change, validate in QEMU before trusting it.
# /etc/default/grub is sourced as shell (last assignment wins), so appending
# overrides any earlier values without editing in place.
RUN { echo 'GRUB_TIMEOUT=5'; echo 'GRUB_TIMEOUT_STYLE=menu'; } >> /etc/default/grub 2>/dev/null || true; \
    if command -v grub2-editenv >/dev/null 2>&1 && [ -f /boot/grub2/grubenv ]; then \
        grub2-editenv /boot/grub2/grubenv set menu_auto_hide=0 || true; \
    fi

# Build extensions
RUN bash /usr/lib/powos/overlay-manager.sh build-all

# ═══════════════════════════════════════════════════════════════════
# Bundle PowOS Source (for self-update capability)
# ═══════════════════════════════════════════════════════════════════
# The complete source is bundled at /var/lib/powos/src
# This allows: powos update self (apply edits to running system)
# Edit source, run update self, changes apply immediately
COPY . /var/lib/powos/src/
# Ensure .git is preserved for version tracking and git pull capability
# Note: .git may be excluded by .dockerignore - that's ok for dev builds

# Setup directories
# Note: Bazzite has /mnt as a symlink, remove and recreate
RUN rm -f /mnt 2>/dev/null || true && \
    mkdir -p /mnt/powos-usb /run/powos/overlay

# Set permissions
RUN chmod +x /usr/bin/powos-boot /usr/bin/powos /usr/bin/pinstall /usr/bin/premove \
    /usr/lib/powos/*.sh /usr/lib/powos/boot/*.sh \
    /usr/lib/powos/ramfs/*.sh /usr/lib/powos/ramfs/*.py \
    /usr/lib/powos/cachefs/*.py \
    /usr/lib/powos/ai/*.sh /usr/lib/powos/ai/clients/*.sh 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════
# E2E Test Dependencies (optional — only installed when building
# the e2e-runner profile: --build-arg INSTALL_E2E_DEPS=1)
# Adds: btrfs-progs (mkfs.btrfs for loop-device USB simulation)
# util-linux provides losetup, already present in bazzite base
# ═══════════════════════════════════════════════════════════════════
ARG INSTALL_E2E_DEPS=0
RUN if [ "$INSTALL_E2E_DEPS" = "1" ]; then \
        dnf install -y btrfs-progs util-linux parted && \
        dnf clean all; \
    fi

EXPOSE 5901 6080
ENTRYPOINT ["/usr/bin/powos-boot"]
