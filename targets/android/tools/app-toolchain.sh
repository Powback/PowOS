#!/bin/sh
# app-toolchain.sh [PREFIX] [TEMPLATE_MODULE_DIR] - the Rust -> wasm toolchain `powos app build` uses on the phone itself
# (gh#13 A3: making an app with a module on a phone without root, offline). Run by install-powos-android.sh in the
# image build; rootfs-packs.conf puts PREFIX (default /opt/powos-rust) in the `rust` pack, so a phone without root adds
# it from Settings > Storage or when `powos app build` asks (powos-pack need rust, + dev for gcc), once, and builds
# offline after. Measured 11-14 (rustc 1.100.0): 815 MiB unpacked (rustup 605, app-target 181, cargo 31), 284 MB gz.
#
#   PREFIX/rustup, PREFIX/cargo   rustup's minimal stable toolchain + the wasm32-unknown-unknown target (Arch Linux ARM's
#                                 rust has no wasm32 std, so not pacman's)
#   PREFIX/cargo/registry         every crate the app template's Cargo.lock names (spacetimedb 2.12 and its ~90): a new
#                                 app's module resolves and builds with `cargo --offline`
#   PREFIX/app-target             those crates compiled once for wasm32 release: an app's first build compiles only
#                                 its own crate (lib/apps/powos-app seeds ~/.cache/powos/app-target from it)
# Writable by everyone (cargo takes its package-cache lock in CARGO_HOME): the rooted image's session user isn't root.
set -eu
P=${1:-/opt/powos-rust}
T=${2:-$(dirname "$0")/../../../lib/apps/templates/module/module}
export RUSTUP_HOME=$P/rustup CARGO_HOME=$P/cargo
mkdir -p "$P"
arch=$(uname -m)
curl -fsSL -o /tmp/rustup-init "https://static.rust-lang.org/rustup/dist/$arch-unknown-linux-gnu/rustup-init"
chmod 755 /tmp/rustup-init
/tmp/rustup-init -y -q --no-modify-path --profile minimal --default-toolchain stable -t wasm32-unknown-unknown
rm -f /tmp/rustup-init
# The template's dependencies, fetched and compiled once (its own crate's artifacts are dropped).
w=$(mktemp -d)
cp -r "$T/." "$w/"
sed -i 's/__CRATE__/powos_app_warm/' "$w/Cargo.toml"
sed -i 's/__[A-Z]*__/warm/g' "$w/src/lib.rs"
(cd "$w" && CARGO_TARGET_DIR=$P/app-target "$CARGO_HOME/bin/cargo" build --release --target wasm32-unknown-unknown -q)
rm -rf "$w" "$P"/app-target/wasm32-unknown-unknown/release/*powos_app_warm* \
  "$P"/app-target/wasm32-unknown-unknown/release/.fingerprint/powos_app_warm-* \
  "$P"/app-target/wasm32-unknown-unknown/release/deps/*powos_app_warm*
rm -rf "$P/rustup/downloads" "$P/rustup/tmp" "$P/cargo/registry/src"
chmod -R a+rwX "$P/cargo" "$P/app-target"
echo "app-toolchain: $("$CARGO_HOME/bin/rustc" --version), $(du -sh "$P" | cut -f1) in $P"
