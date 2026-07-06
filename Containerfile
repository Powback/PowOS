# PowOS - a minimal customization layer on Bazzite.
#
# This is DELIBERATELY the smallest possible layer on top of Bazzite:
#   1. Create a `powos` user (password `powos`, wheel group)
#   2. Enable sshd
#   3. Ship the `powos` CLI + helper libraries in /usr/lib/powos
#   4. Ship a source-tree snapshot at /usr/lib/powos/src (immutable reference)
#      + a tmpfiles.d rule that seeds a writable copy at /var/lib/powos/src on
#      first boot — that's what `powos self test/pull/push` operates on.
#   5. Ship the two KDE Plasma widgets + an XDG autostart script that adds
#      them to the Plasma panel exactly ONCE per user on first login.
#   6. Ship a system-wide KDE no-auto-suspend default.
#   7. Install a desktop peripheral stack: OpenRGB (motherboard/RAM/case),
#      Piper (Logitech gaming mouse) with ratbagd, and LogiOps for Logitech
#      G-key macros. Daemons enabled at boot; user launches OpenRGB/Piper
#      GUIs from the app menu.
#
# All new services here are userspace-plus-config: ratbagd is DBus-activated
# so enabling is a no-op until an app calls it; logid has a safe empty
# device list so the daemon starts and idles. No initramfs is rebuilt.
# No sysext is pre-built. No kargs.d is modified. No podman/distrobox
# reinstall (Bazzite already has them). The only tmpfiles.d entry we add
# just seeds /var from /usr — cannot break the boot path.
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

# Staging stage — assemble every file drop into one scratch tree so the final
# image gets a single COPY layer instead of one per source directory. Nothing
# from this stage ships; it exists purely to consolidate layers.
#
# .snapshot/ is a `git archive HEAD` extraction produced by CI right before
# `podman build`. Bundling it under /usr/lib/powos/src lets `powos self`
# operate on the running box: tmpfiles.d seeds a writable copy at
# /var/lib/powos/src on first boot, then the user edits there directly.
FROM scratch AS staging
COPY bin/                                 /usr/bin/
COPY lib/                                 /usr/lib/powos/
COPY .snapshot/                           /usr/lib/powos/src/
COPY desktop/plasmoid/                    /usr/share/plasma/plasmoids/
COPY desktop/autostart/                   /etc/xdg/autostart/
COPY config/kde/powermanagementprofilesrc /etc/xdg/powermanagementprofilesrc
COPY config/logid/logid.cfg               /etc/logid.cfg
COPY config/tmpfiles.d/                   /etc/tmpfiles.d/

FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="PowOS"
LABEL org.opencontainers.image.description="Minimal PowOS layer on Bazzite (CLI + KDE widgets, zero boot-time services)"

# powos user (uid 1000, wheel), default password, sshd enabled.
# openssh-server is already in Bazzite base.
RUN useradd -m -G wheel -u 1000 powos 2>/dev/null || true && \
    echo "powos:powos" | chpasswd && \
    systemctl enable sshd.service

# Desktop peripheral stack (OpenRGB, Piper, LogiOps).
#   openrgb  motherboard/RAM/case RGB via SMBus (i2c_dev/i2c_piix4 already
#            loaded in the kernel; udev rules already shipped by Bazzite)
#   piper    Logitech gaming mouse config GUI; pulls libratbag + ratbagd
#   logiops  Logitech G-key macros + advanced button mapping (COPR — not
#            in main Fedora because upstream release cadence is slow); the
#            kylegospo copr is the community-maintained build the ublue
#            ecosystem uses.
# Native RPMs beat Flatpak here — Flatpak Piper alone pulls ~200MB of the
# GNOME Platform runtime; RPMs total ~15-20MB and share Bazzite's Qt/KF6
# runtime that Plasma already uses.
# Add the kylegospo COPR .repo file directly rather than `dnf5 copr enable`
# (which requires dnf5-plugins-core preinstalled — not guaranteed in every
# Bazzite base variant). The .repo endpoint is the OFFICIAL COPR-served URL,
# so this stays in lockstep with whatever kylegospo publishes. rpm -E %fedora
# resolves 44 on Bazzite 44 base, forward-compatible when the base advances.
RUN curl -fsSL "https://copr.fedorainfracloud.org/coprs/kylegospo/logiops/repo/fedora-$(rpm -E %fedora)/kylegospo-logiops-fedora-$(rpm -E %fedora).repo" \
        -o /etc/yum.repos.d/_copr_kylegospo-logiops.repo && \
    dnf5 -y install --setopt=install_weak_deps=False \
        openrgb piper logiops && \
    dnf5 -y clean all && \
    systemctl enable ratbagd.service logid.service

# One layer for every file we ship (CLI + libs + plasmoids + KDE default).
COPY --from=staging / /

# Exec bits + SELinux relabel + silence setroubleshootd (crash-loops processing
# initial denials from our /usr additions on first boot) + src-commit marker,
# all in a single layer so post-copy fixups don't multiply layers either.
# POWOS_SRC_COMMIT is used by `powos self pull` to know the true base when
# comparing local edits against upstream. Injected by CI:
#   podman build --build-arg POWOS_SRC_COMMIT="$(git rev-parse HEAD)" ...
# Marker lives under /usr/lib/powos/ (part of the read-only OS image) so it
# ALWAYS reflects the currently-booted image. Writing it to /var was a bug:
# bootc only seeds /var on the FIRST deployment of a stateroot, so a
# `bootc switch` or `bootc upgrade` from a machine with an existing /var
# would silently keep the old (or missing) marker.
ARG POWOS_SRC_COMMIT=""
RUN chmod +x /usr/bin/powos /usr/bin/pinstall /usr/bin/premove /usr/bin/powos-boot /usr/bin/powos-widget-autoadd 2>/dev/null || true && \
    find /usr/lib/powos -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} + 2>/dev/null || true && \
    systemctl mask setroubleshootd.service 2>/dev/null || true && \
    printf '%s\n' "${POWOS_SRC_COMMIT:-unknown}" > /usr/lib/powos/.powos-src-commit && \
    restorecon -RF /usr /etc 2>/dev/null || true
