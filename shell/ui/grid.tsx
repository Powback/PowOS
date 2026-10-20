/**
 * The home pages: widgets, pinned apps and folders on a grid, edited like a phone's home screen.
 *
 * - Tap an app to open it, a folder to open it. Pages slide with the finger (gesture.ts); an empty page always
 *   follows the last.
 * - Long-press a tile to lift it and drag it at once (hold it at a side to turn the page); release without moving to
 *   select it instead: a selected widget shows a handle to resize it, and the tile its actions.
 * - Drop an app on an app or a folder to put them in one folder.
 * - Long-press an app in the drawer and drag it: the drawer gives way and the app lands where it's dropped
 *   (startCarry, called from apps.tsx).
 * - Other apps' Android widgets are tiles too (appwidget.tsx): their frames, the finger's touches sent to them.
 *
 * Everything carried follows window-level pointer events, so a drag outlives the element it started on - the drawer
 * closes under the finger, a page turns.
 */
import { AppIcon } from "./apps.tsx";
import { tapTaken } from "./taps.ts";
import { useEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { byKey, carry, dockAim, editing, folder, home, launch, page, pages, selected, setDocked, type Carry } from "../state.ts";
import { addHome, dropOnDock, hoverDock } from "./dockdrop.ts";
import { powos } from "../bridge.ts";
import { applyTrack, drawerOpen } from "./gesture.ts";
import { OwlWidget } from "./owl.tsx";
import { AppWidgetFace } from "./appwidget.tsx";
import { Island } from "./island.tsx";
import { AgentsPanel } from "./agents.tsx";
import { migrateRecents, RecentsPanel } from "./recentwidget.tsx";
import { openAgents } from "../agents.ts";
import type { Cell, HomeItem } from "../types.ts";

const LONG_PRESS_MS = 420;
const SLOP = 10;
const PAGE_TURN_MS = 600;
const EDGE = 28;
const MAX_SQUARE_ROWS = 24;

interface Geometry {
  left: number;
  top: number;
  width: number;
  height: number;
  cellW: number;
  cellH: number;
  rows: number;
  pad: number;
}

/**
 * The grid's geometry, measured from the pages element: what carried tiles and drops are computed in. As the Compose
 * launcher lays it out (HomeGrid.kt Grid), so both show one home: as many rows as fit square cells, or more if the
 * tiles reach further down; the rows then share the height.
 */
export const geometry = signal<Geometry>({ left: 0, top: 0, width: 0, height: 0, cellW: 0, cellH: 0, rows: 0, pad: 12 });

/** Rows the tiles on every page reach down to (apps count as 1x1). */
const usedRows = () => Math.max(0, ...home.value.items.filter((i) => i.cell).map((i) => (i.resizable ? i.cell!.y + i.cell!.h : i.cell!.y + 1)));

function measure(el: HTMLElement, columns: number) {
  // Under the launcher (open, or a finger opening it) home is faded out and the dock folding away resizes it every
  // frame: measuring then re-laid-out every tile, every frame. It measures again once the launcher closes.
  if (drawerOpen.value) return;
  // Layout sizes, not the box on screen: closing, the launcher scales home's content back up (shell.css .home-content)
  // and its box on screen grows every frame of that - a new grid, every tile re-rendered, each frame.
  const r = el.getBoundingClientRect();
  const size = { width: el.offsetWidth, height: el.offsetHeight };
  if (!size.width || !size.height) return;
  const root = getComputedStyle(document.documentElement);
  const pad = parseFloat(root.getPropertyValue("--edge")) || 12;
  // The grid is laid out for home at rest, not for this frame: the dock folding away under the launcher and the
  // keyboard sliding in give the pages more or less height while they animate, and measuring that re-laid-out (and
  // resized) every tile and widget each frame - the flicker as the launcher closes. So the height the dock has
  // folded away and the room the keyboard takes are counted back in: the same grid in every frame of either.
  const height = size.height - dockFolded(root) + keyboardRoom(root);
  const across = size.width - 2 * pad;
  const down = height - 2 * pad;
  const square = Math.max(1, Math.min(MAX_SQUARE_ROWS, Math.floor(down / (across / columns))));
  const rows = Math.max(square, usedRows());
  const next = { left: r.left, top: r.top, width: size.width, height, cellW: across / columns, cellH: down / rows, rows, pad };
  // The same grid again: no new value, so no render (the launcher settling shut animates the dock back every frame;
  // the folded height counted back in leaves the grid as it was). Where the grid is on screen (left, top: read by a
  // drop, never by a render) is kept current without one.
  const g = geometry.peek();
  // Within a pixel and a half: the layout height is whole pixels, the dock's folded height isn't - their sum wobbles by
  // a fraction each frame of the dock's animation.
  const same = g.rows === next.rows && g.pad === next.pad && Math.abs(g.width - next.width) < 1.5 && Math.abs(g.height - next.height) < 1.5;
  if (!same) geometry.value = next;
  else {
    g.left = next.left;
    g.top = next.top;
  }
}

/** How much of its resting height (the strip's; it sits flush on the bar, no margin) the dock has folded away right now. */
function dockFolded(root: CSSStyleDeclaration) {
  const dock = document.querySelector<HTMLElement>(".home .dock");
  if (!dock) return 0;
  const rest = parseFloat(root.getPropertyValue("--strip-height")) || 0;
  const now = dock.getBoundingClientRect().height + (parseFloat(getComputedStyle(dock).marginBottom) || 0);
  return Math.max(0, rest - now);
}

/** The height the keyboard takes from home beyond the navigation bar's inset (it lifts the bar and the dock). */
function keyboardRoom(root: CSSStyleDeclaration) {
  const kb = parseFloat(root.getPropertyValue("--inset-keyboard")) || 0;
  const nav = parseFloat(root.getPropertyValue("--inset-bottom")) || 0;
  return Math.max(0, kb - nav);
}

/** A cell's box, in the page's coordinates. */
function box(c: Cell) {
  const g = geometry.value;
  return { left: g.pad + c.x * g.cellW, top: g.pad + c.y * g.cellH, width: c.w * g.cellW, height: c.h * g.cellH };
}

const overlaps = (a: Cell, b: Cell) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;

/** Items on the page number [n] (home.pages' numbers, not indices). */
const itemsOn = (n: number) => home.value.items.filter((i) => i.page === n && i.cell);

/** A tile's cell as shown: apps and folders are always 1x1. */
const shown = (i: HomeItem): Cell => (i.resizable ? i.cell! : { ...i.cell!, w: 1, h: 1 });

type Aim = { group: string; page: number; cell?: undefined } | { cell: Cell; page: number; group?: undefined };

/** Where a drop at the finger would go: a free cell at the carried size, or an app or folder to group with. */
function aim(c: Carry): Aim | null {
  const g = geometry.value;
  const n = pages.value[page.value];
  const size = c.item?.resizable ? { w: c.item.cell!.w, h: c.item.cell!.h } : { w: 1, h: 1 };
  const others = itemsOn(n).filter((i) => i.key !== c.item?.key);
  const finger = { x: (c.x - g.pad) / g.cellW, y: (c.y - g.pad) / g.cellH };
  const app = !c.item || c.item.kind === "app";
  const under = others.find((i) => {
    const s = shown(i);
    return finger.x >= s.x && finger.x < s.x + s.w && finger.y >= s.y && finger.y < s.y + s.h;
  });
  if (under && app && (under.kind === "app" || under.kind === "folder") && c.item) return { group: under.key, page: n };
  const x = Math.max(0, Math.min(home.value.columns - size.w, Math.round((c.x - c.grab.x - g.pad) / g.cellW)));
  const y = Math.max(0, Math.min(g.rows - size.h, Math.round((c.y - c.grab.y - g.pad) / g.cellH)));
  const cell = { x, y, ...size };
  return others.some((i) => overlaps(shown(i), cell)) ? null : { cell, page: n };
}

/**
 * Where a new tile [wDp] x [hDp] goes (an Android widget from the picker): that many cells (at least one, at most the
 * grid), in the first free spot on the page on screen, else on a later page, else on a new page after the last; and
 * the tile's size in dp at those cells, as it will show.
 */
export function placeNew(wDp: number, hDp: number) {
  const g = geometry.value;
  const cols = home.value.columns;
  const cellW = g.cellW || 60;
  const cellH = g.cellH || 60;
  const rows = g.rows || 8;
  const w = Math.max(1, Math.min(cols, Math.ceil(wDp / cellW)));
  const h = Math.max(1, Math.min(rows, Math.ceil(hDp / cellH)));
  const gap = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--gap")) || 6;
  const size = { width: w * cellW - gap, height: h * cellH - gap };
  const used = home.value.pages.length ? home.value.pages : [1];
  const here = pages.value[page.value] ?? used[0];
  for (const n of [here, ...used.filter((p) => p > here)]) {
    const taken = itemsOn(n).map(shown);
    for (let y = 0; y + h <= rows; y++)
      for (let x = 0; x + w <= cols; x++) {
        const cell = { x, y, w, h };
        if (!taken.some((t) => overlaps(t, cell))) return { page: n, cell, ...size };
      }
  }
  return { page: Math.max(...used) + 1, cell: { x: 0, y: 0, w, h }, ...size };
}

/** [placeNew] in cells (a PowOS app's widget states its size in cells, ui/apppicker.tsx). */
export const placeNewCells = (w: number, h: number) => placeNew(w * (geometry.value.cellW || 60) - 1, h * (geometry.value.cellH || 60) - 1);

/**
 * Starts carrying [what] ({ item } or { app }) with the pointer of [e]: follows it on the window until it lifts, then
 * drops. [grab] is where the finger holds the tile.
 */
export function startCarry(what: { item?: HomeItem; app?: string; fromDock?: boolean }, e: PointerEvent, grab = { x: 0, y: 0 }) {
  const g = geometry.value;
  carry.value = { ...what, x: e.clientX - g.left, y: e.clientY - g.top, grab };
  hoverDock(carry.value, e.clientX, e.clientY);
  let edgeSince = 0;
  const turner = window.setInterval(() => {
    const c = carry.value;
    if (!c) return;
    const side = c.x < EDGE ? -1 : c.x > geometry.value.width - EDGE ? 1 : 0;
    if (!side) return (edgeSince = 0);
    if (!edgeSince) return (edgeSince = Date.now());
    if (Date.now() - edgeSince > PAGE_TURN_MS) {
      const next = page.value + side;
      if (next >= 0 && next < pages.value.length) {
        page.value = next;
        navigator.vibrate?.(5);
      }
      edgeSince = Date.now() + PAGE_TURN_MS;
    }
  }, 50);
  const move = (ev: PointerEvent) => {
    if (ev.pointerId !== e.pointerId || !carry.value) return;
    const geo = geometry.value;
    carry.value = { ...carry.value, x: ev.clientX - geo.left, y: ev.clientY - geo.top };
    // Over the dock, the dock makes room for it (an app; a widget or a folder passes over it).
    hoverDock(carry.value, ev.clientX, ev.clientY);
  };
  const up = async (ev: PointerEvent) => {
    if (ev.pointerId !== e.pointerId) return;
    window.removeEventListener("pointermove", move);
    window.removeEventListener("pointerup", up);
    window.removeEventListener("pointercancel", up);
    clearInterval(turner);
    const c = carry.value;
    if (ev.type !== "pointerup" || !c) {
      dockAim.value = null;
      carry.value = null;
      return;
    }
    // Let go over the dock: pinned there (dockdrop.ts) - not dropped on home under it.
    const docked = dropOnDock(c, ev.clientX, ev.clientY);
    const target = docked ? null : aim(c);
    carry.value = null;
    if (docked) return;
    // Taken out of the dock and let go off it: unpinned, and on home where it's let go (if there's room there).
    if (c.fromDock && c.app) {
      setDocked(c.app, false);
      navigator.vibrate?.(10);
      if (target?.cell) await addHome(c.app, target.page, target.cell);
      return;
    }
    if (!target) return;
    navigator.vibrate?.(10);
    if (c.app) await powos.home.add(c.app, target.page, target.cell);
    else if (target.group) await powos.home.group(c.item!.key, target.group);
    else await powos.home.place(c.item!.key, target.cell!, target.page);
  };
  window.addEventListener("pointermove", move);
  window.addEventListener("pointerup", up);
  window.addEventListener("pointercancel", up);
}

/** A tile's press: a tap opens, a long press lifts it (and selects it, if it's let go where it is). */
function useTilePress(item: HomeItem, onTap: () => void) {
  const state = useRef<{ x: number; y: number; long: boolean; timer: number } | null>(null);
  const cancel = () => {
    if (state.current) clearTimeout(state.current.timer);
    state.current = null;
  };
  return {
    onPointerDown: (e: PointerEvent) => {
      if (e.button) return;
      const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
      const grab = { x: e.clientX - r.left, y: e.clientY - r.top };
      const s = { x: e.clientX, y: e.clientY, long: false, timer: 0 };
      s.timer = window.setTimeout(() => {
        s.long = true;
        navigator.vibrate?.(10);
        selected.value = item.key;
        // Picking a tile up is editing home: the sheet and the empty page to move it to come with it.
        editing.value = true;
        startCarry({ item }, e, grab);
      }, LONG_PRESS_MS);
      state.current = s;
    },
    onPointerMove: (e: PointerEvent) => {
      const s = state.current;
      // Moved before the hold: a swipe (pages, the drawer), not the tile's.
      if (s && !s.long && Math.hypot(e.clientX - s.x, e.clientY - s.y) > SLOP) cancel();
    },
    onPointerUp: (e: PointerEvent) => {
      const s = state.current;
      cancel();
      if (!s || s.long || Math.hypot(e.clientX - s.x, e.clientY - s.y) > SLOP) return;
      // An element of the widget took it (its own onTap, a terminal's focus).
      if (tapTaken(e)) return;
      if (selected.value) selected.value = null;
      else onTap();
    },
    onPointerCancel: cancel,
  };
}

function AppFace({ appKey, label }: { appKey: string; label?: string }) {
  const app = byKey.value.get(appKey);
  return (
    <div class="tile-app">
      {app ? <AppIcon src={app.icon} label={label ?? app.label} /> : <div class="app-icon initials">{(label ?? "?")[0]}</div>}
      <div class="app-label">{label ?? app?.label}</div>
    </div>
  );
}

/** Drawn on a box of its own (a .tile face): what merges with its neighbours. Apps, folders, Android widgets don't. */
const boxed = (i: HomeItem) => i.kind === "widget" || i.kind === "panel" || (i.kind === "appwidget" && !!i.error);

/**
 * Neighbouring widgets as one surface: for each boxed tile on a page, which of its sides touch another boxed tile (no
 * gap there: the tile reaches its cells' edge) and which of its corners are inside a group (square) - only a group's
 * outer corners stay round. One pass over a grid of the page's cells; recomputed with the page's items.
 */
function joins(items: HomeItem[]): Map<string, Record<string, number>> {
  const at = new Map<string, string>();
  for (const i of items) {
    if (!boxed(i)) continue;
    const c = shown(i);
    for (let y = c.y; y < c.y + c.h; y++) for (let x = c.x; x < c.x + c.w; x++) at.set(`${x},${y}`, i.key);
  }
  const out = new Map<string, Record<string, number>>();
  for (const i of items) {
    if (!boxed(i)) continue;
    const c = shown(i);
    const other = (x: number, y: number) => {
      const k = at.get(`${x},${y}`);
      return k != null && k !== i.key ? 1 : 0;
    };
    const along = (f: (n: number) => number, n: number) => {
      for (let k = 0; k < n; k++) if (f(k)) return 1;
      return 0;
    };
    const r = c.x + c.w;
    const b = c.y + c.h;
    const j = {
      "--jt": along((k) => other(c.x + k, c.y - 1), c.w),
      "--jr": along((k) => other(r, c.y + k), c.h),
      "--jb": along((k) => other(c.x + k, b), c.w),
      "--jl": along((k) => other(c.x - 1, c.y + k), c.h),
      "--ctl": 1 - Math.max(other(c.x - 1, c.y), other(c.x, c.y - 1)),
      "--ctr": 1 - Math.max(other(r, c.y), other(r - 1, c.y - 1)),
      "--cbr": 1 - Math.max(other(r, b - 1), other(r - 1, b)),
      "--cbl": 1 - Math.max(other(c.x - 1, b - 1), other(c.x, b)),
    };
    if (j["--jt"] || j["--jr"] || j["--jb"] || j["--jl"]) out.set(i.key, j);
  }
  return out;
}

/**
 * A page's glass (theme.css, ui/glass.ts): ONE frosted wallpaper layer per page, under its tiles, showing only through
 * their faces (a mask of the faces' rounded boxes, made when the page's tiles change - never per frame). The layer is
 * moved the other way as the pages slide (gesture.ts applyTrack, the same transition as the track's), so on the
 * compositor it stays where the wallpaper is while the tiles slide over it. Every page has its own, always: one mounted
 * as its page came near (going home moves home to its first page) had no picture for a frame or two - a blank
 * flash as home showed.
 */
const textured = (i: HomeItem) => boxed(i) || i.kind === "folder";

function faceMask(items: HomeItem[], joined: Map<string, Record<string, number>>, lifted: string | undefined) {
  const css = getComputedStyle(document.documentElement);
  const half = (parseFloat(css.getPropertyValue("--gap")) || 8) / 2;
  const radius = parseFloat(css.getPropertyValue("--radius")) || 12;
  let w = 1;
  let h = 1;
  const paths: string[] = [];
  for (const i of items) {
    if (!textured(i) || i.key === lifted) continue;
    const b = box(shown(i));
    const j = joined.get(i.key) ?? {};
    const x0 = b.left + half * (1 - (j["--jl"] ?? 0));
    const y0 = b.top + half * (1 - (j["--jt"] ?? 0));
    const x1 = b.left + b.width - half * (1 - (j["--jr"] ?? 0));
    const y1 = b.top + b.height - half * (1 - (j["--jb"] ?? 0));
    const [tl, tr, br, bl] = ["--ctl", "--ctr", "--cbr", "--cbl"].map((k) => radius * (j[k] ?? 1));
    const f = (n: number) => +n.toFixed(1);
    paths.push(
      `M${f(x0 + tl)} ${f(y0)}H${f(x1 - tr)}A${tr} ${tr} 0 0 1 ${f(x1)} ${f(y0 + tr)}V${f(y1 - br)}A${br} ${br} 0 0 1 ${f(x1 - br)} ${f(y1)}` +
        `H${f(x0 + bl)}A${bl} ${bl} 0 0 1 ${f(x0)} ${f(y1 - bl)}V${f(y0 + tl)}A${tl} ${tl} 0 0 1 ${f(x0 + tl)} ${f(y0)}Z`,
    );
    w = Math.max(w, Math.ceil(x1));
    h = Math.max(h, Math.ceil(y1));
  }
  if (!paths.length) return null;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}"><path d="${paths.join("")}"/></svg>`;
  return { "--glass-mask": `url("data:image/svg+xml,${encodeURIComponent(svg)}")`, "--glass-mask-size": `${w}px ${h}px` };
}

function PageGlass({ items, joined, index }: { items: HomeItem[]; joined: Map<string, Record<string, number>>; index: number }) {
  const mask = faceMask(items, joined, carry.value?.item?.key);
  if (!mask) return null;
  const g = geometry.peek();
  // Where applyTrack puts it at rest, from the start (a transition from nowhere would slide it in).
  const transform = `translateX(calc(${Math.max(page.value, 0) - index - (page.value === -1 ? 1 : 0)} * 100%))`;
  return (
    <div class="page-glass" style={mask}>
      <div class="page-glass-img" style={{ "--pg-left": `${g.left}px`, "--pg-top": `${g.top}px`, transform }} />
    </div>
  );
}

function Tile({ item, join }: { item: HomeItem; join?: Record<string, number> }) {
  const press = useTilePress(item, () => {
    if (item.kind === "app") launch(item.app!);
    else if (item.kind === "folder") folder.value = item.key;
    // The widget's own onTap - a terminal's opens its screen, the shell full size.
    else if (item.kind === "widget") powos.widgets.tap(item.key);
    // The Agents widget: its screen (a line's tap opens it on that agent).
    else if (item.kind === "panel" && item.name === "agents") openAgents();
    // A PowOS app's island takes its own taps (ui/island.tsx).
    // An Android widget's taps are its own (appwidget.tsx).
  });
  const lifted = carry.value?.item?.key === item.key;
  const isSelected = selected.value === item.key;
  const b = box(shown(item));
  return (
    <div
      class={`home-tile ${item.kind} ${isSelected ? "selected" : ""} ${lifted ? "lifted" : ""} ${join ? "joined" : ""}`}
      style={{ left: `${b.left}px`, top: `${b.top}px`, width: `${b.width}px`, height: `${b.height}px`, ...join }}
      {...press}
    >
      {item.kind === "widget" && (
        <div class={`tile widget-face ${isSelected ? "focused" : ""}`}>
          {item.error ? (
            <>
              <div class="widget-name">{item.name}</div>
              <div class="widget-error">{item.error}</div>
            </>
          ) : (
            <OwlWidget widget={item.key} cells={item.cell} />
          )}
        </div>
      )}
      {item.kind === "appwidget" &&
        (item.error ? (
          <div class="tile widget-face">
            <div class="widget-name">{item.name}</div>
            <div class="widget-error">{item.error}</div>
          </div>
        ) : (
          <AppWidgetFace item={item} />
        ))}
      {item.kind === "panel" && item.name === "agents" && <AgentsPanel item={item} />}
      {item.kind === "panel" && item.name?.startsWith("app:") && <Island item={item} />}
      {item.kind === "panel" && item.name === "recents" && <RecentsPanel item={item} />}
      {item.kind === "app" && <AppFace appKey={item.app!} label={item.label} />}
      {item.kind === "folder" && (
        <div class="folder-face tile">
          {item.apps!.slice(0, 4).map((a) => {
            const app = byKey.value.get(a.app);
            return app ? <img src={app.icon} alt="" draggable={false} /> : <span>{a.label[0]}</span>;
          })}
        </div>
      )}
      {isSelected && !lifted && <Actions item={item} />}
      {isSelected && !lifted && item.resizable && <ResizeHandle item={item} />}
    </div>
  );
}

function Actions({ item }: { item: HomeItem }) {
  return (
    <div class="tile-actions tile" onPointerDown={(e) => e.stopPropagation()} onPointerUp={(e) => e.stopPropagation()}>
      {item.appWidget?.reconfigurable && (
        <button
          onClick={() => {
            selected.value = null;
            powos.appWidgets.configure(item.appWidget!.id);
          }}
        >
          settings
        </button>
      )}
      <button
        class="danger"
        onClick={async () => {
          selected.value = null;
          await powos.home.remove(item.key);
        }}
      >
        remove
      </button>
    </div>
  );
}

/**
 * An Android widget's smallest size in this grid's cells: the fewest whose tile (cells less the gap) covers its
 * provider's minimum, as a launcher's ceil((dp + gap) / cell) - with the real cell size, which the host doesn't know.
 */
function appWidgetMin(item: HomeItem): [number, number] {
  const g = geometry.value;
  const gap = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--gap")) || 6;
  const [w, h] = item.appWidget!.minDp;
  const cells = (dp: number, cell: number) => Math.max(1, Math.ceil((dp + gap) / (cell || 60) - 0.05));
  return [cells(w, g.cellW), cells(h, g.cellH)];
}

/** Drag the corner: the widget grows or shrinks by whole cells, never under its minimum or onto another tile. */
function ResizeHandle({ item }: { item: HomeItem }) {
  const [size, setSize] = useState<Cell | null>(null);
  const cell0 = item.cell!;
  // An Android widget: its provider's minimum, and only the sides its resize mode moves.
  const aw = item.appWidget;
  const min = aw ? appWidgetMin(item) : item.minSize;
  const fit = (e: PointerEvent): Cell | null => {
    const g = geometry.value;
    const b = box(cell0);
    let w = Math.max(min[0], Math.min(home.value.columns - cell0.x, Math.round((e.clientX - g.left - b.left) / g.cellW)));
    let h = Math.max(min[1], Math.min(g.rows - cell0.y, Math.round((e.clientY - g.top - b.top) / g.cellH)));
    if (aw?.resize === "vertical") w = cell0.w;
    if (aw?.resize === "horizontal") h = cell0.h;
    const cell = { ...cell0, w, h };
    return itemsOn(item.page).some((i) => i.key !== item.key && overlaps(shown(i), cell)) ? null : cell;
  };
  const b = box(cell0);
  const n = size && box(size);
  return (
    <div
      class="resize-handle"
      onPointerDown={(e) => {
        e.stopPropagation();
        (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
      }}
      onPointerMove={(e) => e.buttons && setSize(fit(e) ?? size)}
      onPointerUp={async (e) => {
        e.stopPropagation();
        const cell = fit(e) ?? size;
        setSize(null);
        if (cell) await powos.home.place(item.key, cell, item.page);
      }}
    >
      {n && <div class="resize-preview" style={{ width: `${n.width}px`, height: `${n.height}px`, left: `${-b.width + 18}px`, top: `${-b.height + 18}px` }} />}
    </div>
  );
}

/** Where a carried tile would land on home: its spot outlined (none over the dock - it goes there). */
function Preview() {
  const c = carry.value;
  if (!c) return null;
  const target = dockAim.value ? null : aim(c);
  const spot = target?.cell ? box(target.cell) : null;
  return spot && <div class="drop-spot" style={{ left: `${spot.left}px`, top: `${spot.top}px`, width: `${spot.width}px`, height: `${spot.height}px` }} />;
}

/**
 * The carried tile itself, under the finger: a layer over all of home (home.tsx), not inside the pages, which clip
 * at their foot - an app carried down to the dock stays in sight over it.
 */
export function Carried() {
  const c = carry.value;
  if (!c) return null;
  const g = geometry.value;
  const size = c.item?.resizable ? c.item.cell! : { w: 1, h: 1 };
  return (
    <div
      class="carried"
      style={{ left: `${g.left + c.x - c.grab.x}px`, top: `${g.top + c.y - c.grab.y}px`, width: `${size.w * g.cellW}px`, height: `${size.h * g.cellH}px` }}
    >
      {c.app ? (
        <AppFace appKey={c.app} />
      ) : c.item!.kind === "app" ? (
        <AppFace appKey={c.item!.app!} label={c.item!.label} />
      ) : (
        <div class="tile widget-face focused">
          <div class="widget-name">{c.item!.name ?? "folder"}</div>
        </div>
      )}
    </div>
  );
}

function FolderPanel() {
  const f = home.value.items.find((i) => i.key === folder.value);
  if (!f) return null;
  return (
    <div class="folder-scrim" onClick={() => (folder.value = null)}>
      <div class="folder-panel tile" onClick={(e) => e.stopPropagation()}>
        {f.apps!.map((a) => (
          <div
            class="app"
            key={a.key}
            onClick={() => {
              folder.value = null;
              launch(a.app);
            }}
          >
            <AppFace appKey={a.app} label={a.label} />
          </div>
        ))}
      </div>
    </div>
  );
}

/** A press on the page itself, not on a tile. */
const onEmpty = (e: Event) => {
  const t = e.target as HTMLElement;
  return t.classList.contains("page") || t.classList.contains("page-track") || t.classList.contains("pages");
};

/**
 * Home's empty space: held, it's edit mode (state.ts editing - the home menu's sheet, an empty page to fill); a tap
 * ends a tile's edit, then edit mode, as on a stock launcher.
 */
function useEmptyPress() {
  const s = useRef<{ x: number; y: number; timer: number; long: boolean } | null>(null);
  const cancel = () => {
    if (s.current) clearTimeout(s.current.timer);
    s.current = null;
  };
  return {
    onPointerDown: (e: PointerEvent) => {
      if (e.button || !onEmpty(e) || drawerOpen.value) return;
      const p = { x: e.clientX, y: e.clientY, timer: 0, long: false };
      p.timer = window.setTimeout(() => {
        p.long = true;
        navigator.vibrate?.(10);
        selected.value = null;
        editing.value = true;
      }, LONG_PRESS_MS);
      s.current = p;
    },
    onPointerMove: (e: PointerEvent) => {
      const p = s.current;
      // Moved: a swipe (pages, the drawer), not a hold.
      if (p && !p.long && Math.hypot(e.clientX - p.x, e.clientY - p.y) > SLOP) cancel();
    },
    onPointerUp: (e: PointerEvent) => {
      const p = s.current;
      cancel();
      if (!p || p.long || Math.hypot(e.clientX - p.x, e.clientY - p.y) > SLOP) return;
      if (selected.value) selected.value = null;
      else if (editing.value) editing.value = false;
    },
    onPointerCancel: cancel,
  };
}

export function Pages() {
  const el = useRef<HTMLDivElement>(null);
  const emptyPress = useEmptyPress();
  useEffect(() => {
    const ro = new ResizeObserver(() => measure(el.current!, home.value.columns));
    ro.observe(el.current!);
    return () => ro.disconnect();
  }, []);
  // Tiles reaching further down add rows, and the launcher closing gives the room back: re-measure then.
  useEffect(() => void (el.current && measure(el.current, home.value.columns)), [home.value, drawerOpen.value]);
  // Items without a cell yet (a widget from the store, an app pinned from a menu): the host gives them the first free
  // spot, once the grid's rows are known - as the Compose home does laying a page out.
  const rows = geometry.value.rows;
  useEffect(() => {
    if (rows > 0 && home.value.items.some((i) => !i.cell)) powos.home.arrange(home.value.columns, rows);
  }, [home.value, rows]);
  // The recent apps row, once, as a widget of home's (ui/recentwidget.tsx), at the bottom of the first page.
  useEffect(() => void migrateRecents(rows), [rows]);
  // Also each render: a page's glass layer just mounted takes the track's place at once.
  useEffect(() => applyTrack());
  const list = pages.value;
  if (page.value >= list.length) page.value = list.length - 1;
  // Widgets on the page on screen (and beside it) run their sources; the rest pause.
  useEffect(() => void powos.widgets.page(list[page.value] ?? 1), [page.value, list.join()]);
  return (
    <div class="pages" ref={el} {...emptyPress}>
      {/* Its position and transition are gesture.ts's (applyTrack), never a render's. */}
      <div class="page-track">
        {list.map((n, i) => (
          // Not the page on screen: its animations pause (shell.css .page.away).
          <div class={i === page.value ? "page" : "page away"} key={n}>
            {((on) => {
              const joined = joins(on);
              return (
                <>
                  <PageGlass items={on} joined={joined} index={i} />
                  {on.map((item) => (
                    <Tile key={item.key} item={item} join={joined.get(item.key)} />
                  ))}
                </>
              );
            })(itemsOn(n))}
          </div>
        ))}
      </div>
      <Preview />
      <FolderPanel />
    </div>
  );
}
