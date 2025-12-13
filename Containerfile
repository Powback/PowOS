# PowOS - Based on Bazzite
FROM ghcr.io/ublue-os/bazzite-nvidia:stable

ENV POWOS_ROOT=/var/lib/powos
ENV TERM=xterm

LABEL org.opencontainers.image.title="PowOS"

# PowOS directories
RUN mkdir -p /var/lib/powos/{extensions,overlays,state} \
    /var/lib/extensions /etc/powos /usr/lib/powos /run/powos

# Ensure dnf is configured for build (usually fine in fedora images)
RUN dnf makecache || true

# Install HomeFS dependencies (FUSE, Python)
# Note: Bazzite doesn't have /usr/local by default, create it first
RUN dnf install -y fuse fuse-libs python3 python3-pip && \
    rm -f /usr/local 2>/dev/null || true && \
    mkdir -p /usr/local/lib /usr/local/bin && \
    pip3 install --break-system-packages fusepy psutil rich && \
    dnf clean all

# Copy PowOS boot system
COPY lib/boot/ /usr/lib/powos/boot/
COPY lib/hardware-detect.sh /usr/lib/powos/
COPY lib/overlay-manager.sh /usr/lib/powos/
COPY lib/homefs/ /usr/lib/powos/homefs/
COPY lib/build-helpers.sh /var/lib/powos/lib/
COPY bazzite/system_files/ /tmp/bazzite/system_files/
COPY overlays/ /usr/lib/powos/overlays/
COPY sources/ /var/lib/powos/sources/
COPY bin/powos-boot /usr/bin/
COPY config/ /etc/powos/
COPY systemd/powos-* /usr/lib/powos/

# Build extensions
RUN bash /usr/lib/powos/overlay-manager.sh build-all

# Setup HomeFS directories and CLI
# Note: Bazzite has /mnt as a symlink, remove and recreate
RUN rm -f /mnt 2>/dev/null || true && \
    mkdir -p /var/lib/homefs /etc/homefs /var/run/homefs /mnt/homefs-usb && \
    ln -sf /usr/lib/powos/homefs/cli.py /usr/local/bin/homefs && \
    chmod +x /usr/lib/powos/homefs/cli.py

# Copy HomeFS config and scripts
COPY config/homefs/ /etc/homefs/
COPY bin/homefs-usb-notify /usr/local/bin/

RUN chmod +x /usr/bin/powos-boot /usr/lib/powos/*.sh /usr/lib/powos/boot/*.sh \
    /usr/local/bin/homefs-usb-notify /usr/lib/powos/homefs/*.py 2>/dev/null || true

EXPOSE 5901 6080
ENTRYPOINT ["/usr/bin/powos-boot"]
