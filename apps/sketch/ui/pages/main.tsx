/**
 * Sketch's full-screen page: a canvas to draw on with a finger or a pen. Pen pressure sets the line width, strokes are
 * smoothed, two fingers never draw (so the palm and zoom gestures don't scribble).
 *
 * The drawing is its strokes (vector data in the drawing's own space, ../lib/ink.ts), each saved to the app's
 * database the moment it ends (../lib/outbox.ts), so a rotation, a fold, another screen or a restart never loses or
 * crops it: on any resize the canvas's backing store is resized and every stroke redrawn, fitted to the new size.
 * The page opens on your latest drawing; the gallery reopens any other or starts a fresh one.
 */
import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import { useApp, type Props } from "../lib/app";
import { extent, fit, IDENTITY, paint, picture, shows, type Box, type Ink, type View } from "../lib/ink";
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
/** A data URL as a loaded image (cached), or null while it loads; `loaded` re-renders once it has. */
function useImage(src: string, loaded: () => void): HTMLImageElement | null {
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
  return img && img.complete ? img : null;
}

/** The app's data: drawings, strokes, the outbox and a reducer caller that always uses the live connection. */
function useData(host: Props["host"]) {
  const app = useApp(host);
  const drawings = app.useTable<Drawing>("drawing").sort((a, b) => Number(b.id - a.id));
  const strokes = app.useTable<StrokeRow>("stroke");
  const [, bump] = useState(0);
  const [outbox] = useState(() => new Outbox(() => bump((n) => n + 1)));
  const appRef = useRef(app);
  appRef.current = app;
  const call: Call = (name, args) => appRef.current.useReducer(name)(args);
  useEffect(() => {
    if (app.db.status === "connected") void outbox.flush(call);
  }, [app.db.status, app.db.epoch]);
  return { drawings, strokes, outbox, call, connected: app.db.status === "connected" };
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
  return { key: cur.key, row, inks, box, base };
}

type Scene = ReturnType<typeof useScene>;

/**
 * The canvas: backing store sized to the element at device resolution, the view fitted to the whole drawing, a
 * repaint from the strokes on every change. Resizing never loses anything - the strokes are the state.
 */
function useCanvas(scene: Scene, tool: Tool, end: (ink: Ink, box: Box) => void) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const view = useRef<View>(IDENTITY);
  const live = useRef(scene);
  live.current = scene;
  const toolRef = useRef(tool);
  toolRef.current = tool;
  const pen = useRef<ReturnType<typeof attachPen> | null>(null);
  const boxOf = (c: HTMLCanvasElement) => live.current.box ?? { w: c.width / view.current.s, h: c.height / view.current.s };
  const repaint = (refit: boolean) => {
    const c = canvas.current;
    if (!c || !c.width) return;
    const s = live.current, box = boxOf(c), ink = pen.current?.live();
    const all = ink ? [...s.inks, ink] : s.inks;
    const r = extent(box, all);
    if (refit || !shows(r, view.current, c.width, c.height)) {
      view.current = s.box || all.length ? fit(r, c.width, c.height) : IDENTITY;
      pen.current?.reproject(view.current);
    }
    paint(c.getContext("2d")!, view.current, { box, base: s.base, inks: all });
    // What's drawn, for checks (tools/phone/verify/sketch-rotate.sh, apps/sketch/test): read only, never driven.
    const dbg = { key: s.key, view: view.current, extent: r, strokes: all.length, size: [c.width, c.height] };
    (window as unknown as { __sketch?: unknown }).__sketch = dbg;
  };
  const repaintRef = useRef(repaint);
  repaintRef.current = repaint;
  useSize(canvas, () => repaintRef.current(true));
  useEffect(() => {
    const c = canvas.current!;
    pen.current = attachPen(c, {
      view: () => view.current,
      tool: () => toolRef.current,
      end: (ink) => end(ink, boxOf(c)),
      cancel: () => repaintRef.current(false),
    });
    return () => pen.current?.stop();
  }, []);
  return { canvas, repaint };
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
  const { canvas, repaint } = useCanvas(scene, tool, (ink, box) => strokeRef.current(ink, box));
  const sig = scene.inks.map((k) => k.uid).join();
  useEffect(() => repaint(false), [sig, scene.base, scene.box?.w, scene.box?.h]);
  useEffect(() => repaint(true), [cur.key]);
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
  gallery: () => void;
}

function Tools({ tool, setTool, undo, redo, clear, gallery }: ToolsProps) {
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
  canvas: { position: "absolute", inset: 0, width: "100%", height: "100%", touchAction: "none" },
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
