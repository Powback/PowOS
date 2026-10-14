#!/bin/bash
# Installs PowOS into the Android rootfs: everything comes from the published PowOS Deck image's manifest
# (.github/workflows/phone-manifest.yml), mapped by phone-rules.conf; only phone-specific parts are here.
# Runs inside the aarch64 rootfs, called by Andromarchy's build/build-inside.sh at the step where it used to
# install Omarchy (patches/andromarchy/0001-build-inside-powos.patch). Inputs, staged by build-rootfs.sh in $P:
#   manifest/  leaves.tsv, packages.tsv, flatpaks.txt, content.tar.zst, image.txt (tools/fetch-manifest.sh)
#   phone-rules.conf, resolve-packages.py
#   pkgs/      our built packages (kwin with the Anland backend)
#   session/   the session launcher + first-boot/first-session
#   shims/     stand-ins for Omarchy commands Andromarchy's engine calls
#
# POWOS_TARGET=vm installs the same PowOS for a virtual machine instead (targets/web: PowOS in the browser):
# everything but the phone-specific section, plus a kernel and a normal systemd boot. P= points at the inputs.
set -euo pipefail
POWOS_TARGET=${POWOS_TARGET:-phone}
P=${P:-/tmp/lotfix/powos}
L=/tmp/lotfix
C=/etc/pacman.conf
echo "powos: from $(cat $P/manifest/image.txt)"

# ── What the phone session itself needs (not PowOS content: the Plasma session on Android) ─────────────
pacman -S --noconfirm --needed plasma-workspace xdg-desktop-portal-kde kscreen python zstd

# ── Our packages (build-pkgs.sh): KWin with the Anland backend, FEX, and PowOS packages Arch Linux ARM doesn't
# build (recipes.list: upstream recipes built for aarch64). First, so the mapping below finds them.
pacman -U --noconfirm "$P"/pkgs/*.pkg.tar.*

# ── PowOS's packages: EVERY RPM in the image, mapped to Arch by phone-rules.conf ───────────────────────
# Not only the top-level ones: Fedora and Arch split dependencies differently, so Arch's dependency closure of
# the top level missed real PowOS software (embree, mtools, alsa-utils, bluez's tools... found by
# phone-parity.py). The report (what each RPM became, MISSING ones first) stays in the image for review.
mkdir -p /usr/share/powos
# Available = package names plus the names they provide: Arch's perl ships the core modules Fedora splits into
# ~130 perl-* RPMs, tinyxxd provides xxd... (pacman -S installs a provider by such a name).
{ pacman -Slq; pacman -Qq
  LC_ALL=C pacman -Si | awk '/^[A-Za-z][A-Za-z ]* *: / {p = ($1 == "Provides")} p {sub(/^Provides *: */, ""); print}' \
    | tr -s ' ' '\n' | sed 's/[<>=].*//' | grep -v -x -e None -e ''
} | sort -u > /tmp/arch-available.txt
POWOS_TARGET=$POWOS_TARGET python3 $P/resolve-packages.py $P/manifest/packages.tsv $P/phone-rules.conf /tmp/arch-available.txt \
  /tmp/powos-install.txt /usr/share/powos/phone-report.txt
# Ours are installed already (and in no repo, so pacman -S would not find them).
pacman -Qq | sort -u > /tmp/installed.txt
sort -u /tmp/powos-install.txt | comm -23 - /tmp/installed.txt > /tmp/r && mv /tmp/r /tmp/powos-install.txt
# PowOS's choice among alternative providers first (PipeWire for JACK and PulseAudio, as Fedora/PowOS does):
# otherwise a dependency pulls in pacman's default provider (jack2) and pipewire-jack then conflicts with it.
pacman -S --noconfirm --needed --ask 4 pipewire-jack pipewire-pulse
# One transaction first; if any single package breaks it (a conflict, a repo hiccup), the rest still go
# in one by one and the ones that failed are listed at the top of the report.
if ! pacman -S --noconfirm --needed $(cat /tmp/powos-install.txt); then
  for p in $(cat /tmp/powos-install.txt); do
    pacman -S --noconfirm --needed "$p" >/dev/null 2>&1 || echo "FAILED   $p  pacman could not install it" >> /tmp/powos-failed.txt
  done
  [ -s /tmp/powos-failed.txt ] && { cat /tmp/powos-failed.txt /usr/share/powos/phone-report.txt > /tmp/r && mv /tmp/r /usr/share/powos/phone-report.txt; }
fi

# Our KWin (Anland backend) over Arch's, then pinned: pacman must never swap it for Arch's, which has no
# way to draw on Android. HACK: IgnorePkg means Plasma updates need a matching rebuild of our kwin
# (pacman warns about the held package); the real fix is the Anland backend upstream in KWin.
grep -q '^IgnorePkg.*\bkwin\b' $C || sed -i "/^IgnorePkg/ s/$/ kwin/" $C

# FEX: PowOS's Steam (Valve's bootstrapper is 32-bit x86) and x86 games run through it, as on Valve's own ARM
# hardware. The engine's execve hands x86 programs to FEXInterpreter (patches/andromarchy/0002), standing in for
# the binfmt_misc registration an Android app cannot make. FEX's x86 rootfs comes from FEX's own fetcher,
# extracted: no FUSE mounts on Android.
FEXRootFSFetcher -y -x --distro-list-first --force-ui tty
# System-wide, so every user and service finds it: FEX's global config + rootfs location. (The fetcher's own
# "set as default" writes no config in this rootfs; verified on the S25: FEX then saw an empty RootFS path.)
mkdir -p /usr/share/fex-emu/RootFS
for d in ~/.local/share/fex-emu/RootFS/*/; do mv "$d" /usr/share/fex-emu/RootFS/; done
rm -rf ~/.local/share/fex-emu/RootFS
fexroot=$(ls -d /usr/share/fex-emu/RootFS/*/ | head -1)
printf '{"Config":{"RootFS":"%s"}}\n' "${fexroot%/}" > /usr/share/fex-emu/Config.json

# ── PowOS's files: everything in the image no package owns (PowOS layer, Bazzite's system_files, Deck
# presets...), architecture-independent only. Unpacked after the packages, as the image's layers sit on top
# of its packages.
# Never over an Arch package's own file (outside /etc, where PowOS's configs are meant to win): the image's
# unowned files can carry Fedora-specific copies of things Arch packages provide (a libgcc_s.so.1 symlink did).
# Nor over a directory an Arch package owns: Fedora's compatibility symlinks can sit where Arch has a real
# directory (usr/share/fonts/noto-cjk -> google-noto-sans-cjk-fonts, vs noto-fonts-cjk's noto-cjk/), and tar
# can't replace one. The content holds only files and symlinks (no directories), so skipping such a path drops
# exactly that one entry.
python3 - "$P/manifest/content.list" > /tmp/powos-content-skip <<'PY'
import glob, sys
owned = set()
for f in glob.glob('/var/lib/pacman/local/*/files'):
    for l in open(f):
        l = l.strip()
        if l and not l.startswith('%'):
            owned.add(l.rstrip('/'))
for l in open(sys.argv[1]):
    l = l.strip()
    if l in owned and not l.startswith('etc/'):
        print(l)
PY
echo "powos: $(wc -l < /tmp/powos-content-skip) content files left to the Arch packages that own them"
zstd -dc $P/manifest/content.tar.zst | tar -x -C / --no-same-owner --exclude-from=/tmp/powos-content-skip
cp $P/manifest/flatpaks.txt /usr/share/powos/phone-flatpaks.txt

# HACK: bun is an x86 binary the PowOS image puts outside any package (Containerfile curl), so the manifest
# can't carry it; the aarch64 build of the same release. Real fix: the manifest lists such binaries too.
curl -fsSL -o /tmp/bun.zip https://github.com/oven-sh/bun/releases/latest/download/bun-linux-aarch64.zip
bsdtar -xf /tmp/bun.zip -C /tmp && install -m 755 /tmp/bun-linux-aarch64/bun /usr/bin/bun && rm -rf /tmp/bun*
mkdir -p /etc/powos && echo "$POWOS_TARGET" > /etc/powos/platform

if [ "$POWOS_TARGET" = phone ]; then
# ── Phone-specific ──────────────────────────────────────────────────────────────────────────────────────
# No systemd on Android: startplasma must start the session's services itself, not ask systemd to.
mkdir -p /etc/xdg
printf '[General]\nsystemdBoot=false\n' > /etc/xdg/startkderc
# The app's user is root with home /root: seed it from /etc/skel as useradd would for a new user.
cp -a /etc/skel/. /root/ 2>/dev/null || true

# Session + Omarchy-name stand-ins
install -m 755 "$P/session/Hyprland" /usr/bin/Hyprland            # HACK: see the file
install -Dm 755 "$P/session/first-session.sh" /opt/powos/first-session.sh
# first-boot.sh goes to /opt/lotfix/ in build-inside.sh's own install step (patched to take ours).
# HACK: Omarchy command names the engine calls; see each file. omarchy-dns is Andromarchy's own
# Android version (resolv.conf from Android's network), unchanged.
install -m 755 "$L/native/omarchy-dns-android.sh" /usr/local/bin/omarchy-dns
install -m 755 "$P/shims/omarchy-toggle-idle" /usr/local/bin/omarchy-toggle-idle
install -m 755 "$P/shims/omarchy-lock-screen" /usr/local/bin/omarchy-lock-screen
else
# ── Virtual machine (targets/web) ───────────────────────────────────────────────────────────────────────
# A normal boot: Arch Linux ARM's kernel, systemd as init, the root filesystem on the VM's first virtio disk.
# PowOS's login (powos/powos, as in PowOS's docs).
pacman -S --noconfirm --needed linux-aarch64 mkinitcpio
# The VM's initramfs: only what mounting the root needs (virtio disk + ext4), busybox init (base hook, no
# systemd/udev in the initramfs). The browser downloads it before booting, so size is time: ~3 MB instead of
# the ~185 MB generic one, and emulated systemd-in-initrd was the slow stage that also timed out waiting for
# /dev/vda (devtmpfs makes the node as soon as virtio_blk loads).
cat > /etc/mkinitcpio-powos-vm.conf <<'EOF'
MODULES=(virtio_pci virtio_blk ext4)
BINARIES=()
FILES=()
HOOKS=(base)
COMPRESSION=zstd
COMPRESSION_OPTIONS=(-19)
EOF
mkinitcpio -k "$(ls /usr/lib/modules | head -1)" -c /etc/mkinitcpio-powos-vm.conf -g /boot/initramfs-powos-vm.img
echo '/dev/vda / ext4 rw,relatime 0 1' > /etc/fstab
echo powos > /etc/hostname
id powos >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash powos
echo powos:powos | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel && chmod 440 /etc/sudoers.d/10-wheel
fi

# Parity with the PowOS image: every command, app, autostart entry and enabled unit it offers, checked here.
# Gaps are listed by the PowOS package they come from; the report stays in the image.
install -Dm 644 $P/manifest/index.tsv /usr/share/powos/phone-index.tsv
install -Dm 755 $P/phone-parity.py /usr/lib/powos/phone/phone-parity.py
python3 /usr/lib/powos/phone/phone-parity.py /usr/share/powos/phone-index.tsv > /usr/share/powos/phone-parity.txt || true

echo "powos installed: $(head -1 /usr/share/powos/phone-report.txt)"
sed -n '2,7p' /usr/share/powos/phone-parity.txt
