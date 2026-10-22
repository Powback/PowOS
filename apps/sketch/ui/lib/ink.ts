/**
 * Sketch's drawing as vector data and how it is painted. A stroke is x, y, width triples in the drawing's own space
 * (the canvas's device pixels when the drawing was started: its box). The canvas shows that space through a View
 * (scale + offset) fitted to the whole drawing, so a rotation, a fold or another screen redraws every stroke at the
 * new size - fitted, never cropped - and the canvas's pixels are never the state.
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

/** The drawing's extent: its box and every stroke (with half its width). */
export function extent(box: Box, inks: Ink[]): Rect {
  const r = { x0: 0, y0: 0, x1: box.w, y1: box.h };
  for (const k of inks) {
    const p = k.points;
    for (let i = 0; i + 2 < p.length; i += 3) {
      const h = p[i + 2] / 2;
      r.x0 = Math.min(r.x0, p[i] - h);
      r.y0 = Math.min(r.y0, p[i + 1] - h);
      r.x1 = Math.max(r.x1, p[i] + h);
      r.y1 = Math.max(r.y1, p[i + 1] + h);
    }
  }
  return r;
}

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

export function paint(g: CanvasRenderingContext2D, v: View, { box, base, inks }: Picture) {
  const c = g.canvas;
  g.globalCompositeOperation = "source-over";
  g.fillStyle = BG;
  g.fillRect(0, 0, c.width, c.height);
  if (base && base.naturalWidth) g.drawImage(base, v.ox, v.oy, box.w * v.s, box.h * v.s);
  for (const k of inks) stroke(g, k, v);
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
