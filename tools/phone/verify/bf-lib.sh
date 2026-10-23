# bf-lib.sh: (sourced in the PowOS session as powos by bf-resume-phone.sh and bf-launchpaths-phone.sh) Broforce's
# launch / freeze / resume as checked steps. Each step says what it does on the verify status pill, asserts that it
# happened (the game's X window mapped + KWin's task, Steam's sleep cgroup frozen with the game's tasks in it and not
# running, new frames after the resume) and prints "FAIL <step>: <evidence>" otherwise. A touch: what this check
# started is closed, exit 3 (the queue retries in the next window).
# Mac side (bf-pacing.sh, bf-run.sh, bf-checker.sh, bf-fold.sh): `BF_ADB=<tools/phone/adb.sh> . bf-lib.sh` defines
# only pill <text>: the same step file, written over adb as the session user (at most 15 s), and the log line.
if [ -n "${BF_ADB:-}" ]; then
  # `BF_ADB=$A . bf-lib.sh` sets BF_ADB only while this file is sourced: kept for pill(), which runs later (under
  # set -u, "BF_ADB: unbound variable" failed every bf-pacing/bf-checker/bf-fold job, 2026-10-23 05:02).
  BF_ADB_PATH=$BF_ADB
  pill() { local b; b=$(printf '%s\n' "$1" | base64 | tr -d '\n')
    perl -e 'alarm shift; exec @ARGV' 15 "$BF_ADB_PATH" shell "su -c 'sh /data/powos/powos-run.sh \"umask 022; echo $b | base64 -d > /tmp/powos-verify-step\"'" >/dev/null 2>&1
    echo "-- $(date +%T) $1"; }
  return 0
fi
# APP / GAME / WIN_NAME: the game under test - any Steam app id (default 274190, Broforce, the test case); GAME =
# Steam's name for it (appmanifest), WIN_NAME = its X window's name (default GAME). td-launch-phone.sh sets Teardown's.
steam_field() {  # steam_field <appid> <name|installdir>: from Steam's appmanifest (any library folder)
  local S=$HOME/.local/share/Steam f
  for f in "$S/steamapps/appmanifest_$1.acf" $(sed -nE 's/^\s*"path"\s*"(.*)"/\1/p' "$S/steamapps/libraryfolders.vdf" 2>/dev/null | sed "s|\$|/steamapps/appmanifest_$1.acf|"); do
    [ -f "$f" ] && { sed -nE "s/^\s*\"$2\"\s*\"(.*)\"/\1/p" "$f" | head -1; return; }; done; }
APP=${APP:-274190}
GAME=${GAME:-$(steam_field "$APP" name)}; GAME=${GAME:-app $APP}
WIN_NAME=${WIN_NAME:-$GAME} GLOG=/run/powos-app/powos-sleep-gui.log
export APP
RESUME_MS=${RESUME_MS:-3000}  # resume -> the game's first new frame, at most
LAUNCH_S=${LAUNCH_S:-360}     # a cold start's window (Steam + Proton under FEX), at most
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/powos-app} DISPLAY=${DISPLAY:-:0}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
XAUTHORITY=$(tr '\0' '\n' < "/proc/$(pgrep -x Xwayland | head -1)/cmdline" | grep -A1 -x -- -auth | tail -1); export XAUTHORITY
T=$(mktemp -d /tmp/bf-check.XXXX)
mine=0 FAILS=""
now() { date +%s.%N; }
ms() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%d", (b - a) * 1000}'; }
irq() { awk '/touch-0/{s+=$2+$3+$4+$5+$6+$7+$8+$9} END{print s}' /proc/interrupts; }
I0=$(irq)
close_mine() { eval "${ON_CLOSE:-:}";  # eval: ON_CLOSE="fexcache_off; restore" ran as one word ("command not found"), restore never ran
  [ $mine = 1 ] && { pill "closing $GAME (this check started it)"; echo "== closing what this check started"; bash /var/tmp/powos-bf-stop.sh | head -1; mine=0; }; rm -rf "$T" /tmp/powos-verify-step; }
touched() { [ "$(irq)" != "$I0" ] || return 1; echo "user input $(date +%T) - stopping"; close_mine; exit 3; }
trap 'echo "stopped from outside $(date +%T)"; close_mine; exit 3' HUP TERM INT
fail() { echo "FAIL $1: $2"; FAILS="$FAILS $1"; }

# pill <text>: the check's current sub-step while the queue runs it: the runner's heartbeat shows
# /tmp/powos-verify-step under the check's name with its age ("waiting for the game window · 45 s", queue.sh put);
# the pill's file is rewritten now too (its "prev" line = the step, "step"/"stepel" for newer APKs).
pill() {
  printf '%s\n' "$1" > /tmp/powos-verify-step
  python3 - "$1" <<'PY' 2>/dev/null
import json, os, sys
for p in ("/run/powos-app/verify/status.json", "/run/powos-app/verify-status.json"):
    try:
        s = json.load(open(p))
    except (OSError, ValueError):
        continue
    if s.get("done") or "task" not in s:
        continue
    s["prev"] = sys.argv[1] + " · 0 s"
    s["step"], s["stepel"] = sys.argv[1], 0
    t = p + ".bf"
    with open(t, "w") as f:
        json.dump(s, f)
    os.chmod(t, 0o644)
    os.replace(t, p)
PY
  echo "-- $(date +%T) $1"
}

steam_pid() { cat ~/.steam/steam.pid 2>/dev/null; }
under() { local a=$1; while [ -n "$a" ] && [ "$a" -gt 1 ]; do [ "$a" = "$2" ] && return 0; a=$(awk '{print $4}' "/proc/$a/stat" 2>/dev/null); done; return 1; }
# The game's own launch chain. A Steam launch first runs the game's install script evaluator through the same reaper
# (`SteamLaunch AppId=<id> Install=1`, Proton `run iscriptevaluator.exe`): that one is iscript_reapers, never the game's
# (bf-coldstart took its pressure-vessel / wineserver for the game's, 2026-10-23).
reapers() { local p; for p in $(pgrep -f "SteamLaunch AppId=$APP( |\$)"); do grep -qa 'Install=1' "/proc/$p/cmdline" 2>/dev/null || echo "$p"; done; }
iscript_reapers() { pgrep -f "SteamLaunch AppId=$APP Install=1"; }
reaper() { local p; for p in $(reapers); do under "$p" "$(steam_pid)" && { echo "$p"; return; }; done; }  # Steam's own
tree() { local t=("$1") o=() p; while ((${#t[@]})); do p=${t[0]}; t=("${t[@]:1}"); [ -n "$p" ] && o+=("$p") && t+=($(pgrep -P "$p")); done; echo "${o[*]}"; }
ticks() { local n=0 p f; for p in "$@"; do f=$(cat "/proc/$p/stat" 2>/dev/null) || continue; f=${f##*) }; set -- $f; n=$((n + ${12} + ${13})); done; echo "$n"; }
# gamewin: the game's X window - the one named WIN_NAME, else one whose name starts with "WIN_NAME " (games that put
# their build in the title: Noita's "Noita - Build Aug 12 2024 - ..." under Steam's name "Noita").
gamewin() { xwininfo -root -tree 2>/dev/null | awk -v n="\"$WIN_NAME\"" -v p="\"$WIN_NAME " '
  /has no name/ {next} index($0, n) {print $1; f = 1; exit} !q && index($0, p) {q = $1} END {if (!f && q) print q}' | grep . \
  || xdotool search --onlyvisible --class "^steam_app_$APP\$" 2>/dev/null | head -1 | awk '{printf "0x%x\n", $1}'; }
# (else Proton's class steam_app_<id>: a game whose title isn't its Steam name at all, e.g. ABZU's "AbzuGame")
mapped() { xwininfo -id "$1" 2>/dev/null | awk '/Map State/ {print $3}'; }
active() { printf '%d' "$(xprop -root _NET_ACTIVE_WINDOW 2>/dev/null | awk '{print $NF}')" 2>/dev/null; }
# cg2 <pid>: its cgroup v2 path (the "0::" line: since the 02:07 boot /proc/<pid>/cgroup also lists v1 hierarchies -
# freezer, memory:/apps, cpuset, cpu, blkio - and the whole file read as the path made every freeze look missing:
# bf-resume "FAIL freeze-auto" 02:58 while powos-sleep-gui had frozen Steam at 02:56:50).
cg2() { sed -n 's/^0:://p' "/proc/$1/cgroup" 2>/dev/null; }
cg() { local c; c=$(cg2 "$(steam_pid)"); case $c in */powos/sleep/*) echo "/sys/fs/cgroup$c" ;; esac; }
watcher() { grep -i "steam\|app $APP" "$GLOG" | tail -${1:-2} | cut -c1-200 | tr '\n' '|'; }
# Frames of an X window: Xlib's XGetImage from python3 + ctypes. Not ffmpeg's x11grab: FFmpeg 9 only grabs through
# MIT-SHM, and Android's kernel has no System V shared memory - "Could not get shared memory buffer" / "Error during
# demuxing: Permission denied", no frame ever (every bf-coldstart "frame -", bf-checker's grabs, bf-fold's "changes",
# 2026-10-23; FFmpeg 8 still fell back to plain GetImage). A sample = 16 rows of the window, every 64th pixel.
#   xframes first <window name> <s>        epoch s of the named window's first drawn frame (looked up again each sample:
#                                          Unity maps a 314x208 window, then goes full screen): a sample that isn't flat
#                                          (brightest - darkest > 24) or differs from the window's first sample
#   xframes change <window id> <s> <fps>   epoch s of the first sample that differs from the first one
#   xframes count <window id> <s> <fps>    the number of distinct samples in <s> s (1 = a still window, 0 = none)
#   xframes grab <window name> <s> <dir>   whole frames as PNG for <s> s, 1 a second: <dir>/h%03d.png half size (every
#                                          2nd pixel, as bf-checker.py scores), f<n>.png full size every 10 s, a line
#                                          "<n> <time> <window> <WxH>" per 10 s in <dir>/grab.log, "done" at the end
# "none" when nothing came in <s>. The time is the sample's start (a sample takes a few ms; a whole frame ~0.2 s).
xframes() { python3 - "$@" <<'PY'
import ctypes as C, sys, time
X = C.CDLL("libX11.so.6")
X.XOpenDisplay.restype = C.c_void_p; X.XOpenDisplay.argtypes = [C.c_char_p]
X.XDefaultRootWindow.restype = C.c_ulong; X.XDefaultRootWindow.argtypes = [C.c_void_p]
X.XQueryTree.argtypes = [C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong), C.POINTER(C.c_ulong), C.POINTER(C.POINTER(C.c_ulong)), C.POINTER(C.c_uint)]
X.XFetchName.argtypes = [C.c_void_p, C.c_ulong, C.POINTER(C.c_char_p)]
X.XFree.argtypes = [C.c_void_p]
X.XGetImage.restype = C.c_void_p
X.XGetImage.argtypes = [C.c_void_p, C.c_ulong, C.c_int, C.c_int, C.c_uint, C.c_uint, C.c_ulong, C.c_int]
class Attr(C.Structure):
    _fields_ = [(n, C.c_int) for n in ("x", "y", "width", "height", "border_width", "depth")] + [("visual", C.c_void_p),
        ("root", C.c_ulong), ("cls", C.c_int), ("bit_gravity", C.c_int), ("win_gravity", C.c_int), ("backing_store", C.c_int),
        ("backing_planes", C.c_ulong), ("backing_pixel", C.c_ulong), ("save_under", C.c_int), ("colormap", C.c_ulong),
        ("map_installed", C.c_int), ("map_state", C.c_int), ("all_event_masks", C.c_long), ("your_event_mask", C.c_long),
        ("do_not_propagate_mask", C.c_long), ("override_redirect", C.c_int), ("screen", C.c_void_p)]
class Img(C.Structure):
    _fields_ = [("width", C.c_int), ("height", C.c_int), ("xoffset", C.c_int), ("format", C.c_int), ("data", C.c_void_p),
        ("byte_order", C.c_int), ("bitmap_unit", C.c_int), ("bitmap_bit_order", C.c_int), ("bitmap_pad", C.c_int),
        ("depth", C.c_int), ("bytes_per_line", C.c_int), ("bits_per_pixel", C.c_int)]
X.XGetWindowAttributes.argtypes = [C.c_void_p, C.c_ulong, C.POINTER(Attr)]
ERR = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_void_p)(lambda d, e: 0)  # a window gone or resized mid-sample: no exit
X.XSetErrorHandler(ERR)
d = X.XOpenDisplay(None)
if not d:
    print("none", end=""); sys.exit()
def find(w, name, out):  # every window of that name (Proton also has unmapped ones: "Steam" 400x300)
    n = C.c_char_p()
    if X.XFetchName(d, w, C.byref(n)) and n.value is not None:
        if n.value == name or n.value.startswith(name + b" "):  # gamewin's rule: the name, or "<name> ..."
            out.append(w)
        X.XFree(n)
    r, p, k, c = C.c_ulong(), C.c_ulong(), C.POINTER(C.c_ulong)(), C.c_uint()
    if not X.XQueryTree(d, w, C.byref(r), C.byref(p), C.byref(k), C.byref(c)):
        return out
    kids = [k[i] for i in range(c.value)]
    if c.value:
        X.XFree(k)
    for kid in kids:
        find(kid, name, out)
    return out
def sample(w):
    a = Attr()
    if not X.XGetWindowAttributes(d, w, C.byref(a)) or a.map_state != 2 or a.width < 1 or a.height < 1:
        return None
    px = []
    for i in range(16):
        p = X.XGetImage(d, w, 0, a.height * (2 * i + 1) // 32, a.width, 1, 0xFFFFFFFF, 2)  # ZPixmap
        if not p:
            return None
        im = Img.from_address(p)
        if im.bits_per_pixel == 32:
            row = C.string_at(im.data, im.bytes_per_line)
            px += [(row[x] + row[x + 1] + row[x + 2]) // 3 for x in range(0, a.width * 4, 256)]
        X.XFree(im.data); X.XFree(p)
    return px or None
def frame(w, step):  # the whole window, every <step>th pixel and row, as RGB rows (PNG filter byte 0 each)
    a = Attr()
    if not X.XGetWindowAttributes(d, w, C.byref(a)) or a.map_state != 2 or a.width < 1 or a.height < 1:
        return None
    p = X.XGetImage(d, w, 0, 0, a.width, a.height, 0xFFFFFFFF, 2)
    if not p:
        return None
    im = Img.from_address(p)
    if im.bits_per_pixel != 32:
        X.XFree(im.data); X.XFree(p); return None
    buf = C.string_at(im.data, im.bytes_per_line * a.height)
    X.XFree(im.data); X.XFree(p)
    W = (a.width + step - 1) // step
    out = bytearray()
    for y in range(0, a.height, step):
        r = buf[y * im.bytes_per_line:y * im.bytes_per_line + a.width * 4]
        row = bytearray(W * 3)
        row[0::3], row[1::3], row[2::3] = r[2::4 * step], r[1::4 * step], r[0::4 * step]  # BGRX -> RGB
        out += b"\0" + row
    return W, (a.height + step - 1) // step, bytes(out), a.width, a.height
def png(path, f):
    import struct, zlib
    W, H, raw = f[0], f[1], f[2]
    def chunk(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xFFFFFFFF)
    with open(path, "wb") as o:
        o.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 1)) + chunk(b"IEND", b""))
mode, end = sys.argv[1], time.time() + float(sys.argv[3])
if mode == "grab":
    import os
    out, n = sys.argv[4], 0
    os.makedirs(out, exist_ok=True)
    log = open(os.path.join(out, "grab.log"), "a")
    while time.time() < end:
        t = time.time()
        ws = find(X.XDefaultRootWindow(d), sys.argv[2].encode(), [])
        f = w = None
        for w in ws:
            f = frame(w, 2)
            if f:
                break
        if n % 10 == 0:
            log.write("%d %s %s %s\n" % (n // 10 + 1, time.strftime("%T"), hex(w) if f else "-", "%dx%d" % (f[3], f[4]) if f else "no window")); log.flush()
            if f:
                g = frame(w, 1)
                if g:
                    png(os.path.join(out, "f%d.png" % (n // 10 + 1)), g)
        if f:
            png(os.path.join(out, "h%03d.png" % n), f)
        n += 1
        time.sleep(max(0.0, 1.0 - (time.time() - t)))
    log.write("done\n"); sys.exit()
gap = 1.0 / float(sys.argv[4]) if len(sys.argv) > 4 else 0.1
w, first, seen = (0 if mode == "first" else int(sys.argv[2], 0)), None, set()
while time.time() < end:
    t = time.time()
    s = None
    for w in (find(X.XDefaultRootWindow(d), sys.argv[2].encode(), []) if mode == "first" else [w]):
        s = sample(w)  # the first mapped one
        if s:
            break
    if s and mode == "count":
        seen.add(tuple(s))
    elif s:
        if (mode == "first" and max(s) - min(s) > 24) or (first is not None and s != first):
            print("%.3f" % t, end=""); sys.exit()
        if first is None:
            first = s
    time.sleep(max(0.0, gap - (time.time() - t)))
print(len(seen) if mode == "count" else "none", end="")
PY
}
first_frame() { xframes first "$WIN_NAME" "$1"; }  # first_frame <s>: the game's first drawn frame (xframes first)
first_change() { xframes change "$1" "$2" "$3"; }  # first_change <window> <s> <fps>: its first new frame (xframes change)
open_task() {  # open_task <timeout s> <app id>: the drawer's / widget's launch path; its status line
  # POWOS_NO_LAUNCH_RECORD: the check records its own measured launches for the compat policy (bf-coldstart), not twice.
  # setsid: a Steam this launch starts (cold, or /usr/bin/steam's restart fallback) is the check's descendant
  # otherwise, in its session - the check then died silently at its close, no RESULT line (04:34 bf-coldstart, 06:32
  # bf-launchpaths: every step passed, then "FAIL run: no RESULT line"); a Steam started from the drawer isn't either.
  POWOS_NO_LAUNCH_RECORD=1 setsid -w timeout "$1" powos-open-task --app-id "$2" -- steam steam://rungameid/$APP >"$T/open.out" 2>&1 </dev/null
  grep -m1 '^powos-open-task:' "$T/open.out" || echo "no status line"; }

# A launch chain outside Steam's tree (left by a dead Steam) is never frozen nor resumed and holds Proton's prefix: gone.
clean_stale() {
  local p s=""; for p in $(reapers); do under "$p" "$(steam_pid)" || s="$s $p"; done
  [ -n "$s" ] || return 0
  echo "stale Broforce launch chain(s) outside Steam:$s - closing them"
  for p in $s; do kill -9 $(tree "$p") 2>/dev/null; done; sleep 2
}

# handoff_diag: why a running Steam didn't take a steam:// launch: its state, its threads' states + the main thread's
# wchan, its cgroup, steam.pipe's mtime (the URL was written into it then), the frozen sleep cgroups (a D-Bus / X peer
# it may wait on), powos-sleep-gui's last lines. One line. handoff_detail: the rest, as "handoff:" lines - what decides
# where the URL got stuck: bytes still unread in steam.pipe (>0 = the client never read it; 0 = read and dropped), the
# main thread's syscall + wakeups in 1 s (its loop runs ppoll 50 ms when healthy, ~20/s), the forwarder's output,
# the main thread's stack (gdb), and a second hand-off of the same URL (taken = the first write was lost, not the client).
handoff_diag() {
  local p; p=$(steam_pid)
  echo "steam $p $(awk '{print "state " $3}' "/proc/$p/stat" 2>/dev/null || echo gone) threads $(cat /proc/"$p"/task/*/stat 2>/dev/null | awk '{print $3}' | sort | uniq -c | tr -s ' \n' ' ')wchan $(cat "/proc/$p/wchan" 2>/dev/null) cgroup $(cut -d: -f3 "/proc/$p/cgroup" 2>/dev/null | tail -1) exe $(readlink "/proc/$p/exe" 2>/dev/null); pipe written $(date -r ~/.steam/steam.pipe +%T 2>/dev/null); frozen cgroups: $(for f in /sys/fs/cgroup/powos/sleep/*/cgroup.freeze; do [ "$(cat "$f" 2>/dev/null)" = 1 ] && printf '%s ' "$(basename "$(dirname "$f")")"; done); console_log last: $(tail -1 "$HOME/.local/share/Steam/logs/console_log.txt" | cut -c1-120); sleep-gui: $(tail -2 "$GLOG" | cut -c1-160 | tr '\n' '|')"; }
# hang_diag <pid>: where a started game that shows no window stands - thread states, each thread's syscall number
# (/proc/<pid>/task/*/syscall: 98 futex, 73 ppoll, 63 read, 101 nanosleep on arm64; "running" = busy), wchans, CPU s,
# the sockets/pipes/files it has open (an X/Pulse/D-Bus peer it waits on), the newest files it wrote under $HOME.
# For any game (native or Wine): a cheap "is it busy, waiting on someone, or stuck" before guessing.
hang_diag() {
  local x=$1 t
  [ -d "/proc/$x" ] || { echo "pid $x gone"; return; }
  printf 'pid %s %s cpu %ss threads' "$x" "$(tr '\0' ' ' < /proc/$x/cmdline | cut -c1-90)" "$(sed 's/.*) //' /proc/$x/stat | awk '{printf "%.1f", ($12+$13)/100}')"
  for t in /proc/$x/task/*; do printf '%s:%s/%s/%s\n' "$(cut -c1-12 $t/comm 2>/dev/null | tr ' ' _)" "$(sed 's/.*) //' $t/stat 2>/dev/null | cut -d' ' -f1)" \
    "$(cut -d' ' -f1 $t/syscall 2>/dev/null)" "$(cat $t/wchan 2>/dev/null)"; done | sort | uniq -c | sort -rn | awk '{printf " %s%s", $2, ($1 > 1 ? "x" $1 : "")}' | cut -c1-700
  printf '; fds:'; ls -l /proc/$x/fd 2>/dev/null | awk '{print $NF}' | sed -E 's/\[[0-9]+\]//' | sort | uniq -c | sort -rn | head -8 | awk '{printf " %s x%s", $2, $1}'
  printf '; wrote:'; find "$HOME" -xdev -newer /proc/$x -type f ! -path '*/Steam/logs/*' ! -path '*/.cache/*' 2>/dev/null | head -5 | tr '\n' ' '; echo
}
# sems: the sysvipc shim's semaphores (/dev/shm/y700-sysv/sem-<id>: key, change count, values) - Steam's hand-off
# signal is one of them (the client's first, value 0 while idle).
sems() { python3 - <<'PY' 2>/dev/null
import glob, struct
for f in sorted(glob.glob("/dev/shm/y700-sysv/sem-[0-9]*")):
    b = open(f, "rb").read()
    _, _, _, seq, rm, n, key, _ = struct.unpack("IIiIiiii", b[:32])
    v = [struct.unpack("iiii", b[64 + 16 * i:80 + 16 * i])[0] for i in range(min(n, 4))]
    print("%s key %#x seq %d val %s%s" % (f.rsplit("-", 1)[1], key & 0xffffffff, seq, v, " removed" if rm else ""), end="; ")
PY
}
handoff_detail() {
  local p n0 n1 cl0; p=$(steam_pid)
  echo "handoff: steam.pipe unread bytes $(python3 -c 'import os,fcntl,termios,struct,sys
fd=os.open(sys.argv[1],os.O_RDONLY|os.O_NONBLOCK); print(struct.unpack("i",fcntl.ioctl(fd,termios.FIONREAD,b"\0"*4))[0])' ~/.steam/steam.pipe 2>&1 | tail -1); held by $(for d in /proc/[0-9]*; do ls -l "$d/fd" 2>/dev/null | grep -q 'steam\.pipe' && printf '%s ' "${d#/proc/}"; done)"
  n0=$(awk '/^voluntary/ {print $2}' "/proc/$p/status" 2>/dev/null); sleep 1; n1=$(awk '/^voluntary/ {print $2}' "/proc/$p/status" 2>/dev/null)
  echo "handoff: main thread syscall '$(cut -d' ' -f1-3 "/proc/$p/syscall" 2>/dev/null)' wchan $(cat "/proc/$p/wchan" 2>/dev/null), $((${n1:-0} - ${n0:-0})) wakeups in 1 s; steam processes: $(pgrep -a -f 'steamrtarm64/steam|^\./steam' | cut -c1-70 | tr '\n' '|')"
  echo "handoff: forwarder said: $(grep -v 'LD_PRELOAD\|^$' "$T/open.out" 2>/dev/null | tail -4 | cut -c1-140 | tr '\n' '|')"
  # No gdb here any more: its PTRACE_ATTACH sends SIGSTOP, and on a client unified sleep froze meanwhile gdb never got
  # it, `timeout` killed gdb and the SIGSTOP stayed pending - delivered at the next thaw, Steam sat stopped (state T,
  # do_signal_stop) and the next check's launch failed on that (2026-10-23 04:40 -> 04:59). The stack it gave twice
  # (04:32, 05:00): main thread in poll() <- vgui2_s.so <- steamui.so, a healthy main loop.
  echo "handoff: semaphores before: $(sems)"
  cl0=$(wc -l < "$HOME/.local/share/Steam/logs/console_log.txt")
  # Y700_SYSV_DEBUG: the shim logs the forwarder's semget/semop (pkgs/steam's sysvipc-emu): does it post the client's?
  ( cd ~ && Y700_SYSV_DEBUG=1 timeout 20 steam "steam://rungameid/$APP" > "$T/retry.out" 2>&1 < /dev/null )
  echo "handoff: semaphores after the second hand-off: $(sems); forwarder's IPC: $(grep -a 'sysvipc-emu' "$T/retry.out" | sed 's/^\[sysvipc-emu [0-9]*\] //' | tail -8 | cut -c1-90 | tr '\n' '|')"
  for _ in $(seq 20); do tail -n +$((cl0 + 1)) "$HOME/.local/share/Steam/logs/console_log.txt" | grep -q "rungameid/$APP" && break; sleep 0.5; done
  echo "handoff: second hand-off (the same URL again): $(tail -n +$((cl0 + 1)) "$HOME/.local/share/Steam/logs/console_log.txt" | grep -q "rungameid/$APP" && echo "TAKEN" || echo "not taken either") - $(grep -v 'LD_PRELOAD\|^$' "$T/retry.out" | tail -2 | cut -c1-120 | tr '\n' '|')"
}

# step_launch: the game up through the drawer's path (a running one: brought up the same way). Sets W, LAUNCH.
# A Steam that runs (awake or frozen) logs the launch's URL at once ("ExecCommandLine ... steam://rungameid/<id>" in
# console_log): nothing in HANDOFF_S (20) = the launch was lost (2026-10-23 02:42: a -silent resident Steam took the
# URL into steam.pipe and never acted on it) - FAIL launch-handoff with handoff_diag, not a 6 min wait.
step_launch() {
  clean_stale
  local r t0 st e; r=$(reaper); W=$(gamewin)
  if [ -n "$r" ] && [ -z "$W" ] && [ "$(ps -o etimes= -p "$r" | tr -d ' ')" -gt 600 ]; then
    echo "a Broforce launch without a window for 10 min ($r) - closing it"; bash /var/tmp/powos-bf-stop.sh | tail -1; r=
  fi
  [ -z "$r" ] && mine=1
  pill "launching $GAME$([ -n "$r" ] && echo ' (already running)')"
  local CL=$HOME/.local/share/Steam/logs/console_log.txt cl0 up i
  cl0=$(wc -l < "$CL" 2>/dev/null || echo 0); up=$([ -z "$r" ] && [ -d "/proc/$(steam_pid)" ] && echo 1)
  t0=$(now)
  ( open_task $((LAUNCH_S + 10)) "steam_app_$APP" > "$T/open.status" ) &
  for i in $(seq $((LAUNCH_S * 2))); do W=$(gamewin); [ -n "$W" ] && [ "$(mapped "$W")" = IsViewable ] && break
    if [ "$up" = 1 ] && [ "$i" = $((${HANDOFF_S:-20} * 2)) ]; then
      if tail -n +$((cl0 + 1)) "$CL" 2>/dev/null | grep -q "steam://rungameid/$APP"; then up=; echo "launch: Steam took the URL"
      elif tail -n +$((cl0 + 1)) "$CL" 2>/dev/null | grep -q "Client version"; then up=; echo "launch: Steam restarted with the URL (/usr/bin/steam's fallback: $(grep '^steam: ' "$T/open.out" | tail -1))"
      else fail launch-handoff "the running Steam didn't log the launch's URL in ${HANDOFF_S:-20} s: $(handoff_diag); open-task: $(cat "$T/open.status" 2>/dev/null)"; handoff_detail; return 1; fi
    fi
    touched; sleep 0.5; done
  LAUNCH=$(ms "$t0" "$(now)")
  if [ -z "$W" ] || [ "$(mapped "$W")" != IsViewable ]; then
    fail launch "no mapped $WIN_NAME window ${LAUNCH} ms after the launch (window '${W:-none}' $(mapped "${W:-0}")); steam $(steam_pid) frozen '$(cg)', reaper '$(reaper)' $(tree "$(reaper)" | wc -w) processes, watcher: $(watcher 3)"
    return 1
  fi
  for _ in $(seq 60); do [ -s "$T/open.status" ] && break; touched; sleep 0.5; done
  st=$(cat "$T/open.status" 2>/dev/null)
  echo "launch: window $W mapped ${LAUNCH} ms after the launch, $st"
  [ "$st" = "powos-open-task: task" ] || fail launch "window $W is up but not shown as its own task: '${st:-still waiting}'"
  e=$(first_change "$W" 10 10)
  echo "launch: $([ "$e" = none ] && echo 'no new frame in 10 s (a still screen?)' || echo "drawing (a new frame $(ms "$t0" "$e") ms after the launch)")"
}

# freeze_ok: Steam's sleep cgroup frozen, every task of the game's chain in it, none of them running (prints evidence).
freeze_ok() {
  local c g n=0 in=0 p a b; c=$(cg); g=$(tree "$(reaper)")
  for p in $g; do n=$((n + 1)); [ "$(cg2 "$p")" = "${c#/sys/fs/cgroup}" ] && in=$((in + 1)); done
  a=$(ticks $g); sleep 2; b=$(ticks $g)
  EVID="cgroup ${c:-none}: cgroup.freeze=$(cat "$c/cgroup.freeze" 2>/dev/null) events '$(grep frozen "$c/cgroup.events" 2>/dev/null)', game tasks in it $in/$n, game CPU ticks in 2 s $((b - a)), window $(mapped "$W")"
  [ -n "$c" ] && [ "$(cat "$c/cgroup.freeze")" = 1 ] && grep -qx "frozen 1" "$c/cgroup.events" && [ $n -gt 0 ] && [ $in = $n ] && [ $((b - a)) = 0 ]
}

# step_freeze: `powos game <appid> freeze` (its window minimized, Steam + the game frozen). Sets FREEZE.
step_freeze() {
  local t0 out; touched; pill "freezing $GAME"; t0=$(now)
  out=$(powos game $APP freeze 2>&1 | tail -1)
  for _ in $(seq 20); do [ "$(cat "$(cg)/cgroup.freeze" 2>/dev/null)" = 1 ] && break; sleep 0.5; done
  FREEZE=$(ms "$t0" "$(now)")
  if freeze_ok; then echo "freeze: frozen in ${FREEZE} ms - $EVID"
  else fail freeze "'$out' -> $EVID; watcher: $(watcher)"; return 1; fi
}

# step_resume <label> <how...>: the launch path given (a command; open_task's status line counts), then: Steam out of
# its frozen cgroup, the same game, its window mapped, a new frame within RESUME_MS. Sets RES.
step_resume() {
  local label=$1 r0 t0 st f t; shift; touched; pill "resuming $GAME ($label)"
  r0=$(reaper); t0=$(now)
  st=$("$@" 2>&1 | tail -1)
  t=$(ms "$t0" "$(now)")
  for _ in $(seq 20); do [ "$(mapped "$W")" = IsViewable ] && break; sleep 0.25; done
  f=$(first_change "$W" 5 30)
  RES=$([ "$f" = none ] && echo none || ms "$t0" "$f")
  local ev="'$st' in $t ms, steam frozen '$(cg)', same game $([ "$(reaper)" = "$r0" ] && echo yes || echo "no ($r0 -> $(reaper))"), window $(mapped "$W"), focused $([ "$(active)" = "$(printf '%d' "$W")" ] && echo yes || echo no), first new frame ${RES} ms after the launch"
  if [ -z "$(cg)" ] && [ "$(reaper)" = "$r0" ] && [ "$(mapped "$W")" = IsViewable ] && [ "$RES" != none ] && [ "$RES" -le "$RESUME_MS" ] \
      && { [ "$label" = steam ] || [ "$st" = "powos-open-task: task" ]; }; then
    echo "resume ($label): $ev"
  else fail "resume-$label" "$ev; watcher: $(watcher)"; return 1; fi
}
