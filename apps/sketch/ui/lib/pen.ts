/**
 * The pen on the canvas: one finger (or the pen) draws, pen pressure sets the width. A second finger cancels the stroke
 * and the two move the view instead (pan + pinch, `gesture`) until every finger is up, so the palm and zoom gestures
 * never scribble. Two quick taps in one spot are a double tap (its dots are dropped). Drawn live in canvas pixels;
 * recorded in the drawing's space.
 */
import { BG, dot, quantum, segment, tail, toDrawing, type Ink, type View } from "./ink";
import { uid } from "./outbox";

export interface Tool {
  color: string;
  size: number;
  eraser: boolean;
}

export interface PenHooks {
  view(): View;
  tool(): Tool;
  /** A finished stroke. */
  end(ink: Ink): void;
  /** The stroke was cancelled (a second finger): repaint without it. */
  cancel(): void;
  /** Two fingers: "start" with where they are, "move" with where they started and are now, "end" when one lifts. */
  gesture(phase: "start" | "move" | "end", from: [P2, P2], to: [P2, P2]): void;
  /** Two taps in one spot (their dots are never kept). */
  doubleTap(): void;
}

type P2 = [number, number];
type P3 = [number, number, number];
/** A tap: shorter than this, moved less than TAP_PX css px; a second one within DOUBLE_MS and DOUBLE_PX is a double tap. */
const TAP_MS = 250, TAP_PX = 10, DOUBLE_MS = 300, DOUBLE_PX = 40;

/**
 * Where the canvas sits, untransformed: its frame (the page it fills) and device px per CSS px. Not the canvas's own
 * rect: during a pinch the canvas carries a CSS transform (the last render, scaled), which must not move the fingers.
 */
export function frame(c: HTMLCanvasElement) {
  const r = (c.parentElement ?? c).getBoundingClientRect();
  return { left: r.left, top: r.top, dpr: c.width / (c.clientWidth || c.width || 1) };
}

const xy = (c: HTMLCanvasElement, e: PointerEvent): P2 => {
  const r = frame(c);
  return [(e.clientX - r.left) * r.dpr, (e.clientY - r.top) * r.dpr];
};

function point(c: HTMLCanvasElement, e: PointerEvent, size: number): P3 {
  const r = frame(c), dpr = r.dpr;
  const p = e.pointerType === "pen" ? e.pressure || 0.5 : e.pointerType === "mouse" ? 0.5 : 0.6;
  return [(e.clientX - r.left) * dpr, (e.clientY - r.top) * dpr, size * dpr * (0.4 + p * 1.2)];
}

/** Stroke in progress: what the pen draws now, and the same points in the drawing's space. */
class Live {
  ink: Ink;
  private mid: [number, number];
  constructor(private g: CanvasRenderingContext2D, private v: View, t: Tool, private last: P3) {
    this.ink = { uid: uid(), color: t.color, eraser: t.eraser, points: [] };
    this.mid = [last[0], last[1]];
    this.record(last);
    dot(g, this.color(), last);
  }
  private color() {
    return this.ink.eraser ? BG : this.ink.color;
  }
  private record(p: P3) {
    const [x, y, w] = toDrawing(this.v, p[0], p[1], p[2]), q = quantum(this.v.s);
    this.ink.points.push(Math.round(x * q) / q, Math.round(y * q) / q, Math.round(w * q) / q);
  }
  /** The view changed mid-stroke (a rotation): carry on from the same point at its new place. */
  reproject(v: View) {
    this.v = v;
    const q = this.ink.points, n = q.length;
    this.last = [v.ox + q[n - 3] * v.s, v.oy + q[n - 2] * v.s, q[n - 1] * v.s];
    this.mid = [this.last[0], this.last[1]];
  }
  finish() {
    if (this.ink.points.length > 3) tail(this.g, this.color(), this.mid, this.last);
    return this.ink;
  }
  to(p: P3) {
    this.mid = segment(this.g, this.color(), { mid: this.mid, last: this.last }, p);
    this.last = p;
    this.record(p);
  }
}

/** A finished tap held back for DOUBLE_MS: kept as a dot unless a second tap makes it a double tap. */
class Taps {
  private held: { ink: Ink; at: P2; t: number; timer: ReturnType<typeof setTimeout> } | null = null;
  constructor(private h: PenHooks) {}
  ink() {
    return this.held?.ink ?? null;
  }
  /** Keep the held dot now (before anything that comes after it). */
  flush() {
    const k = this.held;
    if (!k) return;
    clearTimeout(k.timer);
    this.held = null;
    this.h.end(k.ink);
  }
  /** A stroke ended: a tap is held (or with the held one is a double tap), anything else is kept after the held one. */
  ended(ink: Ink, tap: { at: P2; dpr: number } | null) {
    const k = this.held, now = performance.now();
    if (tap && k && now - k.t < DOUBLE_MS && Math.hypot(tap.at[0] - k.at[0], tap.at[1] - k.at[1]) < DOUBLE_PX * tap.dpr) {
      clearTimeout(k.timer);
      this.held = null;
      return this.h.doubleTap();
    }
    this.flush();
    if (!tap) return this.h.end(ink);
    this.held = { ink, at: tap.at, t: now, timer: setTimeout(() => this.flush(), DOUBLE_MS) };
  }
}

/** The fingers down on the canvas and, while two are, the pair moving the view (`blocked` until all are up after). */
class Fingers {
  private at = new Map<number, P2>();
  private pair: { ids: [number, number]; from: [P2, P2] } | null = null;
  blocked = false;
  constructor(private h: PenHooks) {}
  /** A finger down; true when it makes two or more (no drawing then). */
  down(id: number, p: P2) {
    this.at.set(id, p);
    if (this.at.size < 2) return this.blocked;
    if (!this.pair && !this.blocked && this.at.size === 2) {
      const ids = [...this.at.keys()] as [number, number];
      this.pair = { ids, from: [this.at.get(ids[0])!, this.at.get(ids[1])!] };
      this.h.gesture("start", this.pair.from, this.pair.from);
    }
    this.blocked = true;
    return true;
  }
  /** A finger moved; true when it's one of the pair (the view moved, nothing drawn). */
  move(id: number, p: P2) {
    if (this.at.has(id)) this.at.set(id, p);
    const q = this.pair;
    if (!q || !q.ids.includes(id)) return false;
    this.h.gesture("move", q.from, [this.at.get(q.ids[0])!, this.at.get(q.ids[1])!]);
    return true;
  }
  up(id: number) {
    this.at.delete(id);
    if (this.pair && this.pair.ids.includes(id)) {
      this.pair = null;
      this.h.gesture("end", [[0, 0], [0, 0]], [[0, 0], [0, 0]]);
    }
    if (!this.at.size) this.blocked = false;
  }
}

/** Wires the pen to the canvas. `live()` is what's drawn but not saved yet (a repaint draws it too); `stop()` unwires it. */
export function attachPen(c: HTMLCanvasElement, h: PenHooks) {
  const g = c.getContext("2d")!;
  const fingers = new Fingers(h);
  const taps = new Taps(h);
  let active: number | null = null;
  let live: Live | null = null;
  let started = { t: 0, at: [0, 0] as P2, far: 0 };
  const onDown = (e: PointerEvent) => {
    if (fingers.down(e.pointerId, xy(c, e))) {
      if (live) h.cancel();
      active = null;
      live = null;
      return taps.flush();
    }
    try {
      c.setPointerCapture(e.pointerId);
    } catch {
      /* a synthetic pointer (a test) can't be captured */
    }
    active = e.pointerId;
    const t = h.tool();
    live = new Live(g, h.view(), t, point(c, e, t.size));
    started = { t: performance.now(), at: xy(c, e), far: 0 };
  };
  const onMove = (e: PointerEvent) => {
    if (fingers.move(e.pointerId, xy(c, e)) || e.pointerId !== active || !live) return;
    const p = xy(c, e);
    started.far = Math.max(started.far, Math.hypot(p[0] - started.at[0], p[1] - started.at[1]));
    const size = h.tool().size;
    const all = e.getCoalescedEvents?.() ?? [];
    for (const ev of all.length ? all : [e]) live.to(point(c, ev, size));
  };
  const onUp = (e: PointerEvent) => {
    fingers.up(e.pointerId);
    if (e.pointerId !== active) return;
    active = null;
    const ink = live?.finish();
    live = null;
    if (!ink) return;
    const dpr = frame(c).dpr;
    const tap = performance.now() - started.t < TAP_MS && started.far < TAP_PX * dpr;
    taps.ended(ink, tap ? { at: started.at, dpr } : null);
  };
  const on: [string, (e: PointerEvent) => void][] = [
    ["pointerdown", onDown],
    ["pointermove", onMove],
    ["pointerup", onUp],
    ["pointercancel", onUp],
  ];
  for (const [n, f] of on) c.addEventListener(n, f as EventListener);
  return {
    live: () => [live?.ink, taps.ink()].filter((k): k is Ink => !!k),
    reproject: (v: View) => live?.reproject(v),
    stop: () => {
      taps.flush();
      for (const [n, f] of on) c.removeEventListener(n, f as EventListener);
    },
  };
}
