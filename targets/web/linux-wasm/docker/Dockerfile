# PowOS's Linux/Wasm build image: upstream's (linux-wasm-base:dev, built by build.sh) plus what building PowOS's
# userland (Qt, KDE, dbus, ...) needs on top of upstream's kernel/musl/BusyBox: pkg-config. The toolchain
# (qt-toolchain.sh) points it at the Wasm prefix only, so build-machine libraries never leak in.
FROM linux-wasm-base:dev
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends pkg-config \
    && rm -rf /var/lib/apt/lists/*
