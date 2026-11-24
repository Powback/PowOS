# Shared by the in-container scripts. MODE = how the app reaches the compositor:
#   local     app is a direct client of sway (no waypipe) - the app's own baseline
#   shm       waypipe --no-gpu (shm buffers, lossless lz4 diffs)
#   gpu       waypipe default (DMA-BUF via Vulkan, lossless lz4 diffs)
#   video-stock  stock waypipe --video=h264 (0.11.3 picks the hw encoder when Vulkan video encode exists; no CLI
#                switch for sw) - only opaque DMABUF formats get video, see the Dockerfile
#   video     waypipe-argbvideo --video=h264 (the same release + ARGB8888/ABGR8888 accepted for video)
# shellcheck shell=sh
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p -m 700 "$XDG_RUNTIME_DIR" /tmp/run 2>/dev/null || true
wp_opts() {
  case "$1" in
    shm) echo "--no-gpu" ;;
    gpu|local) echo "" ;;
    video-stock|video) echo "--video=h264" ;;
    *) echo "bad mode $1" >&2; exit 2 ;;
  esac
}
wp_bin() { [ "$1" = video ] && echo waypipe-argbvideo || echo waypipe; }
# app_cmd APP: the app's command line (as user u)
app_cmd() {
  case "$1" in
    firefox)
      rm -rf /tmp/ffprof; mkdir -p /tmp/ffprof
      cat > /tmp/ffprof/user.js <<'J'
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("trailhead.firstrun.didSeeAboutWelcome", true);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("app.update.auto", false);
user_pref("ui.caretBlinkTime", 0);
user_pref("widget.transparent-windows", false);
J
      echo "env MOZ_ENABLE_WAYLAND=1 firefox --no-remote --profile /tmp/ffprof --new-instance ${PAGE:-file:///srv/page/index.html}" ;;
    # Kate on a 2.7k-line Python file (syntax highlighting on). On the 1 MB minified Wikipedia HTML Kate itself took
    # ~230 ms p50 per key even locally (measured 2026-11-23), which measured Kate, not the transport.
    kate) cp "$(python3 -c 'import argparse; print(argparse.__file__)')" /tmp/kate-test.py
          echo "env QT_QPA_PLATFORM=wayland kate -n /tmp/kate-test.py" ;;
    dolphin) echo "env QT_QPA_PLATFORM=wayland dolphin /usr/share/icons/breeze/actions/22" ;;
    *) echo "bad app $1" >&2; exit 2 ;;
  esac
}
