#!/bin/bash
# Phone test for PowOS on Android (Windows games through Proton): adb from a container, results under
# targets/android/out/device-test/<time>/. Nothing runs on the Mac host itself.
#
#   tools/device-test.sh pair <host:port> <code>     Wireless debugging: "Pair device with pairing code"
#   tools/device-test.sh connect <host:port>         Wireless debugging: the IP address & port on its main screen
#   tools/device-test.sh info                        device, Android, SoC, app installed, run-as
#   tools/device-test.sh push-rootfs                 the README's install step (then the app's first-launch form)
#   tools/device-test.sh wait-session                until PowOS's session answers (powos-devtest-agent)
#   tools/device-test.sh run <script.sh>             run a script inside the PowOS session, print its output
#   tools/device-test.sh test [--box64] [--steam] [--exe <url-or-phone-path>]   the suite below, logs collected
#   tools/device-test.sh stop                        stop this tool's adb container
#
# Suite: (1) powos-probe: syscalls Wine/Proton need under Android's app seccomp, dma-buf heap access (zero-copy);
# (2) GPU/WSI: vulkaninfo, linux-dmabuf in KWin, DRI3 in Xwayland, vkcube's buffer path (dmabuf vs wl_shm) and fps
# on Wayland / X11 / forced CPU copy; (3) powos-play + GE-Proton aarch64: d3d9/d3d11 test programs (x86_64, i686,
# arm64) with DXVK HUD + MangoHud logs, X11 and Wayland; (4) cpubench across the x86 paths (bench.sh);
# (5) --steam: Steam's bootstrap under box64 with the no-runtime workarounds, logs + screenshot;
# (6) --exe: a Windows program of your choice through powos-play (zip/exe URL or a path on the phone).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
A=$(cd "$HERE/.." && pwd)
C=powos-phone-adb
# Own adb server port: other containers on this Docker VM run adb servers on the default 5037.
ADB_PORT=5137 FWD_PORT=7357

if [ "${POWOS_IN_ADB_CONTAINER:-0}" != 1 ]; then
  # ── Mac side: make sure the adb container runs, then re-run this script inside it ──────────────────────
  if ! docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null | grep -q true; then
    docker rm -f "$C" >/dev/null 2>&1 || true
    docker build -q -t powos-phone-adb - >/dev/null <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache android-tools python3 bash coreutils
EOF
    # Host network: the Colima VM is bridged on the LAN (192.168.50.100), so wireless adb reaches the phone.
    docker run -d --name "$C" --network host --cpus 1 --memory 1g -e POWOS_IN_ADB_CONTAINER=1 \
      -e ADB_SERVER_SOCKET=tcp:127.0.0.1:$ADB_PORT -v powos-phone-adb-keys:/root/.android \
      -v "$A:/android" powos-phone-adb sleep infinity >/dev/null
  fi
  [ "${1:-}" = stop ] && { docker rm -f "$C" >/dev/null; echo stopped; exit 0; }
  if [ "${1:-}" = test ]; then
    # Payloads: the probe, built for the rootfs's glibc in an Arch Linux ARM container; the Windows test programs.
    [ -x "$A/out/probe/powos-probe" ] || docker run --rm --platform linux/arm64 -v "$A:/a" menci/archlinuxarm:latest bash -c \
      'pacman -Sy --noconfirm --needed gcc >/dev/null 2>&1; mkdir -p /a/out/probe && gcc -O2 -o /a/out/probe/powos-probe /a/tools/probe/powos-probe.c'
    [ -f "$A/out/wintest/x86_64/d3d11tri.exe" ] || "$HERE/wintest/build.sh"
  fi
  exec docker exec -i "$C" bash /android/tools/device-test.sh "$@"
fi

# ── Container side ─────────────────────────────────────────────────────────────────────────────────────────
PKG=andro.marchy
adb start-server >/dev/null 2>&1 || true
need_device() { [ "$(adb devices | awk 'NR>1 && $2=="device"' | wc -l)" -ge 1 ] || { echo "no device: pair/connect first" >&2; exit 1; }; }

# Runs stdin as a bash script inside the PowOS session (through powos-devtest-agent); output to stdout.
agent() {
  adb forward tcp:$FWD_PORT localabstract:powos-devtest >/dev/null
  python3 -c '
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=30)
s.sendall(sys.stdin.buffer.read()); s.shutdown(socket.SHUT_WR); s.settimeout(None)
rc = 1
for line in s.makefile("rb"):
    if line.startswith(b"__EXIT "): rc = int(line.split()[1]); continue
    sys.stdout.buffer.write(line); sys.stdout.flush()
sys.exit(rc)' $FWD_PORT
}

# A local file as a here-document that recreates it inside the session (no storage permission needed).
embed() { # <local file> <path in session> [mode]
  echo "mkdir -p \"\$(dirname '$2')\"; base64 -d > '$2' <<'__B64__'"
  base64 "$1"
  echo "__B64__"
  echo "chmod ${3:-644} '$2'"
}

case ${1:-help} in
  pair) adb pair "$2" "$3" ;;
  connect) adb connect "$2"; adb devices -l ;;
  devices) adb devices -l ;;
  info)
    need_device
    for p in ro.product.model ro.build.version.release ro.build.version.sdk ro.soc.model ro.hardware ro.build.version.security_patch; do
      printf '%-32s %s\n' "$p" "$(adb shell getprop $p | tr -d '\r')"
    done
    printf '%-32s %s\n' "app ($PKG)" "$(adb shell pm path $PKG 2>/dev/null | tr -d '\r' || echo 'not installed')"
    printf '%-32s %s\n' "run-as $PKG" "$(adb shell run-as $PKG id 2>&1 | tr -d '\r' | head -1)"
    printf '%-32s %s\n' "child process restrictions" "$(adb shell settings get global settings_enable_monitor_phantom_procs 2>/dev/null | tr -d '\r')"
    printf '%-32s %s\n' "storage free (/sdcard)" "$(adb shell df -h /sdcard | tail -1 | tr -s ' ' | cut -d' ' -f4)"
    ;;
  push-rootfs)
    need_device
    f=/android/out/powos-rootfs.tar.gz
    [ -f "$f" ] || { echo "no $f: build-rootfs.sh first" >&2; exit 1; }
    d=/sdcard/Android/data/$PKG/files
    adb shell "mkdir -p $d" || { echo "open the app once first, back out at the form" >&2; exit 1; }
    adb push "$f" "$d/lotfix-rootfs.tar.gz"
    want=$(cut -d' ' -f1 "$f.sha256"); got=$(adb shell sha256sum "$d/lotfix-rootfs.tar.gz" | cut -d' ' -f1)
    [ "$want" = "$got" ] && echo "pushed, sha256 ok" || { echo "sha256 mismatch: $got != $want" >&2; exit 1; }
    # "Disable child process restrictions" (Andromarchy's requirement), the adb way.
    adb shell settings put global settings_enable_monitor_phantom_procs false || true
    echo "now open the app and go through its first-launch form; then: tools/device-test.sh wait-session"
    ;;
  wait-session)
    need_device
    for i in $(seq 120); do
      if echo 'echo ready $(cat /etc/powos/platform) $(uname -r)' | agent 2>/dev/null; then exit 0; fi
      sleep 5
    done
    echo "no answer from powos-devtest-agent after 10 min (is the PowOS desktop up?)" >&2; exit 1
    ;;
  run) need_device; agent < "$2" ;;
  test)
    need_device
    shift
    box64=0 steam=0 exe=
    while [ $# -gt 0 ]; do
      case $1 in --box64) box64=1; shift ;; --steam) steam=1; shift ;; --exe) exe=$2; shift 2 ;; *) echo "unknown $1" >&2; exit 1 ;; esac
    done
    R=/android/out/device-test/$(date +%Y%m%d-%H%M%S)
    mkdir -p "$R"
    echo "results: ${R#/android/}"
    [ -x /android/out/probe/powos-probe ] || { echo "missing out/probe/powos-probe (the Mac-side wrapper builds it)" >&2; exit 1; }
    "$0" info > "$R/device.txt" 2>&1 || true
    adb shell dumpsys SurfaceFlinger --display-id > "$R/displays.txt" 2>&1 || true

    echo "== 1. probe"
    { embed /android/out/probe/powos-probe /tmp/powos-probe 755; echo /tmp/powos-probe; } | agent | tee "$R/probe.txt"

    echo "== 2. GPU / presentation"
    agent > "$R/gpu.txt" 2>&1 <<'EOF' || true
set -x
env | grep -E '^(MESA|TURNIP|FD_|GALLIUM|VK_|WAYLAND|DISPLAY|XDG_SESSION|ANDROMARCHY)' | sort
ls -la /dev/kgsl-3d0 /dev/dma_heap 2>&1
vulkaninfo --summary 2>&1 | head -40
wayland-info 2>&1 | grep -A3 -E 'zwp_linux_dmabuf_v1|wp_linux_drm_syncobj|wp_presentation' | head -40
xdpyinfo 2>/dev/null | grep -E 'DRI3|Present|MIT-SHM' || echo "xdpyinfo: no X display ($DISPLAY)"
# Which buffer path vkcube's swapchain takes: zwp_linux_buffer_params_v1 = dma-buf (zero copy), wl_shm = CPU copy.
for mode in wayland wayland-sw xcb; do
  case $mode in
    wayland) envs="" wsi=wayland ;;
    wayland-sw) envs="MESA_VK_WSI_DEBUG=sw" wsi=wayland ;;
    xcb) envs="" wsi=xcb ;;
  esac
  echo "--- vkcube $mode"
  env $envs WAYLAND_DEBUG=client timeout 20 vkcube --wsi $wsi --c 600 > /tmp/vkcube-$mode.log 2>&1
  echo "exit $?"
  grep -c 'zwp_linux_buffer_params_v1@.*create' /tmp/vkcube-$mode.log | sed 's/^/dmabuf buffer creations: /'
  grep -c 'wl_shm_pool@.*create_buffer' /tmp/vkcube-$mode.log | sed 's/^/wl_shm buffer creations: /'
  grep -v '^\[' /tmp/vkcube-$mode.log | tail -5
done
# Frame rate with a CPU copy vs without: vkcube's own timing over 600 frames.
for mode in "" "MESA_VK_WSI_DEBUG=sw"; do
  s=$(date +%s.%N); env $mode timeout 60 vkcube --wsi wayland --c 600 >/dev/null 2>&1; e=$(date +%s.%N)
  awk -v s=$s -v e=$e -v m="${mode:-dmabuf}" 'BEGIN { printf "vkcube 600 frames (%s): %.1f fps\n", m, 600 / (e - s) }'
done
EOF
    grep -E "vkcube|buffer creations|deviceName|driverName|zwp_linux_dmabuf|DRI3" "$R/gpu.txt" | head -30

    echo "== 3. Proton (powos-play, GE-Proton aarch64): first run downloads ~600 MB on the phone"
    {
      for a in x86_64 i686 aarch64; do
        for t in d3d9tri d3d11tri cpubench; do embed /android/out/wintest/$a/$t.exe /tmp/wintest/$a/$t.exe; done
      done
      cat <<'EOF'
set +e
powos-play --install-proton >/dev/null || { echo "Proton download failed"; exit 1; }
powos-play --info /tmp/wintest/x86_64/d3d11tri.exe
export WINTEST_LOG=/tmp/wintest/results.txt; rm -f $WINTEST_LOG
for drv in x11 wayland; do
  w=; [ $drv = wayland ] && w=--wayland
  for t in x86_64/d3d11tri x86_64/d3d9tri i686/d3d11tri i686/d3d9tri aarch64/d3d11tri; do
    echo "== $drv $t" >> $WINTEST_LOG
    s=$(date +%s)
    timeout 300 powos-play $w --hud --log --prefix wintest /tmp/wintest/$t.exe 600 > /tmp/wintest/run.log 2>&1
    echo "exit $? after $(( $(date +%s) - s )) s" >> $WINTEST_LOG
    tail -3 /tmp/wintest/run.log >> $WINTEST_LOG
  done
done
cat $WINTEST_LOG
EOF
    } | agent | tee "$R/proton.txt" || true

    echo "== 4. cpubench"
    {
      embed /android/tools/lab/bench.sh /tmp/wintest/bench.sh 755
      cat <<EOF
export PROTON_A64=\$(ls -d ~/.local/share/powos/proton/*-aarch64 | sort -V | tail -1) DISPLAY=\${DISPLAY:-:0}
$( [ $box64 = 1 ] && echo 'export PROTON_X64=$(powos-play --install-proton "" x86_64)' )
/tmp/wintest/bench.sh /tmp/wintest /tmp/wintest/bench.txt
EOF
    } | agent | tee "$R/bench.txt" || true

    if [ $steam = 1 ]; then
      echo "== 5. Steam under box64 (no Steam Linux Runtime)"
      agent > "$R/steam.txt" 2>&1 <<'EOF' || true
set -x
powos-play --register-steam
# Steam's bootstrapper is 32-bit x86: the engine's exec hook hands it to box64 (BOX32). The client's web helper
# normally runs inside the Steam Runtime container (pressure-vessel -> bwrap): no namespaces here, so no CEF sandbox
# and no container. Bootstrap download is ~300 MB.
export STEAM_RUNTIME=1 STEAMOS=1 BOX64_LOG=1 STEAM_DISABLE_ZINK=1
(timeout 900 steam -no-cef-sandbox -noverifyfiles > /tmp/steam-console.log 2>&1 &)
for i in $(seq 90); do sleep 10; pgrep -fa 'steamwebhelper|ubuntu12_32/steam' | head -3; tail -1 /tmp/steam-console.log; done
tail -100 /tmp/steam-console.log
ls ~/.local/share/Steam/logs/ 2>&1; tail -30 ~/.local/share/Steam/logs/bootstrap_log.txt ~/.local/share/Steam/logs/webhelper.txt 2>&1
EOF
      adb exec-out screencap -p > "$R/steam-screen.png" || true
      tail -40 "$R/steam.txt"
    fi

    if [ -n "$exe" ]; then
      echo "== 6. $exe"
      agent > "$R/exe.txt" 2>&1 <<EOF || true
set -x
f='$exe'
case \$f in
  http*) mkdir -p ~/Games/devtest && cd ~/Games/devtest && curl -fLO "\$f" && f=~/Games/devtest/\$(basename "\$f")
         case \$f in *.zip) bsdtar -xf "\$f" && f=\$(find ~/Games/devtest -iname '*.exe' | head -1) ;; esac ;;
esac
timeout 600 powos-play --hud --log "\$f"
echo "exit \$?"
EOF
      adb exec-out screencap -p > "$R/exe-screen.png" || true
      tail -20 "$R/exe.txt"
    fi

    echo "== logs"
    agent 2>/dev/null <<'EOF' | base64 -d > "$R/session-logs.tar.gz" || true
tar -czf - -C / $(cd / && ls -d root/.local/state/powos/play tmp/wintest/run.log "${XDG_RUNTIME_DIR#/}"/powos-*.log usr/share/powos/phone-report.txt 2>/dev/null) 2>/dev/null | base64
EOF
    adb logcat -d -t 2000 > "$R/logcat.txt" 2>&1 || true
    ls -la "$R"
    ;;
  *) sed -n '2,20p' "$0" ;;
esac
