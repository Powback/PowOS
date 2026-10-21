/**
 * PowOS AI over another app (index.html?mode=assist; PowosAssistSession, the phone's digital assistant: holding the
 * side button). The ONE chat surface (ui/assistant.ts): the home pill and its chat (bar.tsx Bar, chat.tsx ChatView),
 * over the screen it was opened on - dimmed, for circling - and nothing of its own besides what the screen needs.
 *
 * Summoned, it listens at once and sends by itself (openAssistant listen + autosend): when the dictation ends - ~4 s
 * with nothing heard, the mic tapped, or the side button let go if Android passes that on (assist.keyup) - the words
 * show a moment and go. Touching the pill first keeps them to edit (takeOver); so does the panel going away.
 *
 * Every question takes the screen along (setAskContext): its screenshot (PowOS AI reads it: the host saves it where
 * PowOS sees it, the question names the path) and its text. Circling is always on, no mode: draw around anything on
 * the screen above the panel and that part is cut out of the screenshot and sent too. A tap there (no stroke) puts the
 * panel away.
 *
 * Live mode: the screen a frame a second (LiveCapture; Android asks once), the panel a bar at the bottom - the app
 * under it stays usable (only the panel takes touches) - and each question takes the last moments that changed as one
 * filmstrip image.
 */
import { useEffect, useRef } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { Bar } from "./bar.tsx";
import { ChatView } from "./chat.tsx";
import { openAssistant, pillTarget, setAskContext, takeOver } from "./assistant.ts";
import { makeHold, speech } from "./dictation.ts";

/** A summoning with the side button already let go: its dictation ends after this much silence. */
const QUICK_SILENCE_MS = 1500;
import type { AssistScreen } from "../types.ts";

const screen = signal<AssistScreen | null>(null);
/** The part of the screen circled (a PNG cut out of the screenshot), sent with the whole screen; null: just the screen. */
const region = signal<string | null>(null);
/** The circle drawn over the screen (px), left showing so it's clear what goes along. */
const stroke = signal<[number, number][]>([]);
/** Live mode: on, and how many different moments it holds. */
const live = signal({ on: false, frames: 0 });
powos.on("assist.live", (l: { on: boolean; frames: number }) => (live.value = l));

/** A summoning: listen, and send what's heard with the screen. */
const summoned = () => openAssistant({ listen: true, autosend: true, context: true });

powos.on("assist.context", (s: AssistScreen) => (screen.value = s));
// Summoned again (the page stays warm between summonings, AssistWeb): last time's cut-out goes, and it listens.
powos.on("assist.reset", () => {
  screen.value = null;
  region.value = null;
  stroke.value = [];
  summoned();
});
// Put away: nothing listens or sends on (the words heard stay in the pill).
powos.on("assist.hidden", () => takeOver());
// Hold to talk: the side button is still down - the dictation lasts until it's let go (assist.keyup: PowerKey reads the
// release as root), then ends, and so sends. Already up: the dictation ends at a short pause instead of ~4 s.
powos.on("assist.held", () => makeHold(pillTarget));
powos.on("assist.quick", () => powos.speech.quiet(QUICK_SILENCE_MS));
powos.on("assist.keyup", () => {
  if (speech.value.listening) powos.speech.stop();
});

/** The screen's text that goes along with a question, at most (the host caps it too). */
const SCREEN_TEXT = 4000;

/**
 * The question with the screen: the image first (the host saves it where PowOS sees it), then the screen's text, both
 * after the question, which is all the chat shows of it (powai.tsx). Live: the filmstrip of the last moments instead.
 */
setAskContext(async (text) => {
  const seen = screen.value?.text.trim();
  const strip = live.value.on ? await powos.assist.filmstrip() : null;
  const shot = !strip && screen.value?.screenshot;
  const part = shot && region.value ? await powos.assist.attach(region.value) : null;
  const path = shot ? await powos.assist.attach(null) : null;
  const context = [
    strip &&
      `(live view of my screen: ${strip} - the last moments that changed, a frame a second, oldest first, left to right then down, each labelled with how long ago; read it)`,
    part && `(the part of the screen I circled: ${part} - read it, it's what I mean)`,
    path && `(image of the whole screen: ${path} - read it to see the screen${part ? " around the part I circled" : ""})`,
    seen?.slice(0, SCREEN_TEXT),
  ]
    .filter(Boolean)
    .join("\n");
  return context ? `${text}\n\n[What's on my screen right now - the app under this overlay, not PowOS AI itself:]\n${context}` : text;
});

/** Around the stroke, so a circle drawn tight still holds what it circles (px on screen). */
const PAD = 12;

/** Moved less than this (px), a press on the screen is a tap: it puts the panel away instead of circling. */
const TAP = 12;

/**
 * Over the screen above the panel, always: a stroke drawn there (a circle, a scribble) cuts its bounds out of the
 * screenshot as the part that goes with the question; a tap puts the panel away. The overlay covers the whole display,
 * as the screenshot does, so a point on the overlay is the same point in the screenshot (scaled to its pixels).
 */
function Draw({ src }: { src: string | undefined }) {
  const drawing = useRef<[number, number][] | null>(null);
  const shot = useRef<HTMLImageElement | null>(null);
  useEffect(() => {
    if (!src) return void (shot.current = null);
    const img = new Image();
    img.src = src;
    shot.current = img;
  }, [src]);
  const cut = (pts: [number, number][]) => {
    const el = shot.current;
    if (!el?.naturalWidth) return;
    const W = window.innerWidth;
    const H = window.innerHeight;
    const xs = pts.map((p) => p[0]);
    const ys = pts.map((p) => p[1]);
    const left = Math.max(0, Math.min(...xs) - PAD);
    const top = Math.max(0, Math.min(...ys) - PAD);
    const right = Math.min(W, Math.max(...xs) + PAD);
    const bottom = Math.min(H, Math.max(...ys) + PAD);
    if (right - left < 16 || bottom - top < 16) return;
    const sx = el.naturalWidth / W;
    const sy = el.naturalHeight / H;
    const c = document.createElement("canvas");
    c.width = Math.round((right - left) * sx);
    c.height = Math.round((bottom - top) * sy);
    c.getContext("2d")!.drawImage(el, left * sx, top * sy, c.width, c.height, 0, 0, c.width, c.height);
    region.value = c.toDataURL("image/png");
  };
  return (
    <div
      class="assist-draw"
      onPointerDown={(e) => {
        (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
        drawing.current = [[e.clientX, e.clientY]];
      }}
      onPointerMove={(e) => {
        const d = drawing.current;
        if (!d) return;
        d.push([e.clientX, e.clientY]);
        if (d.length > 2 || Math.hypot(e.clientX - d[0][0], e.clientY - d[0][1]) >= TAP) stroke.value = [...d];
      }}
      onPointerUp={(e) => {
        const d = drawing.current;
        drawing.current = null;
        if (!d) return;
        d.push([e.clientX, e.clientY]);
        const moved = Math.max(...d.map((p) => Math.hypot(p[0] - d[0][0], p[1] - d[0][1])));
        if (moved < TAP) return powos.assist.close();
        stroke.value = d;
        cut(d);
      }}
      onPointerCancel={() => (drawing.current = null)}
    >
      <svg class="crop-stroke">
        <polyline points={stroke.value.map((p) => p.join(",")).join(" ")} />
      </svg>
    </div>
  );
}

export function Assist() {
  const panel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    // The page loaded during a summoning (not warm before it): no assist.reset came, so it listens now.
    powos.assist.screen().then((s) => {
      if (!s) return;
      screen.value = s;
      summoned();
    });
    powos.assist.liveState().then((l) => (live.value = l));
  }, []);
  const on = live.value.on;
  // Live: only the panel takes touches (the app under it is in use), kept as it moves and resizes; and its count of
  // moments kept fresh. Off: the whole window again.
  useEffect(() => {
    if (!on) return void powos.assist.touchable(null);
    const report = () => {
      const r = panel.current?.getBoundingClientRect();
      if (r) powos.assist.touchable({ left: r.left, top: r.top, width: r.width, height: r.height });
    };
    const ro = new ResizeObserver(report);
    if (panel.current) ro.observe(panel.current);
    report();
    const poll = window.setInterval(() => powos.assist.liveState().then((l) => (live.value = l)), 1500);
    return () => (ro.disconnect(), clearInterval(poll));
  }, [on]);
  const s = screen.value;
  return (
    <div class={`assist ${on ? "live" : ""}`}>
      {!on && <Draw src={s?.screenshot ?? undefined} />}
      <div class="assist-panel" ref={panel}>
        {/* What goes along with a question: the screen (and the circled part), or live moments. */}
        <div class="assist-attach">
          {region.value ? (
            <button type="button" class="chip" onClick={() => ((region.value = null), (stroke.value = []))}>
              the part you circled + the screen ✕
            </button>
          ) : (
            <span class="muted assist-hint">{on ? `● live · ${live.value.frames} moments` : s?.screenshot ? "the screen goes along · circle anything above" : "…"}</span>
          )}
          <button type="button" class={`chip ${on ? "" : "off"}`} onClick={() => powos.assist.live(!on)}>
            {on ? "stop live" : "live"}
          </button>
        </div>
        <ChatView />
        <Bar />
      </div>
    </div>
  );
}
