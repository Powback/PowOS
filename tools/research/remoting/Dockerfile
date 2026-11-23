# Remoting measurements (docs/research/native-window-remoting.md "Measurements"): one image for both ends.
# comp = headless sway (the "phone" compositor) + waypipe client; app = waypipe server + Firefox/Kate/Dolphin.
# Built and run on .58 only (tools/research/remoting/*.sh use the pow58 Docker context). Nothing on any host.
# waypipe 0.11.3 only video-encodes DMABUFs in opaque formats (src/video.rs supports_video_format: Xrgb8888, Xbgr8888,
# 565, 2101010, 16161616), and Firefox's toplevel is ARGB8888 even with widget.transparent-windows=false (measured), so
# stock `--video` never engages for Firefox. waypipe-argbvideo = the same release with Argb8888/Abgr8888 added to that
# list (alpha dropped; the window is opaque anyway): the size of the patch is doc §7 question 2.
FROM docker.io/library/archlinux:latest AS wpbuild
RUN pacman -Syu --noconfirm --needed rust rust-bindgen clang shaderc ffmpeg vulkan-headers lz4 zstd mesa pkgconf git curl patch
RUN curl -fsSL https://gitlab.freedesktop.org/mstoeckl/waypipe/-/archive/v0.11.3/waypipe-v0.11.3.tar.gz | tar xz -C /tmp
COPY waypipe-argb-video.patch /tmp/
RUN cd /tmp/waypipe-v0.11.3 && patch -p1 < /tmp/waypipe-argb-video.patch && cargo build --release --locked \
 && cp target/release/waypipe /waypipe-argbvideo

FROM docker.io/library/archlinux:latest
RUN pacman -Syu --noconfirm --needed sway waypipe wtype firefox kate dolphin breeze-icons qt6-wayland \
      ttf-dejavu noto-fonts socat iproute2 iputils procps-ng criu tmux vim python python-numpy jq curl \
      mesa vulkan-radeon vulkan-tools libva-utils ffmpeg wayland-utils strace psmisc grim \
 && pacman -Scc --noconfirm && rm -rf /var/cache/pacman/pkg/*
# The long page the scroll/typing tests use: Wikipedia's "Linux" article, styles+images still from Wikipedia
# (base href), plus a textarea and a key-driven scroller (page.js: F8 = scroll 12 px/frame for 10 s, F9 = stop).
RUN mkdir -p /srv/page && curl -fsSL -A 'powos-research/1.0' https://en.wikipedia.org/wiki/Linux -o /srv/page/raw.html
COPY page.js /srv/page/page.js
RUN python - <<'PY'
import re
h = open('/srv/page/raw.html', encoding='utf-8').read()
h = h.replace('<head>', '<head><base href="https://en.wikipedia.org/wiki/Linux">', 1)
# Wikipedia's pulsating onboarding dot repaints 128x64 px at the output rate forever (measured: 124 fps, 44 KB/s
# over lossless waypipe while "idle"); hidden so idle/typing commits come only from the test's own input.
inj = '<style>.mw-pulsating-dot{display:none!important}</style>' \
      '<textarea id="ta" rows="3" cols="80" style="position:sticky;top:0;z-index:9;font-size:18px"></textarea>' \
      '<script>' + open('/srv/page/page.js').read() + '</script>'
h = re.sub(r'(<body[^>]*>)', lambda m: m.group(1) + inj, h, count=1)
open('/srv/page/index.html', 'w', encoding='utf-8').write(h)
PY
# Kate and Dolphin refuse to run as root: every app (and sway, waypipe) runs as u; only tc/CRIU need root.
RUN useradd -m -u 1000 u && setcap -r /usr/bin/sway  # sway ships cap_sys_nice+ep; exec fails without it in the bounding set
COPY --from=wpbuild /waypipe-argbvideo /usr/local/bin/waypipe-argbvideo
COPY bin/ /opt/rm/
RUN chmod +x /opt/rm/*
ENV XDG_RUNTIME_DIR=/tmp/xdg PATH=/opt/rm:$PATH
CMD ["sleep", "infinity"]
