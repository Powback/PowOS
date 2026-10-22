/**
 * The pen on the canvas: one active pointer at a time, pen pressure sets the width, a second finger cancels the stroke
 * (so the palm and zoom gestures don't scribble). Drawn live in canvas pixels; recorded in the drawing's space.
 */
import { BG, dot, segment, tail, toDrawing, type Ink, type View } from "./ink";
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
}

type P3 = [number, number, number];

function point(c: HTMLCanvasElement, e: PointerEvent, size: number): P3 {
  const r = c.getBoundingClientRect(), dpr = c.width / r.width;
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
    const [x, y, w] = toDrawing(this.v, p[0], p[1], p[2]);
    this.ink.points.push(Math.round(x * 10) / 10, Math.round(y * 10) / 10, Math.round(w * 10) / 10);
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

/** Wires the pen to the canvas. `live()` is the stroke in progress (a repaint draws it too); `stop()` unwires it. */
export function attachPen(c: HTMLCanvasElement, h: PenHooks) {
  const g = c.getContext("2d")!;
  const down = new Set<number>();
  let active: number | null = null;
  let live: Live | null = null;
  const onDown = (e: PointerEvent) => {
    down.add(e.pointerId);
    if (down.size > 1) {
      if (live) h.cancel();
      active = null;
      live = null;
      return;
    }
    try {
      c.setPointerCapture(e.pointerId);
    } catch {
      /* a synthetic pointer (a test) can't be captured */
    }
    active = e.pointerId;
    const t = h.tool();
    live = new Live(g, h.view(), t, point(c, e, t.size));
  };
  const onMove = (e: PointerEvent) => {
    if (e.pointerId !== active || !live) return;
    const size = h.tool().size;
    const all = e.getCoalescedEvents?.() ?? [];
    for (const ev of all.length ? all : [e]) live.to(point(c, ev, size));
  };
  const onUp = (e: PointerEvent) => {
    down.delete(e.pointerId);
    if (e.pointerId !== active) return;
    active = null;
    if (live) h.end(live.finish());
    live = null;
  };
  const on: [string, (e: PointerEvent) => void][] = [
    ["pointerdown", onDown],
    ["pointermove", onMove],
    ["pointerup", onUp],
    ["pointercancel", onUp],
  ];
  for (const [n, f] of on) c.addEventListener(n, f as EventListener);
  return {
    live: () => live?.ink ?? null,
    reproject: (v: View) => live?.reproject(v),
    stop: () => {
      for (const [n, f] of on) c.removeEventListener(n, f as EventListener);
    },
  };
}
