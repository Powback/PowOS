# FEX for Steam with the futex_waitv probe (temporary)

Steam on ARM runs Proton games under Valve's own FEX build, the Steam tool `FEX-Emu` (appid 3127680,
`steamapps/common/FEX-Emu`). That FEX passes `futex_waitv` (syscall 449, needed by Proton's fsync) through only when
the host kernel version is >= 5.16. The PowOS phone kernel is Android GKI 5.15 with `futex_waitv` backported
(targets/native/patches/gki), so Valve's FEX answers ENOSYS, Wine falls back to wineserver round trips for every
lock and event, and games crawl (Besiege: ~6 fps, wineserver busy, GPU idle).

`build.sh` builds FEX at exactly the commit Valve's tool reports (`VERSIONS.txt`, currently `FEX-2607-76-g37265b1`)
with `0001-futex_waitv-probe-host.patch` (the same change as `pkgs/fex-emu/0003`): probe the host instead of
trusting its version.

Assembly (not automated yet): copy Valve's tool to `~/.local/share/Steam/compatibilitytools.d/FEX-Emu-PowOS`,
replace only `usr/bin/FEX` with `out/usr/bin/FEX` - Valve's thunks, RootFS, server manager and scripts stay as they
are - and give it its own `compatibilitytool.vdf` name.

Check before using: `out/VERSION` records the newest glibc symbol the binary needs; it must not exceed the glibc it
runs against (the host, or the Steam Runtime container when the tool runs FEX inside it).

This directory goes away once upstream FEX probes for `futex_waitv` and Valve ships a FEX with it.
