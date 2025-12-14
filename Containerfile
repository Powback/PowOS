# PowOS - Based on Bazzite
FROM ghcr.io/ublue-os/bazzite-nvidia:stable

ENV POWOS_ROOT=/var/lib/powos
ENV TERM=xterm

LABEL org.opencontainers.image.title="PowOS"

# PowOS directories
RUN mkdir -p /var/lib/powos/{extensions,overlays,state} \
    /var/lib/extensions /etc/powos /usr/lib/powos /run/powos

# Ensure dnf is configured for build
RUN dnf makecache || true

# Install dependencies
# Note: Bazzite doesn't have /usr/local by default, create it first
RUN dnf install -y python3 python3-pip rsync && \
    rm -f /usr/local 2>/dev/null || true && \
    mkdir -p /usr/local/lib /usr/local/bin && \
    pip3 install --break-system-packages psutil rich && \
    dnf clean all

# Copy PowOS boot system
COPY lib/boot/ /usr/lib/powos/boot/
COPY lib/hardware-detect.sh /usr/lib/powos/
COPY lib/overlay-manager.sh /usr/lib/powos/
COPY lib/build-helpers.sh /var/lib/powos/lib/
COPY bazzite/system_files/ /tmp/bazzite/system_files/
COPY overlays/ /usr/lib/powos/overlays/
COPY sources/ /var/lib/powos/sources/
COPY bin/powos-boot /usr/bin/
COPY bin/powos /usr/bin/
COPY config/ /etc/powos/
COPY systemd/powos-* /usr/lib/powos/

# Copy RAM overlay system (replaces HomeFS)
COPY lib/ramfs/ /usr/lib/powos/ramfs/

# Install dracut module for full RAM boot
# This allows the entire OS to run from RAM, USB can be unplugged
COPY lib/dracut/90powos-ramboot/ /usr/lib/dracut/modules.d/90powos-ramboot/
RUN chmod +x /usr/lib/dracut/modules.d/90powos-ramboot/*.sh

# Install ramboot systemd service
COPY systemd/powos-ramboot-init.service /usr/lib/systemd/system/
RUN systemctl enable powos-ramboot-init.service 2>/dev/null || true

# Rebuild initramfs with our dracut module
# This embeds the RAM overlay setup into the boot process
RUN dracut --force --add "powos-ramboot" --kver $(ls /lib/modules/ | head -1) 2>/dev/null || \
    echo "Note: dracut rebuild skipped (will happen at ISO build time)"

# Install bootc kernel arguments for RAM boot
# These tell the kernel to enable our RAM overlay at boot
RUN mkdir -p /usr/lib/bootc/kargs.d
COPY config/bootc/kargs.d/ /usr/lib/bootc/kargs.d/

# Build extensions
RUN bash /usr/lib/powos/overlay-manager.sh build-all

# Setup directories
# Note: Bazzite has /mnt as a symlink, remove and recreate
RUN rm -f /mnt 2>/dev/null || true && \
    mkdir -p /mnt/powos-usb /run/powos/overlay

# Set permissions
RUN chmod +x /usr/bin/powos-boot /usr/bin/powos \
    /usr/lib/powos/*.sh /usr/lib/powos/boot/*.sh \
    /usr/lib/powos/ramfs/*.sh /usr/lib/powos/ramfs/*.py 2>/dev/null || true

EXPOSE 5901 6080
ENTRYPOINT ["/usr/bin/powos-boot"]
