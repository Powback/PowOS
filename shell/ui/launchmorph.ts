/**
 * DS2: the launcher opening FROM home's dock search button (docksearch.tsx; the user, 01:53: "I was hoping it would
 * like expand to the sides and like go up naturally. But right now it seems like it just like fades out"). Runs in the
 * launcher overlay's page (pull.tsx), which lies over home with the same dock (the button's slot in it): its bar's
 * glass starts as the button's circle, on the button, and grows sideways to the bar's width while it rises into the
 * bar's place - one continuous move, the panel rising from it on the same settle (gesture.ts SETTLE_MS/SETTLE_CURVE,
 * the launcher swipe's), or following the finger of a swipe up from the button. Closed, it goes back into the button.
 *
 * Transforms only (the manager's DS5: no layout property animated, no crossfade): the glass is three pieces - two caps
 * scaled uniformly (round at every size) and a middle scaled sideways - in the pill's own box, the pill's own glass
 * cleared meanwhile; its content rides with it (the prompt glyph from the button's glyph to its place, the mic with
 * the right cap) and only the field's text comes in by opacity as there's room for it.
 */
import { signal } from "@preact/signals";
import { SETTLE_CURVE, SETTLE_MS } from "./gesture.ts";

export interface Rect {
  left: number;
  top: number;
  width: number;
  height: number;
}

/** The button's rect the open started from; non-null from pull.begin until the window goes (the button stays away). */
export const morphFrom = signal<Rect | null>(null);

interface Parts {
  pill: HTMLElement;
  /** The pill's own rect (its layout box: transforms here never change it). */
  r: Rect;
  b: Rect;
  /** Cap width: the pill's corner radius. */
  c: number;
  left: HTMLElement;
  mid: HTMLElement;
  right: HTMLElement;
  prompt: HTMLElement | null;
  /** The prompt glyph's centre x at rest (measured before any transform). */
  promptX: number;
  /** The field (and whatever isn't the prompt or right of it): rides with the left cap, comes in by opacity. */
  field: HTMLElement[];
  /** The mic and send: ride with the right cap. */
  tail: HTMLElement[];
  saved: string;
}

let parts: Parts | null = null;
let anims: Animation[] = [];
/** The morph's progress shown: 0 the button, 1 the bar. */
let at = 0;

/** The pill's glass, copied onto each piece (not its drop shadow: three overlapping shadows darken the seams). */
const GLASS = ["background-color", "background-image", "backdrop-filter", "-webkit-backdrop-filter", "border"];
const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

/** One piece of the glass, the pill's own glass copied onto it. */
function piece(pill: HTMLElement, cs: CSSStyleDeclaration, at: { radius: string; left: number; width: number }) {
  const { radius, left, width } = at;
  const el = document.createElement("span");
  el.className = "launch-glass";
  for (const k of GLASS) el.style.setProperty(k, cs.getPropertyValue(k));
  Object.assign(el.style, { left: `${left}px`, width: `${width}px`, borderRadius: radius });
  pill.prepend(el);
  return el;
}

/** The pill's content: the prompt glyph, the mic and what's after it (send), the rest (the field). */
function split(kids: HTMLElement[]) {
  const prompt = kids.find((k) => k.matches(".prompt")) ?? null;
  const mic = kids.findIndex((k) => k.matches(".mic"));
  const tail = mic < 0 ? [] : kids.slice(mic);
  return { prompt, tail, field: kids.filter((k) => k !== prompt && !tail.includes(k)) };
}

function setup(from: Rect): Parts | null {
  const pill = document.querySelector<HTMLElement>(".pull-screen > .bar .bar-pill");
  if (!pill || matchMedia("(prefers-reduced-motion: reduce)").matches) return null;
  const q = pill.getBoundingClientRect();
  if (q.width <= 0) return null;
  const r = { left: q.left, top: q.top, width: q.width, height: q.height };
  const cs = getComputedStyle(pill);
  const c = Math.min(r.height / 2, parseFloat(cs.borderTopLeftRadius) || r.height / 2);
  const saved = pill.getAttribute("style") ?? "";
  const kids = [...pill.children] as HTMLElement[];
  const { prompt, tail, field } = split(kids);
  const p: Parts = {
    pill,
    r,
    b: from,
    c,
    left: piece(pill, cs, { radius: `${c}px 0 0 ${c}px`, left: 0, width: c }),
    mid: piece(pill, cs, { radius: "0", left: c, width: Math.max(1, r.width - 2 * c) }),
    right: piece(pill, cs, { radius: `0 ${c}px ${c}px 0`, left: r.width - c, width: c }),
    prompt,
    promptX: prompt ? prompt.getBoundingClientRect().left + prompt.getBoundingClientRect().width / 2 : 0,
    field,
    tail,
    saved,
  };
  clearGlass(pill);
  return p;
}

/** The pill's own glass cleared while its pieces stand in for it (restored from [saved] at the end). */
function clearGlass(pill: HTMLElement) {
  pill.classList.add("launch-morph");
  const none: [string, string][] = [["background-color", "transparent"], ["background-image", "none"], ["box-shadow", "none"], ["backdrop-filter", "none"], ["-webkit-backdrop-filter", "none"], ["border-color", "transparent"]];
  for (const [k, v] of none) pill.style.setProperty(k, v, "important");
}

/** Each element's transform (and the field's opacity) at progress t: the glass's rect lerped from the button's to the pill's. */
function state(p: Parts, t: number): Map<HTMLElement, Keyframe> {
  const { r, b, c } = p;
  const g = { left: lerp(b.left, r.left, t), top: lerp(b.top, r.top, t), width: lerp(b.width, r.width, t), height: lerp(b.height, r.height, t) };
  const s = g.height / r.height;
  const cap = c * s;
  const dy = g.top - r.top;
  const out = new Map<HTMLElement, Keyframe>();
  out.set(p.left, { transform: `translate(${g.left - r.left}px, ${dy}px) scale(${s})` });
  const midW = Math.max(1, r.width - 2 * c);
  out.set(p.mid, { transform: `translate(${g.left + cap - (r.left + c)}px, ${dy}px) scale(${Math.max(0, g.width - 2 * cap) / midW}, ${s})` });
  out.set(p.right, { transform: `translate(${g.left + g.width - cap - (r.left + r.width - c)}px, ${dy}px) scale(${s})` });
  // Content rides vertically with the glass's centre.
  const cy = g.top + g.height / 2 - (r.top + r.height / 2);
  if (p.prompt) {
    // From the button's centre (its glyph) to its own place.
    out.set(p.prompt, { transform: `translate(${lerp(b.left + b.width / 2 - p.promptX, 0, t)}px, ${cy}px)` });
  }
  const fade = Math.max(0, Math.min(1, (t - 0.4) / 0.6));
  for (const f of p.field) out.set(f, { transform: `translate(${g.left - r.left}px, ${cy}px)`, opacity: String(fade) });
  // The mic and send inside the right cap; shown once the glass is wider than the button (no mic on a bare circle).
  const tailIn = Math.max(0, Math.min(1, (t - 0.25) / 0.5));
  for (const f of p.tail) out.set(f, { transform: `translate(${g.left + g.width - (r.left + r.width)}px, ${cy}px) scale(${lerp(0.6, 1, tailIn)})`, opacity: String(tailIn) });
  return out;
}

const SAMPLES = 11;

/** Animations from progress t0 to t1 ([ms] 0: paused at t0, for a finger to drive). */
function run(p: Parts, t0: number, t1: number, ms: number) {
  for (const a of anims) a.cancel();
  const per = new Map<HTMLElement, Keyframe[]>();
  for (let i = 0; i < SAMPLES; i++) {
    const t = lerp(t0, t1, i / (SAMPLES - 1));
    for (const [el, k] of state(p, t)) {
      const list = per.get(el) ?? [];
      list.push({ ...k, offset: i / (SAMPLES - 1) });
      per.set(el, list);
    }
  }
  const easing = `cubic-bezier(${SETTLE_CURVE.join(", ")})`;
  anims = [...per].map(([el, frames]) => el.animate(frames, { duration: Math.max(1, ms), easing: ms ? easing : "linear", fill: "both", id: "launch-morph" }));
  if (!ms) anims.forEach((a) => a.pause());
  return anims[0];
}

/** pull.begin with a button's rect: the glass on the button (this frame), the overlay's own button away under it. */
export function morphBegin(from: Rect) {
  reset();
  const own = document.querySelector(".pull-screen .dock .dock-search-face")?.getBoundingClientRect();
  const b = own && own.width > 0 ? { left: own.left, top: own.top, width: own.width, height: own.height } : from;
  morphFrom.value = b;
  // Now, not at the next render: the foot's rule changes what the panel's followers read (gesture.ts tableOf).
  document.querySelector(".pull-screen")?.classList.add("from-button");
  parts = setup(b);
  at = 0;
  if (parts) run(parts, 0, 0, 0);
}

/** A finger on it (a swipe up from the button): the morph at its openness. */
export function morphDrag(p: number) {
  if (!parts) return;
  at = Math.max(0, Math.min(1, p));
  const k = state(parts, at);
  for (const a of anims) {
    const el = (a.effect as KeyframeEffect | null)?.target as HTMLElement | null;
    const f = el && k.get(el);
    if (f) (a.effect as KeyframeEffect).setKeyframes([f, f]);
  }
}

/** Settles to the bar (1, then the real pill takes over) or into the button (0, held there until the window goes). */
export function morphTo(to: 0 | 1) {
  // Closing an open that finished: the pieces again, from the bar.
  if (!parts && to === 0 && morphFrom.peek()) ((parts = setup(morphFrom.peek()!)), (at = 1));
  const p = parts;
  if (!p) return;
  const from = at;
  at = to;
  const a = run(p, from, to, SETTLE_MS * Math.max(0.35, Math.abs(to - from)));
  if (to === 1) a?.finished.then(() => parts === p && at === 1 && finish(), () => {});
}

/** Open: the pieces go, the pill's own glass is back (the button stays away while the bar is up). */
function finish() {
  const p = parts;
  parts = null;
  for (const a of anims) a.cancel();
  anims = [];
  if (!p) return;
  for (const el of [p.left, p.mid, p.right]) el.remove();
  p.pill.classList.remove("launch-morph");
  if (p.saved) p.pill.setAttribute("style", p.saved);
  else p.pill.removeAttribute("style");
}

/** The window went (pull.hide), or a new open: nothing of the morph left; the overlay's button back. */
export function reset() {
  finish();
  at = 0;
  morphFrom.value = null;
  document.querySelector(".pull-screen")?.classList.remove("from-button");
}

/** Whether an open from the button is shown (pull.tsx: a close goes back into it). */
export const morphing = () => morphFrom.peek() != null;
