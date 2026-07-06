# PowOS - a minimal customization layer on Bazzite.
#
# This is DELIBERATELY the smallest possible layer on top of Bazzite:
#   1. Create a `powos` user (password `powos`, wheel group)
#   2. Enable sshd
#   3. Ship the `powos` CLI + helper libraries in /usr/lib/powos
#   4. Ship the two KDE Plasma widgets
#   5. Ship a system-wide KDE no-auto-suspend default
#
# That is EVERYTHING. No PowOS service is enabled. No sysext is pre-built.
# No kargs.d is modified. No tmpfiles.d is added. No initramfs is rebuilt.
# No podman/distrobox reinstall (Bazzite already has them).
#
# The rationale: every previous "bootc upgrade bricked my machine" incident
# came from PowOS layers doing things at boot that surprised Bazzite. This
# image adds a userspace CLI and widgets — nothing more. `bootc upgrade`
# from stock Bazzite to this image changes zero boot behavior; rollback
# works exactly as bootc promises.
#
# Advanced PowOS features (sysext overlays, hardware profile chameleon,
# ramboot, layer sync) still ship as sources/service files under
# /var/lib/powos and /usr/lib/systemd/system — dormant until the user
# explicitly `systemctl enable`s them.
#
# Base image is a build ARG so you can target your GPU:
#   ghcr.io/ublue-os/bazzite-nvidia-open:stable  NVIDIA open (RTX 40/50-series)
#   ghcr.io/ublue-os/bazzite-nvidia:stable       NVIDIA closed (Maxwell/Pascal)
#   ghcr.io/ublue-os/bazzite:stable              AMD / Intel
ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite-nvidia-open:stable
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="PowOS"
LABEL org.opencontainers.image.description="Minimal PowOS layer on Bazzite (CLI + KDE widgets, zero boot-time services)"

# powos user (uid 1000, wheel), default password, sshd enabled.
# openssh-server is already in Bazzite base.
RUN useradd -m -G wheel -u 1000 powos 2>/dev/null || true && \
    echo "powos:powos" | chpasswd && \
    systemctl enable sshd.service

# PowOS CLI + helper libraries. Users run `powos ...` — nothing autoloads.
COPY bin/  /usr/bin/
COPY lib/  /usr/lib/powos/

# KDE Plasma widgets (users add them to their panel via KDE settings if wanted).
COPY desktop/plasmoid/ /usr/share/plasma/plasmoids/

# KDE Plasma default: no auto-suspend on idle. Screen lock still works.
# System-wide default; users' explicit overrides in ~/.config still win.
COPY config/kde/powermanagementprofilesrc /etc/xdg/powermanagementprofilesrc

# Exec bits + SELinux relabel + silence setroubleshootd (which crash-loops
# processing the initial denials from our /usr additions on first boot).
RUN chmod +x /usr/bin/powos /usr/bin/pinstall /usr/bin/premove /usr/bin/powos-boot 2>/dev/null || true && \
    find /usr/lib/powos -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} + 2>/dev/null || true && \
    systemctl mask setroubleshootd.service 2>/dev/null || true && \
    restorecon -RF /usr /etc 2>/dev/null || true

# Record the commit this image was built from (used by `powos self pull` to know
# the true base when comparing local edits against upstream). Injected by CI:
#   podman build --build-arg POWOS_SRC_COMMIT="$(git rev-parse HEAD)" ...
ARG POWOS_SRC_COMMIT=""
RUN mkdir -p /var/lib/powos && \
    printf '%s\n' "${POWOS_SRC_COMMIT:-unknown}" > /var/lib/powos/.powos-src-commit
