/**
 * Render scan's live overlay (store "perf.meter" = {on, renders: true}, toggled by the "rs" switch on the status bar's
 * fps meter; home follows it in fpssample.ts - perf.meter is the key the host broadcasts to every shell page): every
 * component that renders is outlined for a moment (react-scan's flashes; red = a needless render), with its name and count, plus a small list of the top re-renderers. Off by default; off = no hooks (renderscan.ts),
 * no canvas, no timers.
 * Never itself a cause of work: one fixed canvas drawn offscreen (no style/layout; resized only with the viewport), rects from an
 * IntersectionObserver (async, no forced layout - never getBoundingClientRect in a render), the list a plain text node
 * updated at 2 Hz, not Preact (so it doesn't render itself into the scan), the rAF loop only while a flash fades.
 */
import { setOnRendered, startScan, stopScan, topRenders } from "./renderscan.ts";
import { viewport } from "./viewport.ts";

const FLASH_MS = 700, MAX_FLASHES = 400, LIST_MS = 500;
type Flash = { x: number; y: number; w: number; h: number; name: string; count: number; needless: boolean; born: number };
type Ctx2D = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D;
let cv: HTMLCanvasElement | null = null, ctx: Ctx2D | null = null, list: HTMLElement | null = null;
/** The bitmap drawn into: the canvas's OffscreenCanvas (transferControlToOffscreen), else the canvas itself. */
let surface: { width: number; height: number } | null = null;
/** One character's width of the labels' monospace font (set per size): a label is never measured. */
let charW = 6;
let io: IntersectionObserver | null = null, raf = 0, listTimer = 0, on = false, outlined = 0;
const flashes = new Map<Element, Flash>(), waiting = new Map<Element, { name: string; count: number; needless: boolean }>();
let colors = { ok: "", bad: "", text: "", bg: "" };

function readColors() {
  const s = getComputedStyle(document.documentElement), v = (n: string) => s.getPropertyValue(n).trim();
  colors = { ok: v("--color-accent"), bad: v("--color-red"), text: v("--color-foreground"), bg: v("--color-background") };
}
function size() {
  if (!cv) return;
  const v = viewport(), w = Math.round(v.w * v.dpr), h = Math.round(v.h * v.dpr);
  const b = surface ?? cv;
  if (b.width !== w || b.height !== h) { b.width = w; b.height = h; }
  // The font once per size (a resize resets the context's state): set in every frame's draw it was resolved against
  // the canvas's style each time - "FrameRequestCallback ui/renderoverlay.ts:draw 6 ms forced 5 ms" (perf-1793970543446).
  if (ctx) { ctx.font = "10px monospace"; ctx.direction = "ltr"; charW = ctx.measureText("0").width || charW; }
}
/** The element to outline for a component's first DOM node (a text node: its parent), or null. */
function target(dom: Node | null | undefined): Element | null {
  const el = dom ? (dom.nodeType === 1 ? (dom as Element) : dom.parentElement) : null;
  return el === cv || el === list ? null : el;
}
function rendered(dom: Node | null | undefined, name: string, needless: boolean) {
  const el = target(dom);
  if (!el || !io) return;
  const w = waiting.get(el);
  if (w) { w.count++; w.needless &&= needless; return; }
  if (waiting.size >= MAX_FLASHES) return;
  waiting.set(el, { name, count: (flashes.get(el)?.count ?? 0) + 1, needless });
  io.observe(el);
}
function onRects(entries: IntersectionObserverEntry[]) {
  const now = performance.now();
  for (const e of entries) {
    io?.unobserve(e.target);
    const w = waiting.get(e.target);
    waiting.delete(e.target);
    const r = e.boundingClientRect;
    if (!w || !r.width || !r.height) continue;
    outlined++;
    flashes.set(e.target, { x: r.x, y: r.y, w: r.width, h: r.height, name: w.name, count: w.count, needless: w.needless, born: now });
  }
  if (!raf && flashes.size) raf = requestAnimationFrame(draw);
}
function drawFlash(c: Ctx2D, f: Flash, a: number, label: boolean) {
  c.globalAlpha = a;
  c.strokeStyle = f.needless ? colors.bad : colors.ok;
  c.lineWidth = Math.min(4, 1 + f.count / 4);
  c.strokeRect(f.x, f.y, f.w, f.h);
  if (!label) return;
  const t = f.count > 1 ? `${f.name} x${f.count}` : f.name;
  c.fillStyle = c.strokeStyle;
  // The label's width from the monospace font's one character width, never c.measureText per label: on a DOM canvas
  // each call brought the page's style up to date mid-frame - measureText 1720 ms self in a 27 s home trace, "rAF
  // renderoverlay.ts:draw 23 ms, forced 22 ms" in 6 of its long frames, then the frame's own style pass again
  // (perf-1795459755191). Component names are ASCII identifiers.
  c.fillRect(f.x, Math.max(0, f.y - 12), t.length * charW + 6, 12);
  c.fillStyle = colors.bg;
  c.fillText(t, f.x + 3, Math.max(10, f.y - 2));
}
function draw() {
  raf = 0;
  if (!cv || !ctx) return;
  const now = performance.now(), c = ctx;
  // The viewport cached (viewport.ts): innerWidth / innerHeight / devicePixelRatio read here, in the rAF after the
  // frame's writes, forced a layout every flash frame - draw's 760 ms self time in perf-1794158824368 (11-08 18:27).
  const v = viewport();
  c.setTransform(v.dpr, 0, 0, v.dpr, 0, 0);
  c.clearRect(0, 0, v.w, v.h);
  let labels = 0;
  for (const [el, f] of flashes) {
    const age = now - f.born;
    if (age > FLASH_MS) { flashes.delete(el); continue; }
    drawFlash(c, f, 1 - age / FLASH_MS, labels++ < 16);
  }
  c.globalAlpha = 1;
  if (flashes.size) raf = requestAnimationFrame(draw);
}
function showList() {
  if (!list) return;
  const t = topRenders(6);
  const line = (r: (typeof t.byCount)[number]) => `${String(r.renders).padStart(5)} ${String(r.needless).padStart(4)} ${r.selfMs.toFixed(1).padStart(6)} ${r.name}`;
  const text = ["renders needless ms(self) component", ...t.byCount.map(line), "needless:", ...t.needless.slice(0, 4).map(line)].join("\n");
  // Written only when it changed: the same text set again still replaced its text node - a relayout and repaint of the
  // list twice a second on an idle home (gate home-paints).
  if (text !== list.textContent) list.textContent = text;
}

function mount() {
  readColors();
  cv = document.createElement("canvas");
  cv.style.cssText = "position:fixed;inset:0;width:100vw;height:100vh;pointer-events:none;z-index:2147483646;contain:strict";
  // Drawn through an OffscreenCanvas on this thread: its 2D context has no element, so neither fillText nor a resize
  // ever touches the document's style or layout (a DOM canvas's text calls update the page's style first).
  const off = typeof cv.transferControlToOffscreen === "function" ? cv.transferControlToOffscreen() : null;
  surface = off;
  ctx = off ? off.getContext("2d") : cv.getContext("2d");
  list = document.createElement("pre");
  list.style.cssText = "position:fixed;left:8px;bottom:8px;margin:0;padding:4px 6px;font:10px/1.25 monospace;white-space:pre;" +
    "pointer-events:none;z-index:2147483647;contain:content;color:var(--color-foreground);background:color-mix(in srgb,var(--color-background) 80%,transparent);border-radius:6px";
  document.documentElement.append(cv, list);
  size();
  addEventListener("resize", size);
  io = new IntersectionObserver(onRects);
  listTimer = window.setInterval(showList, LIST_MS);
}
function unmount() {
  cancelAnimationFrame(raf); raf = 0; clearInterval(listTimer); listTimer = 0;
  removeEventListener("resize", size);
  io?.disconnect(); io = null; flashes.clear(); waiting.clear();
  cv?.remove(); list?.remove(); cv = null; ctx = null; surface = null; list = null;
}

/** The overlay on or off in this page. */
export function setOverlay(v: boolean) {
  if (v === on) return;
  on = v;
  if (v) { outlined = 0; startScan("overlay"); mount(); setOnRendered(rendered); }
  else { setOnRendered(null); unmount(); stopScan("overlay"); }
}
export function overlayOn() { return on; }
/** How many outlines this page's overlay has drawn since it went on (the gate's proof it highlights renders here). */
export function overlayOutlined() { return outlined; }
