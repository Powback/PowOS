# Builds PowOS's native phone kernel, device tree, bring-up initramfs and boot.img (arm64 host, native compile).
FROM debian:trixie
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential bc bison flex libssl-dev libelf-dev cpio xz-utils python3 kmod \
      device-tree-compiler busybox-static mkbootimg curl ca-certificates rsync file lz4 \
    && rm -rf /var/lib/apt/lists/*
