# Builds the OnePlus Open's vendor (GKI android13-5.15) kernel for native PowOS. amd64 on purpose: Google's prebuilt
# Clang r450784e - the exact compiler the stock kernel was built with, so CFI/LTO and module symbol versions match -
# only exists for x86-64 (runs under Colima's Rosetta here).
FROM --platform=linux/amd64 debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
      make bc bison flex libssl-dev libelf-dev cpio xz-utils lz4 python3 kmod git curl ca-certificates rsync file \
      perl gzip libc6-dev gcc \
    && rm -rf /var/lib/apt/lists/*
