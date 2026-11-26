/**
 * HDMI in (hdmiin.ts, docs/HDMI-IN.md): what an HDMI-to-USB capture dongle sees - a PS5, a Switch, a computer - live,
 * full screen (landscape, immersive, the screen kept awake) or as a small window over home. A tap shows / hides the
 * controls and the mode line (resolution, fps); mute; and for a computer, the PC controls: Remote input (remote.tsx)
 * as a side panel over Bluetooth - the USB port is the dongle's.
 */
import type { ComponentChildren } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import { audioBlocked, closeHdmiIn, hdmiMuted, hdmiStatus, hdmiView, openHdmiIn, recheck, setMuted } from "../hdmiin.ts";
import { measuredFps, modeLine } from "../hdmiin-pick.ts";
import { closeRemote, openRemote, remoteOpen } from "../remote.ts";
import { Icon } from "./icons.tsx";
import type { HdmiProbe } from "../types.ts";

/** Its touches are its own: nothing under it (home's swipes) sees them. */
const own = {
  onTouchStart: (e: TouchEvent) => e.stopPropagation(),
  onTouchMove: (e: TouchEvent) => e.stopPropagation(),
  onPointerDown: (e: PointerEvent) => e.stopPropagation(),
};

export function HdmiInScreen() {
  return hdmiView.value ? <HdmiIn view={hdmiView.value} /> : null;
}

function HdmiIn({ view }: { view: "full" | "window" }) {
  const st = hdmiStatus.value;
  const live = st.kind === "live";
  const full = view === "full";
  const [chrome, setChrome] = useChrome(live);
  useHeldScreen(full);
  usePoll(st.kind === "none");

  const body = (
    <>
      {live ? <Picture stream={st.stream} showLine={chrome} onTap={() => setChrome(!chrome)} /> : <Empty />}
      {(chrome || !live) && <Bar full={full} live={live} audio={live && st.audio} />}
    </>
  );
  return full ? (
    <div class="hdmi-screen" {...own}>
      {body}
    </div>
  ) : (
    <HdmiWindow>{body}</HdmiWindow>
  );
}

/**
 * The host holds the screen while this shows: awake always, immersive + landscape full screen (Android; a no-op
 * elsewhere), the Screen Wake Lock API where the engine has it (the Linux desktop, a browser). Off again when it
 * closes or goes to a window.
 */
function useHeldScreen(full: boolean) {
  useEffect(() => {
    void powos.hdmiin.screen(true, full).catch(() => {});
    let lock: WakeLockSentinel | null = null;
    navigator.wakeLock?.request("screen").then((l) => (lock = l), () => {});
    return () => {
      void powos.hdmiin.screen(false, false).catch(() => {});
      void lock?.release().catch(() => {});
    };
  }, [full]);
}

/** The controls: shown, fading after a few seconds of a live picture; a tap brings them back. */
function useChrome(live: boolean) {
  const [chrome, setChrome] = useState(true);
  useEffect(() => {
    if (!live || !chrome) return;
    const t = window.setTimeout(() => setChrome(false), 4000);
    return () => clearTimeout(t);
  }, [live, chrome]);
  return [chrome, setChrome] as const;
}

/** Nothing plugged in: look again every 2 s (Android's WebView doesn't always say "devicechange" for USB). */
function usePoll(on: boolean) {
  useEffect(() => {
    if (!on) return;
    const t = window.setInterval(() => document.hidden || void recheck(), 2000);
    return () => clearInterval(t);
  }, [on]);
}

function close() {
  if (remoteOpen.value) closeRemote();
  closeHdmiIn();
}

/** PC controls: Remote input beside the picture, over Bluetooth - the dongle has the USB port. */
function pcControls() {
  if (remoteOpen.value) return closeRemote();
  void powos.remote.target("bluetooth").catch(() => {});
  openRemote(true);
}

/** Close, the title, mute, PC controls, full screen <-> window. */
function Bar({ full, live, audio }: { full: boolean; live: boolean; audio: boolean }) {
  return (
    <div class="hdmi-bar">
      <button type="button" class="hdmi-btn" onClick={close} aria-label="Close">
        <Icon name="close" size={20} />
      </button>
      <span class="hdmi-title">HDMI in</span>
      {audio && <MuteButton />}
      {live && (
        <button type="button" class={`hdmi-btn ${remoteOpen.value ? "on" : ""}`} onClick={pcControls} aria-label="PC controls">
          <Icon name="keyboardOutline" size={20} />
        </button>
      )}
      <button type="button" class="hdmi-btn" onClick={() => openHdmiInView(full ? "window" : "full")} aria-label={full ? "Window" : "Full screen"}>
        <Icon name={full ? "monitor" : "television"} size={20} />
      </button>
    </div>
  );
}

/** Full screen <-> window, the capture going on as it is (no restart). */
function openHdmiInView(v: "full" | "window") {
  if (hdmiView.value) hdmiView.value = v;
  else openHdmiIn(v);
}

function MuteButton() {
  const m = hdmiMuted.value;
  const blocked = audioBlocked();
  return (
    <button type="button" class="hdmi-btn" onClick={() => setMuted(blocked ? false : !m)} aria-label={m ? "Unmute" : "Mute"}>
      <Icon name={m || blocked ? "volumeOff" : "volumeHigh"} size={20} />
      {blocked && <span class="hdmi-hint">tap for sound</span>}
    </button>
  );
}

/**
 * The live picture: the stream straight in a <video> (no canvas, no copy), contained in 16:9 black bars. The mode line
 * is the track's settings and the frames really shown (requestVideoFrameCallback).
 */
function Picture({ stream, showLine, onTap }: { stream: MediaStream; showLine: boolean; onTap: () => void }) {
  const ref = useRef<HTMLVideoElement>(null);
  const [line, setLine] = useState("starting…");
  useEffect(() => {
    const v = ref.current;
    if (!v) return;
    v.srcObject = stream;
    void v.play().catch(() => {});
    const times: number[] = [];
    let handle = 0;
    type Rvfc = HTMLVideoElement & { requestVideoFrameCallback?(cb: (now: number) => void): number; cancelVideoFrameCallback?(h: number): void };
    const rv = v as Rvfc;
    const frame = (now: number) => {
      times.push(now);
      while (times.length && now - times[0] > 1000) times.shift();
      handle = rv.requestVideoFrameCallback?.(frame) ?? 0;
    };
    handle = rv.requestVideoFrameCallback?.(frame) ?? 0;
    const tick = () => {
      const s = stream.getVideoTracks()[0]?.getSettings() ?? {};
      setLine(modeLine(s.width ?? v.videoWidth, s.height ?? v.videoHeight, s.frameRate, measuredFps(times)));
    };
    tick();
    const t = window.setInterval(tick, 1000);
    return () => {
      clearInterval(t);
      rv.cancelVideoFrameCallback?.(handle);
      v.srcObject = null;
    };
  }, [stream]);
  return (
    <div class="hdmi-picture" onClick={onTap}>
      <video ref={ref} class="hdmi-video" autoplay muted playsInline disablePictureInPicture />
      {showLine && <span class="hdmi-mode">{line}</span>}
    </div>
  );
}

/** No picture: why, and what to do. */
function Empty() {
  const st = hdmiStatus.value;
  if (st.kind === "looking") return <div class="hdmi-empty muted">Looking for the capture dongle…</div>;
  if (st.kind === "permission") {
    return (
      <div class="hdmi-empty">
        <p>HDMI in needs the camera and microphone permission - the dongle is a camera and a mic to the phone.</p>
        <button type="button" class="hdmi-action" onClick={() => openHdmiIn(hdmiView.value ?? "full")}>
          Allow
        </button>
      </div>
    );
  }
  if (st.kind === "error") {
    return (
      <div class="hdmi-empty">
        <p>{st.message}</p>
        <button type="button" class="hdmi-action" onClick={() => openHdmiIn(hdmiView.value ?? "full")}>
          Try again
        </button>
      </div>
    );
  }
  const probe = st.kind === "none" ? st.probe : null;
  return (
    <div class="hdmi-empty">
      <Icon name="television" size={44} />
      <p class="hdmi-head">Plug in an HDMI capture dongle</p>
      <p class="muted">
        A USB HDMI capture stick (MS2109 / MS2130 kind) in the USB-C port, the console or computer on its HDMI side.
        The picture shows here as soon as it's in.
      </p>
      {unseen(probe) && (
        <p class="hdmi-warn">
          A USB video device is plugged in ({unseen(probe)}), but this phone doesn't offer it as a camera to apps, so
          HDMI in can't open it yet (docs/HDMI-IN.md: the native USB source).
        </p>
      )}
      <p class="muted hdmi-tip">
        <b>PS5:</b> Settings → System → HDMI → turn <b>Enable HDCP</b> off, or the dongle gets a blank picture. Its
        controller stays paired to the PS5.
      </p>
    </div>
  );
}

/** A UVC device the host sees on USB while Android has no external camera for it: its name, else null. */
function unseen(p: HdmiProbe | null): string | null {
  if (!p || p.externalCameras.length) return null;
  const d = p.usb.find((u) => u.video);
  return d ? d.name || `USB ${d.vendorId.toString(16).padStart(4, "0")}:${d.productId.toString(16).padStart(4, "0")}` : null;
}

/** The small window: 16:9 over home, dragged by its body; the rest of home stays usable around it. */
function HdmiWindow({ children }: { children: ComponentChildren }) {
  const [at, setAt] = useState(() => ({ x: Math.max(8, window.innerWidth - 376), y: Math.max(8, window.innerHeight - 240) }));
  const drag = useRef<{ dx: number; dy: number; id: number } | null>(null);
  return (
    <div
      class="hdmi-window tile"
      style={{ left: `${at.x}px`, top: `${at.y}px` }}
      {...own}
      onPointerDown={(e) => {
        e.stopPropagation();
        if ((e.target as HTMLElement).closest("button")) return;
        drag.current = { dx: e.clientX - at.x, dy: e.clientY - at.y, id: e.pointerId };
        (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
      }}
      onPointerMove={(e) => {
        const d = drag.current;
        if (!d || d.id !== e.pointerId) return;
        const x = Math.min(Math.max(0, e.clientX - d.dx), window.innerWidth - 120);
        const y = Math.min(Math.max(0, e.clientY - d.dy), window.innerHeight - 80);
        setAt({ x, y });
      }}
      onPointerUp={() => (drag.current = null)}
      onPointerCancel={() => (drag.current = null)}
    >
      {children}
    </div>
  );
}
