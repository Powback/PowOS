/**
 * Sketch's drawing as vector data and how it is painted. A stroke is x, y, width triples in the drawing's own space
 * (the canvas's device pixels when the drawing was started: its box). That space is unbounded; the canvas shows it
 * through a View (scale + offset): fitted to the whole drawing, or where the user panned / zoomed to (a Saved view:
 * centre + zoom, so a rotation, a fold or another screen keeps the same spot). The canvas's pixels are never the state.
 */

export const BG = "#121216";

export interface Ink {
  uid: string;
  color: string;
  eraser: boolean;
  /** x, y, width triples in the drawing's space. */
  points: number[];
}

export interface Box {
  w: number;
  h: number;
}

/** Drawing space -> canvas pixels: canvas = o + s * drawing. */
export interface View {
  s: number;
  ox: number;
  oy: number;
}

export interface Rect {
  x0: number;
  y0: number;
  x1: number;
  y1: number;
}

export const IDENTITY: View = { s: 1, ox: 0, oy: 0 };

/** A stroke's bounds (with half its width), kept per stroke: a stroke's points never change once it's saved. */
const bounds = new Map<string, { n: number; r: Rect }>();
export function bbox(k: Ink): Rect {
  const p = k.points, hit = bounds.get(k.uid);
  if (hit && hit.n === p.length) return hit.r;
  const r = { x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity };
  for (let i = 0; i + 2 < p.length; i += 3) {
    const h = p[i + 2] / 2;
    r.x0 = Math.min(r.x0, p[i] - h);
    r.y0 = Math.min(r.y0, p[i + 1] - h);
    r.x1 = Math.max(r.x1, p[i] + h);
    r.y1 = Math.max(r.y1, p[i + 1] + h);
  }
  bounds.set(k.uid, { n: p.length, r });
  return r;
}

/** The drawing's extent: its box and every stroke. */
export function extent(box: Box, inks: Ink[]): Rect {
  const r = { x0: 0, y0: 0, x1: box.w, y1: box.h };
  for (const k of inks) {
    const b = bbox(k);
    r.x0 = Math.min(r.x0, b.x0);
    r.y0 = Math.min(r.y0, b.y0);
    r.x1 = Math.max(r.x1, b.x1);
    r.y1 = Math.max(r.y1, b.y1);
  }
  return r;
}

/** A view as it's saved (the viewport table): the drawing point at the canvas's centre, CSS px per drawing unit. */
export interface Saved {
  cx: number;
  cy: number;
  zoom: number;
  /** See everything: refitted on every resize. */
  fit: boolean;
}

/** Zoom limits, in canvas px per drawing unit (1 = the scale the drawing was started at). */
export const MIN_S = 0.05, MAX_S = 16;
export const clampS = (s: number) => Math.min(MAX_S, Math.max(MIN_S, s));

/** A canvas: its backing store's size and device pixels per CSS px. */
export interface Screen {
  w: number;
  h: number;
  dpr: number;
}

/** The saved view on a canvas. */
export function place(v: Saved, c: Screen): View {
  const s = clampS(v.zoom * c.dpr);
  return { s, ox: c.w / 2 - v.cx * s, oy: c.h / 2 - v.cy * s };
}

/** The view as it's saved. */
export function save(v: View, c: Screen, fit: boolean): Saved {
  const r = (n: number) => Math.round(n * 1000) / 1000;
  return { cx: r((c.w / 2 - v.ox) / v.s), cy: r((c.h / 2 - v.oy) / v.s), zoom: r(v.s / c.dpr) || MIN_S, fit };
}

export type P2 = [number, number];
/**
 * Two fingers moved from a0, b0 (under view v0) to a, b: the drawing point that was under their centre is under it
 * again (pan) and the scale follows their distance (pinch, around that centre), clamped.
 */
export function pinch(v0: View, [a0, b0]: [P2, P2], [a, b]: [P2, P2]): View {
  const c0 = [(a0[0] + b0[0]) / 2, (a0[1] + b0[1]) / 2], c = [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2];
  const d0 = Math.hypot(a0[0] - b0[0], a0[1] - b0[1]), d = Math.hypot(a[0] - b[0], a[1] - b[1]);
  const s = clampS(d0 > 8 ? (v0.s * d) / d0 : v0.s);
  const px = (c0[0] - v0.ox) / v0.s, py = (c0[1] - v0.oy) / v0.s;
  return { s, ox: c[0] - px * s, oy: c[1] - py * s };
}

/** `r` (drawing space) touches a cw x ch canvas through `v`. */
export const onCanvas = (r: Rect, v: View, cw: number, ch: number) =>
  v.ox + r.x1 * v.s >= 0 && v.oy + r.y1 * v.s >= 0 && v.ox + r.x0 * v.s <= cw && v.oy + r.y0 * v.s <= ch;

/** The view that shows all of `r` in a cw x ch canvas, centred. */
export function fit(r: Rect, cw: number, ch: number): View {
  const ew = Math.max(1, r.x1 - r.x0), eh = Math.max(1, r.y1 - r.y0);
  const s = Math.min(cw / ew, ch / eh);
  return { s, ox: (cw - ew * s) / 2 - r.x0 * s, oy: (ch - eh * s) / 2 - r.y0 * s };
}

/** `r` is wholly on a cw x ch canvas through `v` (1 px of slack for rounding). */
export function shows(r: Rect, v: View, cw: number, ch: number): boolean {
  return v.ox + r.x0 * v.s >= -1 && v.oy + r.y0 * v.s >= -1 && v.ox + r.x1 * v.s <= cw + 1 && v.oy + r.y1 * v.s <= ch + 1;
}

/** Canvas pixels -> drawing space. */
export const toDrawing = (v: View, x: number, y: number, w: number): [number, number, number] => [
  (x - v.ox) / v.s,
  (y - v.oy) / v.s,
  w / v.s,
];

/** The stroke's first dot. */
export function dot(g: CanvasRenderingContext2D, color: string, [x, y, w]: [number, number, number]) {
  g.fillStyle = color;
  g.beginPath();
  g.arc(x, y, w / 2, 0, Math.PI * 2);
  g.fill();
}

/** One smoothed segment: from the last midpoint, through the last point, to the next midpoint. Returns that midpoint. */
export function segment(
  g: CanvasRenderingContext2D,
  color: string,
  { mid, last }: { mid: [number, number]; last: [number, number, number] },
  p: [number, number, number],
): [number, number] {
  const m: [number, number] = [(last[0] + p[0]) / 2, (last[1] + p[1]) / 2];
  g.strokeStyle = color;
  g.lineCap = "round";
  g.lineJoin = "round";
  g.lineWidth = (last[2] + p[2]) / 2;
  g.beginPath();
  g.moveTo(mid[0], mid[1]);
  g.quadraticCurveTo(last[0], last[1], m[0], m[1]);
  g.stroke();
  return m;
}

/** The stroke's last stretch: from the last midpoint straight to its end point (so it ends where the pen lifted). */
export function tail(g: CanvasRenderingContext2D, color: string, mid: [number, number], last: [number, number, number]) {
  g.strokeStyle = color;
  g.lineCap = "round";
  g.lineWidth = last[2];
  g.beginPath();
  g.moveTo(mid[0], mid[1]);
  g.lineTo(last[0], last[1]);
  g.stroke();
}

/** A whole stroke through a view, exactly as the pen drew it. */
export function stroke(g: CanvasRenderingContext2D, k: Ink, v: View) {
  const color = k.eraser ? BG : k.color;
  const p = k.points;
  if (p.length < 3) return;
  const at = (i: number): [number, number, number] => [v.ox + p[i] * v.s, v.oy + p[i + 1] * v.s, p[i + 2] * v.s];
  let last = at(0);
  let mid: [number, number] = [last[0], last[1]];
  dot(g, color, last);
  for (let i = 3; i + 2 < p.length; i += 3) {
    const q = at(i);
    mid = segment(g, color, { mid, last }, q);
    last = q;
  }
  if (p.length > 3) tail(g, color, mid, last);
}

/** The whole drawing on a canvas: background, the base picture (an older drawing's raster) in its box, the strokes. */
export interface Picture {
  box: Box;
  base: HTMLImageElement | null;
  inks: Ink[];
}

/** Paints it through `v`; strokes wholly off the canvas are skipped. Returns how many were drawn. */
export function paint(g: CanvasRenderingContext2D, v: View, { box, base, inks }: Picture): number {
  const c = g.canvas;
  g.globalCompositeOperation = "source-over";
  g.fillStyle = BG;
  g.fillRect(0, 0, c.width, c.height);
  if (base && base.naturalWidth) g.drawImage(base, v.ox, v.oy, box.w * v.s, box.h * v.s);
  let n = 0;
  for (const k of inks) if (onCanvas(bbox(k), v, c.width, c.height)) (stroke(g, k, v), n++);
  return n;
}

/** The whole drawing as a picture (gallery, home widget), its longer side at most `max` px. */
export function picture(p: Picture, max = 1080): string {
  const r = extent(p.box, p.inks);
  const ew = r.x1 - r.x0, eh = r.y1 - r.y0;
  const k = Math.min(1, max / Math.max(ew, eh));
  const c = document.createElement("canvas");
  c.width = Math.max(1, Math.round(ew * k));
  c.height = Math.max(1, Math.round(eh * k));
  paint(c.getContext("2d")!, fit(r, c.width, c.height), p);
  return c.toDataURL("image/webp", 0.85);
}
