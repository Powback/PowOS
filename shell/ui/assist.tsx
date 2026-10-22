/**
 * PowOS AI over another app (index.html?mode=assist; PowosAssistSession, the phone's digital assistant: holding the
 * power button). A panel at the bottom: the screen it was opened over (a thumbnail), the question - typed, or the mic
 * (hold to talk and send, tap to dictate) - and, once asked, the one chat (assistant.ts: the pill's conversation and
 * its ChatView, asks through askQueued - not a chat of its own). What's asked goes with the screen's text, so "what's
 * this?" means the screen. A tap above the panel puts it away.
 *
 * Summoned (the side button), it listens at once and sends by itself: what's said goes into the field, and when it ends
 * - the side button let go when it was held (PowerKey reads the release as root: assist.held / assist.keyup), else
 * ~1.5 s with nothing heard (assist.quick), or the mic tapped - the text shows for a moment (SEND_DELAY_MS) and goes,
 * with the screen and the circled part. A tap on the field in that moment,
 * or typing or tapping it while it listens, keeps the text there to edit instead; the panel going away stops it.
 * The mic button itself keeps its own ways (tap: fill in; hold: send on release).
 *
 * The screenshot always goes along (PowOS AI reads it: the host saves it where PowOS sees it, the question names the
 * path). Circling is always on, no mode: draw around anything on the screen above the panel and that part is cut out
 * of the screenshot and sent too, the whole screen with it for context. A tap there (no stroke) puts the panel away.
 *
 * Live mode: the screen a frame a second (LiveCapture; Android asks once), the panel a bar at the bottom - the app
 * under it stays usable (only the bar takes touches) - and each question takes the last moments that changed as one
 * filmstrip image.
 */
import { useEffect, useRef } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { stored } from "../state.ts";
import { Pill, dictate, hearing, interrupt, speech, type MicTarget } from "./bar.tsx";
import { makeHold, release } from "./dictation.ts";
import { askQueued, setAskContext } from "./assistant.ts";
import { ChatView } from "./chat.tsx";

/** The side button is held to talk (assist.held): its release sends at once. */
let pushToTalk = false;

/** A summoning with the side button already let go: its dictation ends after this much silence. */
const QUICK_SILENCE_MS = 1500;
import type { AssistScreen } from "../types.ts";

const screen = signal<AssistScreen | null>(null);
// What's typed and not sent yet: kept across reloads and summonings (an update, a closed panel mustn't lose it).
const draft = stored("assist.draft");
/** Asked something since it opened: the answer shows. */
const asked = signal(false);
/** The part of the screen circled (a PNG cut out of the screenshot), sent with the whole screen; null: just the screen. */
const region = signal<string | null>(null);
/** The circle drawn over the screen (px), left showing so it's clear what goes along. */
const stroke = signal<[number, number][]>([]);
/** Live mode: on, and how many different moments it holds. */
const live = signal({ on: false, frames: 0 });
powos.on("assist.live", (l: { on: boolean; frames: number }) => (live.value = l));

powos.on("assist.context", (s: AssistScreen) => (screen.value = s));
// Summoned again (the page stays warm between summonings, AssistWeb): last time's question, answer and cut-out go,
// and it listens.
powos.on("assist.reset", () => {
  screen.value = null;
  asked.value = false;
  region.value = null;
  stroke.value = [];
  summoned();
});
powos.on("assist.hidden", () => takeOver());
// The side button let go (when Android passes it on, PowosAssistSession.onKeyUp): the dictation ends, and so sends.
// Hold to talk: the side button still down - the dictation lasts until it's let go (assist.keyup: PowerKey reads the
// release as root), then ends, and so sends. Already up: it ends after QUICK_SILENCE_MS of nothing heard.
// Push to talk: no preview, no silence - the release sends what's heard at once (release()).
powos.on("assist.held", () => {
  if (!autoSend) return;
  autoSend = false;
  pushToTalk = true;
  makeHold(mic);
});
powos.on("assist.quick", () => autoSend && powos.speech.quiet(QUICK_SILENCE_MS));
powos.on("assist.keyup", () => {
  if (!pushToTalk) return;
  pushToTalk = false;
  release(mic);
});

/** The screen's text that goes along with a question, at most (the host caps it too). */
const SCREEN_TEXT = 4000;

/**
 * What goes with every question asked here (assistant.ts setAskContext): the question, then the screen - the image
 * first (the host saves it where PowOS sees it), then the screen's text; the chat shows only the question (chat.tsx).
 */
async function withScreen(text: string) {
  const seen = screen.value?.text.trim();
  // The image first (the host saves it where PowOS sees it), then the screen's text: both after the question, which is
  // all the chat shows of it (powai.tsx). Live: the filmstrip of the last moments instead of the one screenshot.
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
}

/**
 * Asks the one conversation (assistant.ts askQueued, as the pill and the pet do): asked mid-turn, it waits for that
 * turn instead of being dropped; the screen goes along (withScreen).
 */
function send() {
  const text = draft.value.trim();
  if (!text) return;
  draft.value = "";
  asked.value = true;
  askQueued(text);
}

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

/** The text from a summoning's dictation, shown this long before it's sent (a tap on it keeps it to edit). */
const SEND_DELAY_MS = 300;
/** This summoning's dictation sends by itself when it ends (until the user takes over: a tap, typing, the mic). */
let autoSend = false;
/** About to send what was heard (the moment it shows); a tap on the field stops it. */
const sending = signal(false);
let sendTimer = 0;

function holdBack() {
  autoSend = false;
  pushToTalk = false;
  clearTimeout(sendTimer);
  sending.value = false;
}

const mic: MicTarget = {
  typed: () => draft.value,
  heard: (full, sendIt) => {
    draft.value = full;
    if (!sendIt) return;
    if (!autoSend) return void send();
    // The side button's dictation: the words show a moment first, then go.
    autoSend = false;
    sending.value = true;
    sendTimer = window.setTimeout(() => {
      sending.value = false;
      send();
    }, SEND_DELAY_MS);
  },
};

/** The summoning's dictation: listens, and sends when it ends. */
function summoned() {
  holdBack();
  autoSend = true;
  dictate(mic, true);
}

/** The user took over the field: no sending by itself, what's heard stays there to edit. */
function takeOver() {
  holdBack();
  interrupt(mic);
}

export function Assist() {
  const panel = useRef<HTMLDivElement>(null);
  // Over an app, asks carry the screen and put the chat in the app switcher. Registered on mount, never at import:
  // app.tsx imports this module in every mode, and home's sends then started PowosAiActivity (keepInRecents) - its
  // window covered home for a moment, a black flash on every send from the AI page.
  useEffect(() => (setAskContext(withScreen, true), () => setAskContext(null)), []);
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
  // Live: only the bar takes touches (the app under it is in use), kept as it moves and resizes; and its count of
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
      <div class="assist-panel tile" ref={panel}>
        <div class="assist-head">
          {!on && s?.screenshot ? (
            <img class="assist-shot" src={region.value ?? s.screenshot} alt="" />
          ) : (
            !on && <span class="assist-shot blank" />
          )}
          <span class="assist-title">PowOS AI</span>
          <span class="muted assist-sub">{on ? `● live · ${live.value.frames} moments` : s?.text ? "sees your screen" : "…"}</span>
          <button type="button" class={`assist-live ${on ? "on" : ""}`} onClick={() => powos.assist.live(!on)}>
            {on ? "stop" : "live"}
          </button>
          <button type="button" class="assist-open" onClick={() => (powos.ai.open(), powos.assist.close())}>
            open ↗
          </button>
        </div>
        {!on && s?.screenshot && (
          <div class="assist-attach">
            {region.value ? (
              <button type="button" class="chip" onClick={() => ((region.value = null), (stroke.value = []))}>
                the part you circled + the screen ✕
              </button>
            ) : (
              <span class="muted assist-hint">the screen goes along · circle anything above to point at it</span>
            )}
          </div>
        )}
        {/* The one chat (the pill's, chat.tsx): this conversation's newest, once something's asked here - until then
            the screen above stays free to circle. */}
        {asked.value && <ChatView head={false} />}
        <form
          class="assist-ask"
          onSubmit={(e) => {
            e.preventDefault();
            send();
          }}
        >
          {/* The one pill (bar.tsx Pill, as home's search and PowOS AI's page): three rows, then it scrolls; what's
              heard streams in as it's said, newest in view, and stays editable. */}
          <Pill
            target={mic}
            sending={sending.value}
            value={hearing(mic) ?? draft.value}
            onInput={(v: string) => {
              takeOver();
              draft.value = v;
            }}
            onPointerDown={() => takeOver()}
            onFocus={() => (takeOver(), powos.keyboard.show())}
            placeholder={speech.value.listening ? "listening…" : undefined}
            aria-label="Ask about this screen"
            enterKeyHint="send"
            autocomplete="off"
          />
        </form>
      </div>
    </div>
  );
}
