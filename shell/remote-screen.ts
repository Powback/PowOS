/**
 * Remote screen (ui/remote.tsx, docs/REMOTE-SCREEN.md): the computer's picture on the phone, from PowStream's WebRTC
 * sender on the computer (`powos stream cable` there), over the USB cable's network link (RemoteInput.kt net) or the
 * LAN/VPN. PowStream's own protocol, nothing new:
 *
 * - signalling: its /ws - the server sends {type:"offer",sdp} and {type:"ice",candidate,sdpMLineIndex}, we answer
 *   {type:"answer",sdp} and our candidates. On the phone the socket is native (powos.remote.screen/signal: the page is
 *   https, a ws:// socket from it would be mixed content); a desktop browser opens it itself.
 * - input: its "input" data channel - [1, kind, seq u32le, body]; touch on the picture is kind 0x07 TouchContact
 *   (id, phase 0 up / 1 down / 2 move, x u16le, y u16le over the picture), absolute, as PowStream's own web client
 *   sends for direct touch. The touchpad and keys keep going as HID reports (USB/BT), as without the screen.
 */
import { signal } from "@preact/signals";
import { powos } from "./bridge.ts";
import type { RemoteScreenEvent } from "./types.ts";

/** The port `powos stream cable` serves on (plain HTTP/WS, reachable from the cable or --allow only). */
export const SCREEN_PORT = 8092;
/** The computer's end of the cable link (hidg.sh net). */
export const CABLE_PEER = "10.77.0.1";

export type ScreenPhase = "off" | "connecting" | "negotiating" | "waiting" | "live" | "failed";
export const screenPhase = signal<ScreenPhase>("off");
export const screenError = signal<string | null>(null);
export const screenStream = signal<MediaStream | null>(null);
/** Where it was opened: "host[:port]". */
export const screenHost = signal<string | null>(null);

interface Signalling {
  send(text: string): void;
  close(): void;
}

let pc: RTCPeerConnection | null = null;
let dc: RTCDataChannel | null = null;
let sig: Signalling | null = null;
let seq = 0;
/** Which session the callbacks belong to: a stale one's are ignored. */
let session = 0;

function openSignalling(url: string, on: { open(): void; message(t: string): void; closed(why: string | null): void }): Signalling {
  const r = powos.remote;
  if (r.screen && r.signal) {
    const off = powos.on("remote.screen", (e: RemoteScreenEvent) => {
      if (e.type === "open") on.open();
      else if (e.type === "message") on.message(e.data);
      else on.closed(e.why);
    });
    r.screen(url).catch((e) => on.closed(String(e?.message ?? e)));
    return {
      send: (t) => void r.signal!(t).catch(() => {}),
      close: () => {
        off();
        void r.screen!(null).catch(() => {});
      },
    };
  }
  const ws = new WebSocket(url);
  ws.onopen = () => on.open();
  ws.onmessage = (e) => on.message(String(e.data));
  ws.onclose = (e) => on.closed(e.reason || null);
  return { send: (t) => ws.readyState === 1 && ws.send(t), close: () => ws.close() };
}

/** "host[:port]" to PowStream's signalling url. */
export function screenUrl(host: string): string {
  const h = host.trim().replace(/^[a-z]+:\/\//, "").replace(/\/.*$/, "");
  return `ws://${/:\d+$/.test(h) ? h : `${h}:${SCREEN_PORT}`}/ws`;
}

function fail(id: number, why: string) {
  if (id !== session) return;
  screenError.value = why;
  screenPhase.value = "failed";
}

/** Opens the screen at [host] (closing any open one). */
export function openScreen(host: string) {
  closeScreen();
  const id = ++session;
  screenHost.value = host;
  screenError.value = null;
  screenPhase.value = "connecting";
  // Host candidates only: the cable and the LAN need no STUN/TURN (and the server's /api/ice is http, unreachable
  // from the https page).
  const peer = new RTCPeerConnection({ iceServers: [] });
  pc = peer;
  peer.ontrack = (e) => {
    if (id !== session) return;
    // No playout buffer: render each frame as it comes (as PowStream's web client asks).
    const rx = e.receiver as RTCRtpReceiver & { jitterBufferTarget?: number; playoutDelayHint?: number };
    try {
      rx.jitterBufferTarget = 0;
    } catch {}
    try {
      rx.playoutDelayHint = 0;
    } catch {}
    screenStream.value = e.streams[0] ?? new MediaStream([e.track]);
    if (screenPhase.value !== "live") screenPhase.value = "waiting";
  };
  peer.ondatachannel = (e) => {
    if (id !== session || e.channel.label !== "input") return;
    dc = e.channel;
    dc.binaryType = "arraybuffer";
  };
  peer.onicecandidate = (e) => {
    if (id === session && e.candidate) sig?.send(JSON.stringify({ type: "ice", candidate: e.candidate.candidate, sdpMLineIndex: e.candidate.sdpMLineIndex }));
  };
  peer.onconnectionstatechange = () => {
    if (peer.connectionState === "failed") fail(id, "the connection to the computer failed");
    if (peer.connectionState === "disconnected") fail(id, "the computer went away");
  };
  sig = openSignalling(screenUrl(host), {
    open: () => id === session && screenPhase.value === "connecting" && (screenPhase.value = "negotiating"),
    message: (t) => {
      if (id === session) signalled(peer, t).catch((e) => fail(id, `negotiation failed: ${(e as Error)?.message ?? e}`));
    },
    // PowStream ends the session with its signalling socket: closed is the end either way.
    closed: (why) => fail(id, why ? `the computer closed the stream (${why})` : `no PowStream sender at ${host} - run \`powos stream cable\` on the computer`),
  });
}

/** A signalling message from PowStream: its offer answered, its candidates added. */
async function signalled(peer: RTCPeerConnection, text: string) {
  let m: { type?: string; sdp?: string; candidate?: string; sdpMLineIndex?: number };
  try {
    m = JSON.parse(text);
  } catch {
    return;
  }
  if (m.type === "offer" && m.sdp) {
    await peer.setRemoteDescription({ type: "offer", sdp: m.sdp });
    const answer = await peer.createAnswer();
    await peer.setLocalDescription(answer);
    sig?.send(JSON.stringify({ type: "answer", sdp: answer.sdp }));
  } else if (m.type === "ice" && m.candidate) {
    await peer.addIceCandidate({ candidate: m.candidate, sdpMLineIndex: m.sdpMLineIndex ?? 0 }).catch(() => {});
  }
}

/** The first frame is on the glass (the page's video says so). */
export function screenShown() {
  if (screenPhase.value === "waiting" || screenPhase.value === "negotiating") screenPhase.value = "live";
}

export function closeScreen() {
  session++;
  releaseTouches();
  sig?.close();
  sig = null;
  dc = null;
  pc?.close();
  pc = null;
  screenStream.value = null;
  screenPhase.value = "off";
}

function send(kind: number, body: Uint8Array) {
  if (!dc || dc.readyState !== "open") return;
  const b = new Uint8Array(6 + body.length);
  b[0] = 1;
  b[1] = kind;
  new DataView(b.buffer).setUint32(2, seq++ >>> 0, true);
  b.set(body, 6);
  try {
    dc.send(b);
  } catch {}
}

export const TOUCH_UP = 0;
export const TOUCH_DOWN = 1;
export const TOUCH_MOVE = 2;
/** Contacts down now: slot -> last fraction, so a disconnect or close lifts them all. */
const down = new Map<number, { x: number; y: number }>();

/** A contact on the picture: [slot] (0-9), its phase, and where (fractions of the picture, 0..1). */
export function touch(slot: number, phase: number, x: number, y: number) {
  const b = new Uint8Array(6);
  const v = new DataView(b.buffer);
  b[0] = slot & 0xff;
  b[1] = phase;
  v.setUint16(2, Math.round(Math.min(1, Math.max(0, x)) * 65535), true);
  v.setUint16(4, Math.round(Math.min(1, Math.max(0, y)) * 65535), true);
  send(0x07, b);
  if (phase === TOUCH_UP) down.delete(slot);
  else down.set(slot, { x, y });
}

function releaseTouches() {
  for (const [slot, p] of [...down]) touch(slot, TOUCH_UP, p.x, p.y);
}

/** A point on the element to a fraction of the video's picture in it (object-fit: contain; null: on the bars). */
export function pictureFraction(video: HTMLVideoElement, clientX: number, clientY: number): { x: number; y: number } | null {
  const r = video.getBoundingClientRect();
  const va = (video.videoWidth || 16) / (video.videoHeight || 9);
  let w = r.width;
  let h = r.height;
  let ox = 0;
  let oy = 0;
  if (va > r.width / r.height) {
    h = r.width / va;
    oy = (r.height - h) / 2;
  } else {
    w = r.height * va;
    ox = (r.width - w) / 2;
  }
  const x = (clientX - r.left - ox) / w;
  const y = (clientY - r.top - oy) / h;
  return x < 0 || y < 0 || x > 1 || y > 1 ? null : { x, y };
}
