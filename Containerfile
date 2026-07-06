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

# Copy PowOS boot system.
#
# Layer-cache strategy: one COPY per top-level source dir (lib/, bin/, config/,
# systemd/, sources/, bazzite/) instead of 30+ individual file COPYs. Each
# separate COPY layer commits an overlay diff (~seconds of overhead × 30 was
# adding minutes to every rebuild for zero cache benefit — a change to any lib
# file invalidated all the layers below anyway).
COPY lib/ /usr/lib/powos/
# dracut modules live under /usr/lib/dracut, not /usr/lib/powos — clean up the
# duplicate copy that the wildcard COPY above created.
RUN rm -rf /usr/lib/powos/dracut
# build-helpers.sh also expected at /var/lib/powos/lib/ (overlay-manager
# sources it from there when building extensions).
RUN mkdir -p /var/lib/powos/lib && cp /usr/lib/powos/build-helpers.sh /var/lib/powos/lib/
# bazzite/system_files/ was previously copied here only for the handheld
# device overlays (steamdeck / rog-ally / legion-go) to source from — those
# overlays have been dropped for the desktop image, so this ~100MB COPY (and
# its vendor-bazzite.sh clone) is no longer needed. Vendor script is still
# invoked by the ISO build (build/build-iso.sh) for the USB installer
# variant, not by the default desktop container build.
COPY sources/ /var/lib/powos/sources/
COPY bin/ /usr/bin/
COPY config/ /etc/powos/
COPY systemd/powos-* /usr/lib/powos/
# Exec bits can be stripped by Windows checkouts (see repo history) — the
# boot-chain units ExecStart these directly, so force them executable.
RUN chmod +x /usr/lib/powos/powos-init /usr/lib/powos/powos-hardware-detect \
    /usr/lib/powos/powos-overlay-load /usr/lib/powos/powos-hydrate

# lib/ramfs/, lib/cachefs/, lib/ai/ already came in via `COPY lib/ /usr/lib/powos/` above.
# config/ai/ already came in via `COPY config/ /etc/powos/` (as /etc/powos/ai/).

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
# bin/powos-welcome already came in via `COPY bin/ /usr/bin/` above.
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

# Install systemd services — one COPY covers everything under systemd/*.service
# (previously 12 individual COPYs, each a new layer for zero cache benefit —
# any .service change invalidates all subsequent layers regardless).
# Boot-time init chain, ramboot infrastructure, sync daemons, installer/recovery
# services, etc. Individual roles are documented in the .service files.
COPY systemd/*.service /usr/lib/systemd/system/
# Per-service drop-ins (e.g. plasmalogin WantedBy=graphical.target).
COPY systemd/plasmalogin.service.d/ /usr/lib/systemd/system/plasmalogin.service.d/
# bin/powos-safemode, powos-install-wizard, powos-firstboot-apply,
# powos-firstboot-disk already came in via `COPY bin/ /usr/bin/` above.
# Their .service units come in with the wildcard `COPY systemd/powos-*.service`
# below.
# A failed enable must fail the build — no 2>/dev/null || true.
# Unit files must be 0644: a build context from a Windows bind-mount reports
# every file as 0755, and systemd warns "Configuration file ... is marked
# executable" for each unit. Normalize so any build context yields clean units.
RUN chmod +x /usr/bin/powos-safemode /usr/bin/powos-install-wizard /usr/bin/powos-firstboot-apply /usr/bin/powos-firstboot-disk && \
    chmod 0644 /usr/lib/systemd/system/powos-*.service && \
    # All PowOS boot-time services enabled. Each is either:
    #   * always-needed (init, hardware, overlay, hwinfo)
    #   * karg-gated (installer=powos.install, safemode=powos.mode,
    #                 firstboot-disk=rd.powos.ramboot)
    #   * ConditionPathExists-gated on /run/powos/{ramboot-state,layer-paths}
    #     which the dracut ramboot module writes ONLY on a USB live boot
    #     (ramboot-init, layer-sync, cachefs-sync, ramboot-healthy)
    #   * ConditionPathExists-gated on /etc/powos/install.conf which the
    #     guided installer writes once (firstboot).
    # So enabling all of them on every image is safe: on an installed
    # bootc deploy without the ramboot karg, the USB-only ones self-skip
    # silently. On a USB live boot they all fire. One image supports both.
    systemctl enable \
        powos-init.service \
        powos-hardware.service \
        powos-overlay.service \
        powos-hwinfo.service \
        powos-ramboot-init.service \
        powos-ramboot-healthy.service \
        powos-layer-sync.service \
        powos-cachefs-sync.service \
        powos-installer.service \
        powos-safemode.service \
        powos-firstboot.service \
        powos-firstboot-disk.service && \
    # powos-hydrate.service is NOT enabled by default: it runs on every boot
    # even when nothing is configured, adds seconds to boot time, and has
    # historically been the source of "why did boot fail" incidents. It's
    # shipped but must be `systemctl enable`'d explicitly by users who set
    # POWOS_GIT_REPO and want git-based state hydration.
    systemctl enable plasmalogin.service && \
    systemctl add-wants graphical.target plasmalogin.service && \
    systemctl set-default graphical.target && \
    systemctl disable NetworkManager-wait-online.service

# The dracut ramboot module ships in the tree (lib/dracut/90powos-ramboot/) so
# a POWOS_INSTALLER=1 or explicit USB-live build can add it; the DEFAULT
# desktop-install image inherits Bazzite's ready-made initramfs and does NOT
# do this rebuild. Reasons:
#   * every rebuild is ~1–2 minutes of build time,
#   * the ramboot module only fires on `rd.powos.ramboot=1` which we do not
#     set as a default karg, so on installed systems the extra initramfs
#     content is pure dead weight,
#   * initramfs regeneration was one of the historical boot-hang triggers.
# Rebuild is gated behind POWOS_BUILD_RAMBOOT=1 (opt-in for the USB variant).
ARG POWOS_BUILD_RAMBOOT=0
RUN if [ "$POWOS_BUILD_RAMBOOT" = "1" ]; then \
        KVER="$(ls /lib/modules/ | head -1)" && \
        dracut --force --no-hostonly --reproducible --zstd \
            --add ostree --add fido2 --add powos-ramboot \
            --kver "$KVER" "/usr/lib/modules/$KVER/initramfs.img" && \
        chmod 0600 "/usr/lib/modules/$KVER/initramfs.img"; \
    else \
        echo "[powos] Skipping ramboot initramfs rebuild (install variant); base Bazzite initramfs stays."; \
    fi

# Install bootc kernel arguments (console ordering only).
# RAM boot is NOT baked into the default image: the ramboot dracut step hangs in
# initramfs on real hardware, so the default image — whether flashed to a USB or
# installed to disk — boots a normal disk root. RAM boot is an explicit OPT-IN
# (`powos ramboot enable`, which sets rd.powos.ramboot.installed=1). The dracut
# module ships in the initramfs (above) so the opt-in works; only the default
# karg is gone. (Was config/bootc/kargs.d/50-powos-ramboot.toml, removed in the
# scope-B streamline: install-to-disk is the primary story.)
RUN mkdir -p /usr/lib/bootc/kargs.d
COPY config/bootc/kargs.d/ /usr/lib/bootc/kargs.d/

# tmpfiles.d: force /etc/systemd/system/display-manager.service to alias
# plasmalogin every boot (overrides any sddm alias left over from prior installs).
COPY config/tmpfiles.d/powos-display-manager.conf /usr/lib/tmpfiles.d/

# KDE Plasma power defaults: NEVER auto-suspend (kills network + SSH + builds).
# Installed system-wide under /etc/xdg so it applies to every user, and mirrored
# into /etc/skel so a new user gets it on first login too (needed because
# ~/.config/powermanagementprofilesrc overrides /etc/xdg once created).
COPY config/kde/powermanagementprofilesrc /etc/xdg/powermanagementprofilesrc
RUN mkdir -p /etc/skel/.config /home/powos/.config && \
    cp /etc/xdg/powermanagementprofilesrc /etc/skel/.config/powermanagementprofilesrc && \
    cp /etc/xdg/powermanagementprofilesrc /home/powos/.config/powermanagementprofilesrc && \
    chown -R 1000:1000 /home/powos/.config

# ── Lean installer variant (behind a build flag; default image unaffected) ──
# Build with --build-arg POWOS_INSTALLER=1 to produce an installer image that:
#   * boots STRAIGHT into the guided wizard via powos.install=1 (see
#     config/bootc/installer/50-powos-installer.toml → powos-installer.service),
#     and
#   * does NOT run the live-USB first-boot self-completion (POWOS-DATA + boot
#     menu dance) — powos-firstboot-disk.service is masked.
# Neither variant bakes ramboot anymore, so the variants differ only in the
# wizard kargs + the firstboot-disk masking. The installer-only kargs live
# OUTSIDE kargs.d so the default image never picks them up; they are added here
# only when POWOS_INSTALLER=1.
COPY config/bootc/installer/ /tmp/powos-installer-kargs/
ARG POWOS_INSTALLER=0
RUN if [ "$POWOS_INSTALLER" = "1" ]; then \
        echo "[powos] Building INSTALLER variant: boot straight to the wizard"; \
        cp /tmp/powos-installer-kargs/50-powos-installer.toml /usr/lib/bootc/kargs.d/; \
        systemctl mask powos-firstboot-disk.service; \
    else \
        echo "[powos] Building default variant: normal disk boot (installable)"; \
    fi

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

# Bake the exact commit this snapshot came from. .dockerignore strips .git, so
# without this marker `powos self pull` has no TRUE base and would have to blindly
# reset to master (discarding local edits). Build passes it via
# --build-arg POWOS_SRC_COMMIT="$(git rev-parse HEAD)". "unknown" if not provided.
ARG POWOS_SRC_COMMIT=""
RUN printf '%s\n' "${POWOS_SRC_COMMIT:-unknown}" > /var/lib/powos/.powos-src-commit

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
# SELinux hygiene (BOTH variants)
# ═══════════════════════════════════════════════════════════════════
# The base Bazzite image has no SELinux handling for the custom files we COPY
# into /usr/{bin,lib}, /var/lib/powos, /etc/powos, etc. Those land with default/
# wrong SELinux contexts, so on a real (enforcing) boot they generate a FLOOD of
# denials — and the base image's setroubleshootd crash-loops trying to process
# them ("Start request repeated too quickly" + "audit: backlog limit exceeded").
#
# Two fixes, applied AFTER every COPY/RUN that adds PowOS files:
#   1) Mask setroubleshootd — a diagnostic daemon, not needed to run the system;
#      masking stops the crash-loop and the "processing SELinux denials" spam.
#   2) Relabel our files to the CORRECT contexts with restorecon, which reads
#      the policy's file_contexts shipped in the base image (effective at build
#      time). This removes the denials at the source, so the flood never starts.
#      Guarded (|| true) so a base without a usable policy (e.g. a plain docker
#      test build) cannot fail the image build; on a real bootc image the policy
#      is present and the relabel takes effect.
RUN systemctl mask setroubleshootd.service 2>/dev/null || true
RUN restorecon -RF /usr /etc /var 2>/dev/null || true

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
