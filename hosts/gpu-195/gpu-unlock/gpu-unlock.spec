Name: powos-gpu-unlock
Version: 1.0.0
Release: 1
Summary: GPU unlock built for the PowOS GPU server kernel
License: GPL-2.0-only AND LicenseRef-NVIDIA
URL: https://github.com/Zagitta/gpu-unlock
Source0: payload.tar.gz
ExclusiveArch: x86_64
# No DKMS hooks on an ostree deployment. Rebuild this package before a kernel update.
Requires: kernel-core-uname-r = %{kver}
Requires(post): /usr/sbin/depmod
AutoReqProv: no
%global debug_package %{nil}
%global __os_install_post %{nil}

%description
Pinned upstream af28cbbfd3d922a659227ecfb7369adfd924cf03, with verified
firmware and a module built for %{kver}. Inert without gpu_unlock.targets.
Requires local initramfs regeneration on rpm-ostree. No live loading.

%prep
%setup -q -c -T
tar -xf %{SOURCE0}

%install
mkdir -p %{buildroot}
cp -a usr etc %{buildroot}/

%post
/usr/sbin/depmod -a %{kver}

%files
/usr/lib/modules/%{kver}/extra/gpu_unlock.ko
/usr/lib/firmware/gpu-unlock
/usr/lib/dracut/dracut.conf.d/gpu-unlock.conf
/usr/share/licenses/gpu-unlock
/usr/share/licenses/gpu-unlock-firmware
/usr/share/powos/gpu-unlock
/usr/bin/powos-gpu-unlock
%config(noreplace) /etc/powos/units.d/gpu-unlock.json
