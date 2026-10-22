/**
 * Sketch's full-screen page: an unbounded canvas to draw on with a finger or a pen. Pen pressure sets the line width,
 * strokes are smoothed. Two fingers never draw: they pan, and pinch zooms (0.02x to 100x) around their centre - never
 * rotate; while they move the last render is moved by a CSS transform (translate + scale only), and when they lift
 * the strokes are re-rendered as vectors at the new zoom, so they're crisp at any level. "fit all" shows the
 * whole drawing, a double tap goes back to its page at 100%. Each drawing's view is saved (the viewport table), so a
 * restart or a rotation keeps the same spot; one that was never moved stays fitted whole.
 *
 * The drawing is its strokes (vector data in the drawing's own space, ../lib/ink.ts), each saved to the app's
 * database the moment it ends (../lib/outbox.ts), so a rotation, a fold, another screen or a restart never loses or
 * crops it: on any resize the canvas's backing store is resized and every stroke redrawn, fitted to the new size.
 * The page opens on your latest drawing; the gallery reopens any other or starts a fresh one.
 */
import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import { useApp, type Props } from "../lib/app";
import { extent, fit, IDENTITY, keyed, paint, picture, pinch, place, save, shows } from "../lib/ink";
import type { Box, Ink, P2, Rect, Saved, Screen, View } from "../lib/ink";
import { Outbox, uid, visible, type Call, type Op, type Row } from "../lib/outbox";
import { attachPen, type Tool } from "../lib/pen";

interface Drawing {
  id: bigint;
  title: string;
  image: string;
  width: number;
  height: number;
  key: string;
  base: string;
}

interface StrokeRow extends Row {
  drawing: bigint;
}

interface ViewRow extends Saved {
  key: string;
}

/** The drawing on the canvas: its key, its row once the server has it, its box before then. */
interface Current {
  key: string;
  id: bigint | null;
  box: Box | null;
  /** Picked by the user or opened: the page no longer jumps to the latest drawing. */
  chosen: boolean;
}

/** An undoable step: these strokes were set to hidden = `to`. */
interface Step {
  uids: string[];
  to: boolean;
}

const COLORS = ["#f2f2f2", "#1b1b1f", "#ff5c5c", "#ffb340", "#ffe14d", "#5cd67a", "#4da3ff", "#b07cff"];
const SIZES = [2, 5, 12];
const UNDO_MAX = 30;
const THUMB_MS = 1500;

const fresh = (): Current => ({ key: uid(), id: null, box: null, chosen: true });

const images = new Map<string, HTMLImageElement>();
const keyedOf = new WeakMap<HTMLImageElement, HTMLCanvasElement>();
/** A data URL as a loaded image (cached) with its background keyed out (ink.ts keyed), or null while it loads. */
function useImage(src: string, loaded: () => void): HTMLCanvasElement | null {
  const img = useMemo(() => {
    if (!src) return null;
    let i = images.get(src);
    if (!i) {
      i = new Image();
      i.src = src;
      images.set(src, i);
    }
    return i;
  }, [src]);
  useEffect(() => {
    if (!img) return;
    if (img.complete) loaded();
    else img.onload = loaded;
  }, [img]);
  if (!img || !img.complete || !img.naturalWidth) return null;
  let k = keyedOf.get(img);
  if (!k) keyedOf.set(img, (k = keyed(img)));
  return k;
}

/** The app's data: drawings, strokes, the outbox and a reducer caller that always uses the live connection. */
function useData(host: Props["host"]) {
  const app = useApp(host);
  const drawings = app.useTable<Drawing>("drawing").sort((a, b) => Number(b.id - a.id));
  const strokes = app.useTable<StrokeRow>("stroke");
  const views = app.useTable<ViewRow>("viewport");
  const [, bump] = useState(0);
  const [outbox] = useState(() => new Outbox(() => bump((n) => n + 1)));
  const appRef = useRef(app);
  appRef.current = app;
  const call: Call = (name, args) => appRef.current.useReducer(name)(args);
  useEffect(() => {
    if (app.db.status === "connected") void outbox.flush(call);
  }, [app.db.status, app.db.epoch]);
  return { drawings, strokes, views, outbox, call, connected: app.db.status === "connected" };
}

/** Until the user picks: the latest drawing once the database answers (else a fresh page, as before). */
function useLatest(d: ReturnType<typeof useData>, cur: Current, setCur: (c: Current) => void) {
  useEffect(() => {
    if (cur.chosen || !d.connected) return;
    const drew = d.outbox.ops.some((o) => o.key === cur.key);
    const latest = d.drawings[0];
    if (drew) return setCur({ ...cur, chosen: true });
    if (!latest) return; // the rows may not be here yet
    setCur({ key: latest.key || uid(), id: latest.id, box: null, chosen: true });
  }, [cur.chosen, d.connected, d.drawings.length]);
}

/** What's on the canvas now: the row, its box, its base picture and its visible strokes. */
function useScene(d: ReturnType<typeof useData>, cur: Current, loaded: () => void) {
  const row = d.drawings.find((r) => (cur.id !== null && r.id === cur.id) || (r.key !== "" && r.key === cur.key));
  const rows = row ? d.strokes.filter((s) => s.drawing === row.id) : [];
  const inks = visible(rows, d.outbox.ops, cur.key);
  const box: Box | null = row ? { w: row.width, h: row.height } : cur.box;
  // An older drawing (no key yet) is its picture; once adopted, `base` keeps that picture under its strokes.
  const base = useImage(row ? row.base || (row.key === "" ? row.image : "") : "", loaded);
  // The view: one not sent yet, else the server's (none = fitted whole).
  const op = d.outbox.ops.filter((o) => o.kind === "view" && o.key === cur.key).pop();
  const vr = d.views.find((v) => v.key === cur.key);
  const saved: Saved | null = op?.kind === "view" ? op.v : vr ? { cx: vr.cx, cy: vr.cy, zoom: vr.zoom, fit: vr.fit } : null;
  return { key: cur.key, row, inks, box, base, saved };
}

type Scene = ReturnType<typeof useScene>;

/** How the canvas is looked at: the view, "free" (the user's, kept as saved) or fitted, and fingers moving it. */
interface Look {
  view: View;
  free: Saved | null;
  moving: boolean;
  /** The view the canvas's pixels were rendered at: while fingers move, a CSS transform shows them at `view`. */
  shown: View;
}

/** The strokes plus what the pen holds unsaved (the stroke in progress, a tap). */
const withHeld = (inks: Ink[], pen: { live(): Ink[] } | null) => {
  const held = pen ? pen.live() : [];
  return held.length ? [...inks, ...held] : inks;
};

const screen = (c: HTMLCanvasElement): Screen => ({ w: c.width, h: c.height, dpr: c.width / (c.clientWidth || c.width) });

/**
 * The view for this paint: the free one placed again on a resize, else fitted to `r` (on a resize, or when strokes left
 * it); `r` null = an empty new page (1:1).
 */
function nextView(k: Look, c: Screen, r: Rect | null, refit: boolean): View {
  if (k.free) return refit ? place(k.free, c) : k.view;
  if (!r) return refit ? IDENTITY : k.view;
  if (k.moving || (!refit && shows(r, k.view, c.w, c.h))) return k.view;
  return fit(r, c.w, c.h);
}

/**
 * The canvas: backing store sized to the element at device resolution, a repaint from the strokes on a change of the
 * drawing or of the view only (one per frame at most while two fingers move, none at rest), strokes off the canvas
 * skipped. The view is fitted to the whole drawing until the user pans or zooms; then it's theirs ("free": the same
 * centre and zoom across a resize, saved through `onView`).
 */
function useCanvas(scene: Scene, tool: Tool, end: (ink: Ink, box: Box) => void, onView: (v: Saved) => void) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const look = useRef<Look>({ view: IDENTITY, free: null, moving: false, shown: IDENTITY });
  const live = useRef(scene);
  live.current = scene;
  const toolRef = useRef(tool);
  toolRef.current = tool;
  const pen = useRef<ReturnType<typeof attachPen> | null>(null);
  const paints = useRef(0);
  const boxOf = (c: HTMLCanvasElement) => live.current.box ?? { w: c.width / look.current.view.s, h: c.height / look.current.view.s };
  const repaint = (refit: boolean) => {
    const c = canvas.current;
    if (!c || !c.width) return;
    const s = live.current, box = boxOf(c), all = withHeld(s.inks, pen.current);
    const r = extent(box, all), k = look.current;
    k.view = nextView(k, screen(c), s.box || all.length ? r : null, refit);
    if (refit) pen.current?.reproject(k.view);
    // Mid-pinch (a cancelled stroke, a stroke arriving) the pixels stay at the transform's base view.
    if (!k.moving || refit) k.shown = k.view;
    const drawn = paint(c.getContext("2d")!, k.shown, { box, base: s.base, inks: all });
    // What's drawn, for checks (tools/phone/verify/sketch-*.sh, apps/sketch/test): read only, never driven.
    (window as unknown as { __sketch?: unknown }).__sketch = {
      key: s.key, view: k.view, extent: r, strokes: all.length, drawn, size: [c.width, c.height],
      mode: k.free ? "free" : "fit", saved: s.saved, paints: ++paints.current,
    };
  };
  const repaintRef = useRef(repaint);
  repaintRef.current = repaint;
  useSize(canvas, () => repaintRef.current(true));
  const ctl = useViewControls({ canvas, look, live, onView, repaint: (refit) => repaintRef.current(refit), boxOf });
  useEffect(() => {
    const c = canvas.current!;
    pen.current = attachPen(c, {
      view: () => look.current.view,
      tool: () => toolRef.current,
      end: (ink) => end(ink, boxOf(c)),
      cancel: () => repaintRef.current(false),
      gesture: ctl.gesture,
      doubleTap: ctl.home,
    });
    return () => (pen.current?.stop(), ctl.stop());
  }, []);
  return { canvas, repaint, fitAll: ctl.fitAll };
}

interface ViewDeps {
  canvas: { current: HTMLCanvasElement | null };
  look: { current: Look };
  live: { current: Scene };
  onView: (v: Saved) => void;
  repaint: (refit: boolean) => void;
  boxOf: (c: HTMLCanvasElement) => Box;
}

/** What moves the view: two fingers, "fit all", a double tap (the page at 100%), and a saved view arriving. */
function useViewControls({ canvas, look, live, onView, repaint, boxOf }: ViewDeps) {
  const touched = useRef(false);
  const frame = useRef(0);
  const onViewRef = useRef(onView);
  onViewRef.current = onView;
  const v0 = useRef(IDENTITY);
  /** The last render (at look.shown) shown as if at `v`: a CSS translate + scale only, so never a rotation. */
  const show = (v: View | null) => {
    const c = canvas.current!;
    if (!v) return void (c.style.transform = "");
    const b = look.current.shown, r = v.s / b.s, d = c.width / (c.clientWidth || c.width);
    c.style.transform = `translate(${(v.ox - b.ox * r) / d}px, ${(v.oy - b.oy * r) / d}px) scale(${r})`;
  };
  /** The user set the view: kept free (or fitted again), painted, saved. */
  const settle = (v: View, fitted: boolean) => {
    const c = canvas.current!, k = look.current;
    touched.current = true;
    k.view = v;
    const sv = save(v, screen(c), fitted);
    k.free = fitted ? null : sv;
    repaint(false);
    onViewRef.current(sv);
  };
  // While the fingers move: one transform per frame, no repaint (a huge drawing stays as fast as an empty one).
  const soon = () => (frame.current ||= requestAnimationFrame(() => ((frame.current = 0), look.current.moving && show(look.current.view))));
  const gesture = (phase: "start" | "move" | "end", from: [P2, P2], to: [P2, P2]) => {
    const k = look.current;
    if (phase === "start") ((v0.current = k.view), (k.shown = k.view), (k.moving = true));
    else if (phase === "move") ((k.view = pinch(v0.current, from, to)), soon());
    else ((k.moving = false), settle(k.view, false), show(null));
  };
  const home = () => {
    const c = canvas.current!, b = boxOf(c);
    settle({ s: 1, ox: (c.width - b.w) / 2, oy: (c.height - b.h) / 2 }, false);
  };
  const fitAll = () => {
    const c = canvas.current!, s = live.current;
    settle(s.box || s.inks.length ? fit(extent(boxOf(c), s.inks), c.width, c.height) : IDENTITY, true);
  };
  // Another drawing, or its saved view arrived: take it, unless the user moved this one's view since it opened.
  const opened = useRef("");
  const scene = live.current;
  const sig = scene.saved ? JSON.stringify(scene.saved) : "";
  useEffect(() => {
    if (opened.current !== scene.key) ((opened.current = scene.key), (touched.current = false));
    if (!touched.current) look.current.free = scene.saved && !scene.saved.fit ? scene.saved : null;
    repaint(true);
  }, [scene.key, sig]);
  return { gesture, home, fitAll, stop: () => cancelAnimationFrame(frame.current) };
}

/** Resizes the canvas's backing store to its element (device pixels) on any size or density change, then `after`. */
function useSize(canvas: { current: HTMLCanvasElement | null }, after: () => void) {
  useEffect(() => {
    const c = canvas.current!;
    const size = () => {
      const dpr = window.devicePixelRatio || 1;
      const w = Math.round(c.clientWidth * dpr), h = Math.round(c.clientHeight * dpr);
      if (!w || !h) return;
      if (c.width !== w || c.height !== h) {
        c.width = w;
        c.height = h;
      }
      after();
    };
    size();
    const ro = new ResizeObserver(size);
    ro.observe(c);
    window.addEventListener("resize", size);
    return () => (ro.disconnect(), window.removeEventListener("resize", size));
  }, []);
}

/** Undo / redo / clear as hide / show of strokes (the server keeps them), and the picture made after a change. */
function useHistory(d: ReturnType<typeof useData>, cur: Current, scene: Scene) {
  const undo = useRef<Step[]>([]);
  const redo = useRef<Step[]>([]);
  const dirty = useRef(false);
  const timer = useRef<number | undefined>(undefined);
  const push = (op: Op) => d.outbox.push(op, d.call);
  const thumbNow = () => {
    clearTimeout(timer.current);
    if (!dirty.current) return;
    dirty.current = false;
    const box = scene.box;
    if (box) push({ kind: "thumb", key: cur.key, image: picture({ box, base: scene.base, inks: scene.inks }) });
  };
  const changed = () => {
    dirty.current = true;
    clearTimeout(timer.current);
    timer.current = window.setTimeout(() => thumbRef.current(), THUMB_MS);
  };
  const thumbRef = useRef(thumbNow);
  thumbRef.current = thumbNow;
  const act = (s: Step) => {
    const gone = redo.current.filter((r) => !r.to).flatMap((r) => r.uids);
    if (gone.length) push({ kind: "drop", key: cur.key, uids: gone });
    redo.current = [];
    undo.current.push(s);
    if (undo.current.length > UNDO_MAX) undo.current.shift();
    changed();
  };
  const step = (from: Step[], to: Step[], undoing: boolean) => {
    const s = from.pop();
    if (!s) return;
    push({ kind: "hide", key: cur.key, uids: s.uids, hidden: undoing ? !s.to : s.to });
    to.push(s);
    changed();
  };
  const reset = () => ((undo.current = []), (redo.current = []), thumbNow());
  return { undo, redo, act, step, reset, push, thumbNow, thumbRef };
}

export default function Main({ host, close }: Props) {
  const d = useData(host);
  const [cur, setCur] = useState<Current>(() => ({ ...fresh(), chosen: false }));
  const [tool, setTool] = useState<Tool>({ color: COLORS[0], size: SIZES[1], eraser: false });
  const [gallery, setGallery] = useState(false);
  const [, bump] = useState(0);
  useLatest(d, cur, setCur);
  const scene = useScene(d, cur, () => bump((n) => n + 1));
  const h = useHistory(d, cur, scene);
  const curRef = useRef(cur);
  curRef.current = cur;
  const onStroke = (ink: Ink, box: Box) => strokeEnded({ d, cur: curRef.current, row: scene.row, setCur, h }, ink, box);
  const strokeRef = useRef(onStroke);
  strokeRef.current = onStroke;
  // A view is saved once there's a drawing to look at (panning an empty page keeps nothing).
  const onView = (v: Saved) => {
    const c = curRef.current;
    if (scene.row || d.outbox.ops.some((o) => o.kind === "add" && o.key === c.key)) h.push({ kind: "view", key: c.key, v });
  };
  const viewRef = useRef(onView);
  viewRef.current = onView;
  const { canvas, repaint, fitAll } = useCanvas(scene, tool, (ink, box) => strokeRef.current(ink, box), (v) => viewRef.current(v));
  const sig = scene.inks.map((k) => k.uid).join();
  useEffect(() => repaint(false), [sig, scene.base, scene.box?.w, scene.box?.h]);
  useLeave(() => h.thumbRef.current());
  const open = (next: Current) => (h.reset(), setCur(next), setGallery(false));
  const clear = () => {
    const uids = scene.inks.map((k) => k.uid);
    if (uids.length) (h.push({ kind: "hide", key: cur.key, uids, hidden: true }), h.act({ uids, to: true }));
  };
  return (
    <div style={S.page}>
      <canvas ref={canvas} style={S.canvas} />
      <Colors tool={tool} setTool={setTool} back={() => (h.thumbNow(), close?.())} />
      <Tools
        tool={tool}
        setTool={setTool}
        undo={h.undo.current.length ? () => h.step(h.undo.current, h.redo.current, true) : null}
        redo={h.redo.current.length ? () => h.step(h.redo.current, h.undo.current, false) : null}
        clear={clear}
        fitAll={fitAll}
        gallery={() => (h.thumbNow(), setGallery(true))}
      />
      {gallery && (
        <Gallery
          drawings={d.drawings}
          close={() => setGallery(false)}
          fresh={() => open(fresh())}
          open={(r) => open({ key: r.key || uid(), id: r.id, box: null, chosen: true })}
          remove={(r) => d.call("remove", { id: r.id }).then(() => r.id === scene.row?.id && open(fresh()))}
        />
      )}
    </div>
  );
}

/** A finished stroke: an older drawing is adopted first, a new one gets its box, then the stroke is sent. */
interface StrokeCtx {
  d: ReturnType<typeof useData>;
  cur: Current;
  row: Drawing | undefined;
  setCur: (c: Current) => void;
  h: ReturnType<typeof useHistory>;
}

function strokeEnded({ d, cur, row, setCur, h }: StrokeCtx, ink: Ink, box: Box) {
  if (row && row.key === "" && !d.outbox.ops.some((o) => o.kind === "adopt" && o.key === cur.key))
    h.push({ kind: "adopt", key: cur.key, id: String(row.id) });
  const b = row ? { w: row.width, h: row.height } : cur.box ?? { w: Math.round(box.w), h: Math.round(box.h) };
  if (!row && !cur.box) setCur({ ...cur, box: b });
  h.push({ kind: "add", key: cur.key, ink, width: b.w, height: b.h });
  h.act({ uids: [ink.uid], to: false });
}

/** The picture is made when the page is hidden or closed (the strokes are saved already). */
function useLeave(leave: () => void) {
  useEffect(() => {
    const hide = () => document.visibilityState === "hidden" && leave();
    document.addEventListener("visibilitychange", hide);
    return () => (document.removeEventListener("visibilitychange", hide), leave());
  }, []);
}

function Colors({ tool, setTool, back }: { tool: Tool; setTool: (t: Tool) => void; back: () => void }) {
  return (
    <div style={S.bar}>
      <button style={S.btn} onClick={back} aria-label="back">‹</button>
      {COLORS.map((c) => (
        <button
          key={c}
          onClick={() => setTool({ ...tool, color: c, eraser: false })}
          style={{ ...S.swatch, background: c, outline: !tool.eraser && tool.color === c ? "2px solid #fff" : "none" }}
          aria-label={`color ${c}`}
        />
      ))}
    </div>
  );
}

interface ToolsProps {
  tool: Tool;
  setTool: (t: Tool) => void;
  undo: (() => void) | null;
  redo: (() => void) | null;
  clear: () => void;
  fitAll: () => void;
  gallery: () => void;
}

function Tools({ tool, setTool, undo, redo, clear, fitAll, gallery }: ToolsProps) {
  return (
    <div style={{ ...S.bar, top: "auto", bottom: "calc(12px + env(safe-area-inset-bottom))" }}>
      {SIZES.map((s) => (
        <button key={s} style={{ ...S.btn, ...(tool.size === s ? S.on : {}) }} onClick={() => setTool({ ...tool, size: s })} aria-label={`size ${s}`}>
          <span style={{ width: `${s + 4}px`, height: `${s + 4}px`, borderRadius: "50%", background: "currentColor", display: "block" }} />
        </button>
      ))}
      <button style={{ ...S.btn, ...(tool.eraser ? S.on : {}) }} onClick={() => setTool({ ...tool, eraser: !tool.eraser })} aria-label="eraser">⌫</button>
      <button style={S.btn} disabled={!undo} onClick={() => undo?.()} aria-label="undo">↶</button>
      <button style={S.btn} disabled={!redo} onClick={() => redo?.()} aria-label="redo">↷</button>
      <button style={S.btn} onClick={clear} aria-label="clear">✕</button>
      <button style={S.btn} onClick={fitAll} aria-label="fit all">⤢</button>
      <button style={S.btn} onClick={gallery} aria-label="drawings">▦</button>
    </div>
  );
}

interface GalleryProps {
  drawings: Drawing[];
  close: () => void;
  fresh: () => void;
  open: (d: Drawing) => void;
  remove: (d: Drawing) => void;
}

function Gallery({ drawings, close, fresh, open, remove }: GalleryProps) {
  return (
    <div style={S.gallery}>
      <div style={S.ghead}>
        <button style={S.btn} onClick={close} aria-label="close">‹</button>
        <span style={{ flex: 1, fontWeight: 600 }}>Drawings</span>
        <button style={S.btn} onClick={fresh} aria-label="new drawing">＋</button>
      </div>
      <div style={S.grid}>
        {drawings.map((d) => (
          <div key={String(d.id)} style={S.card} data-drawing={d.key || String(d.id)}>
            {d.image || d.base ? (
              <img src={d.image || d.base} style={S.thumb} onClick={() => open(d)} />
            ) : (
              <div style={{ ...S.thumb, background: "#121216" }} onClick={() => open(d)} />
            )}
            <div style={S.cap}>
              <span style={{ flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{d.title}</span>
              <button style={S.x} onClick={() => remove(d)} aria-label={`delete ${d.title}`}>×</button>
            </div>
          </div>
        ))}
        {drawings.length === 0 && <div style={{ opacity: 0.6 }}>Nothing saved yet.</div>}
      </div>
    </div>
  );
}

const S: Record<string, Record<string, string | number>> = {
  page: { position: "fixed", inset: 0, background: "#121216", color: "#eee", touchAction: "none", userSelect: "none" },
  canvas: { position: "absolute", inset: 0, width: "100%", height: "100%", touchAction: "none", transformOrigin: "0 0" },
  bar: {
    position: "absolute", left: "12px", right: "12px", top: "calc(12px + env(safe-area-inset-top))", display: "flex", gap: "8px",
    alignItems: "center", padding: "8px", borderRadius: "16px", background: "rgba(30,30,38,0.85)", backdropFilter: "blur(10px)",
    overflowX: "auto",
  },
  btn: {
    minWidth: "40px", height: "40px", border: "none", borderRadius: "12px", background: "rgba(255,255,255,0.06)", color: "inherit",
    font: "inherit", fontSize: "18px", display: "flex", alignItems: "center", justifyContent: "center", flex: "none",
  },
  on: { background: "rgba(120,160,255,0.35)" },
  swatch: { width: "30px", height: "30px", borderRadius: "50%", border: "none", flex: "none", outlineOffset: "2px" },
  gallery: { position: "absolute", inset: 0, background: "#121216", overflowY: "auto", padding: "calc(12px + env(safe-area-inset-top)) 12px 24px" },
  ghead: { display: "flex", alignItems: "center", gap: "8px", marginBottom: "12px" },
  grid: { display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(140px, 1fr))", gap: "10px" },
  card: { borderRadius: "12px", overflow: "hidden", background: "rgba(255,255,255,0.05)" },
  thumb: { width: "100%", aspectRatio: "3 / 4", objectFit: "contain", display: "block", background: "#121216" },
  cap: { display: "flex", alignItems: "center", gap: "6px", padding: "6px 8px", fontSize: "13px" },
  x: { border: "none", background: "none", color: "inherit", fontSize: "18px", opacity: 0.7 },
};
