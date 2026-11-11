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
import { tileFit } from "./fit.js";

declare function importShim(url: string): Promise<any>;

/**
 * Every WebGL canvas the sheet's tiles open keeps its drawing buffer, so the fit checks can read what it shows. By
 * default (preserveDrawingBuffer false) a WebGL canvas's buffer is cleared once the frame is presented: the page shows
 * the frame (a screenshot has it), but a later drawImage/toDataURL - fit.js inked() and stable() below, in their own task -
 * reads blank. A terminal tile (ui/terminal.tsx: xterm's WebGL renderer) measured "nothing drawn" at every size while
 * drawing its session. Measured 2026-11-02 in the gate's Chromium: red cleared, read in-task 255,0,0,255, after a
 * frame 0,0,0,0, the screenshot 255,0,0,255. Only the sheet's page: the shell itself keeps the cheaper default.
 */
const getContext = HTMLCanvasElement.prototype.getContext as (this: HTMLCanvasElement, id: string, o?: any) => any;
HTMLCanvasElement.prototype.getContext = function (this: HTMLCanvasElement, id: string, o?: any) {
  return getContext.call(this, id, /^(webgl2?|experimental-webgl)$/.test(id) ? { ...o, preserveDrawingBuffer: true } : o);
} as typeof HTMLCanvasElement.prototype.getContext;

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
    /**
     * host.notifications' list (apps/notify.tsx): PhoneNotification-shaped, a negative [time] (and a message's) is that
     * many seconds ago. Its actions answer and do nothing.
     */
    notifications?: any[];
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

/** host.notifications over the data's list, times made relative to now; the actions press nothing. */
function mockNotifications(items: any[]) {
  const now = Date.now() / 1000;
  const at = (t: number) => (t < 0 ? now + t : t);
  const list = {
    available: true,
    items: items.map((n) => ({ ...n, time: at(n.time), messages: n.messages?.map((m: any) => ({ ...m, time: at(m.time) * 1000 })) })),
  };
  const none = async () => {};
  return { ...realHost.notifications!, list: async () => list, useList: () => list, action: none, open: none, dismiss: none, access: none };
}

/** An island's host over mock data: the app's tables as given, its network answered from the data's patterns. */
function mockHost(spec: Spec) {
  // A row value {"$daysAgo": n} is that local midnight (BigInt ms): fixtures with dated rows stay "today" whenever they render.
  const midnight = (n: number) => { const d = new Date(); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() - n); return BigInt(d.getTime()); };
  const rows = Object.fromEntries(
    Object.entries(spec.data?.rows ?? {}).map(([t, rs]) => [
      t,
      rs.map((r) => (r && typeof r === "object" ? Object.fromEntries(Object.entries(r).map(([k, v]: [string, any]) => [k, v && typeof v === "object" && "$daysAgo" in v ? midnight(v.$daysAgo) : v])) : r)),
    ]),
  ) as Record<string, any[]>;
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
    notifications: spec.data?.notifications ? mockNotifications(spec.data.notifications) : realHost.notifications,
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
  await onScreenOnce(root);
  await stable(root);
}

/**
 * Brings every tile into the viewport for a couple of frames, then back to the top: a tile that draws only while it's
 * on screen (xterm pauses a terminal its IntersectionObserver sees off screen, as on home) drew nothing below the
 * page's first 900 px - the terminal's 4x4 tiles, last on the sheet, measured "nothing drawn" with a full buffer
 * (renderer paused, a full refresh pending). What it drew stays when scrolled away (pausing stops new frames only).
 */
async function onScreenOnce(root: HTMLElement) {
  const frame = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  for (const cell of root.querySelectorAll<HTMLElement>(".pv-cell")) {
    cell.scrollIntoView({ block: "center" });
    await frame();
  }
  window.scrollTo(0, 0);
  await frame();
}

/** What the sheet shows, as a number: its markup and every canvas's drawn pixels. */
const shown = (root: HTMLElement) => root.innerHTML.length + [...root.querySelectorAll("canvas")].reduce((n, c) => n + (c.width ? pixels(c) : 0), 0);
/** A canvas's pixels as a number; one handed to a worker (transferControlToOffscreen: the stickman's) can't be read. */
function pixels(c: HTMLCanvasElement) {
  try {
    return c.toDataURL().length;
  } catch {
    return 0;
  }
}

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

/** How much of each tile its content covered, %, by tile key: the last check()'s. */
export const fills: Record<string, number> = {};

/** The fit checks (fit.js tileFit, the device check's own) on every tile of the sheet: the problems by tile key. */
export function check(EMPTY = 0.12, COVER = 0.25) {
  const out: Record<string, string[]> = {};
  for (const cellEl of document.querySelectorAll<HTMLElement>(".pv-cell")) {
    const key = cellEl.dataset.key!;
    const face = cellEl.querySelector<HTMLElement>(".home-tile > .tile");
    if (!face) continue;
    const { problems: list, covered } = tileFit(face, EMPTY, COVER);
    if (covered !== null) fills[key] = Math.round(covered * 100);
    if (list.length) {
      out[key] = list;
      cellEl.classList.add("bad");
      cellEl.querySelector(".pv-problems")!.textContent = list.join("\n");
    }
  }
  return out;
}
