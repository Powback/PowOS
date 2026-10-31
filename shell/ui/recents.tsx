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
import { tileApps, webWindowsOn } from "./webwindows.tsx";
import { spring } from "./spring.ts";
import { dropKeyboard } from "./keyboard.ts";
import { appView, closeApp, forgetOpened, mergeTasks, openApp, taskApp } from "../apps/pages.ts";

type Phase = "closed" | "drag" | "shown";

const phase = signal<Phase>("closed");
const tasks = signal<RecentTask[]>([]);
/** The task it was opened over (null: home). */
const from = signal<number | null>(null);
/** The first card's frame is under the app's real window (hidden till the window lets go). */
const live = signal(false);
/** Animating between states (CSS transitions on), rather than following a finger. */
const settling = signal(false);
/**
 * The screen's size as the eye sees it (the visual viewport), the keyboard left out: the cards are the screen's shape.
 * Not innerWidth / innerHeight - the layout viewport, which over the PowOS AI page with the keyboard up grew to
 * 759x1690 on a 404x899 screen, and the cards landed off center. A height that shrinks at the same width while the
 * keyboard is up is the keyboard's: the cards keep the full one.
 */
const keyboardUp = () => (parseFloat(document.documentElement.style.getPropertyValue("--inset-keyboard")) || 0) > 0;
function bounds(was?: { w: number; h: number }) {
  const vv = window.visualViewport;
  const w = Math.round(vv?.width ?? innerWidth);
  const full = Math.round(vv?.height ?? innerHeight);
  const h = was && was.w === w && full < was.h && keyboardUp() ? was.h : full;
  return { w, h };
}
const size = signal(bounds());
/** A card's menu, open over it. */
const menu = signal<{ id: number; left: number; top: number } | null>(null);
/** Split screen: the first app picked, waiting for the second. */
const splitFirst = signal<number | null>(null);
/**
 * Web windows on: PowOS's own split (tiles, ui/webwindows.tsx) instead of Android's - up to 3 more picks after the
 * first (2-4 apps), "Split" tiles them; null: Android's split (the second pick splits at once).
 */
const splitMore = signal<number[] | null>(null);
/** A card growing to the screen as its app opens. */
const opening = signal<{ id: number; rect: Rect; src: string; radius: string; to?: Rect } | null>(null);
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

/**
 * The app it was opened over first (its window lands on the first card), then the rest, newest first - the PowOS
 * apps opened in home among them (apps/pages.ts mergeTasks: negative ids).
 */
function order(list: RecentTask[], over: number | null) {
  return mergeTasks(list, over);
}

/**
 * A frame: [p] 0 (the app full screen, home as it was) .. 1 (the switcher up), the row moved by [x], [y] (CSS px).
 * Custom properties on the layer (its few nodes restyle) and home's content's opacity - no render.
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
    // Home is a desktop: always there, where it is (the user, 2026-10-31: "the whole thing pops up a little bit" ...
    // "it should just like always be there"). Never scaled or moved by the switcher - it had receded to 0.92 with the
    // swipe and a swipe home let go (collapse at once) put it back to 1 in one frame: the pop. Only the app's window
    // moves; home only fades under the cards once the switcher is up (landed). A swipe up over an app keeps it at full
    // opacity the whole way - faded with the window's progress, a quick swipe home had it at nothing from frame one.
    const shown = Math.max(1 - p, home);
    const fade = phase.value === "drag" && from.value != null ? 1 : shown;
    s.style.opacity = fade < 1 ? String(fade) : "";
  }
}

function settle(on: boolean) {
  settling.value = on;
  const s = screens();
  if (s) s.style.transition = on ? "opacity 240ms ease" : "none";
}

const nextFrame = () => new Promise<void>((r) => requestAnimationFrame(() => r()));

function reset() {
  menu.value = null;
  splitFirst.value = null;
  splitMore.value = null;
  opening.value = null;
}

/** The next swipe's snapshots fetched ahead into the HTTP cache (not decoded, not in the page: no GPU memory held). */
function prefetch(list: RecentTask[]) {
  for (const t of list.slice(0, 4)) fetch(t.snapshot).catch(() => {});
}

/** The card of task [id]: a split's card for either of its apps (the card's id is its first app's). */
function cardOf(id: number | null, list: RecentTask[]): number | null {
  if (id == null) return null;
  return list.find((t) => t.split?.some((s) => s.id === id))?.id ?? id;
}

/** Task [t] closed: a split card's apps all of them (WM Shell's split ends with them). */
function removeTask(t: RecentTask | undefined, id: number) {
  if (t?.split) t.split.forEach((s) => powos.tasks.remove(s.id));
  else powos.tasks.remove(id);
}

/** A split card ([t]) tapped: the split back, never one of its apps alone or in a floating window. */
function openSplit(t: RecentTask) {
  const [a, b] = t.split!;
  close();
  powos.tasks.openSplit(a.id, b.id).then((ok) => void (ok || refresh()));
}

function begin(e: { from: number | null; tasks: RecentTask[] }) {
  e = { ...e, from: cardOf(e.from, e.tasks) };
  // The keyboard goes as the swipe starts, as for a page swipe (gesture.ts): the cards are laid out without it.
  dropKeyboard();
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
  e = { ...e, from: cardOf(e.from, e.tasks) };
  dropKeyboard();
  // Ordered while a PowOS app open full screen in home still counts as showing: its card comes first.
  const list = order(e.tasks, e.from);
  // That app goes into its card (its picture taken as it closes).
  if (appView.value) closeApp();
  loaded.value = true;
  settle(false);
  reset();
  from.value = e.from;
  tasks.value = list;
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
  // Home (in sight behind the window the whole swipe) fades out under the cards now.
  settle(true);
  phase.value = "shown";
  frame(1);
  const id = from.value;
  // (A split card keeps its sides' pictures: the fresh one is one app's.)
  if (snapshot && id != null) tasks.value = tasks.value.map((t) => (t.id === id && !t.split ? { ...t, snapshot } : t));
  // The render (a microtask), then the card's image decoded, shown, and painted - then the host lets the window go.
  await Promise.resolve();
  // The first card's shot is a <div> placeholder when it has no snapshot (a PowOS app, a fresh task): a div has no
  // decode(), and sucrase's optional-chain helper (line 1 of the served module) failed it as "Cannot read properties of
  // undefined (reading 'call')" at recents.tsx:1 (2026-10-28). Only an <img> is decoded.
  const shot = row?.querySelector(".task:first-child .task-shot");
  const img = shot instanceof HTMLImageElement ? shot : null;
  if (img && snapshot && img.getAttribute("src") !== snapshot) img.src = snapshot;
  await img?.decode().catch(() => {});
  if (img) img.style.visibility = "";
  live.value = false;
  await nextFrame();
  await nextFrame();
  powos.recents.ready();
}

/**
 * A web window floating on its display ([t]): back where it was, on its page - the host shows it (ShellBridge.openTask),
 * no card growing to it. False: not one.
 */
function floatingWebWindow(t: RecentTask): boolean {
  if (t.webwindow == null || t.fullScreen) return false;
  close();
  powos.tasks.open(t.id).then((ok) => void (ok || refresh()));
  return true;
}

/**
 * Opens task [id] from its card: the card's frame grows to the screen (a spring), then the app is opened with no
 * animation of its own - it appears over its own snapshot. The layer stays till home is out of sight ("recents.hide").
 * Unfolded the card grows to the app's floating window instead; home stays in sight, so the host sends "recents.hide"
 * once the window is up (ShellBridge.openTask).
 */
function open(id: number, shot?: HTMLElement) {
  const split = tasks.value.find((x) => x.id === id && x.split);
  if (split) {
    menu.value = null;
    openSplit(split);
  } else openOne(id, shot);
}

/** [open] of a single app's card. */
function openOne(id: number, shot?: HTMLElement) {
  menu.value = null;
  // A PowOS app's card: the switcher goes back into home and the app opens full screen there (ui/appscreen.tsx).
  const app = taskApp(id);
  if (app) {
    close();
    openApp(app);
    return;
  }
  const t = tasks.value.find((x) => x.id === id);
  const img = shot as HTMLImageElement | undefined;
  if (!t || !img || !img.complete || !img.naturalWidth) {
    powos.tasks.open(id).then((ok) => void (ok || refresh()));
    return;
  }
  if (floatingWebWindow(t)) return;
  const r = img.getBoundingClientRect();
  const rect = { left: r.left, top: r.top, width: r.width, height: r.height };
  // A full-screen task that comes back as a new floating window (unfolded): where it lands isn't known here, so the
  // host opens it out of its card - never a full-screen frame of it. The host closes the layer once it's up.
  if (t.floats && !t.window) {
    powos.tasks.open(id, rect).then((ok) => void (ok || refresh()));
    return;
  }
  // A floating window grows back to where it is, not to the screen (home stays in sight behind it).
  opening.value = { id, rect, src: img.currentSrc || img.src, radius: getComputedStyle(img).borderTopLeftRadius, to: t.window };
}

/** The growing card reached the screen's edges: the app now. */
function opened(id: number) {
  const split = tasks.value.find((x) => x.id === id && x.split);
  if (split) return openSplit(split);
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
  if (id < 0) forgetOpened(t!.key!);
  else removeTask(t, id);
  flipFrom = cardPositions();
  tasks.value = tasks.value.filter((t) => t.id !== id);
  if (splitFirst.value === id) splitFirst.value = null;
  if (!tasks.value.length) close();
  return true;
}

/**
 * All but the pinned ones fly up and go - an app with a widget on home too (the widget is the host's RemoteViews, not
 * the app's process: AppWidgets keeps drawing it); with nothing left, the switcher closes.
 */
function clearAll() {
  const stays = (t: RecentTask) => pinned.value.has(pinKey(t));
  const keep = tasks.value.filter(stays);
  const going = tasks.value.filter((t) => !stays(t));
  if (!going.length) return;
  let left = going.length;
  going.forEach((t, i) => {
    const card = row?.querySelector<HTMLElement>(`.task[data-task="${t.id}"]`);
    const done = () => {
      if (t.id < 0) forgetOpened(t.key!);
      else removeTask(t, t.id);
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
/**
 * A card's tap and its menu: one handler each for every card (they take the task's id), never a closure per render -
 * TaskCard is memoised, and a new function each Recents render re-rendered every card (122x in perf-1793456386286).
 */
function openCard(id: number, shot: HTMLElement) {
  if (splitFirst.value != null) pickForSplit(id);
  else open(id, shot);
}
function menuCard(id: number, card: HTMLElement) {
  const r = card.getBoundingClientRect();
  menu.value = { id, left: Math.max(8, Math.min(innerWidth - 228, r.left + 8)), top: r.top + 36 };
}

function pickForSplit(id: number) {
  const first = splitFirst.value;
  if (first == null) {
    splitFirst.value = id;
    splitMore.value = null;
    void webWindowsOn().then((on) => splitFirst.value === id && on && (splitMore.value = []));
    return;
  }
  const more = splitMore.value;
  if (more == null) {
    splitFirst.value = null;
    if (first !== id) nativeSplit(first, id);
    return;
  }
  if (id === first || more.includes(id)) return;
  splitMore.value = [...more, id];
  if (splitMore.value.length >= 3) void splitTiles();
}

/** The picks (2-4) as PowOS tiles on home; one that can't be a web window: Android's split of the first two. */
async function splitTiles() {
  const ids = [splitFirst.value, ...(splitMore.value ?? [])].filter((v): v is number => v != null);
  splitFirst.value = null;
  splitMore.value = null;
  if (ids.length < 2) return;
  const apps = ids.map((i) => tasks.value.find((t) => t.id === i)).filter((t): t is RecentTask => !!t?.key);
  close();
  if (apps.length === ids.length && (await tileApps(apps.map((t) => ({ key: t.key!, label: t.label }))))) return;
  console.info(`[tiles] split screen of tasks ${ids.join(",")}: Android's split (not all are web windows)`);
  nativeSplit(ids[0], ids[1]);
}

/**
 * A card that can be a side of Android's split: a real app's task. Not a PowOS app open in home (negative id) and not
 * PowOS home's own task - 10-31 logcat `split=[com.powos.app, com.discord]`: home itself became one half.
 */
function nativeSide(id: number): boolean {
  const t = tasks.value.find((v) => v.id === id);
  return !!t && id >= 0 && !(t.key ?? "").startsWith("com.powos.app");
}

/** Android's split of two real apps ([nativeSide]), or nothing (a note; the host refuses it too: Tasks.splitApps). */
function nativeSplit(a: number, b: number) {
  if (a !== b && nativeSide(a) && nativeSide(b)) return void powos.tasks.split(a, b);
  console.info(`[tiles] split of tasks ${a},${b} refused: PowOS home is never one side of Android's split`);
  showNote("Pick two apps to split");
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
// The swipe's list as it is now (the one it began with was laid out ahead): swapped in under the finger.
powos.on("recents.update", (e: { tasks: RecentTask[] }) => {
  if (phase.value === "closed") return;
  const next = order(e.tasks, from.value);
  // A split card has its first app's id: the same id as that app's own card, but not the same card.
  const kin = (a: RecentTask, b: RecentTask) => a.id === b.id && !a.split === !b.split;
  const same = next.length === tasks.value.length && next.every((t, i) => kin(t, tasks.value[i]));
  if (!same) tasks.value = next.map((t) => tasks.value.find((o) => kin(o, t)) ?? t);
});
// The list for the next swipe, while an app is in front: laid out (hidden) now, snapshots loading.
// Kept while equal: the host sends it again on every task-stack change (a page swipe), and a new list re-rendered the
// switcher and its cards each time (Recents 16/16 by a signal, perf-1793458475110). Cards that didn't change keep theirs.
powos.on("recents.tasks", (e: { tasks: RecentTask[] }) => {
  if (phase.value !== "closed") return;
  const was = tasks.value;
  const next = order(e.tasks, null).map((t, i) => (was[i] && sameTask(was[i], t) ? was[i] : t));
  if (next.length !== was.length || next.some((t, i) => t !== was[i])) tasks.value = next;
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
/** The same card: every field equal (a split's apps compared by value). */
const sameTask = (a: RecentTask, b: RecentTask) => JSON.stringify(a) === JSON.stringify(b);

function resized() {
  const next = bounds(size.value);
  if (next.w !== size.value.w || next.h !== size.value.h) size.value = next;
}
addEventListener("resize", resized);
window.visualViewport?.addEventListener("resize", resized);

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
    // Its box is the screen, or the floating window it goes back to (its picture is that window's: covers it whole).
    const to = o.to ?? { left: 0, top: 0, width: size.value.w, height: size.value.h };
    if (o.to) Object.assign(el.current.style, { width: `${to.width}px`, height: `${to.height}px` });
    const sx = width / to.width;
    const sy = height / to.height;
    el.current.animate(
      [
        { transform: `translate(${left}px, ${top}px) scale(${sx}, ${sy})`, borderRadius: `${parseFloat(o.radius) / sx}px` },
        { transform: `translate(${to.left}px, ${to.top}px)`, borderRadius: "0px" },
      ],
      { duration: Math.min(spring.ms, 320), easing: "cubic-bezier(0.2, 0.9, 0.2, 1)", fill: "forwards" },
    ).onfinish = () => opened(o.id);
  }, [o?.id]);
  if (!o) return null;
  return <img ref={el} class="recents-expand" src={o.src} alt="" />;
}

/**
 * A card's window item: a web window's full-screen app (its bar's full screen button) goes back into its window, where
 * it was; any other app into a floating window.
 */
function WindowItem({ t, act }: { t: RecentTask; act: (f: () => void) => () => void }) {
  if (t.fullScreen && powos.tasks.toWindow) {
    const back = () => void powos.tasks.toWindow?.(t.id).then((ok) => (ok ? close() : showNote("Not supported by this build yet")));
    return (
      <button type="button" onClick={act(back)}>
        Back to window
      </button>
    );
  }
  return (
    <button type="button" onClick={act(() => powos.tasks.float(t.id))}>
      Floating window
    </button>
  );
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
      <div class="recents-menu tile sheet pop" style={{ left: `${m.left}px`, top: `${m.top}px` }}>
        {/* A PowOS app's card (negative id) is no Android task: no split, window, screenshot or app info for it. */}
        {t.id >= 0 && (
          <>
            <button type="button" onClick={act(() => pickForSplit(t.id))}>
              Split screen
            </button>
            <WindowItem t={t} act={act} />
            {/* Unfolded only. A window goes back to full screen. A host without the call (an older APK, f307) rejects
                "no such call": say so instead of leaving an unhandled rejection. */}
            {t.floats && powos.tasks.desktopWindow && (
              <button
                type="button"
                onClick={act(() =>
                  powos.tasks.desktopWindow?.(t.id, !t.window).catch(() => showNote("Not supported by this build yet")),
                )}
              >
                {t.window ? "Full screen" : "Desktop window"}
              </button>
            )}
            <button
              type="button"
              onClick={act(() =>
                powos.tasks.screenshot(t.id).then((name) => showNote(name ? `Saved ${name}` : "No screenshot of this app yet")),
              )}
            >
              Screenshot
            </button>
          </>
        )}
        <button type="button" onClick={act(() => togglePin(t))}>
          {isPinned ? "Unpin" : "Pin (keep on clear all)"}
        </button>
        {t.id >= 0 && (
          <button type="button" onClick={act(() => powos.tasks.info(t.id))}>
            App info
          </button>
        )}
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
      class={`recents ${p} ${p === "closed" ? "" : "open"} ${live.value ? "live" : ""} ${settling.value ? "settling" : ""} ${first != null ? "splitting" : ""} ${p === "drag" && from.value == null ? "homeswipe" : ""}`}
      style={{ "--screen-ratio": `${w} / ${h}`, "--screen-ratio-n": String(w / h), "--screen-w": `${w}px`, "--screen-h": `${h}px` }}
      onClick={(e) => e.target === e.currentTarget && (first != null ? (splitFirst.value = null) : close())}
      onTransitionEnd={(e) => {
        if (e.target === row) reportSlot();
        // Collapsed: its snapshots leave the page.
        if (e.target === e.currentTarget && phase.value === "closed") loaded.value = false;
      }}
    >
      <div class="recents-scrim" />
      {first != null && splitMore.value == null && <div class="recents-banner">Pick an app to split the screen with</div>}
      {first != null && splitMore.value != null && (
        <div class="recents-banner">
          {splitMore.value.length ? `${splitMore.value.length + 1} apps picked - pick up to ${3 - splitMore.value.length} more, or` : "Pick 1 to 3 more apps to tile with it"}
          {splitMore.value.length > 0 && (
            <button type="button" class="recents-banner-go" onClick={() => void splitTiles()}>
              Split
            </button>
          )}
        </div>
      )}
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
              picked={first === t.id || !!splitMore.value?.includes(t.id)}
              onOpen={openCard}
              onRemove={remove}
              onMenu={menuCard}
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
