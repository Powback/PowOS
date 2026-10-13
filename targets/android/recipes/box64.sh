# HACK: box64 exports its own dlopen/dlclose/dlsym (hooks for native libraries loading x86 Vulkan overlays) and
# found the real ones by walking dl_iterate_phdr; under fakechroot (Andromarchy's no-root runtime) that recursed
# without bound and box64 segfaulted before main, even for "box64 --version" (tools/lab/phone-sim.sh, 2026-10-13).
# box64-real-dl-functions.patch takes libc's dlsym from dlvsym and resolves the rest with it, from box64 itself, so
# RTLD_NEXT still reaches fakechroot's dlopen (path rewriting for native libraries' dlopen). Real fix: upstream box64.
cp /fixups/box64-real-dl-functions.patch .
sed -i 's|^build() {|prepare() {\n    cd ${pkgname}-${pkgver}\n    patch -p1 < "$startdir/box64-real-dl-functions.patch"\n}\n\nbuild() {|' PKGBUILD
grep -q 'box64-real-dl-functions.patch' PKGBUILD
