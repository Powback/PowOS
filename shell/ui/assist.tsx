/**
 * PowOS AI over another app (index.html?mode=assist; PowosAssistSession, the phone's digital assistant: holding the
 * power button). A panel at the bottom: the screen it was opened over (a thumbnail), the question - typed, or the mic
 * (hold to talk and send, tap to dictate) - and PowOS AI's answer as it comes. What's asked goes with the screen's text,
 * so "what's this?" means the screen. A tap above the panel puts it away.
 *
 * The screenshot goes along too (PowOS AI reads it: the host saves it where PowOS sees it, the question names the
 * path). Tapping the thumbnail opens it full size to circle what you mean instead - letting go cuts that part out.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { Mic, hearing, type MicTarget } from "./bar.tsx";
import { Now } from "./powai.tsx";
import type { AssistScreen } from "../types.ts";

const screen = signal<AssistScreen | null>(null);
const draft = signal("");
/** Asked something since it opened: the answer shows. */
const asked = signal(false);
/** What PowOS AI gets to look at with the question: the whole screen, a region cut out of it (a PNG), or nothing. */
const image = signal<{ region: string | null } | null>({ region: null });
/** The cut-out view, open. */
const cropping = signal(false);

powos.on("assist.context", (s: AssistScreen) => (screen.value = s));
// Summoned again (the page stays warm between summonings, AssistWeb): last time's question, answer and cut-out go.
powos.on("assist.reset", () => {
  screen.value = null;
  draft.value = "";
  asked.value = false;
  image.value = { region: null };
  cropping.value = false;
});

/** The screen's text that goes along with a question, at most (the host caps it too). */
const SCREEN_TEXT = 4000;

async function send() {
  const text = draft.value.trim();
  if (!text) return;
  draft.value = "";
  asked.value = true;
  const seen = screen.value?.text.trim();
  // The image first (the host saves it where PowOS sees it), then the screen's text: both after the question, which is
  // all the chat shows of it (powai.tsx).
  const path = image.value && screen.value?.screenshot ? await powos.assist.attach(image.value.region) : null;
  const context = [path && `(image of it: ${path} - read it to see the screen${image.value?.region ? ", the part I mean" : ""})`, seen?.slice(0, SCREEN_TEXT)]
    .filter(Boolean)
    .join("\n");
  powos.ai.send(context ? `${text}\n\n[What's on my screen right now:]\n${context}` : text);
}

/** Around the stroke, so a circle drawn tight still holds what it circles (px on screen). */
const PAD = 12;

/**
 * The screenshot full size: circle (or scribble over) what you mean; letting go cuts out the stroke's bounds (a canvas
 * from the same-origin image) as the image that goes with the question.
 */
function Crop({ src }: { src: string }) {
  const img = useRef<HTMLImageElement>(null);
  const [points, setPoints] = useState<[number, number][]>([]);
  const drawing = useRef(false);
  const cut = (pts: [number, number][]) => {
    const el = img.current!;
    const r = el.getBoundingClientRect();
    const xs = pts.map((p) => p[0]);
    const ys = pts.map((p) => p[1]);
    const left = Math.max(r.left, Math.min(...xs) - PAD);
    const top = Math.max(r.top, Math.min(...ys) - PAD);
    const right = Math.min(r.right, Math.max(...xs) + PAD);
    const bottom = Math.min(r.bottom, Math.max(...ys) + PAD);
    if (right - left < 16 || bottom - top < 16) return setPoints([]);
    const sx = el.naturalWidth / r.width;
    const sy = el.naturalHeight / r.height;
    const c = document.createElement("canvas");
    c.width = Math.round((right - left) * sx);
    c.height = Math.round((bottom - top) * sy);
    c.getContext("2d")!.drawImage(el, (left - r.left) * sx, (top - r.top) * sy, c.width, c.height, 0, 0, c.width, c.height);
    image.value = { region: c.toDataURL("image/png") };
    cropping.value = false;
  };
  return (
    <div class="crop">
      <div
        class="crop-area"
        onPointerDown={(e) => {
          (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
          drawing.current = true;
          setPoints([[e.clientX, e.clientY]]);
        }}
        onPointerMove={(e) => drawing.current && setPoints((p) => [...p, [e.clientX, e.clientY]])}
        onPointerUp={(e) => {
          drawing.current = false;
          cut([...points, [e.clientX, e.clientY]]);
        }}
      >
        <img ref={img} src={src} alt="" draggable={false} />
        <svg class="crop-stroke">
          <polyline points={points.map((p) => p.join(",")).join(" ")} />
        </svg>
      </div>
      <div class="crop-bar tile">
        <span class="muted">circle what you mean</span>
        <button type="button" onClick={() => (cropping.value = false)}>
          cancel
        </button>
        <button type="button" onClick={() => ((image.value = { region: null }), (cropping.value = false))}>
          whole screen
        </button>
      </div>
    </div>
  );
}

const mic: MicTarget = {
  typed: () => draft.value,
  heard: (full, sendIt) => {
    draft.value = full;
    if (sendIt) send();
  },
};

export function Assist() {
  useEffect(() => {
    powos.assist.screen().then((s) => s && (screen.value = s));
  }, []);
  const s = screen.value;
  return (
    <div class="assist" onClick={(e) => e.target === e.currentTarget && powos.assist.close()}>
      <div class="assist-panel tile">
        <div class="assist-head">
          {s?.screenshot ? (
            <img class="assist-shot" src={image.value?.region ?? s.screenshot} alt="" onClick={() => (cropping.value = true)} />
          ) : (
            <span class="assist-shot blank" />
          )}
          <span class="assist-title">PowOS AI</span>
          <span class="muted assist-sub">{s?.text ? "sees your screen" : "…"}</span>
          <button type="button" class="assist-open" onClick={() => (powos.ai.open(), powos.assist.close())}>
            open ↗
          </button>
        </div>
        {s?.screenshot && (
          <div class="assist-attach">
            {image.value ? (
              <button type="button" class="chip" onClick={() => (image.value = null)}>
                {image.value.region ? "region of the screen" : "the screen"} ✕
              </button>
            ) : (
              <button type="button" class="chip off" onClick={() => (image.value = { region: null })}>
                + the screen
              </button>
            )}
            <button type="button" class="chip off" onClick={() => (cropping.value = true)}>
              circle a part…
            </button>
          </div>
        )}
        {asked.value && <Now />}
        <form
          class="assist-ask"
          onSubmit={(e) => {
            e.preventDefault();
            send();
          }}
        >
          <input
            value={hearing(mic) ?? draft.value}
            onInput={(e) => (draft.value = (e.currentTarget as HTMLInputElement).value)}
            onFocus={() => powos.keyboard.show()}
            placeholder="ask about this screen"
            enterKeyHint="send"
            autocomplete="off"
          />
          <Mic target={mic} />
        </form>
      </div>
      {cropping.value && s?.screenshot && <Crop src={s.screenshot} />}
    </div>
  );
}
