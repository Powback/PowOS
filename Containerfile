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
COPY config/kde/kglobalshortcutsrc        /etc/xdg/kglobalshortcutsrc
COPY config/logid/logid.cfg               /etc/logid.cfg
COPY config/tmpfiles.d/                   /etc/tmpfiles.d/
COPY config/sysctl.d/                     /etc/sysctl.d/
COPY config/NetworkManager/conf.d/        /etc/NetworkManager/conf.d/
COPY config/etc/containers/systemd/users/  /etc/containers/systemd/users/
COPY config/etc/ssh/sshd_config.d/         /etc/ssh/sshd_config.d/
COPY config/etc/ssh/authorized_keys.d/     /etc/ssh/authorized_keys.d/
COPY config/etc/systemd/logind.conf.d/     /etc/systemd/logind.conf.d/
COPY config/etc/profile.d/                 /etc/profile.d/
# Mask all sleep-related systemd targets — no code path can suspend the box.
# Complements config/etc/systemd/logind.conf.d/50-powos-no-suspend.conf which
# blocks the trigger side (lid/keys/idle); this blocks the target side so a
# rogue systemctl suspend or systemd-inhibit --shell suspend has no effect.
RUN ln -sf /dev/null /etc/systemd/system/sleep.target && \
    ln -sf /dev/null /etc/systemd/system/suspend.target && \
    ln -sf /dev/null /etc/systemd/system/hibernate.target && \
    ln -sf /dev/null /etc/systemd/system/hybrid-sleep.target
# Login-availability fix (exception to zero-boot-services, deliberately):
# Plasma Login Manager's greeter can wedge into a broken-QML state after a
# session exit ("...not a function" TypeErrors, black frozen login screen —
# hit on real hardware 2026-07-09). greeter-watchdog detects that signature
# and bounces plasmalogin; it NEVER touches an active user session. The
# plasmalogin.service.d drop-ins also gain Restart=on-failure for the
# plain-crash case. A broken login screen is exactly the "bricked feeling"
# the zero-boot-services rule exists to prevent — hence the exception.
COPY systemd/greeter-watchdog.service     /usr/lib/systemd/system/greeter-watchdog.service
COPY systemd/greeter-watchdog.timer       /usr/lib/systemd/system/greeter-watchdog.timer
COPY systemd/plasmalogin.service.d/       /usr/lib/systemd/system/plasmalogin.service.d/

FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="PowOS"
LABEL org.opencontainers.image.description="Minimal PowOS layer on Bazzite (CLI + KDE widgets, zero boot-time services)"

# powos user (uid 1000, wheel), default password, sshd enabled.
# openssh-server is already in Bazzite base.
RUN useradd -m -G wheel -u 1000 powos 2>/dev/null || true && \
    echo "powos:powos" | chpasswd && \
    systemctl enable sshd.service && \
    mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/powos

# Desktop peripheral + dev-runtime stack.
#   openrgb  motherboard/RAM/case RGB via SMBus (i2c_dev/i2c_piix4 already
#            loaded in the kernel; udev rules already shipped by Bazzite)
#   piper    Logitech gaming mouse config GUI; pulls libratbag + ratbagd
#   logiops  Logitech G-key macros + advanced button mapping
#   uv       Astral's Python package/env manager. Backs `powos ai install
#            aider` and other Python tools. Modern replacement for
#            pip/venv/pipenv; single fast Rust binary.
# openrgb, piper, logiops, and uv are all in main Fedora 44 repos. bun is
# NOT in Fedora repos, so we download the official Linux glibc build from
# GitHub releases and drop it directly into /usr/bin. Can't use /usr/local
# because on Fedora Atomic/Silverblue (and thus Bazzite) /usr/local is a
# symlink into an unpopulated /var target — mkdir -p /usr/local/bin fails
# during container build. Using bun.sh/install would try to put it under
# $HOME/.bun which isn't the right layout for an OS-image build either.
# Native RPMs beat Flatpak/curl-installers here: Flatpak Piper pulls ~200MB
# of GNOME Platform, and vendor curl-installers bypass the OS package
# manager entirely which makes rollback via bootc noisier. Total install
# ~120MB and everything shares Bazzite's existing Qt/KF6 + glibc runtime.
# podman-compose + podman-docker make `podman compose up` AND `docker compose up`
# work out of the box on this Podman-native OS: podman-compose is the compose
# provider, podman-docker ships /usr/bin/docker→podman plus the `nodocker` file
# that silences the emulation notice. No Docker daemon, fully rootless.
RUN dnf5 -y install --setopt=install_weak_deps=False \
        openrgb piper logiops uv unzip podman-compose podman-docker && \
    curl -fsSL "https://github.com/oven-sh/bun/releases/latest/download/bun-linux-x64.zip" \
        -o /tmp/bun.zip && \
    unzip -q -j /tmp/bun.zip 'bun-linux-x64/bun' -d /usr/bin/ && \
    chmod +x /usr/bin/bun && \
    rm -f /tmp/bun.zip && \
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
RUN chmod +x /usr/bin/powos /usr/bin/pinstall /usr/bin/premove /usr/bin/powos-boot /usr/bin/powos-widget-autoadd /usr/bin/greeter-watchdog 2>/dev/null || true && \
    find /usr/lib/powos -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} + 2>/dev/null || true && \
    systemctl enable greeter-watchdog.timer && \
    systemctl mask setroubleshootd.service 2>/dev/null || true && \
    systemctl mask plasma-setup.service 2>/dev/null || true && \
    printf '%s\n' "${POWOS_SRC_COMMIT:-unknown}" > /usr/lib/powos/.powos-src-commit && \
    restorecon -RF /usr /etc 2>/dev/null || true
