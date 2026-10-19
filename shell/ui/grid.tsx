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
 *
 * Everything carried follows window-level pointer events, so a drag outlives the element it started on - the drawer
 * closes under the finger, a page turns.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { byKey, carry, folder, home, launch, page, pages, selected, type Carry } from "../state.ts";
import { powos } from "../bridge.ts";
import { pageDrag } from "./gesture.ts";
import { OwlWidget } from "./owl.tsx";
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
const geometry = signal<Geometry>({ left: 0, top: 0, width: 0, height: 0, cellW: 0, cellH: 0, rows: 0, pad: 12 });

/** Rows the tiles on every page reach down to (apps count as 1x1). */
const usedRows = () => Math.max(0, ...home.value.items.filter((i) => i.cell).map((i) => (i.resizable ? i.cell!.y + i.cell!.h : i.cell!.y + 1)));

function measure(el: HTMLElement, columns: number) {
  const r = el.getBoundingClientRect();
  if (!r.width || !r.height) return;
  const pad = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--edge")) || 12;
  const across = r.width - 2 * pad;
  const down = r.height - 2 * pad;
  const square = Math.max(1, Math.min(MAX_SQUARE_ROWS, Math.floor(down / (across / columns))));
  const rows = Math.max(square, usedRows());
  geometry.value = { left: r.left, top: r.top, width: r.width, height: r.height, cellW: across / columns, cellH: down / rows, rows, pad };
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
 * Starts carrying [what] ({ item } or { app }) with the pointer of [e]: follows it on the window until it lifts, then
 * drops. [grab] is where the finger holds the tile.
 */
export function startCarry(what: { item?: HomeItem; app?: string }, e: PointerEvent, grab = { x: 0, y: 0 }) {
  const g = geometry.value;
  carry.value = { ...what, x: e.clientX - g.left, y: e.clientY - g.top, grab };
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
  };
  const up = async (ev: PointerEvent) => {
    if (ev.pointerId !== e.pointerId) return;
    window.removeEventListener("pointermove", move);
    window.removeEventListener("pointerup", up);
    window.removeEventListener("pointercancel", up);
    clearInterval(turner);
    const c = carry.value;
    const target = ev.type === "pointerup" && c ? aim(c) : null;
    carry.value = null;
    if (!c || !target) return;
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
      {app ? <img class="app-icon" src={app.icon} alt="" draggable={false} /> : <div class="app-icon initials">{(label ?? "?")[0]}</div>}
      <div class="app-label">{label ?? app?.label}</div>
    </div>
  );
}

function Tile({ item }: { item: HomeItem }) {
  const press = useTilePress(item, () => {
    if (item.kind === "app") launch(item.app!);
    else if (item.kind === "folder") folder.value = item.key;
  });
  const lifted = carry.value?.item?.key === item.key;
  const isSelected = selected.value === item.key;
  const b = box(shown(item));
  return (
    <div
      class={`home-tile ${item.kind} ${isSelected ? "selected" : ""} ${lifted ? "lifted" : ""}`}
      style={{ left: `${b.left}px`, top: `${b.top}px`, width: `${b.width}px`, height: `${b.height}px` }}
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

/** Drag the corner: the widget grows or shrinks by whole cells, never under its minimum or onto another tile. */
function ResizeHandle({ item }: { item: HomeItem }) {
  const [size, setSize] = useState<Cell | null>(null);
  const cell0 = item.cell!;
  const fit = (e: PointerEvent): Cell | null => {
    const g = geometry.value;
    const b = box(cell0);
    const w = Math.max(item.minSize[0], Math.min(home.value.columns - cell0.x, Math.round((e.clientX - g.left - b.left) / g.cellW)));
    const h = Math.max(item.minSize[1], Math.min(g.rows - cell0.y, Math.round((e.clientY - g.top - b.top) / g.cellH)));
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

function Preview() {
  const c = carry.value;
  if (!c) return null;
  const target = aim(c);
  const g = geometry.value;
  const size = c.item?.resizable ? c.item.cell! : { w: 1, h: 1 };
  const spot = target?.cell ? box(target.cell) : null;
  return (
    <>
      {spot && <div class="drop-spot" style={{ left: `${spot.left}px`, top: `${spot.top}px`, width: `${spot.width}px`, height: `${spot.height}px` }} />}
      <div class="carried" style={{ left: `${c.x - c.grab.x}px`, top: `${c.y - c.grab.y}px`, width: `${size.w * g.cellW}px`, height: `${size.h * g.cellH}px` }}>
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
    </>
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

export function Pages() {
  const el = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const ro = new ResizeObserver(() => measure(el.current!, home.value.columns));
    ro.observe(el.current!);
    return () => ro.disconnect();
  }, []);
  // Tiles reaching further down add rows: re-measure as the home changes.
  useEffect(() => void (el.current && measure(el.current, home.value.columns)), [home.value]);
  const list = pages.value;
  if (page.value >= list.length) page.value = list.length - 1;
  // Widgets on the page on screen (and beside it) run their sources; the rest pause.
  useEffect(() => void powos.widgets.page(list[page.value] ?? 1), [page.value, list.join()]);
  const dx = pageDrag.value;
  return (
    <div
      class="pages"
      ref={el}
      onClick={(e) => {
        // A tap on the page itself, not a tile: edit mode ends.
        const t = e.target as HTMLElement;
        if (t.classList.contains("page") || t.classList.contains("page-track")) selected.value = null;
      }}
    >
      <div class={`page-track ${dx != null ? "dragging" : ""}`} style={{ transform: `translateX(calc(${-page.value * 100}% + ${dx ?? 0}px))` }}>
        {list.map((n) => (
          <div class="page" key={n}>
            {itemsOn(n).map((item) => (
              <Tile key={item.key} item={item} />
            ))}
          </div>
        ))}
      </div>
      <Preview />
      <div class="dots">
        {list.map((_, i) => (
          <span class={i === page.value ? "on" : ""} />
        ))}
      </div>
      <FolderPanel />
    </div>
  );
}
