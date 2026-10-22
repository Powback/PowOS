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
import { applyTrack, drawerOpen, held } from "./gesture.ts";
import { LibraryPage } from "./library.tsx";
import { FolderFace, FolderPanel, folderable, folderName, groupIntoFolder, loadFolderNames } from "./folders.tsx";
import { chosen, isChosen, marquee, MARQUEE_DWELL, partyCells, partyOf, startMarquee, toggleChosen } from "./homeselect.ts";
import { OwlWidget } from "./owl.tsx";
import { AppWidgetFace } from "./appwidget.tsx";
import { Island } from "./island.tsx";
import { AgentsPanel } from "./agents.tsx";
import { migrateRecents, RecentsPanel } from "./recentwidget.tsx";
import { footSearch, isFootSearch, placeItem, SearchPanel } from "./searchwidget.tsx";
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
  // Layout sizes, not the box on screen: closing, the launcher scales home's content back up (shell.css .home-content)
  // and its box on screen grows every frame of that - a new grid, every tile re-rendered, each frame.
  const r = el.getBoundingClientRect();
  const size = { width: el.offsetWidth, height: el.offsetHeight };
  // Hidden (an app in front, maybe at another size and orientation): never laid out at that size - measured again
  // when home is shown (Pages).
  if (!size.width || !size.height || document.hidden) return;
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
  // The columns too (cellW): home relaid in another column count at the same size (wide <-> narrow, back from an app
  // that ran in landscape) kept the other count's cell width - tiny tiles squashed at the top.
  const same = g.rows === next.rows && g.pad === next.pad && Math.abs(g.cellW - next.cellW) < 0.5 && Math.abs(g.width - next.width) < 1.5 && Math.abs(g.height - next.height) < 1.5;
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
/** Page [n]'s placed items - in edit mode with the foot's search pill on the grid too (searchwidget.tsx footSearch). */
const itemsOn = (n: number) => (footSearch.value ? [...home.value.items, footSearch.value] : home.value.items).filter((i) => i.page === n && i.cell);

/** A tile's cell as shown: apps and folders are always 1x1. */
const shown = (i: HomeItem): Cell => (i.resizable ? i.cell! : { ...i.cell!, w: 1, h: 1 });

type Aim = { group: string; page: number; cell?: undefined } | { cell: Cell; page: number; group?: undefined };

/** The tile of [items] under the carrying finger. */
function underFinger(c: Carry, items: HomeItem[]) {
  const g = geometry.value;
  const finger = { x: (c.x - g.pad) / g.cellW, y: (c.y - g.pad) / g.cellH };
  return items.find((i) => {
    const s = shown(i);
    return finger.x >= s.x && finger.x < s.x + s.w && finger.y >= s.y && finger.y < s.y + s.h;
  });
}

/**
 * An app taken out of a folder, let go: back over its own folder it stays in; anywhere else on home it's out - where
 * it's let go, or the first free spot when there's no room there (the host's add takes it out of the folder).
 */
async function dropFromFolder(c: Carry, target: Aim | null) {
  if (underFinger(c, itemsOn(pages.value[page.value]))?.key === c.fromFolder) return;
  navigator.vibrate?.(10);
  await powos.home.add(c.app!, target?.page ?? pages.value[page.value], target?.cell);
}

/** Where a drop at the finger would go: a free cell at the carried size, or an app or folder to group with. */
function aim(c: Carry): Aim | null {
  const n = pages.value[page.value];
  // The app library (the page after the last): nothing lands there.
  return n == null ? null : aimOn(c, n);
}

/** [aim] on home page [n]. */
function aimOn(c: Carry, n: number): Aim | null {
  const g = geometry.value;
  const size = c.item?.resizable ? { w: c.item.cell!.w, h: c.item.cell!.h } : { w: 1, h: 1 };
  const others = itemsOn(n).filter((i) => i.key !== c.item?.key);
  const app = !c.item || c.item.kind === "app";
  const under = underFinger(c, others);
  if (under && app && (under.kind === "app" || under.kind === "folder") && c.item) return { group: under.key, page: n };
  const x = Math.max(0, Math.min(home.value.columns - size.w, Math.round((c.x - c.grab.x - g.pad) / g.cellW)));
  const y = Math.max(0, Math.min(g.rows - size.h, Math.round((c.y - c.grab.y - g.pad) / g.cellH)));
  const cell = { x, y, ...size };
  return others.some((i) => overlaps(shown(i), cell)) ? null : { cell, page: n };
}

/** The picked tiles carried with [c]'s item, and where each would land: null for a lone tile. */
function partyAim(c: Carry): { party: HomeItem[]; cells: Map<string, Cell> | null; page: number } | null {
  const n = pages.value[page.value];
  const party = partyOf(c.item, itemsOn(c.item?.page ?? n));
  if (!party || n == null) return null;
  const g = geometry.value;
  const lead = c.item!;
  const x = Math.round((c.x - c.grab.x - g.pad) / g.cellW);
  const y = Math.round((c.y - c.grab.y - g.pad) / g.cellH);
  const others = itemsOn(n).filter((i) => !party.some((p) => p.key === i.key)).map(shown);
  const cells = partyCells(party, { lead, cell: { ...lead.cell!, x, y } }, others, { columns: home.value.columns, rows: g.rows, shown });
  return { party, cells, page: n };
}

/** Lets the carried party go: every tile to its cell (one after another: the host keeps one layout). */
async function dropParty(t: NonNullable<ReturnType<typeof partyAim>>) {
  if (!t.cells) return;
  navigator.vibrate?.(10);
  for (const [key, cell] of t.cells) await placeItem(key, cell, t.page);
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
export function startCarry(what: { item?: HomeItem; app?: string; fromDock?: boolean; fromFolder?: string }, e: PointerEvent, grab = { x: 0, y: 0 }) {
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
    // Picked tiles carried together: onto home only, all or none.
    const party = c && ev.type === "pointerup" ? partyAim(c) : null;
    if (ev.type !== "pointerup" || !c || party) {
      dockAim.value = null;
      carry.value = null;
      return party && dropParty(party);
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
    if (c.fromFolder) return dropFromFolder(c, target);
    if (!target) return;
    navigator.vibrate?.(10);
    if (c.app) await powos.home.add(c.app, target.page, target.cell);
    else if (target.group) await powos.home.group(c.item!.key, target.group);
    else await placeItem(c.item!.key, target.cell!, target.page);
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
        // One of several picked: they go together (partyAim), none of them selected on its own.
        if (!partyOf(item, itemsOn(item.page))) selected.value = item.key;
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
      // Editing home, a tap picks the tile (or puts it back): picked ones move together, apps make a folder.
      else if (editing.value) toggleChosen(item.key);
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
// The search widget's pill is its own surface (no box around it, no page glass behind its cells).
const boxed = (i: HomeItem) =>
  i.kind === "widget" || (i.kind === "panel" && i.name !== "search") || (i.kind === "appwidget" && !!i.error);

/**
 * Neighbouring widgets as one surface: for each boxed tile on a page, which of its sides touch another boxed tile (no
 * gap there: the tile reaches its cells' edge) and which of its corners are inside a group (square) - only a group's
 * outer corners stay round. One pass over a grid of the page's cells; recomputed with the page's items.
 */
/** Which tile covers each cell ("x,y" -> key): the boxed ones. */
function cellOwners(items: HomeItem[]) {
  const at = new Map<string, string>();
  for (const i of items.filter(boxed)) {
    const c = shown(i);
    for (let y = c.y; y < c.y + c.h; y++) for (let x = c.x; x < c.x + c.w; x++) at.set(`${x},${y}`, i.key);
  }
  return at;
}

/** A tile's four outside edges as cell runs: top, right, bottom, left. */
function edgesOf(c: Cell) {
  return [
    { x: c.x, y: c.y - 1, dx: 1, dy: 0, n: c.w },
    { x: c.x + c.w, y: c.y, dx: 0, dy: 1, n: c.h },
    { x: c.x, y: c.y + c.h, dx: 1, dy: 0, n: c.w },
    { x: c.x - 1, y: c.y, dx: 0, dy: 1, n: c.h },
  ];
}

/** How many cells of [e] another tile than [key] covers. */
function coveredCells(at: Map<string, string>, key: string, e: { x: number; y: number; dx: number; dy: number; n: number }) {
  let k = 0;
  for (let i = 0; i < e.n; i++) {
    const o = at.get(`${e.x + e.dx * i},${e.y + e.dy * i}`);
    if (o != null && o !== key) k++;
  }
  return k;
}

/**
 * Merged per shared span (grid.tsx seams): a side covered WHOLE by neighbours reaches half the gutter towards them
 * (--jX 1); a side touched over part of it keeps its edge where an unjoined one is (the user's steam-over-fetch: the
 * wide tile's free half stays level with its neighbours), and the gutter along just the shared span is filled by a
 * seam piece, with a rounded inner corner where the group turns. Corners are square where a neighbour continues.
 */
function joinOf(at: Map<string, string>, i: HomeItem): Record<string, number> | null {
  const c = shown(i);
  const edges = edgesOf(c);
  const cover = edges.map((e) => coveredCells(at, i.key, e));
  if (!cover.some((k) => k > 0)) return null;
  const other = (x: number, y: number) => (coveredCells(at, i.key, { x, y, dx: 0, dy: 0, n: 1 }) ? 1 : 0);
  const [r, b] = [c.x + c.w, c.y + c.h];
  const [jt, jr, jb, jl] = cover.map((k, n) => (k === edges[n].n ? 1 : 0));
  return {
    "--jt": jt,
    "--jr": jr,
    "--jb": jb,
    "--jl": jl,
    "--ctl": 1 - Math.max(other(c.x - 1, c.y), other(c.x, c.y - 1)),
    "--ctr": 1 - Math.max(other(r, c.y), other(r - 1, c.y - 1)),
    "--cbr": 1 - Math.max(other(r, b - 1), other(r - 1, b)),
    "--cbl": 1 - Math.max(other(c.x - 1, b - 1), other(c.x, b)),
  };
}

function joins(items: HomeItem[]): Map<string, Record<string, number>> {
  // The desktop's home (powos-shell under Plasma): widgets stay separate surfaces, like plasmoids - never merged.
  if (document.documentElement.dataset.mode === "desktop") return new Map();
  const at = cellOwners(items);
  const out = new Map<string, Record<string, number>>();
  for (const i of items.filter(boxed)) {
    const j = joinOf(at, i);
    if (j) out.set(i.key, j);
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

/** A tile's face on the page: its box less the half gutter on each side not merged whole (grid.tsx joins). */
function faceRect(i: HomeItem, j: Record<string, number>, half: number) {
  const b = box(shown(i));
  return {
    x0: b.left + half * (1 - (j["--jl"] ?? 0)),
    y0: b.top + half * (1 - (j["--jt"] ?? 0)),
    x1: b.left + b.width - half * (1 - (j["--jr"] ?? 0)),
    y1: b.top + b.height - half * (1 - (j["--jb"] ?? 0)),
  };
}

/** A piece of a merged group between two faces: the gutter along a shared span, or an inner corner's fillet. */
export interface Seam {
  kind: "bridge" | "fillet";
  x: number;
  y: number;
  w: number;
  h: number;
  /** fillet: the circle's centre, from the piece's top-left (the corner it rounds is the opposite one). */
  cx?: number;
  cy?: number;
  d: string;
}

/**
 * The pieces that merge two faces touching over PART of an edge (joins): the gutter between them along the shared
 * span only (both faces' extents: edges line up exactly with the faces), and at each end where one face goes on past
 * the other, a fillet rounding the inner corner of the L - so the group reads as one surface, its free edges level.
 */
type Face = { x0: number; y0: number; x1: number; y1: number };
const fx = (n: number) => +n.toFixed(1);

/** A fillet rounding the inner corner at (px, py), opening towards (sx, sy) - none where a face already is. */
function filletAt(p: { px: number; py: number; sx: number; sy: number; r: number }, faces: Face[]): Seam | null {
  const { px, py, sx, sy, r } = p;
  if (r < 1) return null;
  const x = sx > 0 ? px : px - r;
  const y = sy > 0 ? py : py - r;
  // A third tile already there (the corner is inside the group, not where it turns): no fillet over its face.
  if (faces.some((q) => q.x0 < x + r - 0.5 && x + 0.5 < q.x1 && q.y0 < y + r - 0.5 && y + 0.5 < q.y1)) return null;
  const sweep = sx * sy < 0 ? 1 : 0;
  const d = `M${fx(px)} ${fx(py)}L${fx(px + sx * r)} ${fx(py)}A${fx(r)} ${fx(r)} 0 0 ${sweep} ${fx(px)} ${fx(py + sy * r)}Z`;
  return { kind: "fillet", x, y, w: r, h: r, cx: sx > 0 ? r : 0, cy: sy > 0 ? r : 0, d };
}

/** Do B's cells start where A's end, under A (or right of it when [vertical]), overlapping along the seam? */
function meets(a: Cell, b: Cell, vertical: boolean) {
  if (vertical) return b.x === a.x + a.w && b.y < a.y + a.h && a.y < b.y + b.h;
  return b.y === a.y + a.h && b.x < a.x + a.w && a.x < b.x + b.w;
}

/** The pieces between faces A and B meeting over a seam: the gutter along the shared span, the inner corners' fillets. */
function seamPieces(fa: Face, fb: Face, vertical: boolean, ctx: { radius: number; faces: Face[] }): Seam[] {
  // Along the seam (u) and across it.
  const [a0, a1, b0, b1] = vertical ? [fa.y0, fa.y1, fb.y0, fb.y1] : [fa.x0, fa.x1, fb.x0, fb.x1];
  const [aEnd, bStart] = vertical ? [fa.x1, fb.x0] : [fa.y1, fb.y0];
  const u0 = Math.max(a0, b0);
  const u1 = Math.min(a1, b1);
  if (u1 - u0 < 1) return [];
  const out: (Seam | null)[] = [];
  const gap = bStart - aEnd;
  if (gap > 0.5) {
    const [x, y, w, h] = vertical ? [aEnd, u0, gap, u1 - u0] : [u0, aEnd, u1 - u0, gap];
    out.push({ kind: "bridge", x, y, w, h, d: `M${fx(x)} ${fx(y)}H${fx(x + w)}V${fx(y + h)}H${fx(x)}Z` });
  }
  // The ends: where A goes on past B, the inner corner is on B's side of A's edge; where B goes on, on A's side.
  const r = Math.min(ctx.radius, (u1 - u0) / 2);
  const at = (end: number, across: number, sAcross: number, s: number) =>
    filletAt(vertical ? { px: across, py: end, sx: sAcross, sy: s, r } : { px: end, py: across, sx: s, sy: sAcross, r }, ctx.faces);
  const aOn = [a0 < u0 - 0.5, a1 > u1 + 0.5];
  const bOn = [b0 < u0 - 0.5, b1 > u1 + 0.5];
  [u0, u1].forEach((end, k) => {
    const s = k ? 1 : -1;
    if (aOn[k] && !bOn[k]) out.push(at(end, aEnd, 1, s));
    if (bOn[k] && !aOn[k]) out.push(at(end, bStart, -1, s));
  });
  return out.filter((p): p is Seam => !!p);
}

/**
 * The pieces that merge two faces touching over PART of an edge (joins): the gutter between them along the shared
 * span only (both faces' extents: edges line up exactly with the faces), and at each end where one face goes on past
 * the other, a fillet rounding the inner corner of the L - so the group reads as one surface, its free edges level.
 */
function seams(items: HomeItem[], joined: Map<string, Record<string, number>>, lifted: string | undefined, geo: { half: number; radius: number }): Seam[] {
  const on = items.filter((i) => boxed(i) && i.key !== lifted && joined.has(i.key));
  const face = new Map(on.map((i) => [i.key, faceRect(i, joined.get(i.key)!, geo.half)]));
  const ctx = { radius: geo.radius, faces: [...face.values()] };
  const out: Seam[] = [];
  for (const A of on)
    for (const B of on)
      for (const vertical of [false, true])
        if (A !== B && meets(shown(A), shown(B), vertical)) out.push(...seamPieces(face.get(A.key)!, face.get(B.key)!, vertical, ctx));
  return out;
}

/** The faces' rounded boxes on a page, as SVG path data: all of them, and those in a merged group; the extent. */
function faces(items: HomeItem[], joined: Map<string, Record<string, number>>, lifted: string | undefined) {
  const css = getComputedStyle(document.documentElement);
  const half = (parseFloat(css.getPropertyValue("--gap")) || 8) / 2;
  const radius = parseFloat(css.getPropertyValue("--radius")) || 12;
  let w = 1;
  let h = 1;
  const paths: string[] = [];
  const grouped: string[] = [];
  for (const i of items) {
    if (!textured(i) || i.key === lifted) continue;
    const j = joined.get(i.key) ?? {};
    const { x0, y0, x1, y1 } = faceRect(i, j, half);
    const [tl, tr, br, bl] = ["--ctl", "--ctr", "--cbr", "--cbl"].map((k) => radius * (j[k] ?? 1));
    const f = (n: number) => +n.toFixed(1);
    const d =
      `M${f(x0 + tl)} ${f(y0)}H${f(x1 - tr)}A${tr} ${tr} 0 0 1 ${f(x1)} ${f(y0 + tr)}V${f(y1 - br)}A${br} ${br} 0 0 1 ${f(x1 - br)} ${f(y1)}` +
      `H${f(x0 + bl)}A${bl} ${bl} 0 0 1 ${f(x0)} ${f(y1 - bl)}V${f(y0 + tl)}A${tl} ${tl} 0 0 1 ${f(x0 + tl)} ${f(y0)}Z`;
    paths.push(d);
    if (joined.has(i.key)) grouped.push(d);
    w = Math.max(w, Math.ceil(x1));
    h = Math.max(h, Math.ceil(y1));
  }
  // The seam pieces are face too: the picture shows through them, the group's shadow falls round them.
  for (const p of seams(items, joined, lifted, { half, radius })) {
    paths.push(p.d);
    grouped.push(p.d);
  }
  return { all: paths.join(""), grouped: grouped.join(""), w, h };
}

/** The seam pieces as surfaces (a .tile each: the compositor's glass region and the tint, as a face's). */
function Seams({ items, joined }: { items: HomeItem[]; joined: Map<string, Record<string, number>> }) {
  if (!joined.size) return null;
  const css = getComputedStyle(document.documentElement);
  const half = (parseFloat(css.getPropertyValue("--gap")) || 8) / 2;
  const radius = parseFloat(css.getPropertyValue("--radius")) || 12;
  const list = seams(items, joined, carry.value?.item?.key, { half, radius });
  return (
    <>
      {list.map((p) => (
        <div
          key={`${p.kind}${p.x},${p.y}`}
          class={`tile seam ${p.kind}`}
          style={{
            left: `${p.x}px`,
            top: `${p.y}px`,
            width: `${p.w}px`,
            height: `${p.h}px`,
            ...(p.kind === "fillet" ? { "--fx": `${p.cx}px`, "--fy": `${p.cy}px`, "--fr": `${p.w}px` } : {}),
          }}
        />
      ))}
    </>
  );
}

function faceMask(items: HomeItem[], joined: Map<string, Record<string, number>>, lifted: string | undefined) {
  const f = faces(items, joined, lifted);
  if (!f.all) return null;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${f.w}" height="${f.h}" viewBox="0 0 ${f.w} ${f.h}"><path d="${f.all}"/></svg>`;
  return { "--glass-mask": `url("data:image/svg+xml,${encodeURIComponent(svg)}")`, "--glass-mask-size": `${f.w}px ${f.h}px` };
}

/**
 * A merged group's --lift (theme.css) as one surface's: the shadow under the GROUP's outline, not under each tile
 * (each tile's own would fall on its neighbours, through them). One static SVG per page, drawn when its tiles change:
 * the group outlines, blurred and dropped, cut away wherever a face is. The light top edge is the tiles' own
 * (shell.css .home-tile.joined: only where a tile's top is the group's).
 */
function GroupShadow({ items, joined, id }: { items: HomeItem[]; joined: Map<string, Record<string, number>>; id: string }) {
  const f = faces(items, joined, carry.value?.item?.key);
  if (!f.grouped) return null;
  const W = f.w + 40;
  const H = f.h + 40;
  return (
    <svg class="group-shadow" width={W} height={H} viewBox={`0 0 ${W} ${H}`} aria-hidden="true">
      <defs>
        <filter id={`gs-${id}`} x="-10%" y="-10%" width="120%" height="120%">
          <feGaussianBlur stdDeviation="7" />
        </filter>
        {/* The faces cut out stroked too: two faces meeting at a fractional pixel each antialias their shared edge, and the
            shadow showed through between merged tiles as a dark hairline. */}
        <mask id={`gm-${id}`} maskUnits="userSpaceOnUse" x="0" y="0" width={W} height={H}>
          <rect width={W} height={H} fill="#fff" />
          <path d={f.all} fill="#000" stroke="#000" stroke-width="1" />
        </mask>
      </defs>
      <g mask={`url(#gm-${id})`}>
        <path d={f.grouped} fill="rgb(0 0 0 / 0.42)" transform="translate(0 7)" filter={`url(#gs-${id})`} />
      </g>
    </svg>
  );
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
  const c = carry.value;
  const lifted = c?.item?.key === item.key || (!!c?.item && isChosen(item.key) && isChosen(c.item.key));
  const isSelected = selected.value === item.key;
  const b = box(shown(item));
  return (
    <div
      class={`home-tile ${item.kind} ${isSelected ? "selected" : ""} ${isChosen(item.key) ? "chosen" : ""} ${lifted ? "lifted" : ""} ${join ? "joined" : ""}`}
      /* Its key: what finds it from outside (the pet perches on a tile by it - ui/petperch.ts). */
      data-key={item.key}
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
      {item.kind === "panel" && item.name === "search" && <SearchPanel />}
      {item.kind === "app" && <AppFace appKey={item.app!} label={item.label} />}
      {item.kind === "folder" && <FolderFace item={item} />}
      {isSelected && !lifted && !isFootSearch(item.key) && <Actions item={item} />}
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
        if (cell) await placeItem(item.key, cell, item.page);
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
  const party = partyAim(c);
  if (party) return <>{[...(party.cells ?? new Map<string, Cell>()).entries()].map(([key, cell]) => <Spot key={key} cell={shownCell(party.party, key, cell)} />)}</>;
  const target = dockAim.value ? null : aim(c);
  const spot = target?.cell ? box(target.cell) : null;
  return spot && <div class="drop-spot" style={{ left: `${spot.left}px`, top: `${spot.top}px`, width: `${spot.width}px`, height: `${spot.height}px` }} />;
}

/** A picked tile's landing cell as it shows (apps and folders 1x1). */
const shownCell = (party: HomeItem[], key: string, cell: Cell) => shown({ ...party.find((i) => i.key === key)!, cell });

function Spot({ cell }: { cell: Cell }) {
  const spot = box(cell);
  return <div class="drop-spot" style={{ left: `${spot.left}px`, top: `${spot.top}px`, width: `${spot.width}px`, height: `${spot.height}px` }} />;
}

/**
 * What the picked tiles can do together, over them (under them when they're at the top): 2+ apps go into one folder,
 * opened at once so it can be named. Only at rest - not while a finger draws or carries.
 */
function ChosenActions() {
  const n = pages.value[page.value];
  const items = itemsOn(n).filter((i) => isChosen(i.key));
  if (!editing.value || items.length < 2 || carry.value || marquee.value || !folderable(items)) return null;
  const boxes = items.map((i) => box(shown(i)));
  const top = Math.min(...boxes.map((b) => b.top));
  const bottom = Math.max(...boxes.map((b) => b.top + b.height));
  const left = Math.min(...boxes.map((b) => b.left));
  const above = top > 56;
  const stop = (e: Event) => e.stopPropagation();
  return (
    <div class="tile-actions tile chosen-actions" style={{ left: `${left}px`, top: above ? `${top - 52}px` : `${bottom + 4}px`, bottom: "auto" }} onPointerDown={stop} onPointerUp={stop}>
      <button
        class="group-folder"
        onClick={async () => {
          const made = await groupIntoFolder(items);
          chosen.value = [];
          if (made) folder.value = made;
        }}
      >
        group into folder
      </button>
    </div>
  );
}

/** The selection rectangle being drawn on empty space (homeselect.ts): only while a finger draws it. */
function Marquee() {
  const r = marquee.value;
  if (!r) return null;
  const [l, t] = [Math.min(r.x0, r.x1), Math.min(r.y0, r.y1)];
  return <div class="marquee" style={{ left: `${l}px`, top: `${t}px`, width: `${Math.abs(r.x1 - r.x0)}px`, height: `${Math.abs(r.y1 - r.y0)}px` }} />;
}

/** The other picked tiles carried with the lead one, where they sit beside it. */
function PartyGhosts({ c }: { c: Carry }) {
  const party = partyOf(c.item, itemsOn(c.item?.page ?? 0));
  if (!party) return null;
  const g = geometry.value;
  const lead = box(shown(c.item!));
  return (
    <>
      {party
        .filter((i) => i.key !== c.item!.key)
        .map((i) => {
          const b = box(shown(i));
          return (
            <div class="carried" key={i.key} style={{ left: `${g.left + c.x - c.grab.x + b.left - lead.left}px`, top: `${g.top + c.y - c.grab.y + b.top - lead.top}px`, width: `${b.width}px`, height: `${b.height}px` }}>
              <Face item={i} />
            </div>
          );
        })}
    </>
  );
}

/** A carried tile's face: an app's icon, else its name on a plain face. */
function Face({ item }: { item: HomeItem }) {
  if (item.kind === "app") return <AppFace appKey={item.app!} label={item.label} />;
  return (
    <div class="tile widget-face focused">
      <div class="widget-name">{item.kind === "folder" ? folderName(item.key) : item.name}</div>
    </div>
  );
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
    <>
      <div
        class="carried"
        style={{ left: `${g.left + c.x - c.grab.x}px`, top: `${g.top + c.y - c.grab.y}px`, width: `${size.w * g.cellW}px`, height: `${size.h * g.cellH}px` }}
      >
        {c.app ? <AppFace appKey={c.app} /> : <Face item={c.item!} />}
      </div>
      <PartyGhosts c={c} />
    </>
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
type EmptyPress = { x: number; y: number; timer: number; long: boolean; at: number; armed: number };

/**
 * Editing, a finger moved on empty space draws the selection rectangle (homeselect.ts) when it was held still first
 * (then home's swipes hold off from that moment: gesture.ts held) or went up/down first; sideways at once it's the pages'.
 */
function marqueeFrom(p: EmptyPress, e: PointerEvent) {
  const dwelt = performance.now() - p.at >= MARQUEE_DWELL;
  if (!editing.value || !(dwelt || Math.abs(e.clientY - p.y) > Math.abs(e.clientX - p.x))) return;
  const g = geometry.value;
  const n = pages.value[page.value];
  // The app library has no tiles to pick.
  if (n == null) return;
  startMarquee(e, p, { origin: { left: g.left, top: g.top }, items: () => itemsOn(n), boxOf: (i) => box(shown(i)) });
}

function useEmptyPress() {
  const s = useRef<EmptyPress | null>(null);
  const cancel = () => {
    if (s.current) clearTimeout(s.current.timer);
    if (s.current) clearTimeout(s.current.armed);
    // Armed but never drawn: home's swipes are home's again.
    if (s.current?.armed && !marquee.value) held.value = false;
    s.current = null;
  };
  return {
    onPointerDown: (e: PointerEvent) => {
      if (e.button || !onEmpty(e) || drawerOpen.value) return;
      const p = { x: e.clientX, y: e.clientY, timer: 0, long: false, at: performance.now(), armed: 0 };
      // Already editing: a hold arms the rectangle instead (nothing more to start).
      if (editing.value) p.armed = window.setTimeout(() => (held.value = true), MARQUEE_DWELL);
      else
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
      // Moved: a swipe (pages, the drawer), not a hold - or, editing, the rectangle.
      if (!p || p.long || Math.hypot(e.clientX - p.x, e.clientY - p.y) <= SLOP) return;
      marqueeFrom(p, e);
      cancel();
    },
    onPointerUp: (e: PointerEvent) => {
      const p = s.current;
      cancel();
      if (!p || p.long || Math.hypot(e.clientX - p.x, e.clientY - p.y) > SLOP) return;
      if (selected.value) selected.value = null;
      else if (chosen.value.length) chosen.value = [];
      else if (editing.value) editing.value = false;
    },
    onPointerCancel: cancel,
  };
}

/**
 * The grid measured from the pages element: on a resize, and when home is shown again or turned/folded (back from an
 * app that ran in landscape the pages had been measured at its size while hidden) - at once and after the window settles.
 */
function useMeasured(el: { current: HTMLDivElement | null }) {
  useEffect(() => {
    const again = () => el.current && measure(el.current, home.value.columns);
    const ro = new ResizeObserver(again);
    ro.observe(el.current!);
    const shown = () => {
      if (document.hidden) return;
      again();
      requestAnimationFrame(() => requestAnimationFrame(again));
      setTimeout(again, 400);
    };
    document.addEventListener("visibilitychange", shown);
    addEventListener("pageshow", shown);
    addEventListener("orientationchange", shown);
    addEventListener("resize", shown);
    return () => {
      ro.disconnect();
      document.removeEventListener("visibilitychange", shown);
      removeEventListener("pageshow", shown);
      removeEventListener("orientationchange", shown);
      removeEventListener("resize", shown);
    };
  }, []);
}

export function Pages() {
  const el = useRef<HTMLDivElement>(null);
  const emptyPress = useEmptyPress();
  useMeasured(el);
  // Tiles reaching further down add rows: re-measure then. (Not on the drawer opening or closing: nothing of home's
  // layout changes with it - shell.css .launcher - and reading drawerOpen here re-rendered every page, its glass mask
  // rebuilt, at each open and close.)
  useEffect(() => void (el.current && measure(el.current, home.value.columns)), [home.value]);
  // Items without a cell yet (a widget from the store, an app pinned from a menu): the host gives them the first free
  // spot, once the grid's rows are known - as the Compose home does laying a page out.
  const rows = geometry.value.rows;
  useEffect(() => {
    if (rows > 0 && home.value.items.some((i) => !i.cell)) powos.home.arrange(home.value.columns, rows);
  }, [home.value, rows]);
  useEffect(loadFolderNames, []);
  // The recent apps row, once, as a widget of home's (ui/recentwidget.tsx), at the bottom of the first page.
  useEffect(() => void migrateRecents(rows), [rows]);
  // Also each render: a page's glass layer just mounted takes the track's place at once.
  useEffect(() => applyTrack());
  const list = pages.value;
  // The app library is the page after them (ui/library.tsx).
  if (page.value > list.length) page.value = list.length;
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
                  <GroupShadow items={on} joined={joined} id={String(n)} />
                  <Seams items={on} joined={joined} />
                  {on.map((item) => (
                    <Tile key={item.key} item={item} join={joined.get(item.key)} />
                  ))}
                </>
              );
            })(itemsOn(n))}
          </div>
        ))}
        <LibraryPage here={page.value === list.length} onHold={(app, from, e, grab) => startCarry({ app, fromFolder: from }, e, grab)} />
      </div>
      <Preview />
      <Marquee />
      <ChosenActions />
      <FolderPanel onDragOut={(app, from, e, grab) => startCarry({ app, fromFolder: from }, e, grab)} />
    </div>
  );
}
