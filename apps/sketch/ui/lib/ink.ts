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

/** Zoom limits, in canvas px per drawing unit (1 = the scale the drawing was started at): 0.02x to 100x. */
export const MIN_S = 0.02, MAX_S = 100;
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

/** The rounding step for a point recorded through scale `s`: about 0.1 canvas px, so a stroke drawn at 100x is as
 * smooth as one drawn at 1x (a fixed 0.1 drawing unit would be 10 px steps there). */
export const quantum = (s: number) => 10 ** Math.ceil(Math.log10(Math.max(s, 1e-6) * 10));

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

/** A piece of stroke through points `p` with width w touches canvas `c`. */
function near(p: number[][], w: number, c: HTMLCanvasElement) {
  const h = w / 2 + 1;
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const q of p) ((x0 = Math.min(x0, q[0])), (y0 = Math.min(y0, q[1])), (x1 = Math.max(x1, q[0])), (y1 = Math.max(y1, q[1])));
  return x1 + h >= 0 && y1 + h >= 0 && x0 - h <= c.width && y0 - h <= c.height;
}

/**
 * A whole stroke through a view, exactly as the pen drew it: re-rendered from its points at the view's scale (crisp at
 * any zoom). Each segment is stroked on its own, so the ones off the canvas are skipped (a long stroke seen at 100x).
 */
export function stroke(g: CanvasRenderingContext2D, k: Ink, v: View) {
  const color = k.eraser ? BG : k.color;
  const p = k.points, cv = g.canvas;
  if (p.length < 3) return;
  const at = (i: number): [number, number, number] => [v.ox + p[i] * v.s, v.oy + p[i + 1] * v.s, p[i + 2] * v.s];
  let last = at(0);
  let mid: [number, number] = [last[0], last[1]];
  if (near([last], last[2], cv)) dot(g, color, last);
  for (let i = 3; i + 2 < p.length; i += 3) {
    const q = at(i);
    if (near([mid, last, q], Math.max(last[2], q[2]), cv)) mid = segment(g, color, { mid, last }, q);
    else mid = [(last[0] + q[0]) / 2, (last[1] + q[1]) / 2];
    last = q;
  }
  if (p.length > 3 && near([mid, last], last[2], cv)) tail(g, color, mid, last);
}

/** The whole drawing on a canvas: background, the base picture (an older drawing's raster) in its box, the strokes. */
export interface Picture {
  box: Box;
  /** An older drawing's raster with its background made transparent (`keyed`), so it has no edge on the canvas. */
  base: HTMLCanvasElement | null;
  inks: Ink[];
}

/**
 * An older drawing's picture as an overlay: its background pixels (BG, give or take the picture's compression) made
 * transparent, so the rectangle it was saved as never shows against the unbounded background. Only how it's drawn:
 * the saved picture is never changed.
 */
export function keyed(img: HTMLImageElement): HTMLCanvasElement {
  const c = document.createElement("canvas");
  c.width = img.naturalWidth;
  c.height = img.naturalHeight;
  const g = c.getContext("2d", { willReadFrequently: true })!;
  g.drawImage(img, 0, 0);
  const d = g.getImageData(0, 0, c.width, c.height), px = d.data;
  const [br, bg, bb] = [0x12, 0x12, 0x16];
  for (let i = 0; i < px.length; i += 4) {
    const e = Math.max(Math.abs(px[i] - br), Math.abs(px[i + 1] - bg), Math.abs(px[i + 2] - bb));
    if (e < 24) px[i + 3] = Math.round((px[i + 3] * Math.max(0, e - 8)) / 16);
  }
  g.putImageData(d, 0, 0);
  return c;
}

/**
 * Paints it through `v`: the background over the whole canvas (it has no edge: any pan, any zoom), the strokes
 * re-rendered as vectors at the view's scale, the ones wholly off the canvas skipped. Returns how many were drawn.
 */
export function paint(g: CanvasRenderingContext2D, v: View, { box, base, inks }: Picture): number {
  const c = g.canvas;
  g.globalCompositeOperation = "source-over";
  g.fillStyle = BG;
  g.fillRect(0, 0, c.width, c.height);
  if (base && base.width) {
    g.imageSmoothingQuality = "high";
    g.drawImage(base, v.ox, v.oy, box.w * v.s, box.h * v.s);
  }
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
