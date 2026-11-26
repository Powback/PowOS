/**
 * HDMI in (ui/hdmiin.tsx, docs/HDMI-IN.md): an HDMI-to-USB capture dongle's picture and sound, live. One source on
 * every platform: getUserMedia on the dongle's camera and mic - the Linux desktop's V4L2 + ALSA devices, the phone's
 * WebView over Android's external-camera HAL (Camera2) and its USB audio input. The picture is the camera track in a
 * <video> (the browser's own zero-copy path to the compositor), the sound a Web Audio graph at the lowest latency
 * (MediaStreamSource -> gain (mute) -> out), never a media element's buffered playback.
 *
 * Seam for later (docs/HDMI-IN.md "PowStream"): [session]'s stream is the one thing a streamer needs - a
 * MediaStreamTrack to encode (WebRTC / MediaCodec) - so sending it to other devices hangs off [captureStream], not off
 * the screen.
 */
import { signal } from "@preact/signals";
import { powos } from "./bridge.ts";
import { constraints, pickAudio, pickVideo, type MediaDev } from "./hdmiin-pick.ts";
import type { HdmiProbe } from "./types.ts";

/** The screen: closed, full screen, or a small window over home (dragged where the user put it). */
export const hdmiView = signal<"full" | "window" | null>(null);

/** Where the capture is: looking for the dongle, none plugged in, asking a permission, showing, or failed. */
export type HdmiStatus =
  | { kind: "looking" }
  | { kind: "none"; probe: HdmiProbe | null }
  | { kind: "permission" }
  | { kind: "live"; stream: MediaStream; label: string; audio: boolean }
  | { kind: "error"; message: string };
export const hdmiStatus = signal<HdmiStatus>({ kind: "looking" });
export const hdmiMuted = signal(false);

export function openHdmiIn(view: "full" | "window" = "full") {
  hdmiView.value = view;
  void start();
}

export function closeHdmiIn() {
  if (!hdmiView.value) return;
  hdmiView.value = null;
  stop();
}

// A dongle plugged in and the user chose PowOS for it (Android's USB dialog, HdmiInAttach.kt): open, full screen.
powos.on("hdmiin.open", () => openHdmiIn("full"));
powos.on("hdmiin.permission", () => hdmiView.value && void start());

let audio: { ctx: AudioContext; gain: GainNode } | null = null;
let starting = 0;

/** The capture's stream while it's live (the PowStream seam: a later streamer encodes this). */
export const captureStream = () => {
  const s = hdmiStatus.value;
  return s.kind === "live" ? s.stream : null;
};

async function probe(): Promise<HdmiProbe | null> {
  return powos.hdmiin.probe().catch(() => null);
}

async function devices(): Promise<MediaDev[]> {
  return ((await navigator.mediaDevices?.enumerateDevices().catch(() => [])) ?? []) as MediaDev[];
}

/**
 * Finds the dongle and starts showing it. Labels come only after a camera permission was given to the page once:
 * without them, the host's permission (Android's dialog) is asked first, then a short getUserMedia of any camera
 * stopped at once - the browser's own permission - and the list read again.
 */
export async function start() {
  const run = ++starting;
  stop(false);
  hdmiStatus.value = { kind: "looking" };
  const next = await find();
  // Closed or started again meanwhile: this one's stream goes.
  if (run !== starting || !hdmiView.value) {
    if (next.kind === "live") next.stream.getTracks().forEach((t) => t.stop());
    return;
  }
  if (next.kind === "live") {
    // Unplugged: back to looking (and on to the empty state).
    next.stream.getVideoTracks()[0]?.addEventListener("ended", () => hdmiView.value && void start());
    if (next.audio) playAudio(next.stream);
  }
  hdmiStatus.value = next;
}

/** [start]'s search: the state it ends in (live with its stream, or why not). */
async function find(): Promise<HdmiStatus> {
  if (!navigator.mediaDevices?.getUserMedia) return { kind: "error", message: "This screen has no camera access (getUserMedia)." };
  const p = await probe();
  // Android: nothing camera-like plugged in at all - the empty state, without asking for anything.
  if (p && !p.usb.some((d) => d.video) && !p.externalCameras.length) return { kind: "none", probe: p };
  if (!(await allowed(p))) return { kind: "permission" };
  const list = await labelled();
  if (!list) return { kind: "permission" };
  const video = pickVideo(list);
  if (!video) return { kind: "none", probe: p };
  return open(video, pickAudio(list, video, p ? p.usbAudioIn : null));
}

/** The host's permissions (Android: the camera, and the mic when a USB audio input is there): held, or asked now. */
async function allowed(p: HdmiProbe | null): Promise<boolean> {
  if (!p || (p.camera && (p.mic || !p.usbAudioIn))) return true;
  return (await powos.hdmiin.permissions().catch(() => "unavailable")) === "granted";
}

/** The devices with their labels (a browser permission given once first); null: refused. */
async function labelled(): Promise<MediaDev[] | null> {
  const list = await devices();
  if (list.some((d) => d.kind === "videoinput" && d.label)) return list;
  try {
    const s = await navigator.mediaDevices.getUserMedia({ video: true });
    s.getTracks().forEach((t) => t.stop());
  } catch {
    return null;
  }
  return devices();
}

/** The dongle's stream; the mic refused or busy: the picture alone rather than nothing. */
async function open(video: MediaDev, mic: { deviceId?: string } | null): Promise<HdmiStatus> {
  const ask = (a: { deviceId?: string } | null) => navigator.mediaDevices.getUserMedia(constraints(video, a));
  try {
    const stream = await ask(mic).catch((e) => {
      if (!mic) throw e;
      return ask(null);
    });
    return { kind: "live", stream, label: video.label, audio: stream.getAudioTracks().length > 0 };
  } catch (e) {
    return { kind: "error", message: `Couldn't open ${video.label}: ${(e as Error).message || e}` };
  }
}

/** The dongle's sound out of the speaker / headphones: Web Audio at the interactive latency, muted by the gain. */
function playAudio(stream: MediaStream) {
  try {
    const ctx = new AudioContext({ latencyHint: "interactive", sampleRate: 48000 });
    const gain = ctx.createGain();
    gain.gain.value = hdmiMuted.value ? 0 : 1;
    ctx.createMediaStreamSource(stream).connect(gain).connect(ctx.destination);
    audio = { ctx, gain };
    void ctx.resume().catch(() => {});
  } catch (e) {
    console.warn("hdmi in: no audio out", e);
  }
}

/** The audio context still waits for a tap (autoplay rules): the mute button says "tap for sound". */
export const audioBlocked = () => audio?.ctx.state === "suspended";

export function setMuted(m: boolean) {
  hdmiMuted.value = m;
  if (!audio) return;
  audio.gain.gain.value = m ? 0 : 1;
  // A tap is the user gesture a suspended context needs.
  void audio.ctx.resume().catch(() => {});
}

function stop(reset = true) {
  const s = hdmiStatus.value;
  if (s.kind === "live") s.stream.getTracks().forEach((t) => t.stop());
  void audio?.ctx.close().catch(() => {});
  audio = null;
  if (reset) {
    starting++;
    hdmiStatus.value = { kind: "looking" };
  }
}

/** Looks again when devices change (plugged in / out), while the screen shows and isn't live. */
navigator.mediaDevices?.addEventListener?.("devicechange", () => {
  if (hdmiView.value && hdmiStatus.value.kind !== "live") void start();
});

/**
 * The empty state's poll (ui/hdmiin.tsx, every 2 s while it shows): Android's WebView doesn't always say "devicechange"
 * for a USB camera, so look - quietly, never back through "looking" - and start once the dongle is there.
 */
export async function recheck() {
  if (hdmiStatus.value.kind !== "none") return;
  const p = await probe();
  const found = p ? p.externalCameras.length > 0 : pickVideo(await devices()) != null;
  if (found && hdmiView.value && hdmiStatus.value.kind === "none") void start();
}
