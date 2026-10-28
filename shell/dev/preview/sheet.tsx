/**
 * The widget preview's page half (shell/dev/preview.sh -> preview.mjs, in the gate's headless Chromium): one widget's
 * contact sheet - every size it allows on the cover screen's and the inner screen's cells - drawn by the shell's own
 * components (an OWL widget's tile is ui/owl.tsx's OwlWidget in a .home-tile like grid.tsx's, an app's island its
 * module with an island's props, a shell panel its component), then measured: the fit checks below.
 *
 * Loaded into the home page (index.html, the mock bridge) after it's ready; home itself is hidden under the sheet.
 */
import { render, type ComponentType } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { powos } from "../../bridge.ts";
import { OwlWidget } from "../../ui/owl.tsx";
import { host as realHost } from "../../apps/stdb.ts";
import { net } from "../../apps/net.ts";
import { WidgetSheet } from "../../ui/widgetsheet.tsx";
import type { HomeItem } from "../../types.ts";

declare function importShim(url: string): Promise<any>;

export interface Cell {
  /** Unique: the OWL key the trees are served under, or a DOM id. */
  key: string;
  label: string;
  screen: "folded" | "unfolded";
  cols: number;
  rows: number;
  /** The tile's box on home (cells x cell size), CSS px; the face is this less the gap. */
  w: number;
  h: number;
}

export interface Spec {
  title: string;
  kind: "owl" | "island" | "panel";
  /** island: the app id and its widget's entry; panel: the shell panel's name. */
  app?: string;
  entry?: string;
  panel?: string;
  /** island: the mock data its host answers with (rows by table, net responses by URL pattern). */
  data?: {
    rows?: Record<string, any[]>;
    /** By URL pattern: an answer ([status], [json]), or [error] - the request fails with that raw text, as the native layer's would (away from home: "failed to connect to (192.168.x.x...)"). */
    net?: { match: string; status?: number; json?: unknown; error?: string }[];
    /**
     * A native-card island's Android widget: the tree its host answers with (fixtures only), [images] by ref (data
     * URLs), [frame] the pixel fallback's picture (a tree with nothing to draw shows it).
     */
    android?: { tree: any; images?: Record<string, string>; frame?: string };
    /** The app's localStorage before it mounts (e.g. what it cached from an earlier visit). */
    storage?: Record<string, string>;
    /**
     * A long press on [press] in the first [pressCell] tile ("4x2", folded), once it's up: the widget's detail sheet
     * (ui/widgetsheet.tsx) shows in the contact sheet. Held, then a pointercancel - never a release, never a tap.
     */
    press?: string;
    pressCell?: string;
  };
  /** panel agents: the mock's agents replaced (preview.mjs's nobody-running variants). */
  agents?: { role: string; state: "working" | "idle" | "needs_you" | "blocked" | "paused" | "gone"; title: string; step: string; report: string; ago: number }[];
  cells: Cell[];
}

/** What a canvas reported (OwlWidget -> powos.widgets.canvas), by widget key: the second trees are drawn at these. */
const canvases: Record<string, Record<string, [number, number]>> = {};
powos.widgets.canvas = async (key: string, id: string, w: number, h: number) => {
  (canvases[key] ??= {})[id] = [Math.round(w * 10) / 10, Math.round(h * 10) / 10];
};

/** An island's host over mock data: the app's tables as given, its network answered from the data's patterns. */
function mockHost(spec: Spec) {
  const rows = spec.data?.rows ?? {};
  const db = { conn: { db: Object.fromEntries(Object.keys(rows).map((t) => [t, {}])), reducers: {} }, status: "connected", epoch: 1 };
  const answer = (url: string) => {
    const hit = spec.data?.net?.find((n) => new RegExp(n.match).test(url));
    if (hit?.error !== undefined) throw net.error(new Error(hit.error));
    const body = hit?.json ?? null;
    return { status: hit ? (hit.status ?? 200) : 404, ok: !!hit, json: () => body, text: () => JSON.stringify(body), headers: {} };
  };
  return {
    ...realHost,
    useDb: () => db,
    useRows: (_db: unknown, table: string) => rows[table] ?? [],
    openApp: () => {},
    appWidget: spec.data?.android && {
      idOf: async () => 1,
      data: (id: number, on: (d: unknown) => void) => {
        const t = window.setTimeout(() => on({ id, provider: "preview", at: Date.now(), tree: spec.data!.android!.tree }), 0);
        return () => window.clearTimeout(t);
      },
      frames: (_id: number, _w: number, _h: number, on: (u: string) => void) => {
        const t = window.setTimeout(() => spec.data!.android!.frame && on(spec.data!.android!.frame), 0);
        return () => window.clearTimeout(t);
      },
      image: async (ref: string) => spec.data!.android!.images?.[ref] ?? null,
      tap: async () => {},
    },
    net: {
      ...net,
      fetch: async (_app: string, url: string) => answer(url),
      useEvents: (_app: string, url: string | null) => (url && spec.data?.net?.some((n) => n.error !== undefined && new RegExp(n.match).test(url)) ? "retry" : "open"),
    },
  };
}

/**
 * The page's localStorage as this widget's own, seeded from its data: the sheets run side by side on one origin, and a
 * variant's "what it cached last time" (or the plain one's fresh cache) mustn't leak into another's tiles.
 */
let stored: Map<string, string> | null = null;
function pageStorage(seed: Record<string, string>) {
  if (!stored) {
    stored = new Map();
    const m = stored;
    const mem = {
      getItem: (k: string) => m.get(k) ?? null,
      setItem: (k: string, v: string) => void m.set(k, String(v)),
      removeItem: (k: string) => void m.delete(k),
      clear: () => m.clear(),
      key: (i: number) => [...m.keys()][i] ?? null,
      get length() {
        return m.size;
      },
    };
    Object.defineProperty(window, "localStorage", { value: mem, configurable: true });
  }
  for (const [k, v] of Object.entries(seed)) stored.set(k, v);
}

function sheetProblems(sh: HTMLElement): string[] {
  const r = sh.getBoundingClientRect();
  const body = sh.querySelector<HTMLElement>(".wsheet-body");
  const bad: string[] = [];
  if (r.top < 0 || r.bottom > innerHeight + 0.5) bad.push(`detail sheet off the screen (${Math.round(r.top)}-${Math.round(r.bottom)} of ${innerHeight} px)`);
  const last = body?.lastElementChild?.getBoundingClientRect();
  const scrolls = !!body && body.scrollHeight > body.clientHeight + 1 && getComputedStyle(body).overflowY === "auto";
  if (last && body && last.bottom > body.getBoundingClientRect().bottom + 0.5 && !scrolls) bad.push("detail sheet's last row cut off (no scroll to it)");
  return bad;
}

function Island({ spec, cell }: { spec: Spec; cell: Cell }) {
  const [C, setC] = useState<ComponentType<any> | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    pageStorage(spec.data?.storage ?? {});
    importShim(`./_app/${spec.app}/${spec.entry}`).then(
      (m) => setC(() => m.default),
      (e) => setErr(String(e?.message ?? e)),
    );
  }, []);
  const face = useRef<HTMLDivElement>(null);
  const pressHere = !!spec.data?.press && spec.cells.find((c) => `${c.cols}x${c.rows}` === (spec.data?.pressCell ?? "4x2")) === cell;
  useEffect(() => {
    if (!C || !pressHere) return;
    const t = window.setTimeout(() => {
      const el = face.current?.querySelector(spec.data!.press!);
      if (!el) return;
      const r = el.getBoundingClientRect();
      const ev = (type: string) => new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 9, pointerType: "touch", isPrimary: true, clientX: r.left + 20, clientY: r.top + r.height / 2, buttons: type === "pointerdown" ? 1 : 0 });
      el.dispatchEvent(ev("pointerdown"));
      window.setTimeout(() => el.dispatchEvent(ev("pointercancel")), 700);
      // The sheet it opened must fit the screen: inside it top to bottom, the last row reachable (shown, or the body
      // scrolls to it) - a sheet running under the dock cut the last room off on the phone.
      window.setTimeout(() => {
        const sh = document.querySelector<HTMLElement>(".wsheet");
        if (face.current) face.current.dataset.pvSheet = sh ? sheetProblems(sh).join("\n") : "the long press opened no sheet";
      }, 1500);
    }, 300);
    return () => clearTimeout(t);
  }, [C]);
  if (err) return <div class="tile widget-face"><div class="widget-error">{err}</div></div>;
  if (!C) return <div class="tile island-face" />;
  return (
    <div class="tile island-face" ref={face}>
      <C host={mockHost(spec)} app={spec.app} cells={[cell.cols, cell.rows]} base={`./_app/${spec.app}/`} />
    </div>
  );
}

function Panel({ spec, cell }: { spec: Spec; cell: Cell }) {
  const [C, setC] = useState<ComponentType<any> | null>(null);
  useEffect(() => {
    const from: Record<string, [string, string]> = { agents: ["./ui/agents.tsx", "AgentsPanel"], recents: ["./ui/recentwidget.tsx", "RecentsPanel"] };
    const [file, name] = from[spec.panel!] ?? [];
    if (file) importShim(file).then((m) => setC(() => m[name]));
  }, []);
  // A variant's agents (preview.mjs panel.agents-idle / -empty): the mock's replaced once the widget subscribed, and
  // the mock's ticking coder kept quiet so it doesn't come back.
  useEffect(() => {
    if (!C || !spec.agents) return;
    const w = window as unknown as { __mockEvents?: { emit(n: string, e: unknown): void }; __powosMockQuiet?: boolean };
    w.__powosMockQuiet = true;
    const now = Date.now();
    const agents = spec.agents.map((a, i) => ({
      id: `mac:v${i}`, host: "mac", parent: null, cwd: "PowOS", pid: 0, subs: 0, unread: 0, started: now - 3_600_000 - a.ago, rev: 1,
      role: a.role, state: a.state, title: a.title, step: a.step, report: a.report, last: now - a.ago,
    }));
    const t = setTimeout(() => w.__mockEvents?.emit("agents.delta", { full: true, agents, tasks: [], messages: [], asks: [] }), 200);
    return () => clearTimeout(t);
  }, [C]);
  const item: HomeItem = { key: `panel:${spec.panel}`, kind: "panel", name: spec.panel, page: 1, cell: { x: 0, y: 0, w: cell.cols, h: cell.rows }, resizable: true, minSize: [2, 1], size: [cell.cols, cell.rows] };
  return C ? <C item={item} /> : null;
}

function Tile({ spec, cell }: { spec: Spec; cell: Cell }) {
  return (
    <div class="pv-cell" data-key={cell.key}>
      <div class="pv-label">{cell.label}</div>
      <div class={`home-tile ${spec.kind === "owl" ? "widget" : "panel"}`} style={{ position: "relative", left: 0, top: 0, width: `${cell.w}px`, height: `${cell.h}px` }}>
        {spec.kind === "owl" && (
          <div class="tile widget-face">
            <OwlWidget widget={cell.key} cells={{ x: 0, y: 0, w: cell.cols, h: cell.rows }} />
          </div>
        )}
        {spec.kind === "island" && <Island spec={spec} cell={cell} />}
        {spec.kind === "panel" && <Panel spec={spec} cell={cell} />}
      </div>
      <div class="pv-problems" />
    </div>
  );
}

function Sheet({ spec }: { spec: Spec }) {
  const rows = (["folded", "unfolded"] as const).map((s) => spec.cells.filter((c) => c.screen === s));
  return (
    <div class="pv-sheet">
      <h1>{spec.title}</h1>
      {rows.map((cells, i) =>
        cells.length ? (
          <section key={i}>
            <h2>{i ? "inner screen (unfolded)" : "cover screen (folded)"}</h2>
            <div class="pv-row">
              {cells.map((c) => (
                <Tile key={c.key} spec={spec} cell={c} />
              ))}
            </div>
          </section>
        ) : null,
      )}
    </div>
  );
}

const STYLE = `
  body > :not(#pv-root) { display: none !important; }
  html, body { overflow: visible !important; height: auto !important; }
  #pv-root { position: relative; padding: 16px 20px 24px; width: max-content; min-width: 100vw; box-sizing: border-box; }
  .pv-sheet h1 { font: 600 18px var(--font); color: var(--color-foreground); margin: 0 0 4px; text-shadow: var(--label-shadow); }
  .pv-sheet h2 { font: 13px var(--font); color: var(--color-foreground); opacity: .85; margin: 14px 0 6px; text-shadow: var(--label-shadow); }
  .pv-row { display: flex; flex-wrap: wrap; gap: 14px 18px; align-items: flex-start; max-width: var(--pv-max, 1900px); }
  .pv-cell { display: flex; flex-direction: column; gap: 4px; }
  .pv-label { font: 12px var(--font); color: var(--color-foreground); text-shadow: var(--label-shadow); }
  .pv-cell.bad .home-tile { outline: 2px solid var(--color-red); outline-offset: 2px; border-radius: var(--radius); }
  .pv-problems { font: 11px var(--font); color: var(--color-red); max-width: 100%; white-space: pre-wrap; text-shadow: var(--label-shadow); }
  .pv-cell .pv-problems:empty { display: none; }
`;

/** Draws [spec]'s sheet in place of home; resolves once its tiles have had time to load and settle. */
export async function mount(spec: Spec, settleMs = 900) {
  const root = document.createElement("div");
  root.id = "pv-root";
  document.body.append(root);
  const st = document.createElement("style");
  st.textContent = STYLE;
  document.head.append(st);
  render(
    <>
      <Sheet spec={spec} />
      <WidgetSheet />
    </>,
    root,
  );
  await new Promise((r) => setTimeout(r, settleMs));
  await stable(root);
}

/** What the sheet shows, as a number: its markup and every canvas's drawn pixels. */
const shown = (root: HTMLElement) => root.innerHTML.length + [...root.querySelectorAll("canvas")].reduce((n, c) => n + (c.width ? c.toDataURL().length : 0), 0);

/**
 * Resolves once the sheet has stopped changing for 400 ms (at most 6 s): a tile whose content arrives or paints late
 * (a terminal's transcript on a loaded run) is measured settled, not mid-draw - "nothing drawn" at 4x4 vs a sparse
 * fit finding was the same tile measured before and after, depending on the machine's load.
 */
async function stable(root: HTMLElement) {
  let last = shown(root);
  for (let still = 0, t = 0; still < 8 && t < 120; t++) {
    await new Promise((r) => setTimeout(r, 50));
    const now = shown(root);
    still = now === last ? still + 1 : 0;
    last = now;
  }
}

export const canvasSizes = () => canvases;

/** A box's visible part: clipped by every overflow-hiding ancestor up to [stop]. */
function visible(el: Element, r: DOMRect, stop: Element) {
  let { left, top, right, bottom } = r;
  for (let a = el.parentElement; a && a !== stop.parentElement; a = a.parentElement) {
    const cs = getComputedStyle(a);
    if (cs.overflowX === "visible" && cs.overflowY === "visible") continue;
    const b = a.getBoundingClientRect();
    if (cs.overflowX !== "visible") (left = Math.max(left, b.left)), (right = Math.min(right, b.right));
    if (cs.overflowY !== "visible") (top = Math.max(top, b.top)), (bottom = Math.min(bottom, b.bottom));
  }
  return { left, top, right, bottom, w: Math.max(0, right - left), h: Math.max(0, bottom - top) };
}

/** A canvas's drawn pixels' box, in page coordinates (null: nothing drawn). */
function inked(c: HTMLCanvasElement) {
  if (!c.width || !c.height) return null;
  const d = c.getContext("2d")!.getImageData(0, 0, c.width, c.height).data;
  let x0 = c.width, y0 = c.height, x1 = -1, y1 = -1;
  for (let y = 0; y < c.height; y++)
    for (let x = 0; x < c.width; x++)
      if (d[(y * c.width + x) * 4 + 3] > 24) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
  if (x1 < 0) return null;
  const r = c.getBoundingClientRect();
  const k = r.width / c.width;
  return { left: r.left + x0 * k, top: r.top + y0 * k, right: r.left + (x1 + 1) * k, bottom: r.top + (y1 + 1) * k };
}

/** Painted: a background or a shadow of its own (a chip, a bar, a swatch), not a transparent box. */
const painted = (cs: CSSStyleDeclaration) =>
  (cs.backgroundColor && !/rgba\(0, 0, 0, 0\)|transparent/.test(cs.backgroundColor)) || cs.backgroundImage !== "none";

/**
 * The fit checks, per tile: what fails the gate, each with the tile's size.
 * - clipped text: a text box wider (or taller) than the box that shows it - ellipsis, a cut line;
 * - a row cut in half: content partly hidden by the tile's (or a container's) edge - between 8% and 92% of it shows;
 * - unfilled: the content's box leaves more than [EMPTY] of a side of the tile's inside empty;
 * - small content: what's drawn (text boxes, painted boxes, a canvas's ink, an SVG) covers less than [COVER] of it
 *   (calibrated 2026-10-21 on the manager's review: the big tiles flagged as "a tiny 5° in a huge box" measured 8-15%,
 *   the folded ones approved as they were 27-44%);
 * - scroll: a scrolling container in a tile (a home tile can't take a scroll gesture from the page) - but a strip
 *   that scrolls sideways and says so (touch-action: pan-x: it took the gesture), or a list that scrolls up and down
 *   in whole rows (pan-y, scroll-snap y);
 * - a slider (a range, role=slider: a drag-to-dim pill) inside something that scrolls sideways;
 * - a sideways drag (touch-action none / pan-y) without the flag home's pager respects (role=slider, data-owns-gesture);
 * - hard border: a drawn 1px+ line round content (the design language: no lines).
 * An island's shared offline state (.island-offline.alone: the app can't reach its device, nothing to show) and the
 * Agents widget's compact empty line (.ag-idle-line: nobody running, a small tile / the desktop) are sparse by design -
 * one calm muted line was asked for, not a filled tile - so unfilled / small content don't apply to them; everything
 * else (clipped text above all) does.
 */
/** How much of each tile its content covered, %, by tile key: the last check()'s. */
export const fills: Record<string, number> = {};

export function check(EMPTY = 0.12, COVER = 0.25) {
  const out: Record<string, string[]> = {};
  for (const cellEl of document.querySelectorAll<HTMLElement>(".pv-cell")) {
    const key = cellEl.dataset.key!;
    const face = cellEl.querySelector<HTMLElement>(".home-tile > .tile");
    const problems: string[] = [];
    if (!face) continue;
    const fr = face.getBoundingClientRect();
    // The inside: the face less its own padding and the OWL root's (the widget's declared padding is its margin).
    const owl = face.querySelector<HTMLElement>(":scope > .owl");
    const pad = (e: HTMLElement | null) => {
      const cs = e ? getComputedStyle(e) : null;
      return cs ? [parseFloat(cs.paddingLeft), parseFloat(cs.paddingTop), parseFloat(cs.paddingRight), parseFloat(cs.paddingBottom)] : [0, 0, 0, 0];
    };
    const [a, b] = [pad(face), pad(owl)];
    const inner = { left: fr.left + a[0] + b[0], top: fr.top + a[1] + b[1], right: fr.right - a[2] - b[2], bottom: fr.bottom - a[3] - b[3] };
    const ink = { left: Infinity, top: Infinity, right: -Infinity, bottom: -Infinity };
    // How much of the inside the content covers: a 2 px grid over it, each cell under some ink marked once.
    const GW = Math.max(1, Math.ceil((inner.right - inner.left) / 2));
    const GH = Math.max(1, Math.ceil((inner.bottom - inner.top) / 2));
    const grid = new Uint8Array(GW * GH);
    const add = (r: { left: number; top: number; right: number; bottom: number }) => {
      if (r.right - r.left < 1 || r.bottom - r.top < 1) return;
      const x0 = Math.max(0, Math.floor((r.left - inner.left) / 2));
      const x1 = Math.min(GW, Math.ceil((r.right - inner.left) / 2));
      const y0 = Math.max(0, Math.floor((r.top - inner.top) / 2));
      const y1 = Math.min(GH, Math.ceil((r.bottom - inner.top) / 2));
      for (let y = y0; y < y1; y++) grid.fill(1, y * GW + x0, Math.max(y * GW + x0, y * GW + x1));
      ink.left = Math.min(ink.left, r.left);
      ink.top = Math.min(ink.top, r.top);
      ink.right = Math.max(ink.right, r.right);
      ink.bottom = Math.max(ink.bottom, r.bottom);
    };
    const clipped = new Set<string>();
    const cut = new Set<string>();
    const range = document.createRange();
    // A strip that scrolls sideways on purpose (touch-action: pan-x - it took the gesture from the page): what it holds
    // past its edge is reachable, not cut.
    const strip = (e: Element) => {
      const cs = getComputedStyle(e);
      return /(auto|scroll)/.test(cs.overflowX) && cs.touchAction.includes("pan-x");
    };
    // A list that scrolls up and down on purpose: it takes the vertical gesture (pan-y) and snaps to whole rows.
    const column = (e: Element) => {
      const cs = getComputedStyle(e);
      return /(auto|scroll)/.test(cs.overflowY) && cs.touchAction.includes("pan-y") && cs.scrollSnapType.startsWith("y");
    };
    const inColumn = (e: Element) => {
      for (let a = e.parentElement; a && a !== face; a = a.parentElement) if (column(a)) return true;
      return false;
    };
    // Something dragged sideways (a slider, a range, a drag-to-dim pill): never inside what scrolls sideways - the
    // scroll would take its drag (Lights' strip of pills that couldn't be dimmed).
    const sideways = (e: Element) => {
      for (let a = e.parentElement; a && a !== face; a = a.parentElement) {
        const cs = getComputedStyle(a);
        if (/(auto|scroll)/.test(cs.overflowX) && a.scrollWidth > a.clientWidth + 1) return true;
      }
      return false;
    };
    const inStrip = (e: Element) => {
      for (let a = e.parentElement; a && a !== face; a = a.parentElement) if (strip(a)) return true;
      return false;
    };
    for (const el of face.querySelectorAll<HTMLElement>("*")) {
      // A failed image hidden in its own box (owl.tsx Image onError) keeps the widget's layout: its slot counts as laid out.
      if (el instanceof HTMLImageElement && el.complete && !el.naturalWidth && el.style.visibility === "hidden") add(visible(el, el.getBoundingClientRect(), face));
      if (!el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) continue;
      const cs = getComputedStyle(el);
      if (el instanceof HTMLCanvasElement) {
        // Sized by its node, never by its bitmap (owl.tsx Canvas: contain size): one taller or wider than its tile grew.
        const cr = el.getBoundingClientRect();
        if (cr.height > fr.height + 1 || cr.width > fr.width + 1) problems.push(`a canvas ${Math.round(cr.width)}x${Math.round(cr.height)} past its tile (sized by its bitmap)`);
        const r = inked(el);
        if (r) add(r);
        continue;
      }
      // An SVG (a ring, a sparkline): its box - a gauge's open foot is its shape, not empty room.
      if (el instanceof SVGSVGElement) {
        add(visible(el, el.getBoundingClientRect(), face));
        continue;
      }
      if (el instanceof SVGElement) continue;
      // A failed image is hidden (owl.tsx Image onError), never the WebView's broken-image box (data/97-now-playing~broken-art).
      if (el instanceof HTMLImageElement && el.complete && !el.naturalWidth && el.getAttribute("src")) problems.push("a broken image shows (hide it on error)");
      if (el instanceof HTMLImageElement || el instanceof HTMLInputElement || painted(cs)) add(visible(el, el.getBoundingClientRect(), face));
      // Its own text: clipped by itself (ellipsis, line clamp) or by what holds it.
      const own = [...el.childNodes].filter((n) => n.nodeType === 3 && n.textContent!.trim());
      if (own.length) {
        const t = el.textContent!.trim().replace(/\s+/g, " ");
        if ((el.scrollWidth > el.clientWidth + 1 && cs.overflowX !== "visible") || (el.scrollHeight > el.clientHeight + 2 && cs.overflowY !== "visible" && el.clientHeight > 0))
          clipped.add(t.length > 28 ? t.slice(0, 27) + "…" : t);
        for (const n of own) {
          range.selectNodeContents(n);
          for (const r of range.getClientRects()) {
            const v = visible(el, r, face);
            const shown = (v.w * v.h) / Math.max(1, r.width * r.height);
            if (shown > 0.08 && shown < 0.92 && r.height > 4 && !inStrip(el) && !inColumn(el)) cut.add(t.length > 28 ? t.slice(0, 27) + "…" : t);
            if (shown > 0.08) add(v);
          }
        }
      }
      const scrollsY = /(auto|scroll)/.test(cs.overflowY) && el.scrollHeight > el.clientHeight + 1;
      const scrollsX = /(auto|scroll)/.test(cs.overflowX) && el.scrollWidth > el.clientWidth + 1;
      if ((scrollsY && !column(el)) || (scrollsX && !strip(el))) problems.push("scrolls (a tile can't)");
      const drags = (el instanceof HTMLInputElement && el.type === "range") || el.getAttribute("role") === "slider";
      if (drags && sideways(el)) problems.push("a slider in a sideways scroller (the scroll takes its drag)");
      // It asks for sideways drags itself (touch-action none / pan-y, not a list that scrolls) but doesn't say it owns
      // them: home's pager (shell/ui/gesture.ts) takes the drag and swipes the page. A range, role=slider or
      // data-owns-gesture is the flag.
      const wantsX = /^(none|pan-y)$/.test(cs.touchAction) && !/(auto|scroll)/.test(cs.overflowY) && !(el instanceof HTMLInputElement);
      if (wantsX && !el.closest("input[type=range], [role=slider], [data-owns-gesture]"))
        problems.push("a drag the home pager takes (mark it role=slider or data-owns-gesture)");
      const bw = Math.max(parseFloat(cs.borderTopWidth), parseFloat(cs.borderLeftWidth));
      if (bw >= 1 && cs.borderTopStyle !== "none" && !/rgba\(0, 0, 0, 0\)|transparent/.test(cs.borderTopColor)) problems.push("hard border");
    }
    // Other visible children (an element painted nothing but has size, e.g. a fixed-size Box) don't count as ink.
    if (face.dataset.pvSheet) problems.push(...face.dataset.pvSheet.split("\n"));
    for (const t of clipped) problems.push(`clipped text "${t}"`);
    for (const t of cut) if (!clipped.has(t)) problems.push(`row cut in half "${t}"`);
    if (face.querySelector(".island-offline.alone, .ag-idle-line")) {
      if (!(ink.right > ink.left)) problems.push("nothing drawn");
    } else if (ink.right > ink.left) {
      const W = inner.right - inner.left;
      const H = inner.bottom - inner.top;
      const gaps = {
        left: (ink.left - inner.left) / W,
        right: (inner.right - ink.right) / W,
        top: (ink.top - inner.top) / H,
        bottom: (inner.bottom - ink.bottom) / H,
      };
      const empty = Object.entries(gaps).filter(([, g]) => g > EMPTY).map(([s, g]) => `${s} ${Math.round(g * 100)}%`);
      if (empty.length) problems.push(`unfilled: ${empty.join(", ")} empty`);
      // Spread thin: content reaching the edges but small in the middle of a big tile (a "5°" in a box) - it should
      // scale with the tile, not only spread out.
      let n = 0;
      for (let i = 0; i < grid.length; i++) n += grid[i];
      const covered = n / grid.length;
      fills[key] = Math.round(covered * 100);
      if (covered < COVER) problems.push(`small content: covers ${Math.round(covered * 100)}% of the tile`);
    } else problems.push("nothing drawn");
    const list = [...new Set(problems)];
    if (list.length) {
      out[key] = list;
      cellEl.classList.add("bad");
      cellEl.querySelector(".pv-problems")!.textContent = list.join("\n");
    }
  }
  return out;
}
