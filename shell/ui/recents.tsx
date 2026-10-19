/**
 * The switcher: a layer of home's own page, as Quickstep's recents view lives in the launcher. The recent tasks side by
 * side as Android lays them out: the app it was opened over in the middle, the ones used before it to its left (the
 * one just left right next to it), older further left - a sideways swipe scrolls them, with momentum. A tap opens one
 * (its card grows to the screen, then the app is there), a swipe up removes it, "clear all" removes all but the pinned
 * ones, a tap beside the cards or Back closes it (Back goes back to the app it was opened over). A card's icon (or a
 * long press) opens its menu: split screen (then pick the second app), floating window, screenshot, app info, pin.
 *
 * A swipe up over an app builds it under the finger (system/Switcher.kt, the native side): home comes up behind the
 * app ("recents.begin"), the app's window shrinks onto the first card's slot - where that slot is, the page tells the
 * host ([reportSlot]) - while the other cards slide in with the finger ("recents.drag", every display frame: only CSS
 * variables and transforms change, nothing re-renders). The cards are laid out before that, while the app is in front
 * ("recents.tasks"), their snapshots loaded, so the first frame of a swipe has them. Let go:
 * - held, or slowly (to: switcher): the window is on its card; the card gets the app's fresh snapshot, and once it
 *   shows it the host lets the window go (powos.recents.ready) - the layer is simply up, it's home's own page.
 * - flung up (to: home), or early (to: app): the layer collapses back into home.
 * The overview button shows it without a swipe ("recents.show"); home going away hides it ("recents.hide").
 */
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { RecentTask } from "../types.ts";
import { TaskCard, type Rect } from "./switcher.tsx";
import { spring } from "./spring.ts";

type Phase = "closed" | "drag" | "shown";

const phase = signal<Phase>("closed");
const tasks = signal<RecentTask[]>([]);
/** The task it was opened over (null: home). */
const from = signal<number | null>(null);
/** The first card's frame is under the app's real window (hidden till the window lets go). */
const live = signal(false);
/** Animating between states (CSS transitions on), rather than following a finger. */
const settling = signal(false);
/** The screen's size: the cards are the screen's shape. */
const size = signal({ w: innerWidth, h: innerHeight });
/** A card's menu, open over it. */
const menu = signal<{ id: number; left: number; top: number } | null>(null);
/** Split screen: the first app picked, waiting for the second. */
const splitFirst = signal<number | null>(null);
/** A card growing to the screen as its app opens. */
const opening = signal<{ id: number; rect: Rect; src: string; radius: string } | null>(null);
/** Apps kept from "clear all" (by app, as Android's lock: task ids don't outlive a reboot). */
const pinned = signal<Set<string>>(new Set());
/** The cards' snapshots are in the page (the switcher up, or on its way up or down); off at rest. */
const loaded = signal(false);
/** A short note (a screenshot saved). */
const note = signal<string | null>(null);

powos.store
  .get<string[]>("recents.pinned")
  .then((keys) => keys && (pinned.value = new Set(keys)))
  .catch(() => {});

const pinKey = (t: RecentTask) => t.key ?? `label:${t.label}`;

let layer: HTMLDivElement | null = null;
let row: HTMLDivElement | null = null;

/**
 * The row back at its start (the first card - the app it was opened over - in the middle) once the new list has
 * rendered: scrolled before the render, the browser kept the card that was in view where it was (scroll anchoring)
 * and the window landed on the wrong card.
 */
let rewind = false;
function toStart() {
  rewind = true;
  row?.scrollTo({ left: 0 });
}

/** Home's content (the pages, the bar, the dock): it recedes as the switcher comes up. */
const screens = () => document.querySelector<HTMLElement>(".screens");

/** The app it was opened over first (its window lands on the first card), then the rest, newest first. */
function order(list: RecentTask[], over: number | null) {
  const i = list.findIndex((t) => t.id === over);
  return i > 0 ? [list[i], ...list.slice(0, i), ...list.slice(i + 1)] : list;
}

/**
 * A frame: [p] 0 (the app full screen, home as it was) .. 1 (the switcher up), the row moved by [x], [y] (CSS px).
 * Custom properties on the layer (its few nodes restyle) and an inline transform on home's content - no render.
 */
function frame(p: number, x = 0, y = 0, home = 0) {
  if (layer) {
    layer.style.setProperty("--rp", String(p));
    layer.style.setProperty("--rx", `${x}px`);
    layer.style.setProperty("--ry", `${y}px`);
    // Into the home zone (near the top): the cards fade and shrink away, home's icons come in - letting go there goes home.
    layer.style.setProperty("--rh", String(home));
  }
  const s = screens();
  if (s) {
    const shown = Math.max(1 - p, home);
    s.style.transform = shown < 1 ? `scale(${0.92 + 0.08 * shown})` : "";
    s.style.opacity = shown < 1 ? String(shown) : "";
  }
}

function settle(on: boolean) {
  settling.value = on;
  const s = screens();
  if (s) s.style.transition = on ? `transform ${spring.ms}ms ${spring.easing}, opacity 240ms ease` : "none";
}

const nextFrame = () => new Promise<void>((r) => requestAnimationFrame(() => r()));

function reset() {
  menu.value = null;
  splitFirst.value = null;
  opening.value = null;
}

/** The next swipe's snapshots fetched ahead into the HTTP cache (not decoded, not in the page: no GPU memory held). */
function prefetch(list: RecentTask[]) {
  for (const t of list.slice(0, 4)) fetch(t.snapshot).catch(() => {});
}

function begin(e: { from: number | null; tasks: RecentTask[] }) {
  loaded.value = true;
  console.log(`recents: begin over ${e.from}, ${e.tasks.length} tasks, visible ${document.visibilityState}`);
  settle(false);
  reset();
  from.value = e.from;
  tasks.value = order(e.tasks, e.from);
  live.value = e.from != null;
  phase.value = "drag";
  toStart();
  frame(0);
}

/** Shown without a swipe (the overview button, up and hold over home): it comes up over home. */
async function show(e: { from: number | null; tasks: RecentTask[] }) {
  loaded.value = true;
  settle(false);
  reset();
  from.value = e.from;
  tasks.value = order(e.tasks, e.from);
  live.value = false;
  phase.value = "shown";
  toStart();
  frame(0);
  await nextFrame();
  settle(true);
  frame(1);
}

/** The switcher goes, back into home: animated ([animate]) or at once (home went out of sight). */
function collapse(animate: boolean) {
  settle(animate);
  reset();
  phase.value = "closed";
  frame(0);
  // At once when it's gone at once; else when the collapse is over (the layer's visibility transition ends).
  if (!animate) loaded.value = false;
}

/** The page closes it itself (beside the cards, Back over home, the last card gone, Home). */
function close() {
  if (phase.value === "closed") return;
  collapse(true);
  powos.recents.closed();
}

/** Held: the window is on the first card. Its fresh snapshot goes on the card; once it shows, the window may go. */
async function landed(snapshot: string | null) {
  settle(false);
  phase.value = "shown";
  frame(1);
  const id = from.value;
  if (snapshot && id != null) tasks.value = tasks.value.map((t) => (t.id === id ? { ...t, snapshot } : t));
  // The render (a microtask), then the card's image decoded, shown, and painted - then the host lets the window go.
  await Promise.resolve();
  const img = row?.querySelector<HTMLImageElement>(".task:first-child .task-shot");
  if (img && snapshot && img.getAttribute("src") !== snapshot) img.src = snapshot;
  await img?.decode().catch(() => {});
  if (img) img.style.visibility = "";
  live.value = false;
  await nextFrame();
  await nextFrame();
  powos.recents.ready();
}

/**
 * Opens task [id] from its card: the card's frame grows to the screen (a spring), then the app is opened with no
 * animation of its own - it appears over its own snapshot. The layer stays till home is out of sight ("recents.hide").
 */
function open(id: number, shot?: HTMLElement) {
  menu.value = null;
  const t = tasks.value.find((x) => x.id === id);
  const img = shot as HTMLImageElement | undefined;
  if (!t || !img || !img.complete || !img.naturalWidth) {
    powos.tasks.open(id).then((ok) => void (ok || refresh()));
    return;
  }
  const r = img.getBoundingClientRect();
  opening.value = { id, rect: { left: r.left, top: r.top, width: r.width, height: r.height }, src: img.currentSrc || img.src, radius: getComputedStyle(img).borderTopLeftRadius };
}

/** The growing card reached the screen's edges: the app now. */
function opened(id: number) {
  powos.tasks.open(id, "instant").then((ok) => {
    if (ok) return;
    opening.value = null;
    refresh();
  });
}

/** Where every card is now (for [flip]: the others close the gap a removed one leaves). */
let flipFrom: Map<number, number> | null = null;
function cardPositions() {
  const m = new Map<number, number>();
  row?.querySelectorAll<HTMLElement>(".task[data-task]").forEach((c) => m.set(Number(c.dataset.task), c.getBoundingClientRect().left));
  return m;
}

function remove(id: number) {
  menu.value = null;
  const t = tasks.value.find((x) => x.id === id);
  if (t?.kept) {
    showNote(`${t.label} stays: its widget is on home`);
    return false;
  }
  powos.tasks.remove(id);
  flipFrom = cardPositions();
  tasks.value = tasks.value.filter((t) => t.id !== id);
  if (splitFirst.value === id) splitFirst.value = null;
  if (!tasks.value.length) close();
  return true;
}

/** All but the pinned ones (and those with a widget on home) fly up and go; with nothing left, the switcher closes. */
function clearAll() {
  const stays = (t: RecentTask) => t.kept || pinned.value.has(pinKey(t));
  const keep = tasks.value.filter(stays);
  const going = tasks.value.filter((t) => !stays(t));
  if (!going.length) return;
  let left = going.length;
  going.forEach((t, i) => {
    const card = row?.querySelector<HTMLElement>(`.task[data-task="${t.id}"]`);
    const done = () => {
      powos.tasks.remove(t.id);
      if (--left) return;
      flipFrom = cardPositions();
      tasks.value = keep;
      if (!keep.length) close();
    };
    if (!card) return done();
    card.animate([{ transform: "none", opacity: 1 }, { transform: `translateY(-${innerHeight}px)`, opacity: 0 }], {
      duration: 260,
      delay: Math.min(i, 6) * 30,
      easing: "cubic-bezier(0.4, 0, 1, 1)",
      fill: "forwards",
    }).onfinish = done;
  });
}

const refresh = () => powos.tasks.list().then((t) => (tasks.value = order(t, from.value)));

function togglePin(t: RecentTask) {
  const next = new Set(pinned.value);
  const k = pinKey(t);
  if (next.has(k)) next.delete(k);
  else next.add(k);
  pinned.value = next;
  powos.store.set("recents.pinned", [...next]);
}

/** A card picked for split screen: the first one waits for the second; the second splits them. */
function pickForSplit(id: number) {
  const first = splitFirst.value;
  if (first == null) {
    splitFirst.value = id;
    return;
  }
  splitFirst.value = null;
  if (first !== id) powos.tasks.split(first, id);
}

function showNote(text: string) {
  note.value = text;
  // The note goes with its own fade (CSS); the next one replaces it.
  layer?.querySelector(".recents-note")?.getAnimations().forEach((a) => a.cancel());
}

/** The first card's frame (inside its border), where a swiped-up window lands. */
function firstShot() {
  return row?.querySelector<HTMLElement>(".task:first-child .task-shot") ?? null;
}

let reported = "";
/**
 * Tells the host where the first card's frame is (CSS px), when it moved - the row's finger offset (--rx, --ry)
 * discounted, so it's right mid-swipe too (the page resized under a swipe: a window just made for it). Not scrolled.
 */
function reportSlot() {
  // Not while the row is animating (settling) or scrolled: its box is between places.
  if (!row || !layer || Math.abs(row.scrollLeft) >= 1 || row.getAnimations().length) return;
  const shot = firstShot();
  if (!shot) return;
  const r = shot.getBoundingClientRect();
  if (!r.width) return;
  const dx = parseFloat(layer.style.getPropertyValue("--rx")) || 0;
  const dy = parseFloat(layer.style.getPropertyValue("--ry")) || 0;
  const slot = {
    left: r.left - dx + shot.clientLeft,
    top: r.top - dy + shot.clientTop,
    width: shot.clientWidth,
    height: shot.clientHeight,
    radius: parseFloat(getComputedStyle(shot).borderTopLeftRadius) || 0,
  };
  const key = JSON.stringify(slot);
  if (key === reported) return;
  reported = key;
  powos.recents.slot(slot);
}

/** Back: out of a menu or split screen's pick, else to the app it was opened over, or home. False when it isn't up. */
export function recentsBack(): boolean {
  if (phase.value === "closed") return false;
  if (menu.value) menu.value = null;
  else if (splitFirst.value != null) splitFirst.value = null;
  else if (from.value != null) open(from.value, firstShot() ?? undefined);
  else close();
  return true;
}

/** Home pressed: the switcher goes with everything else - not one a swipe is building now (a late home intent). */
export function recentsHome() {
  if (phase.value === "drag") return;
  close();
}

powos.on("recents.begin", begin);
powos.on("recents.drag", (e: { progress: number; x: number; y: number; home?: number }) => {
  if (phase.value === "drag") frame(e.progress, e.x, e.y, e.home ?? 0);
});
powos.on("recents.end", (e: { to: "switcher" | "home" | "app"; snapshot?: string | null }) => {
  if (e.to === "switcher") landed(e.snapshot ?? null);
  // The window's settle drove the layer here frame by frame (its spring, "recents.drag"): it's there - let go at once.
  // Not from a swipe (or the host gave up on one): collapsed with its own spring.
  else collapse(phase.value !== "drag");
});
powos.on("recents.show", (e: { open: boolean; from: number | null; tasks: RecentTask[] }) => void show(e));
powos.on("recents.hide", () => collapse(false));
// The list for the next swipe, while an app is in front: laid out (hidden) now, snapshots loading.
powos.on("recents.tasks", (e: { tasks: RecentTask[] }) => {
  if (phase.value !== "closed") return;
  tasks.value = e.tasks;
  toStart();
  prefetch(e.tasks);
});
// The overview button again: the task before the one it was opened over (or the newest, from home), as Android's.
powos.on("switcher.toggle", () => {
  const list = tasks.value;
  const next = list[0]?.id === from.value ? list[1] : list[0];
  if (next) open(next.id, row?.querySelector<HTMLElement>(`.task[data-task="${next.id}"] .task-shot`) ?? undefined);
  else close();
});
addEventListener("resize", () => (size.value = { w: innerWidth, h: innerHeight }));

/** A card's stand-in while there are no tasks: the first card's slot stays laid out (it's measured). */
function Placeholder() {
  return (
    <div class="task" aria-hidden="true">
      <div class="task-head">
        <span class="task-icon blank" />
        <span class="task-label" />
      </div>
      <div class="task-shot" />
    </div>
  );
}

/** The card growing to the screen as its app opens (over everything, the layer included). */
function Opening() {
  const o = opening.value;
  const el = useRef<HTMLImageElement>(null);
  useLayoutEffect(() => {
    if (!o || !el.current) return;
    const { left, top, width, height } = o.rect;
    const sx = width / innerWidth;
    const sy = height / innerHeight;
    el.current.animate(
      [
        { transform: `translate(${left}px, ${top}px) scale(${sx}, ${sy})`, borderRadius: `${parseFloat(o.radius) / sx}px` },
        { transform: "none", borderRadius: "0px" },
      ],
      { duration: Math.min(spring.ms, 320), easing: "cubic-bezier(0.2, 0.9, 0.2, 1)", fill: "forwards" },
    ).onfinish = () => opened(o.id);
  }, [o?.id]);
  if (!o) return null;
  return <img ref={el} class="recents-expand" src={o.src} alt="" />;
}

function Menu() {
  const m = menu.value;
  if (!m) return null;
  const t = tasks.value.find((x) => x.id === m.id);
  if (!t) return null;
  const isPinned = pinned.value.has(pinKey(t));
  const act = (f: () => void) => () => {
    menu.value = null;
    f();
  };
  return (
    <>
      <div class="recents-menu-scrim" onPointerDown={() => (menu.value = null)} />
      <div class="recents-menu tile" style={{ left: `${m.left}px`, top: `${m.top}px` }}>
        <button type="button" onClick={act(() => pickForSplit(t.id))}>
          Split screen
        </button>
        <button type="button" onClick={act(() => powos.tasks.float(t.id))}>
          Floating window
        </button>
        <button
          type="button"
          onClick={act(() =>
            powos.tasks.screenshot(t.id).then((name) => showNote(name ? `Saved ${name}` : "No screenshot of this app yet")),
          )}
        >
          Screenshot
        </button>
        <button type="button" onClick={act(() => togglePin(t))}>
          {isPinned ? "Unpin" : "Pin (keep on clear all)"}
        </button>
        <button type="button" onClick={act(() => powos.tasks.info(t.id))}>
          App info
        </button>
      </div>
    </>
  );
}

export function Recents() {
  const el = useRef<HTMLDivElement>(null);
  const rowEl = useRef<HTMLDivElement>(null);
  useEffect(() => {
    layer = el.current;
    row = rowEl.current;
    frame(0);
    // Its list now (laid out ahead of the first swipe); opened before this page loaded (home started cold for the
    // switcher): up at once.
    powos.recents.state().then((s) => {
      if (!s) return;
      if (s.open && phase.value === "closed") show(s);
      else if (phase.value === "closed" && s.tasks?.length) {
        tasks.value = s.tasks;
        prefetch(s.tasks);
      }
    });
    // The slot moves when the screen does (rotation, folding) or the insets change.
    const observer = new ResizeObserver(() => reportSlot());
    observer.observe(el.current!);
    const off = powos.on("system.insets", () => requestAnimationFrame(reportSlot));
    requestAnimationFrame(reportSlot);
    return () => {
      observer.disconnect();
      off();
      layer = row = null;
    };
  }, []);
  // The cards changed (a swipe's list came in, the screen turned): where the first card is, again.
  useEffect(() => {
    requestAnimationFrame(reportSlot);
  }, [phase.value, size.value, tasks.value]);
  // A new list: the row at its start (see rewind).
  useLayoutEffect(() => {
    if (!rewind || !row) return;
    rewind = false;
    row.scrollLeft = 0;
    reportSlot();
  }, [tasks.value]);
  // A card went: the others slide into its place (from where they were, as a spring).
  useLayoutEffect(() => {
    const before = flipFrom;
    flipFrom = null;
    if (!before || !row) return;
    row.querySelectorAll<HTMLElement>(".task[data-task]").forEach((c) => {
      const was = before.get(Number(c.dataset.task));
      if (was == null) return;
      const dx = was - c.getBoundingClientRect().left;
      if (Math.abs(dx) > 1) c.animate([{ transform: `translateX(${dx}px)` }, { transform: "none" }], { duration: spring.ms, easing: spring.easing });
    });
  }, [tasks.value]);
  const list = tasks.value;
  const p = phase.value;
  const { w, h } = size.value;
  const first = splitFirst.value;
  return (
    <div
      ref={el}
      class={`recents ${p} ${p === "closed" ? "" : "open"} ${live.value ? "live" : ""} ${settling.value ? "settling" : ""} ${first != null ? "splitting" : ""}`}
      style={{ "--screen-ratio": `${w} / ${h}`, "--screen-ratio-n": String(w / h) }}
      onClick={(e) => e.target === e.currentTarget && (first != null ? (splitFirst.value = null) : close())}
      onTransitionEnd={(e) => {
        if (e.target === row) reportSlot();
        // Collapsed: its snapshots leave the page.
        if (e.target === e.currentTarget && phase.value === "closed") loaded.value = false;
      }}
    >
      <div class="recents-scrim" />
      {first != null && <div class="recents-banner">Pick an app to split the screen with</div>}
      <div class="task-row" ref={rowEl} onClick={(e) => e.target === e.currentTarget && (first != null ? (splitFirst.value = null) : close())}>
        {list.length ? (
          list.map((t, i) => (
            <TaskCard
              key={t.id}
              t={t}
              current={i === 0}
              eager={i < 4}
              load={loaded.value}
              pinned={pinned.value.has(pinKey(t))}
              picked={first === t.id}
              onOpen={(id, shot) => (first != null ? pickForSplit(id) : open(id, shot))}
              onRemove={remove}
              onMenu={(id, card) => {
                const r = card.getBoundingClientRect();
                menu.value = { id, left: Math.max(8, Math.min(innerWidth - 228, r.left + 8)), top: r.top + 36 };
              }}
            />
          ))
        ) : (
          <Placeholder />
        )}
      </div>
      <button type="button" class="task-clear" style={{ visibility: list.length ? undefined : "hidden" }} onClick={clearAll}>
        Clear all
      </button>
      {note.value && (
        <div class="recents-note" key={note.value} onAnimationEnd={() => (note.value = null)}>
          {note.value}
        </div>
      )}
      <Menu />
      <Opening />
    </div>
  );
}
