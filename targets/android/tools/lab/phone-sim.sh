#!/bin/bash
# The phone without the phone: the PowOS rootfs run the way the Andromarchy app runs it, in a container.
#   - host side is Alpine (musl, no glibc anywhere outside the rootfs, like Android's Bionic userland);
#   - the rootfs sits where the app keeps it (/data/data/andro.marchy/files/rootfs), extracted by a plain user;
#   - it is entered only through lotfix-run (the app's own launcher, built here with musl): the rootfs's patched
#     glibc loader + fakechroot + android-compat.so, fakeroot over TCP for ARCH_ROOT=1;
#   - an app-like uid, no capabilities, Docker's default seccomp (no user namespaces: bwrap/pressure-vessel fail
#     as on Android), no binfmt use (x86 programs reach box64 only through android-compat's exec hook).
# Differences left: no KGSL GPU (lavapipe instead, from Arch Linux ARM's vulkan-swrast, outside the rootfs's own
# Mesa; lab only), no Android seccomp filter (tools/probe on the phone covers that), an X server on the host
# side (Xvfb; on the phone KWin's Xwayland runs inside the rootfs), and Colima's Rosetta binfmt still exists
# (checked: a Rosetta mapping in any process is reported).
#
#   phone-sim.sh setup [rootfs.tar.gz]   extract (default out/powos-rootfs.tar.gz), first-boot, lavapipe
#   phone-sim.sh run '<bash cmd>'        as the app's session runs programs   (ARCH_ROOT=1 phone-sim.sh run ... : fake root;
#                                        SIM_PRE='<host-side cmds>': e.g. copy files from /android into $ARCH_ROOTFS)
#   phone-sim.sh rm                      drop the simulation's storage
# Storage: a sparse ext4 image on the Mac's disk (out/phone-sim.img), loop-mounted in the Colima VM at
# /mnt/powos-phone-sim and bind-mounted into the container: the extracted rootfs (~15 GB) stays off the Docker
# disk shared with live services. The app directory inside is owned by the app uid, as on the phone.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
A=$(cd "$HERE/../.." && pwd)
IMG=$A/out/phone-sim.img
MNT=/mnt/powos-phone-sim
APP=/data/data/andro.marchy
R=$APP/files/rootfs
RUN=$APP/files/run
UID_APP=10234
IMAGE=powos-phone-sim-host

docker image inspect $IMAGE >/dev/null 2>&1 || docker build -q -t $IMAGE - >/dev/null <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache bash coreutils tar gzip xvfb xdpyinfo gcc musl-dev zstd curl mesa-dri-gallium mesa-gl xwd imagemagick
EOF

mounted() { colima ssh -- mountpoint -q $MNT; }
mount_store() {
  mounted && return
  [ -f "$IMG" ] || { truncate -s 60G "$IMG"; colima ssh -- sudo mkfs.ext4 -q "$IMG"; }
  colima ssh -- sudo sh -c "mkdir -p $MNT && mount -o loop '$IMG' $MNT && mkdir -p $MNT/app && chown $UID_APP:$UID_APP $MNT/app"
}

sim() { # run a host-side bash script in the simulation container, as the app's uid
  mkdir -p "$A/out/sim-shots" && chmod 777 "$A/out/sim-shots"
  docker run --rm -i --platform linux/arm64 --user $UID_APP:$UID_APP --cap-drop ALL --security-opt no-new-privileges \
    --cpus "${SIM_CPUS:-6}" --memory "${SIM_MEM:-12g}" --shm-size 1g \
    -v $MNT/app:$APP -v "$A:/android:ro" -v "$A/out/sim-shots:/shots" ${SIM_MOUNTS:-} -e ARCH_ROOT="${ARCH_ROOT:-0}" $IMAGE bash -s
}

case ${1:-help} in
  setup)
    tarball=${2:-$A/out/powos-rootfs.tar.gz}
    [ -f "$tarball" ] || { echo "no $tarball" >&2; exit 1; }
    mount_store
    rel=${tarball#$A/}
    sim <<EOF
set -e
mkdir -p $R $RUN
tar -xzf /android/$rel -C $R --no-same-owner --no-same-permissions --delay-directory-restore 2>&1 | grep -v 'Cannot mknod' | head -20 || true
chmod -R u+rwX $R 2>/dev/null || true
gcc -O2 -o $APP/files/lotfix-run /android/out/work/andromarchy/native/launcher/lotfix-run.c
echo "rootfs: \$(du -sh $R | cut -f1)"
EOF
    # The app runs first-boot.sh once, through the launcher (SessionService), before the first session.
    ARCH_ROOT=1 "$0" run '/opt/lotfix/first-boot.sh' 2>&1 | tail -5 || true
    # Lab only: lavapipe, since there is no KGSL here. Outside the rootfs's own Mesa (its ICD list is untouched).
    docker run --rm -v $MNT/app:$APP menci/archlinuxarm:latest bash -c "
      set -e
      grep -q '^DisableSandbox' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
      pacman-key --init >/dev/null 2>&1; pacman-key --populate archlinuxarm >/dev/null 2>&1
      mkdir -p /tmp/c && pacman -Syw --noconfirm --cachedir /tmp/c vulkan-swrast >/dev/null
      mkdir -p /tmp/x $R/opt/powos-lab && bsdtar -xf \$(ls /tmp/c/vulkan-swrast-*.pkg.tar.* | grep -v sig\$) -C /tmp/x
      cp /tmp/x/usr/lib/libvulkan_lvp.so $R/opt/powos-lab/
      sed 's|\"library_path\": *\"[^\"]*\"|\"library_path\": \"/opt/powos-lab/libvulkan_lvp.so\"|' /tmp/x/usr/share/vulkan/icd.d/lvp_icd*.json > $R/opt/powos-lab/lvp_icd.json
      chown -R $UID_APP:$UID_APP $R/opt/powos-lab"
    echo "phone-sim ready"
    ;;
  run)
    shift
    mount_store
    cmd=$*
    # The app's environment (SessionService.archEnv) + an X server on the host side + lavapipe.
    sim <<EOF
export ARCH_ROOTFS=$R XDG_RUNTIME_DIR=$RUN ARCH_EXCLUDE_EXTRA=$RUN:/tmp/.X11-unix TZ=UTC LANG=C.UTF-8
export DBUS_SESSION_BUS_ADDRESS=unix:path=$RUN/bus HOME=/root
Xvfb :1 -screen 0 1280x720x24 -nolisten tcp +extension GLX >/dev/null 2>&1 &
for i in \$(seq 50); do [ -S /tmp/.X11-unix/X1 ] && break; sleep 0.1; done
export DISPLAY=:1 VK_ICD_FILENAMES=/opt/powos-lab/lvp_icd.json POWOS_SIM=1
# SIM_PRE: host-side commands first (e.g. copying test files from /android into \$ARCH_ROOTFS).
${SIM_PRE:-}
# Rosetta watch: Colima registers it for x86 binaries; on the phone nothing would. Any hit means an x86 exec
# bypassed android-compat's hook (and would fail on the phone).
( while sleep 1; do grep -l -i rosetta /proc/[0-9]*/maps 2>/dev/null; done | sort -u > /tmp/rosetta.txt ) &
# No KGSL here: the session launcher's own fallback (session/Hyprland) for every program, llvmpipe.
$APP/files/lotfix-run -c $(printf %q "unset MESA_LOADER_DRIVER_OVERRIDE TURNIP_KMD FD_FORCE_KGSL XWAYLAND_FORCE_KGSL_SURFACELESS; export GALLIUM_DRIVER=llvmpipe LIBGL_ALWAYS_SOFTWARE=1; $cmd")
rc=\$?
# SIM_SHOT=<name>.png: a screenshot of the simulated display afterwards, to out/sim-shots/.
[ -n "${SIM_SHOT:-}" ] && xwd -root -display :1 -silent | magick xwd:- "/shots/${SIM_SHOT:-}"
[ -s /tmp/rosetta.txt ] && echo "phone-sim: WARNING rosetta ran x86 code: \$(cat /tmp/rosetta.txt | tr '\n' ' ')" >&2
exit \$rc
EOF
    ;;
  umount) colima ssh -- sudo umount $MNT ;;
  rm) mounted && colima ssh -- sudo umount $MNT; rm -f "$IMG" ;;
  *) sed -n '2,20p' "$0" ;;
esac
