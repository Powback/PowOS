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
# Source of the compiled KDE artifacts. MUST be global (declared before the
# first FROM) — an ARG used in a FROM is only visible if it is global scope.
# Default builds them in-tree; CI overrides with a content-addressed image.
ARG KDE_BUILDER=kde-builder-local

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
COPY config/kde/kwinrc                    /etc/xdg/kwinrc
# Dark by default. See the file — this is a default, not an override.
COPY config/kde/kdeglobals                /etc/xdg/kdeglobals
COPY config/kde/konsolerc                 /etc/xdg/konsolerc
COPY config/kde/konsole/                  /usr/share/konsole/
# Rebrand the login MOTD from Bazzite → PowOS. /usr/libexec/ublue-motd renders
# this exact path (with %IMAGE_NAME%/%GREENBOOT% substitutions through glow), so
# overwriting it swaps the banner while keeping the renderer + themes intact.
COPY config/ublue-os/motd/powos.md        /usr/share/ublue-os/motd/bazzite.md
# AI agent/client/context configs. `lib/ai/agent.sh` resolves agents from
# AI_CONFIG_DIR=/etc/powos/ai on an installed system, so an agent that isn't
# copied here does not exist at runtime — `powos ai manager` fell back to
# "Warning: Agent 'manager' not found, using defaults". The pre-strip
# Containerfile shipped this as part of a blanket `COPY config/ /etc/powos/`;
# the curated list that replaced it dropped config/ai entirely, and the older
# agents only kept working because they survived in the ostree /etc merge from
# a pre-strip deployment.
COPY config/ai/                           /etc/powos/ai/
COPY config/zones/                        /etc/powos/zones/
COPY config/logid/logid.cfg               /etc/logid.cfg
COPY config/tmpfiles.d/                   /etc/tmpfiles.d/
# Seeded into new users' homes: the power button must sleep the device when
# the Plasma session is the one running. See the file.
COPY config/skel/                         /etc/skel/
# Staged, not installed: this must only take effect for the deck variant.
COPY config/dracut.conf.d/95-powos-deck-slim.conf /usr/share/powos/dracut-deck-slim.conf
# Keep sshd enabled against Bazzite's preset, which disables it. See the file.
COPY config/systemd-preset/              /usr/lib/systemd/system-preset/
COPY config/sysctl.d/                     /etc/sysctl.d/
COPY config/NetworkManager/conf.d/        /etc/NetworkManager/conf.d/
COPY config/etc/containers/systemd/users/  /etc/containers/systemd/users/
COPY config/etc/ssh/sshd_config.d/         /etc/ssh/sshd_config.d/
COPY config/etc/ssh/authorized_keys.d/     /etc/ssh/authorized_keys.d/
COPY config/etc/systemd/logind.conf.d/     /etc/systemd/logind.conf.d/
COPY config/etc/containers/oci/hooks.d/     /etc/containers/oci/hooks.d/
COPY config/etc/containers/containers.conf.d/ /etc/containers/containers.conf.d/
COPY config/etc/profile.d/                  /etc/profile.d/
COPY config/tmux/tmux.conf                  /etc/tmux.conf
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
# Same treatment for sddm, the display manager the deck variant uses (it has no
# plasma-login-manager). See the drop-in for why the alias alone is not enough.
COPY systemd/sddm.service.d/              /usr/lib/systemd/system/sddm.service.d/
# Bound the plymouth handoff. Without these the boot can stop dead at
# "Starting plymouth-quit-wait.service" and never reach a display manager —
# reproduced in QEMU off our own image and on a Steam Deck. See the drop-ins.
COPY systemd/plymouth-quit.service.d/     /usr/lib/systemd/system/plymouth-quit.service.d/
COPY systemd/plymouth-quit-wait.service.d/ /usr/lib/systemd/system/plymouth-quit-wait.service.d/
# Drop cardwired's Wants= on the deprecated udev-settle, which was stalling
# sysinit.target — and therefore the desktop — for ~4.6s. See the drop-in.
COPY systemd/cardwired.service.d/         /usr/lib/systemd/system/cardwired.service.d/
# Bound the network wait rather than removing greenboot's dependency on it —
# removing it turns "slow when offline" into a reboot loop. See the drop-in.
COPY systemd/NetworkManager-wait-online.service.d/ /usr/lib/systemd/system/NetworkManager-wait-online.service.d/
# Replace greenboot's network-online drop-in so the desktop is not gated on
# DHCP — 5.0s on the critical path, measured. See the drop-in for why this is
# safe and why the earlier revert was based on a misdiagnosis.
COPY systemd/greenboot-healthcheck.service.d/ /usr/lib/systemd/system/greenboot-healthcheck.service.d/
# Bootloader updates are not something to wait at a blank screen for.
COPY systemd/bootloader-update.service.d/ /usr/lib/systemd/system/bootloader-update.service.d/

# First-boot appliers. bin/powos-firstboot-apply already shipped (COPY bin/
# above), but its UNIT never did — so on every installed system the applier sat
# in /usr/bin and nothing ever invoked it, and the guided installer's hostname,
# user, password, SSH key, RAM-boot, AI and restore choices were silently
# dropped. Both units are self-disabling via ConditionPathExists, so this does
# not violate the zero-boot-services rule: with no install.conf and no pending
# variant they are skipped outright.
COPY systemd/powos-firstboot.service      /usr/lib/systemd/system/powos-firstboot.service
COPY systemd/powos-variant-retry.service  /usr/lib/systemd/system/powos-variant-retry.service
# The boot-menu entries install-to-usb.sh writes are useless without these two.
# "Install PowOS to disk" appends powos.install=1 and boots multi-user.target;
# with powos-installer.service absent NOTHING starts the wizard, so choosing it
# gave a black screen. Likewise the Safe mode / AI Debug entries append
# powos.mode= and did nothing. Both are ConditionKernelCommandLine-gated, so
# they stay inert on a normal boot.
COPY systemd/powos-installer.service      /usr/lib/systemd/system/powos-installer.service
COPY systemd/powos-safemode.service       /usr/lib/systemd/system/powos-safemode.service
COPY systemd/powos-boot-entries.service   /usr/lib/systemd/system/powos-boot-entries.service
COPY systemd/powos-firstboot-notice.service /usr/lib/systemd/system/powos-firstboot-notice.service
COPY systemd/powos-initramfs-slim.service /usr/lib/systemd/system/powos-initramfs-slim.service

# KDE-builder stage — bakes sources/kde/patches/<app>/ into the image.
# Built FROM THE SAME base image so the rebuilt bits match the shipped app's
# exact version and ABI (the script clones the tag matching the installed
# rpm). Only patch dirs + config are copied in (upstream/ is a gitignored
# multi-GB clone cache — never part of the build context). A patch that no
# longer applies/builds fails the image build loudly. Discarded after COPY.
FROM ${BASE_IMAGE} AS kde-builder-local
COPY sources/kde/dev.conf sources/kde/image-build.sh /tmp/kde/
COPY sources/kde/patches/ /tmp/kde/patches/
RUN chmod +x /tmp/kde/image-build.sh && /tmp/kde/image-build.sh /tmp/kde /kde-out

# Where the KDE artifacts come from. Defaults to building them right here, so a
# plain `podman build .` still works with no arguments.
#
# CI overrides it with a prebuilt, content-addressed image:
#   --build-arg KDE_BUILDER=ghcr.io/<owner>/powos-kde:<hash-of-sources/kde>
# and buildah then SKIPS the kde-builder-local stage entirely, because nothing
# references it. Compiling plasma-desktop takes ~30 min and its inputs change
# maybe monthly, so rebuilding it on every commit was the dominant CI cost.
#
# Deliberately NOT solved with --cache-to: that has never once worked here
# (podman/buildah#5148, the COPY --from=staging race) and, worse, it fails
# SILENTLY into a cold build. A missing builder image is a hard error you can
# see; a missing cache entry is a 40-minute mystery.
FROM ${KDE_BUILDER} AS kde-builder

FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="PowOS"
LABEL org.opencontainers.image.description="Minimal PowOS layer on Bazzite (CLI + KDE widgets, zero boot-time services)"

# powos user (uid 1000, wheel), default password, sshd enabled.
# openssh-server is already in Bazzite base.
RUN useradd -m -d /home/powos -G wheel -u 1000 powos 2>/dev/null || true && \
    echo "powos:powos" | chpasswd && \
    systemctl enable sshd.service && \
    mkdir -p /usr/lib/systemd/system/multi-user.target.wants && \
    ln -sf ../sshd.service /usr/lib/systemd/system/multi-user.target.wants/sshd.service && \
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
#
# PowStream runtime dep. NOTE: PowStream ITSELF is deliberately NOT in this
# image — it's a private repo, so it ships as a sysext overlay
# (sources/powstream/) built on the target with `powos overlay build
# powstream`. What's baked here is only its one missing GStreamer plugin, so
# that building the overlay later doesn't ALSO require layering an RPM onto an
# atomic OS. `powos stream` tells you if the overlay isn't installed yet.
#
# Bazzite already ships gstreamer1, -plugins-base, -plugins-good,
# -plugins-bad-free (webrtcbin/dtls/srtp), -plugin-pipewire (pipewiresrc),
# and nvcodec (nvh264enc) via the NVIDIA image. The ONE package it omits is
# libnice-gstreamer1 — the GStreamer plugin for ICE (nicesink/nicesrc), which
# webrtcbin needs at runtime to negotiate WebRTC connections. Without it the
# stream hangs at "Negotiating" with "missing a plug-in" in the server log.
# akmod-openrgb's %post builds a kernel module and refuses to run as root
# ("Not to be used as root; start as user or 'akmodsbuild' instead"), which
# fails the whole rpm transaction on the bazzite-deck base. It succeeds on the
# desktop bases, so the akmod is excluded ONLY on Deck images rather than
# stripping RGB kernel support from desktops. No loss there: that module drives
# motherboard/RAM lighting over SMBus, which a Steam Deck does not have. The
# openrgb userspace tool still installs.
RUN . /etc/os-release; \
    EXCL=""; \
    . /etc/os-release 2>/dev/null || true; \
    case "${VARIANT_ID:-}${IMAGE_ID:-}" in *deck*) EXCL="--exclude=akmod-openrgb" ;; esac; \
    dnf5 -y install --setopt=install_weak_deps=False $EXCL \
        openrgb piper logiops uv unzip podman-compose podman-docker \
        libnice-gstreamer1 maliit-keyboard && \
    curl -fsSL "https://github.com/oven-sh/bun/releases/latest/download/bun-linux-x64.zip" \
        -o /tmp/bun.zip && \
    unzip -q -j /tmp/bun.zip 'bun-linux-x64/bun' -d /usr/bin/ && \
    chmod +x /usr/bin/bun && \
    rm -f /tmp/bun.zip && \
    curl -fsSL "https://github.com/gerritdevriese/kzones/releases/download/v0.9.2/kzones.kwinscript" \
        -o /tmp/kzones.kwinscript && \
    mkdir -p /usr/share/kwin/scripts && \
    unzip -q /tmp/kzones.kwinscript -d /usr/share/kwin/scripts/kzones && \
    rm -f /tmp/kzones.kwinscript && \
    dnf5 -y clean all && \
    systemctl enable ratbagd.service logid.service

# tmux session persistence ACROSS REBOOT. The resume picker only ever survived a
# closed tab, a logout or an SSH drop — the tmux server dies with the kernel, so
# a restart still lost everything. resurrect snapshots sessions/windows/panes and
# their working directories; continuum autosaves on a timer and restores on
# server start. Vendored and PINNED at build time rather than through tpm, which
# clones from GitHub on first run — unacceptable in an image and broken offline.
ARG TMUX_RESURRECT_VER=v4.0.0
ARG TMUX_CONTINUUM_VER=v3.1.0
RUN mkdir -p /usr/share/tmux-plugins && \
    curl -fsSL "https://github.com/tmux-plugins/tmux-resurrect/archive/refs/tags/${TMUX_RESURRECT_VER}.tar.gz" \
        | tar xz -C /usr/share/tmux-plugins && \
    mv /usr/share/tmux-plugins/tmux-resurrect-* /usr/share/tmux-plugins/tmux-resurrect && \
    curl -fsSL "https://github.com/tmux-plugins/tmux-continuum/archive/refs/tags/${TMUX_CONTINUUM_VER}.tar.gz" \
        | tar xz -C /usr/share/tmux-plugins && \
    mv /usr/share/tmux-plugins/tmux-continuum-* /usr/share/tmux-plugins/tmux-continuum && \
    test -x /usr/share/tmux-plugins/tmux-resurrect/resurrect.tmux && \
    test -x /usr/share/tmux-plugins/tmux-continuum/continuum.tmux

# One layer for every file we ship (CLI + libs + plasmoids + KDE default).
COPY --from=staging / /

# Version-matched rebuilds of patched KDE apps (sources/kde/patches/).
COPY --from=kde-builder /kde-out/ /

# Mask all sleep-related systemd targets — no code path can suspend the box.
# Must run in the real base stage (not the scratch staging stage, which has no
# shell). Complements config/etc/systemd/logind.conf.d/50-powos-no-suspend.conf
# which blocks the trigger side (lid/keys/idle); this blocks the target side so
# a rogue systemctl suspend or systemd-inhibit --shell suspend has no effect.
# A HANDHELD IS THE EXCEPTION, and getting this wrong produces a boot that
# looks broken. PowOS ships PowerButtonAction=1 (suspend-to-RAM) so the Deck's
# power button behaves like stock SteamOS. If the sleep targets are ALSO masked,
# the two fight: PowerDevil asks logind to suspend, logind starts a masked
# target, the request fails, and each attempt tears down and re-initialises the
# display — which is when amdgpu logs "DTM TA is not initialized". The screen
# blanks and returns over and over and the machine looks wedged.
#
# So: masked everywhere EXCEPT the deck variant, which is allowed to sleep and
# whose power button is expected to.
RUN . /etc/os-release 2>/dev/null || true; \
    case "${VARIANT_ID:-}${IMAGE_ID:-}${POWOS_VARIANT:-}" in \
      *deck*) \
        echo "sleep: ALLOWED (handheld — power button suspends)"; \
        rm -f /etc/systemd/system/sleep.target \
              /etc/systemd/system/suspend.target \
              /etc/systemd/system/hibernate.target \
              /etc/systemd/system/hybrid-sleep.target; \
        rm -f /etc/systemd/logind.conf.d/50-powos-no-suspend.conf; \
        ;; \
      *) \
        echo "sleep: BLOCKED (infra box — suspend kills Traefik/containers)"; \
        ln -sf /dev/null /etc/systemd/system/sleep.target; \
        ln -sf /dev/null /etc/systemd/system/suspend.target; \
        ln -sf /dev/null /etc/systemd/system/hibernate.target; \
        ln -sf /dev/null /etc/systemd/system/hybrid-sleep.target; \
        # Nothing may ASK for a suspend that cannot happen: leaving
        # PowerButtonAction=1 here recreates the same fight on a desktop.
        if [ -f /etc/skel/.config/powerdevilrc ]; then \
          sed -i 's/^PowerButtonAction=1/PowerButtonAction=0/' \
              /etc/skel/.config/powerdevilrc; \
        fi; \
        ;; \
    esac

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
RUN chmod +x /usr/bin/powos /usr/bin/pinstall /usr/bin/premove /usr/bin/powos-boot /usr/bin/powos-pty-run /usr/bin/powos-widget-autoadd /usr/bin/greeter-watchdog /usr/bin/pow-collision-check 2>/dev/null || true && \
    find /usr/lib/powos -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} + 2>/dev/null || true && \
    # Guard: OCI hook JSON must never ship without its binary. crun fails
    # opaquely ("error executing hook … (exit code: 1)") on EVERY container
    # start when the binary is missing — this broke docker compose for an
    # agent on 2026-07-14. Fail the build here so the misalignment is caught
    # before the image is published.
    if [ -f /etc/containers/oci/hooks.d/pow-collision-check.json ] && \
       [ ! -x /usr/bin/pow-collision-check ]; then \
      echo "BUILD ERROR: OCI hook JSON shipped without /usr/bin/pow-collision-check" >&2; \
      exit 1; \
    fi && \
    systemctl enable greeter-watchdog.timer && \
    systemctl enable powos-firstboot.service && \
    systemctl enable powos-variant-retry.service && \
    systemctl enable powos-installer.service && \
    systemctl enable powos-safemode.service && \
    systemctl enable powos-boot-entries.service && \
    systemctl enable powos-firstboot-notice.service && \
    systemctl enable powos-initramfs-slim.service && \
    # powos-display-manager.conf pins display-manager.service to plasmalogin and
    # re-creates it with 'L+' on EVERY boot. Right on a base shipping
    # plasma-login-manager; catastrophic on one where sddm is the DM and
    # plasmalogin does not exist (bazzite-deck): every boot repointed
    # display-manager.service at a missing unit and clobbered the correct
    # symlink baked into the image, so graphical.target started nothing.
    { if [ -f /usr/lib/systemd/system/plasmalogin.service ]; then \
          echo "display-manager alias: plasmalogin (unchanged)"; \
      elif [ -f /usr/lib/systemd/system/sddm.service ]; then \
          sed -i "s|plasmalogin.service|sddm.service|" /etc/tmpfiles.d/powos-display-manager.conf; \
          echo "display-manager alias: retargeted to sddm"; \
      else \
          rm -f /etc/tmpfiles.d/powos-display-manager.conf; \
          echo "display-manager alias: no known DM, rule removed"; \
      fi; } && \
    # Enable whichever display manager this base actually ships. Enabling both
    # would put two DMs in graphical.target's Wants.
    { [ -f /usr/lib/systemd/system/plasmalogin.service ] \
        || systemctl enable sddm.service; } && \
    systemctl mask setroubleshootd.service 2>/dev/null || true && \
    # systemd-udev-settle is deprecated upstream ("should not be used") and is
    # ordered Before=sysinit.target, so ONE unit wanting it makes the whole
    # boot wait for the udev queue to drain: +4.637s on the critical chain to
    # graphical.target, measured on a Steam Deck, and the reason
    # `systemd-analyze blame` is topped by dev-ttyS0.device and dev-tpm0.device
    # at ~10s each — symptoms, not costs.
    #
    # Only Bazzite's cardwired.service wants it. A drop-in resetting that
    # unit's Wants= is the polite fix and it did NOT work: verified on a live
    # medium built with the drop-in in place, udev-settle still ran after
    # switch-root and cardwired started only once it finished. Masking is
    # decisive — a Wants= on a masked unit is simply ignored — and cardwired
    # keeps its own Restart=on-failure if it genuinely needs devices later.
    systemctl mask systemd-udev-settle.service 2>/dev/null || true && \
    # ublue-os-media-automount crashes on every PowOS boot. It runs
    # `findmnt -s --json ...`, which reads /etc/fstab and exits non-zero when
    # there is nothing to list — and a bootc install leaves /etc/fstab EMPTY,
    # because mounts come from kernel args and ostree rather than fstab. Its
    # Python does not handle that exit status, so the unit dies with a
    # CalledProcessError and sits red in `systemctl --failed` forever. The
    # precondition never holds on our images, and anything a user does put in
    # fstab is mounted by systemd's own fstab generator regardless.
    systemctl mask ublue-os-media-automount.service 2>/dev/null || true && \
    # Two units that cost seconds of CPU on a 4-core APU during boot and do
    # nothing a handheld needs. Neither is on the critical path, so this does
    # not move the headline number — it stops them competing with the units
    # that ARE on it.
    #   mandb-update  rebuilds the man-page database. On a games console.
    #   avahi-daemon  mDNS/zeroconf discovery; nothing here consumes it, and
    #                 it can be started later if something ever does.
    systemctl disable fedora-atomic-desktop-mandb-update.service 2>/dev/null || true && \
    systemctl disable avahi-daemon.service avahi-daemon.socket 2>/dev/null || true && \
    systemctl mask plasma-setup.service 2>/dev/null || true && \
    # DECK ONLY: install the dracut trim and REGENERATE the initramfs.
    #
    # The config alone changes nothing — the initramfs is already built in the
    # base image, so it has to be rebuilt for the omissions to take effect.
    # Guarded on the variant because main and nvidia-open need exactly the
    # drivers this omits. Failure is fatal on purpose: silently shipping the
    # old 241MB initramfs while claiming it was trimmed is worse than a failed
    # build.
    { . /etc/os-release 2>/dev/null || true; \
      case "${VARIANT_ID:-}${IMAGE_ID:-}${POWOS_VARIANT:-}" in \
        *deck*) \
          if [ -f /usr/lib/dracut/dracut.conf.d/95-powos-deck-slim.conf ]; then \
            echo "initramfs: already trimmed in an earlier stage, leaving it"; \
          else \
            install -Dm644 /usr/share/powos/dracut-deck-slim.conf \
                    /usr/lib/dracut/dracut.conf.d/95-powos-deck-slim.conf; \
            KVER=$(ls /usr/lib/modules | head -1); \
            BEFORE=$(stat -c %s "/usr/lib/modules/$KVER/initramfs.img"); \
            dracut --force --no-hostonly --kver "$KVER" \
                   "/usr/lib/modules/$KVER/initramfs.img"; \
            AFTER=$(stat -c %s "/usr/lib/modules/$KVER/initramfs.img"); \
            echo "initramfs: $((BEFORE/1048576))MB -> $((AFTER/1048576))MB (deck trim)"; \
            [ "$AFTER" -lt "$BEFORE" ] || { echo "BUILD ERROR: initramfs did not shrink"; exit 1; }; \
            lsinitrd "/usr/lib/modules/$KVER/initramfs.img" 2>/dev/null \
              | grep -q ostree-prepare-root \
              || { echo "BUILD ERROR: regenerated initramfs has no ostree-prepare-root — it cannot switch root"; exit 1; }; \
            echo "initramfs: ostree support verified present"; \
            for _need in plymouthd amdgpu; do \
              lsinitrd "/usr/lib/modules/$KVER/initramfs.img" 2>/dev/null \
                | grep -q "$_need" \
                || { echo "BUILD ERROR: regenerated initramfs is missing $_need"; exit 1; }; \
            done; \
            echo "initramfs: plymouth and amdgpu verified present"; \
          fi; \
          ;; \
        *) echo "initramfs: left generic (not the deck variant)" ;; \
      esac; } && \
    printf '%s\n' "${POWOS_SRC_COMMIT:-unknown}" > /usr/lib/powos/.powos-src-commit && \
    restorecon -RF /usr /etc 2>/dev/null || true

# ── Icon themes: keep the referenced set ───────────────────────────
#
#   podman build --build-arg POWOS_ICON_THEMES="breeze breeze-dark" ...
#
# 205M of themes, most never selected. Trimmed the same way as wallpapers --
# by REFERENCE, not by size -- because two of these are load-bearing in ways
# their size does not hint at:
#
#   hicolor          the freedesktop fallback theme. breeze declares
#                    Inherits=hicolor, so dropping it does not remove one theme,
#                    it breaks icon lookup for everything.
#   breeze_cursors   the cursor theme. Losing it gives you an X11 default
#                    cursor, or none.
#   Adwaita          what GTK apps fall back to; KDE-only keep-lists miss it.
#
# The keep-list is always UNIONED with those three plus whatever the
# look-and-feel defaults name, so a narrow POWOS_ICON_THEMES cannot break the
# desktop. Build fails if the union comes back empty.
ARG POWOS_ICON_THEMES=""
RUN set -eu; \
    keep="hicolor breeze_cursors Adwaita ${POWOS_ICON_THEMES}"; \
    keep="$keep $(grep -rhs '^Theme=' /usr/share/plasma/look-and-feel/*/contents/defaults \
                    2>/dev/null | sed 's/^Theme=//; s/^org\.kde\.//; s/\.desktop$//' | sort -u)"; \
    keep=$(printf '%s\n' $keep | sort -u); \
    [ -n "$keep" ] || { echo "BUILD ERROR: icon keep-list is EMPTY"; exit 1; }; \
    if [ -d /usr/share/icons ]; then \
      before=$(du -sm /usr/share/icons | cut -f1); \
      for d in /usr/share/icons/*/; do \
        [ -d "$d" ] || continue; n=$(basename "$d"); \
        printf '%s\n' $keep | grep -qxF "$n" || rm -rf "$d"; \
      done; \
      [ -d /usr/share/icons/hicolor ] \
        || { echo "BUILD ERROR: hicolor removed — breeze Inherits it, icon lookup breaks"; exit 1; }; \
      after=$(du -sm /usr/share/icons | cut -f1); \
      echo "icons: ${before}M -> ${after}M (kept: $(printf '%s ' $keep))"; \
    fi

# ── Homebrew: fetch on demand, do not ship the payload ─────────────
#
# homebrew.tar.zst is 125M of payload unpacked into /home/linuxbrew on first
# boot. It is worth dropping not because of the size but because of what it is:
# lib/install-router.sh rates brew UNSANDBOXED, "opt-in only (-m brew); never
# chosen automatically — this is the supply-chain surface". The sandbox backend
# does the same job for CLI tools with a separate $HOME, so on a machine that
# never types `-m brew` this is dormant attack surface being carried forever.
#
# SAFE BECAUSE brew-setup.service is ALREADY gated on the tarball:
#     ConditionPathExists=/usr/share/homebrew.tar.zst
# so removing it makes the unit no-op rather than fail. No drop-in, no masking,
# nothing left in `systemctl --failed`.
#
# POWOS_BREW=bundled keeps it for an install that must have brew offline.
ARG POWOS_BREW="fetch"
RUN set -eu; \
    if [ "${POWOS_BREW}" = "bundled" ]; then \
      echo "brew: bundled (payload kept)"; \
    elif [ -f /usr/share/homebrew.tar.zst ]; then \
      sz=$(du -sm /usr/share/homebrew.tar.zst | cut -f1); \
      rm -f /usr/share/homebrew.tar.zst; \
      grep -q 'ConditionPathExists=/usr/share/homebrew.tar.zst' \
           /usr/lib/systemd/system/brew-setup.service 2>/dev/null \
        || echo "brew: WARNING — brew-setup.service is not gated on the payload; it may now fail at boot"; \
      echo "brew: fetch-on-demand (dropped ${sz}M payload)"; \
    else \
      echo "brew: no payload present"; \
    fi

# ── Languages: keep only what this build needs ─────────────────────
#
#   podman build --build-arg POWOS_LOCALES="en_US nb_NO de_DE" ...
#
# Empty ("") keeps everything. 700 languages ship by default, which is ~886M
# across TWO trees that need completely different handling:
#
#   /usr/share/locale  663M  gettext .mo app translations, one dir per language.
#                            A plain prune. Note both "nb" and "nb_NO" forms
#                            exist, so the language prefix must be kept too or
#                            translations vanish while the locale still works.
#   /usr/lib/locale    223M  NOT per-language files — a single binary
#                            locale-archive. `rm` does nothing useful here;
#                            entries come out with localedef --delete-from-archive.
#
# C and POSIX are never removed: they are the fallback every program lands on,
# and losing them breaks things in ways that look unrelated to locale.
ARG POWOS_LOCALES="en_US nb_NO"
RUN set -eu; \
    if [ -z "${POWOS_LOCALES}" ]; then \
      echo "locales: keeping all (POWOS_LOCALES empty)"; \
    else \
      before=$(( $(du -sm /usr/share/locale 2>/dev/null | cut -f1) \
               + $(du -sm /usr/lib/locale   2>/dev/null | cut -f1) )); \
      keep="C POSIX"; \
      for l in ${POWOS_LOCALES}; do keep="$keep $l ${l%%_*}"; done; \
      for d in /usr/share/locale/*/; do \
        [ -d "$d" ] || continue; n=$(basename "$d"); \
        case " $keep " in *" $n "*) ;; *) rm -rf "$d" ;; esac; \
      done; \
      if command -v localedef >/dev/null 2>&1; then \
        for e in $(localedef --list-archive 2>/dev/null); do \
          b=${e%%.*}; \
          case " $keep " in \
            *" $b "*) ;; \
            *) localedef --delete-from-archive "$e" 2>/dev/null || true ;; \
          esac; \
        done; \
      fi; \
      for m in C POSIX; do \
        [ -d "/usr/share/locale/$m" ] || true; \
      done; \
      after=$(( $(du -sm /usr/share/locale 2>/dev/null | cut -f1) \
              + $(du -sm /usr/lib/locale   2>/dev/null | cut -f1) )); \
      echo "locales: ${before}M -> ${after}M (kept: ${POWOS_LOCALES})"; \
      for l in ${POWOS_LOCALES}; do \
        [ -d "/usr/share/locale/${l}" ] || [ -d "/usr/share/locale/${l%%_*}" ] \
          || echo "locales: note — no translation dir for '$l' (locale itself may still work)"; \
      done; \
    fi

# ── DECK ONLY: firmware for hardware a Deck does not have ──────────
#
# linux-firmware ships blobs for every vendor and lands in every variant. The
# gpu-amd / gpu-nvidia / gpu-intel capabilities in sources/ scope the DRIVERS
# per variant, but not these blobs — so a Deck image carries 285M of firmware
# it can never load.
#
# WHAT MUST SURVIVE, because getting this wrong bricks connectivity rather than
# just wasting space:
#   amdgpu   the GPU. Obviously.
#   ath*     THE WIFI. The LCD Deck (Jupiter) uses a Qualcomm Atheros QCA6174,
#            so ath10k is required. `ath` looks like a removable vendor blob and
#            is not — it very nearly went into a removal list on that basis.
#   qcom     Qualcomm; the OLED Deck (Galileo) uses a WCN6855.
#
# Only vendors with NO presence on either Deck are removed, and the build fails
# loudly if a required tree went with them.
RUN . /etc/os-release 2>/dev/null || true; \
    case "${VARIANT_ID:-}${IMAGE_ID:-}${POWOS_VARIANT:-}" in \
      *deck*) \
        before=$(du -sm /usr/lib/firmware 2>/dev/null | cut -f1); \
        rm -rf /usr/lib/firmware/nvidia \
               /usr/lib/firmware/intel \
               /usr/lib/firmware/i915 \
               /usr/lib/firmware/mediatek; \
        for _keep in amdgpu ath10k qcom; do \
          ls -d /usr/lib/firmware/${_keep}* >/dev/null 2>&1 \
            || { echo "BUILD ERROR: firmware trim removed $_keep — the Deck needs it (gpu/wifi)"; exit 1; }; \
        done; \
        after=$(du -sm /usr/lib/firmware 2>/dev/null | cut -f1); \
        echo "firmware: ${before}M -> ${after}M (deck: dropped nvidia/intel/i915/mediatek)"; \
        ;; \
      *) echo "firmware: left complete (not the deck variant)" ;; \
    esac

# ── Trim base-image bulk the system never uses ─────────────────────
#
# All of this comes from the Bazzite base; PowOS adds none of it. Removing it
# takes ~555 MB off the DEPLOYED system.
#
# It does NOT shrink the download, and it is worth being explicit about that so
# nobody re-measures it expecting one. The build runs with --layers and no
# squash, so a delete here is a whiteout in a NEW layer while the bytes stay in
# the base layer and are still fetched — the 135-layer, ~7 GB first pull is
# unchanged, possibly a few KB larger. Shrinking THAT means squashing or moving
# off the base image, which is a different job.
#
# Three deliberate exclusions:
#   /usr/share/licenses  a SEPARATE tree from /usr/share/doc (14 MB), so the
#                        license texts survive. Do not fold it in.
#   /usr/share/locale    663 MB, but pruning to English drops nb_NO with it.
#   /usr/share/fonts     409 MB, mostly Noto CJK — that is what renders
#                        Japanese and Chinese game titles in Steam.
#
# Wallpapers are TRIMMED TO THE REFERENCED SET, not emptied. Plasma's
# look-and-feel defaults name specific wallpapers, and deleting one leaves the
# default desktop pointing at a missing image. The keep-list is derived from
# those files at build time rather than hardcoded, so it cannot drift when the
# base changes its defaults, and the build fails loudly if that derivation
# comes back empty — which would otherwise delete every wallpaper silently.

RUN set -eu; \
    keep=$(grep -rhs '^Image=' /usr/share/plasma/look-and-feel/*/contents/defaults 2>/dev/null \
             | sed 's/^Image=//' | sort -u); \
    keep="$keep $(grep -rhso '/usr/share/wallpapers/[A-Za-z0-9_-]*' \
             /usr/share/plasma /usr/share/sddm /etc 2>/dev/null | sed 's|.*/||' | sort -u)"; \
    keep=$(printf '%s\n' $keep | sort -u); \
    if [ -d /usr/share/wallpapers ]; then \
      [ -n "$keep" ] || { echo "BUILD ERROR: wallpaper keep-list is EMPTY; refusing to delete them all"; exit 1; }; \
      for d in /usr/share/wallpapers/*/; do \
        [ -d "$d" ] || continue; \
        n=$(basename "$d"); \
        printf '%s\n' $keep | grep -qxF "$n" || rm -rf "$d"; \
      done; \
    fi; \
    rm -rf /usr/share/doc /usr/share/man /usr/share/help; \
    [ -d /usr/share/licenses ] \
      || { echo "BUILD ERROR: /usr/share/licenses was removed - license texts must survive"; exit 1; }; \
    echo "trim: /usr/share is now $(du -sh /usr/share 2>/dev/null | cut -f1)"

# Container dev/test entrypoint: `docker compose up` / `docker run` launches the
# desktop boot sequence + VNC/noVNC. IGNORED by the installed OS (it boots via
# systemd), this only affects running the image as a container.
CMD ["/usr/bin/powos-desktop-entrypoint"]
