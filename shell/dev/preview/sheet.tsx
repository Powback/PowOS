/**
 * The widget preview's page half (shell/dev/preview.sh -> preview.mjs, in the gate's headless Chromium): one widget's
 * contact sheet - every size it allows on the cover screen's and the inner screen's cells - drawn by the shell's own
 * components (an OWL widget's tile is ui/owl.tsx's OwlWidget in a .home-tile like grid.tsx's, an app's island its
 * module with an island's props, a shell panel its component), then measured: the fit checks below.
 *
 * Loaded into the home page (index.html, the mock bridge) after it's ready; home itself is hidden under the sheet.
 */
import { render, type ComponentType } from "preact";
import { useEffect, useState } from "preact/hooks";
import { powos } from "../../bridge.ts";
import { OwlWidget } from "../../ui/owl.tsx";
import { host as realHost } from "../../apps/stdb.ts";
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
  data?: { rows?: Record<string, any[]>; net?: { match: string; status?: number; json?: unknown }[] };
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
    const body = hit?.json ?? null;
    return { status: hit ? (hit.status ?? 200) : 404, ok: !!hit, json: () => body, text: () => JSON.stringify(body), headers: {} };
  };
  return {
    ...realHost,
    useDb: () => db,
    useRows: (_db: unknown, table: string) => rows[table] ?? [],
    openApp: () => {},
    net: {
      fetch: async (_app: string, url: string) => answer(url),
      useEvents: () => "open",
    },
  };
}

function Island({ spec, cell }: { spec: Spec; cell: Cell }) {
  const [C, setC] = useState<ComponentType<any> | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    importShim(`./_app/${spec.app}/${spec.entry}`).then(
      (m) => setC(() => m.default),
      (e) => setErr(String(e?.message ?? e)),
    );
  }, []);
  if (err) return <div class="tile widget-face"><div class="widget-error">{err}</div></div>;
  if (!C) return <div class="tile island-face" />;
  return (
    <div class="tile island-face">
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
  render(<Sheet spec={spec} />, root);
  await new Promise((r) => setTimeout(r, settleMs));
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
 * - scroll: a scrolling container in a tile (a home tile can't take a scroll gesture from the page) - but a strip
 *   that scrolls sideways and says so (touch-action: pan-x: it took the gesture);
 * - hard border: a drawn 1px+ line round content (the design language: no lines).
 */
export function check(EMPTY = 0.12) {
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
    const add = (r: { left: number; top: number; right: number; bottom: number }) => {
      if (r.right - r.left < 1 || r.bottom - r.top < 1) return;
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
    const inStrip = (e: Element) => {
      for (let a = e.parentElement; a && a !== face; a = a.parentElement) if (strip(a)) return true;
      return false;
    };
    for (const el of face.querySelectorAll<HTMLElement>("*")) {
      if (!el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) continue;
      const cs = getComputedStyle(el);
      if (el instanceof HTMLCanvasElement) {
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
      if (el instanceof HTMLImageElement || painted(cs)) add(visible(el, el.getBoundingClientRect(), face));
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
            if (shown > 0.08 && shown < 0.92 && r.height > 4 && !inStrip(el)) cut.add(t.length > 28 ? t.slice(0, 27) + "…" : t);
            if (shown > 0.08) add(v);
          }
        }
      }
      const scrollsY = /(auto|scroll)/.test(cs.overflowY) && el.scrollHeight > el.clientHeight + 1;
      const scrollsX = /(auto|scroll)/.test(cs.overflowX) && el.scrollWidth > el.clientWidth + 1;
      if (scrollsY || (scrollsX && !strip(el))) problems.push("scrolls (a tile can't)");
      const bw = Math.max(parseFloat(cs.borderTopWidth), parseFloat(cs.borderLeftWidth));
      if (bw >= 1 && cs.borderTopStyle !== "none" && !/rgba\(0, 0, 0, 0\)|transparent/.test(cs.borderTopColor)) problems.push("hard border");
    }
    // Other visible children (an element painted nothing but has size, e.g. a fixed-size Box) don't count as ink.
    for (const t of clipped) problems.push(`clipped text "${t}"`);
    for (const t of cut) if (!clipped.has(t)) problems.push(`row cut in half "${t}"`);
    if (ink.right > ink.left) {
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
