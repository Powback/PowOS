#!/usr/bin/env python3
# PowOS Camera Indicator — scanner.
#
# Emits one line per (app, device) that is USING the physical camera:
#     pid|name|device
# The plasmoid groups these by process for display.
#
# Why this exists / why the old approach was wrong
# ------------------------------------------------
# The widget used to scan /proc/<pid>/fd for open handles to /dev/video*.
# On a PipeWire desktop that NEVER names the real app: PipeWire opens the
# camera device on the client's behalf, so the only process holding a
# /dev/video* fd is `pipewire` itself. The indicator therefore showed
# "Pipewire" (the broker) — or, when the camera was suspended, nothing —
# instead of the application actually looking through the lens.
#
# Two detectors, merged:
#
#   1. PipeWire graph (PRIMARY). A physical camera is in use when a
#      v4l2/libcamera "Video/Source" node is streaming (state == running) or
#      has an active outgoing link. The consumer is whatever node is linked to
#      that camera source — its application.name / node.description names the
#      real app, and application.process.id gives its PID. This deliberately
#      keys off the CAMERA SOURCE, so a screen-cast (a client capturing
#      kwin_wayland, which is a Stream/Output/Video, not a camera) is NOT
#      mistaken for camera use.
#
#   2. /proc fd scan (FALLBACK). Catches apps that open /dev/video* directly,
#      bypassing PipeWire (e.g. ffmpeg, some Flatpak/containers). Broker
#      processes (pipewire/wireplumber) are dropped when the PipeWire detector
#      is available — they're just holding the device for the clients named in
#      (1). If pw-dump is unavailable we keep the brokers so the light still
#      comes on when the camera is live.
#
# Unprivileged by design: readlink on another user's fd fails and is skipped,
# and pw-dump talks to the user's own PipeWire — exactly where desktop camera
# use lives. Root-owned openers stay invisible; an accepted trade for needing
# no privileges.

import json
import os
import subprocess

BROKERS = {"pipewire", "pipewire-pulse", "wireplumber", "pipewire-media-session"}


def _is_camera_source(props):
    """A v4l2/libcamera capture source (NOT a screencast / virtual sink)."""
    if "Video/Source" not in props.get("media.class", ""):
        return False
    return (
        props.get("device.api") in ("v4l2", "libcamera")
        or props.get("media.role") == "Camera"
        or str(props.get("object.path", "")).startswith(("v4l2:", "libcamera:"))
    )


def pw_camera_users():
    """(ok, [(pid, name, device)]). ok=False when pw-dump can't be run."""
    try:
        out = subprocess.run(
            ["pw-dump"], capture_output=True, text=True, timeout=8
        )
        data = json.loads(out.stdout)
    except Exception:
        return False, []

    info = {}
    for o in data:
        if str(o.get("type", "")).endswith("Node"):
            info[o["id"]] = o.get("info") or {}

    def props(nid):
        return (info.get(nid, {}) or {}).get("props") or {}

    def state(nid):
        return (info.get(nid, {}) or {}).get("state")

    cams = {nid for nid, i in info.items() if _is_camera_source(i.get("props") or {})}
    if not cams:
        return True, []

    results = []
    linked = set()
    for o in data:
        if not str(o.get("type", "")).endswith("Link"):
            continue
        i = o.get("info") or {}
        src, dst = i.get("output-node-id"), i.get("input-node-id")
        if src in cams:
            linked.add(src)
            c = props(dst)
            name = (
                c.get("application.name")
                or c.get("node.description")
                or c.get("node.name")
                or "Unknown app"
            )
            pid = c.get("application.process.id")
            dev = props(src).get("node.description") or props(src).get("object.path") or "camera"
            results.append((str(pid) if pid else "-", str(name), str(dev)))

    # Camera streaming but no resolvable consumer link — still surface it so the
    # privacy light comes on; we just can't name the app.
    for nid in cams:
        if nid in linked:
            continue
        if state(nid) == "running":
            dev = props(nid).get("node.description") or props(nid).get("object.path") or "camera"
            results.append(("-", "Unknown app", str(dev)))

    return True, results


def fd_camera_users(include_brokers):
    """Apps holding a /dev/video* fd directly (readable ones = our own procs)."""
    users = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        fddir = "/proc/%s/fd" % pid
        try:
            fds = os.listdir(fddir)
        except OSError:
            continue
        for fd in fds:
            try:
                tgt = os.readlink("%s/%s" % (fddir, fd))
            except OSError:
                continue
            if tgt.startswith("/dev/video"):
                try:
                    with open("/proc/%s/comm" % pid) as f:
                        comm = f.read().strip()
                except OSError:
                    comm = "?"
                if not include_brokers and comm in BROKERS:
                    continue
                users.append((pid, comm, tgt))
    return users


def main():
    ok, pw = pw_camera_users()
    fd = fd_camera_users(include_brokers=not ok)

    seen = set()
    for pid, name, dev in pw + fd:
        key = (pid if pid != "-" else "name:" + name, dev)
        if key in seen:
            continue
        seen.add(key)
        print("%s|%s|%s" % (pid, name, dev))


if __name__ == "__main__":
    main()
