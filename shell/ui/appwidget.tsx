/**
 * Other apps' Android widgets on home (AppWidgets.kt): Hue's light switch, a weather card, a player.
 *
 * - A tile is the widget's latest frame: the host draws the real widget off screen at the tile's size, and says when
 *   it redrew ("appwidgets.frame"). The page stays in charge - the tile is an <img> in the grid, so it moves, resizes,
 *   fades and slides with the pages like any tile, and home's swipes and long presses work over it.
 * - The finger on it goes back to the widget: down, moves and up, at the tile's coordinates, so its buttons press,
 *   ripple and click as on any launcher. When home takes the gesture (a page swipe, the drawer, the tile lifted) the
 *   widget gets a cancel instead, as a view whose parent intercepts does. A widget with a list (a calendar's agenda)
 *   keeps its drags - "scrolls", which gesture.ts leaves alone - so the list scrolls; on others, swipes are home's.
 * - Frames as fast as the page shows them: the next is asked for once the last one is on screen.
 * - The picker: every widget the phone's apps offer, by app, with their pictures and a search; the edit sheet places
 *   the one picked (editsheet.tsx).
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { signal, type Signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { apps, carry, editing, selected } from "../state.ts";
import { drawerDrag, notifDrag, pageDrag } from "./gesture.ts";
import { takeTap } from "./taps.ts";
import type { AppWidgetProvider, HomeItem } from "../types.ts";

/** Each widget's latest frame (a URL) and whether it has a list to scroll, by its id. */
type Frame = { url: string | null; scrolls: boolean };
const frames = new Map<number, Signal<Frame | null>>();
const frameOf = (id: number) => {
  if (!frames.has(id)) frames.set(id, signal<Frame | null>(null));
  return frames.get(id)!;
};
powos.on("appwidgets.frame", (f: Frame & { id: number }) => (frameOf(f.id).value = f));

/** How long a tile's size must hold before the widget is drawn at it. */
const SETTLE_MS = 300;

/** Home has the finger now: the widget's press ends as a cancel. */
const homeTook = () => !!carry.value || pageDrag.value != null || drawerDrag.value != null || notifDrag.value != null;

/** One Android widget's tile: its frame, watched while it's on screen, at its size; touches to the widget. */
export function AppWidgetFace({ item }: { item: HomeItem }) {
  const id = item.appWidget!.id;
  const el = useRef<HTMLDivElement>(null);
  const press = useRef<number | null>(null);
  const latest = frameOf(id).value;
  // The frame on screen; the next replaces it once it has loaded, so a list scrolling never queues frames up.
  const [shown, setShown] = useState<string | null>(null);
  const loading = useRef(false);
  const next = () => {
    const url = frameOf(id).value?.url;
    if (!url || url === shown) return void (loading.current = false);
    loading.current = true;
    setShown(url);
  };
  useEffect(() => void (loading.current || next()), [latest?.url]);

  useEffect(() => {
    // Its layout size, unrounded (transforms aside: the launcher's fold scales home, which isn't a new size to draw
    // at): the host draws the widget exactly this big, so the frame shows 1:1.
    let size = { w: 0, h: 0 };
    let settle = 0;
    const watch = () => {
      if (!size.w || !size.h || document.hidden) return;
      powos.appWidgets.watch(id, size.w, size.h).then((f) => f?.url && (frameOf(id).value = f));
    };
    // Sizes settle first: the keyboard sliding up re-lays the grid out every frame, and each new size is the widget
    // drawn again and its app told (APPWIDGET_UPDATE_OPTIONS).
    const ro = new ResizeObserver(([entry]) => {
      const next = { w: entry.contentRect.width, h: entry.contentRect.height };
      if (next.w === size.w && next.h === size.h) return;
      const first = !size.w;
      size = next;
      clearTimeout(settle);
      if (first) watch();
      else settle = window.setTimeout(watch, SETTLE_MS);
    });
    ro.observe(el.current!);
    // Home hidden behind an app: the widget isn't listened to (the host stops once no page shows it).
    const visible = () => (document.hidden ? powos.appWidgets.unwatch(id) : watch());
    document.addEventListener("visibilitychange", visible);
    return () => {
      ro.disconnect();
      clearTimeout(settle);
      document.removeEventListener("visibilitychange", visible);
      powos.appWidgets.unwatch(id);
    };
  }, [id]);

  const send = (action: "down" | "move" | "up" | "cancel", e: PointerEvent) => {
    const r = el.current!.getBoundingClientRect();
    powos.appWidgets.touch(id, action, e.clientX - r.left, e.clientY - r.top, r.width, r.height);
  };
  const end = (e: PointerEvent, action: "up" | "cancel") => {
    if (press.current !== e.pointerId) return;
    press.current = null;
    send(homeTook() ? "cancel" : action, e);
  };
  // Lifted by a long press: the widget lets go at once, not when the finger does.
  useEffect(
    () =>
      carry.subscribe((c) => {
        if (c && press.current != null) {
          press.current = null;
          powos.appWidgets.touch(id, "cancel", 0, 0, 1, 1);
        }
      }),
    [id],
  );

  return (
    <div
      ref={el}
      class={`aw-face ${latest?.scrolls ? "scrolls" : ""}`}
      onPointerDown={(e) => {
        // Editing home, a tile is moved and resized, not used.
        if (e.button || press.current != null || editing.value || selected.value || carry.value) return;
        press.current = e.pointerId;
        send("down", e);
      }}
      onPointerMove={(e) => {
        if (press.current !== e.pointerId) return;
        if (homeTook()) return end(e, "cancel");
        send("move", e);
      }}
      onPointerUp={(e) => {
        if (press.current === e.pointerId && !homeTook()) takeTap(e);
        end(e, "up");
      }}
      onPointerCancel={(e) => end(e, "cancel")}
    >
      {shown ? (
        <img src={shown} alt="" draggable={false} onLoad={next} onError={next} />
      ) : (
        <div class="aw-wait muted">{item.name}</div>
      )}
    </div>
  );
}

/** The picker, open over home (the edit sheet's "android widget"). */
export const picker = signal(false);

/** An app's drawer icon, by its package (an Android app's key is "a:<package>/<activity>"). */
const iconOf = (pkg: string) => apps.value.find((a) => a.key.startsWith(`a:${pkg}/`))?.icon;

export function AppWidgetPicker({ onPick }: { onPick: (p: AppWidgetProvider) => void }) {
  const [list, setList] = useState<AppWidgetProvider[] | null>(null);
  const [query, setQuery] = useState("");
  const open = picker.value;
  useEffect(() => {
    if (!open) return;
    setQuery("");
    // Fresh each time: apps are installed and removed.
    powos.appWidgets.providers().then(setList, () => setList([]));
  }, [open]);
  if (!open) return null;
  const q = query.trim().toLowerCase();
  const shown = (list ?? [])
    .filter((p) => !q || `${p.label} ${p.app} ${p.description ?? ""}`.toLowerCase().includes(q))
    .sort((a, b) => a.app.localeCompare(b.app) || a.label.localeCompare(b.label));
  const groups = new Map<string, AppWidgetProvider[]>();
  for (const p of shown) {
    const k = `${p.app}${p.work ? " (work)" : ""}`;
    groups.set(k, [...(groups.get(k) ?? []), p]);
  }
  const close = () => (picker.value = false);
  const stop = (e: Event) => e.stopPropagation();
  return (
    <div class="aw-scrim" onClick={close} onPointerDown={stop} onTouchStart={stop}>
      <div class="aw-picker tile" onClick={stop}>
        <div class="sheet-head">
          <span class="muted">android widgets</span>
          <button type="button" class="sheet-done" onClick={close}>
            close
          </button>
        </div>
        <input
          class="aw-search"
          type="search"
          placeholder="search widgets"
          value={query}
          onInput={(e) => setQuery((e.target as HTMLInputElement).value)}
        />
        <div class="aw-list">
          {list == null && <div class="muted">loading…</div>}
          {list != null && !shown.length && <div class="muted">no widgets{q ? ` for "${query}"` : ""}</div>}
          {[...groups].map(([app, items]) => {
            const icon = iconOf(items[0].package);
            return (
              <div class="aw-app" key={app}>
                <div class="aw-app-head">
                  {icon ? <img src={icon} alt="" /> : <span class="aw-app-blank" />}
                  <span>{app}</span>
                </div>
                <div class="aw-row">
                  {items.map((p) => (
                    <button type="button" class="aw-provider" key={p.provider} onClick={() => onPick(p)}>
                      <span class="aw-preview">
                        <img src={p.preview} alt="" loading="lazy" draggable={false} />
                      </span>
                      <span class="aw-label">{p.label}</span>
                      {p.description && <span class="aw-desc muted">{p.description}</span>}
                    </button>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
