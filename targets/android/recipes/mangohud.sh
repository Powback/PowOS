# HACK: Arch's mangohud recipe builds with NVIDIA's XNVCtrl (GPU stats on NVIDIA cards); libxnvctrl has no
# aarch64 build and phones have no NVIDIA GPU. MangoHud's own meson switch turns that part off; everything
# else is the upstream recipe. Real fix: Arch Linux ARM packaging mangohud.
sed -i "s/'libxnvctrl' //" PKGBUILD
sed -i 's/-Dmangoapp=true/-Dmangoapp=true -Dwith_xnvctrl=disabled/' PKGBUILD
grep -q with_xnvctrl=disabled PKGBUILD
