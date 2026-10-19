/**
 * The switcher: a layer of home's own page, as Quickstep's recents view lives in the launcher. The recent tasks side by
 * side, newest first, the app it was opened over first; a tap opens one (it grows out of its card), a swipe up removes
 * it, "clear all" removes them all, a tap beside the cards or Back closes it (Back goes back to the app it was opened
 * over).
 *
 * A swipe up over an app builds it under the finger (system/Switcher.kt, the native side): home comes up behind the
 * app ("recents.begin"), the app's window shrinks onto the first card's slot - where that slot is, the page tells the
 * host ([reportSlot]) - while the other cards slide in with the finger ("recents.drag", every frame: only CSS
 * variables and transforms change, nothing re-renders). Let go:
 * - held ("recents.end" to: switcher): the window is on its card; the card gets the app's fresh snapshot, and once it
 *   shows it the host lets the window go (powos.recents.ready) - the layer is simply up, it's home's own page.
 * - flung or far (to: home), or early (to: app): the layer collapses back into home.
 * The overview button shows it without a swipe ("recents.show"); home going away hides it ("recents.hide").
 */
import { useEffect, useRef } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { RecentTask } from "../types.ts";
import { TaskCard, type Rect } from "./switcher.tsx";

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

let layer: HTMLDivElement | null = null;
let row: HTMLDivElement | null = null;

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
function frame(p: number, x = 0, y = 0) {
  if (layer) {
    layer.style.setProperty("--rp", String(p));
    layer.style.setProperty("--rx", `${x}px`);
    layer.style.setProperty("--ry", `${y}px`);
  }
  const s = screens();
  if (s) {
    s.style.transform = p ? `scale(${1 - 0.08 * p})` : "";
    s.style.opacity = p ? String(1 - p) : "";
  }
}

function settle(on: boolean) {
  settling.value = on;
  const s = screens();
  if (s) s.style.transition = on ? "transform 240ms cubic-bezier(0.2, 0.8, 0.2, 1), opacity 240ms ease" : "none";
}

const nextFrame = () => new Promise<void>((r) => requestAnimationFrame(() => r()));

function begin(e: { from: number | null; tasks: RecentTask[] }) {
  settle(false);
  from.value = e.from;
  tasks.value = order(e.tasks, e.from);
  live.value = e.from != null;
  phase.value = "drag";
  row?.scrollTo({ left: 0 });
  frame(0);
}

/** Shown without a swipe (the overview button, up and hold over home): it fades in over home. */
async function show(e: { from: number | null; tasks: RecentTask[] }) {
  settle(false);
  from.value = e.from;
  tasks.value = order(e.tasks, e.from);
  live.value = false;
  phase.value = "shown";
  row?.scrollTo({ left: 0 });
  frame(0);
  await nextFrame();
  settle(true);
  frame(1);
}

/** The switcher goes, back into home: animated ([animate]) or at once (home went out of sight). */
function collapse(animate: boolean) {
  settle(animate);
  phase.value = "closed";
  frame(0);
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

function open(id: number, rect?: Rect) {
  // The layer stays until home is out of sight ("recents.hide"): the app grows out of its card over it.
  powos.tasks.open(id, rect).then((ok) => void (ok || refresh()));
}

function remove(id: number) {
  powos.tasks.remove(id);
  tasks.value = tasks.value.filter((t) => t.id !== id);
  if (!tasks.value.length) close();
}

const refresh = () => powos.tasks.list().then((t) => (tasks.value = order(t, from.value)));

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
  // Not while the row is animating (settling): its box is between places.
  if (!row || !layer || row.scrollLeft !== 0 || row.getAnimations().length) return;
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

/** Back: to the app it was opened over, or home. False when it isn't up. */
export function recentsBack(): boolean {
  if (phase.value === "closed") return false;
  const id = from.value;
  if (id != null) {
    const r = firstShot()?.getBoundingClientRect();
    open(id, r && { left: r.left, top: r.top, width: r.width, height: r.height });
  } else close();
  return true;
}

/** Home pressed: the switcher goes with everything else. */
export function recentsHome() {
  close();
}

powos.on("recents.begin", begin);
powos.on("recents.drag", (e: { progress: number; x: number; y: number }) => {
  if (phase.value === "drag") frame(e.progress, e.x, e.y);
});
powos.on("recents.end", (e: { to: "switcher" | "home" | "app"; snapshot?: string | null }) => {
  if (e.to === "switcher") landed(e.snapshot ?? null);
  else collapse(true);
});
powos.on("recents.show", (e: { open: boolean; from: number | null; tasks: RecentTask[] }) => void show(e));
powos.on("recents.hide", () => collapse(false));
// The overview button again: the task before the one it was opened over (or the newest, from home), as Android's.
powos.on("switcher.toggle", () => {
  const list = tasks.value;
  const next = list[0]?.id === from.value ? list[1] : list[0];
  if (next) open(next.id);
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

export function Recents() {
  const el = useRef<HTMLDivElement>(null);
  const rowEl = useRef<HTMLDivElement>(null);
  useEffect(() => {
    layer = el.current;
    row = rowEl.current;
    frame(0);
    // Opened before this page loaded (home started cold for the switcher): up at once.
    powos.recents.state().then((s) => {
      if (s?.open && phase.value === "closed") show(s);
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
  const list = tasks.value;
  const p = phase.value;
  const { w, h } = size.value;
  return (
    <div
      ref={el}
      class={`recents ${p} ${p === "closed" ? "" : "open"} ${live.value ? "live" : ""} ${settling.value ? "settling" : ""}`}
      style={{ "--screen-ratio": `${w} / ${h}`, "--screen-ratio-n": String(w / h) }}
      onClick={(e) => e.target === e.currentTarget && close()}
      onTransitionEnd={(e) => {
        if (e.target === row) reportSlot();
        // Collapsed: the cards (and their snapshots) let go, till the next time.
        if (e.target === e.currentTarget && phase.value === "closed" && tasks.value.length) tasks.value = [];
      }}
    >
      <div class="recents-scrim" />
      <div class="task-row" ref={rowEl} onClick={(e) => e.target === e.currentTarget && close()}>
        {list.length ? list.map((t, i) => <TaskCard key={t.id} t={t} current={i === 0} onOpen={open} onRemove={remove} />) : <Placeholder />}
      </div>
      <button
        type="button"
        class="task-clear"
        style={{ visibility: list.length ? undefined : "hidden" }}
        onClick={() => {
          tasks.value.forEach((t) => powos.tasks.remove(t.id));
          tasks.value = [];
          close();
        }}
      >
        clear all
      </button>
    </div>
  );
}
