/**
 * Widget stacks on home (the user, 11-23: "stack widgets and swipe between them like pages like samsung allows you").
 * The model is ui/stackmodel.ts (pure, tested); this wires it to the home signals, the store and the host.
 *
 * - Make one: in edit mode, drag a widget onto another widget (grid.tsx aimOn -> {stack}); or a widget's "add to stack"
 *   (its long-press actions) opens the "+ widget" picker and what's added next joins it.
 * - Use it: a sideways swipe on the stack shows the next/previous widget, dots inside the stack say where you are. At
 *   the first/last widget the swipe is home's page swipe (stackmodel stackTakesSwipe - gesture.ts asks the same, so
 *   the two never both move). Only the widget on top is mounted; its neighbour mounts for the swipe and goes after.
 * - Edit it: "edit stack" in its actions: reorder, take one out (a plain widget again, in a free spot), remove one,
 *   add one, unstack all. Down to one widget, the stack is gone.
 *
 * Every member stays the host's own item (its config/state untouched); the store "home.stacks" only groups them.
 */
import { computed, effect, signal } from "@preact/signals";
import { useLayoutEffect, useRef, useState } from "preact/hooks";
import type { ComponentChildren } from "preact";
import { powos } from "../bridge.ts";
import { editing, home, selected, topBack } from "../state.ts";
import { tick } from "./haptics.ts";
import { optimistic } from "./pending.tsx";
import { paintDots } from "./pagedots.tsx";
import type { Cell, HomeItem } from "../types.ts";
import {
  addToStack, parseStacks, pruneStacks, removeFromStack, reorderStack, serializeStacks, showIndex, sideways, stackable,
  stackOf, stackOnto, stackSwipeAt, stackView, swipeTarget, unstack, type Stacks,
} from "./stackmodel.ts";

const STORE = "home.stacks";
const SLOP = 10;
const SETTLE_MS = 260;

export const stacks = signal<Stacks>({});
let loaded = false;

/** Reads the stacks once (no store yet = none: an older layout shows exactly as it was). */
export function loadStacks() {
  if (loaded) return;
  loaded = true;
  powos.store
    .get(STORE)
    .then((v) => (stacks.value = { ...parseStacks(v), ...stacks.value }))
    .catch(() => {});
}

function save(next: Stacks) {
  stacks.value = next;
  return powos.store.set(STORE, serializeStacks(next));
}

/** What grid.tsx gives the stacks (it owns the grid's geometry; importing it here would be a cycle). */
export const stackHooks: {
  /** A free cell of [w] x [h] for a widget taken out of a stack (grid.tsx placeNewCells). */
  spot: ((w: number, h: number) => { page: number; cell: Cell }) | null;
  /** Opens home's "+ widget" picker (edit mode). */
  openPicker: (() => void) | null;
} = { spot: null, openPicker: null };

/**
 * Home's items as the grid shows them: one tile per stack (stackView). The virtual tile objects are kept while their
 * sources are the same objects, so the grid's per-page cache (pageItems) still sees "nothing changed".
 */
const virtual = new Map<string, { src: HomeItem; anchor: HomeItem; stacks: Stacks; out: HomeItem }>();
export const homeView = computed<HomeItem[]>(() => {
  const items = home.value.items;
  const st = stacks.value;
  const out = stackView(items, st);
  if (out === items) return items;
  const byKey = new Map(items.map((i) => [i.key, i]));
  return out.map((i) => {
    if (!i.stack) return i;
    const src = byKey.get(i.key)!;
    const anchor = byKey.get(st[i.stack].anchor)!;
    const v = virtual.get(i.stack);
    if (v && v.src === src && v.anchor === anchor && v.out.key === i.key) return v.out;
    virtual.set(i.stack, { src, anchor, stacks: st, out: i });
    return i;
  });
});

/** The members of the stack [key] is in (anchor first, then in order), or just [key]. */
export function stackKeysFor(key: string): string[] {
  const id = stackOf(stacks.value, key);
  if (!id) return [key];
  const s = stacks.value[id];
  return [s.anchor, ...s.keys.filter((k) => k !== s.anchor)];
}

/** The stack's members as home items, in swipe order (missing ones skipped). */
export function membersOf(id: string): HomeItem[] {
  const s = stacks.value[id];
  if (!s) return [];
  const byKey = new Map(home.value.items.map((i) => [i.key, i]));
  return s.keys.map((k) => byKey.get(k)).filter((i): i is HomeItem => !!i);
}

const newId = () => "stack:" + Date.now().toString(36) + Math.floor(Math.random() * 1e4);

/** Places [keys] at [cell] on [page], one after another (the host keeps one layout). */
async function placeAll(keys: string[], cell: Cell, page: number) {
  for (const k of keys) await powos.home.place(k, cell, page);
}

/** Can [carried] be let go on [target] to stack them? Both widgets; the carried one fits the slot (its minimum). */
export function canStack(carried: HomeItem | undefined, target: HomeItem, min: (i: HomeItem) => [number, number]): boolean {
  if (!carried || carried.key === target.key || !stackable(carried) || !stackable(target)) return false;
  if (target.stack && target.stack === stackOf(stacks.value, carried.key)) return false;
  const [mw, mh] = min(carried);
  return mw <= target.cell!.w && mh <= target.cell!.h;
}

/**
 * [carried] (a widget, or a whole stack) let go on [target] (a widget or a stack, as the grid shows it - its cell is
 * the slot): one stack, shown at once (optimistic), the moved widgets placed into the slot behind it; undone if the
 * host refuses a place.
 */
export function dropOnStack(carried: HomeItem, target: HomeItem): Promise<unknown> {
  const before = stacks.value;
  const r = stackOnto(before, target.key, carried.key, newId());
  if (!r) return Promise.resolve();
  tick();
  const moving = stackKeysFor(carried.key);
  return optimistic(
    () => void (stacks.value = r.stacks),
    async () => {
      await save(r.stacks);
      await placeAll(moving, target.cell!, target.page);
    },
    () => void save(before),
  ).catch(() => {});
}

/** The widget [key]'s "add to stack": the picker opens; the next widget added to home joins [key]'s stack. */
export const addingTo = signal<string | null>(null);
export function startAddToStack(key: string) {
  addingTo.value = key;
  selected.value = null;
  editing.value = true;
  stackHooks.openPicker?.();
}

/**
 * Home changed: a key that left home leaves its stack (removed elsewhere: its tile's "remove", the Compose home); a new
 * widget while "add to stack" waits joins that stack. Only between two loaded homes - never against the empty default
 * before the first read, which would empty every stack.
 */
let prevKeys: Set<string> | null = null;
effect(() => {
  const items = home.value.items;
  const keys = new Set(items.map((i) => i.key));
  const prev = prevKeys;
  prevKeys = items.length ? keys : prevKeys;
  if (!prev || !items.length) return;
  const gone = [...prev].filter((k) => !keys.has(k));
  const st = stacks.peek();
  if (gone.length && Object.values(st).some((s) => s.keys.some((k) => gone.includes(k)))) {
    const present = new Set([...Object.values(st).flatMap((s) => s.keys)].filter((k) => !gone.includes(k)));
    void save(pruneStacks(st, present));
  }
  const target = addingTo.peek();
  if (!target) return;
  const added = items.find((i) => !prev.has(i.key) && stackable(i));
  if (added) {
    addingTo.value = null;
    void joinNew(target, added);
  }
});
// Leaving edit mode ends the wait (nothing was added).
effect(() => {
  if (!editing.value) addingTo.value = null;
});

/** A widget just added for "add to stack" [target]: into the stack (or a new one with target), into its slot. */
async function joinNew(target: string, added: HomeItem) {
  const slot = homeView.peek().find((i) => i.key === target || (i.stack && stackKeysFor(target).includes(i.key)));
  if (!slot?.cell) return;
  const id = stackOf(stacks.peek(), target);
  const next = id ? addToStack(stacks.peek(), id, added.key) : stackOnto(stacks.peek(), target, added.key, newId())?.stacks;
  if (!next) return;
  await save(next);
  await powos.home.place(added.key, slot.cell, slot.page);
}

/** Shows member [i] of stack [id] on top (a swipe); kept in the store, written a moment later. */
let showTimer: ReturnType<typeof setTimeout> | undefined;
export function showMember(id: string, i: number) {
  stacks.value = showIndex(stacks.value, id, i);
  clearTimeout(showTimer);
  showTimer = setTimeout(() => void powos.store.set(STORE, serializeStacks(stacks.peek())).catch(() => {}), 600);
}

/** [key] out of its stack: a plain widget again, in a free spot at its size (its own cell may be under the stack). */
export async function takeOut(key: string) {
  const before = stacks.value;
  const item = home.value.items.find((i) => i.key === key);
  const next = removeFromStack(before, key);
  if (next === before || !item?.cell) return;
  const spot = stackHooks.spot?.(item.cell.w, item.cell.h);
  await optimistic(
    () => void (stacks.value = next),
    async () => {
      await save(next);
      if (spot) await powos.home.place(key, spot.cell, spot.page);
    },
    () => void save(before),
  ).catch(() => {});
}

/** Every member a plain widget: the one on top keeps the slot, the others go to free spots. */
export async function unstackAll(id: string) {
  const s = stacks.value[id];
  if (!s) return;
  const top = s.keys[s.shown];
  const slot = home.value.items.find((i) => i.key === s.anchor)?.cell;
  const rest = membersOf(id).filter((m) => m.key !== top);
  const before = stacks.value;
  const next = unstack(before, id);
  await optimistic(
    () => void (stacks.value = next),
    async () => {
      await save(next);
      const page = home.value.items.find((i) => i.key === s.anchor)?.page ?? 1;
      if (slot && top !== s.anchor) await powos.home.place(top, slot, page);
      for (const m of rest) {
        const spot = stackHooks.spot?.(m.cell!.w, m.cell!.h);
        if (spot) await powos.home.place(m.key, spot.cell, spot.page);
      }
    },
    () => void save(before),
  ).catch(() => {});
}

export function moveMember(id: string, from: number, to: number) {
  void save(reorderStack(stacks.value, id, from, to)).catch(() => {});
}

/** The stack whose edit sheet is open. */
export const editStack = signal<string | null>(null);

/** A member's name in the edit sheet. */
function memberName(i: HomeItem) {
  if (i.kind === "panel") return i.name?.startsWith("app:") ? i.name.slice(4) : (i.name ?? "panel");
  return i.name || i.label || i.key;
}

/** The edit sheet: the stack's widgets in order - up/down, take out, remove; add one; unstack all. */
export function StackSheet() {
  const id = editStack.value;
  const s = id ? stacks.value[id] : undefined;
  useLayoutEffect(() => {
    if (!id) return;
    const back = () => (editStack.value = null);
    topBack.value = back;
    return () => {
      if (topBack.peek() === back) topBack.value = null;
    };
  }, [id]);
  if (!id || !s) return null;
  const members = membersOf(id);
  const close = () => (editStack.value = null);
  const stop = (e: Event) => e.stopPropagation();
  return (
    <div class="stack-scrim" onPointerDown={(e) => e.target === e.currentTarget && close()} onTouchStart={stop}>
      <div class="stack-sheet tile sheet pop" role="dialog" aria-label="edit stack" onPointerDown={stop} onPointerUp={stop}>
        <div class="stack-sheet-head">edit stack</div>
        <ol class="stack-list">
          {members.map((m, n) => (
            <li key={m.key} class={n === s.shown ? "on" : ""}>
              <span class="stack-name">{memberName(m)}</span>
              <button type="button" aria-label="move up" disabled={n === 0} onClick={() => moveMember(id, n, n - 1)}>
                ↑
              </button>
              <button type="button" aria-label="move down" disabled={n === members.length - 1} onClick={() => moveMember(id, n, n + 1)}>
                ↓
              </button>
              <button type="button" onClick={() => void takeOut(m.key)}>
                take out
              </button>
              <button type="button" class="danger" onClick={() => void powos.home.remove(m.key)}>
                remove
              </button>
            </li>
          ))}
        </ol>
        <div class="stack-sheet-acts">
          <button type="button" onClick={() => (close(), startAddToStack(s.anchor))}>
            + widget
          </button>
          <button type="button" onClick={() => (close(), void unstackAll(id))}>
            unstack all
          </button>
          <button type="button" class="primary" onClick={close}>
            done
          </button>
        </div>
      </div>
    </div>
  );
}

type Swipe = { id: number; x0: number; y0: number; mode: "?" | "mine" | "no"; samples: [number, number][] };
type Els = { strip: { current: HTMLDivElement | null }; track: { current: HTMLDivElement | null }; dots: { current: HTMLDivElement | null } };

/** The track at [px] from rest: eased (a settle) or at once (following the finger). */
function trackTo(t: HTMLDivElement | null, px: number, ease: boolean) {
  if (!t) return;
  t.style.transition = ease ? `transform ${SETTLE_MS}ms var(--spring-fast, ease-out)` : "none";
  t.style.transform = px ? `translateX(${px}px)` : "";
}

/** The content's gesture ends (a button under the finger never gets its click; an Android widget's touch cancels) and
 * the pointer is the strip's. */
function claimPointer(el: HTMLDivElement, e: PointerEvent) {
  const target = e.target as Element | null;
  if (target && target !== el && el.contains(target)) {
    target.dispatchEvent(new PointerEvent("pointercancel", { pointerId: e.pointerId, pointerType: e.pointerType, isPrimary: e.isPrimary, bubbles: true }));
  }
  try {
    el.setPointerCapture(e.pointerId);
  } catch {
    /* a synthetic pointer: nothing to capture */
  }
}

/** Release velocity over the last samples, px/ms. */
const releaseV = (g: Swipe) => {
  const [x1, t1] = g.samples[g.samples.length - 1];
  const [x0, t0] = g.samples[0];
  return t1 > t0 ? (x1 - x0) / (t1 - t0) : 0;
};

/** Decides a fresh move: the stack's (sideways, a widget that way, not a control's own drag) or not. */
function decide(g: Swipe, e: PointerEvent): boolean {
  const dx = e.clientX - g.x0;
  const dy = e.clientY - g.y0;
  if (Math.hypot(dx, dy) < SLOP) return false;
  g.mode = sideways(dx, dy) && stackSwipeAt(e.target as Element, dx) ? "mine" : "no";
  return g.mode === "mine";
}

/** The stack's swipe: follows the finger by style (no render per move), eases to the widget it lands on. */
function useStackSwipe(id: string, pos: { at: number; n: number }, els: Els, setWide: (on: boolean) => void) {
  const sw = useRef<Swipe | null>(null);
  const { at, n } = pos;
  const width = () => els.strip.current?.clientWidth || 1;
  const end = (e: PointerEvent) => {
    const g = sw.current;
    sw.current = null;
    if (g?.mode !== "mine") return;
    const next = e.type === "pointerup" ? swipeTarget(at, n, { dx: e.clientX - g.x0, width: width(), vx: releaseV(g) }) : at;
    trackTo(els.track.current, (at - next) * width(), true);
    paintDots(els.dots.current, next, false);
    window.setTimeout(() => {
      if (next !== at) {
        tick();
        showMember(id, next);
      }
      trackTo(els.track.current, 0, false);
      setWide(false);
    }, SETTLE_MS);
  };
  const follow = (g: Swipe, e: PointerEvent) => {
    g.samples.push([e.clientX, e.timeStamp]);
    while (g.samples.length > 2 && e.timeStamp - g.samples[1][1] > 120) g.samples.shift();
    const dx = e.clientX - g.x0;
    // Past the first/last widget the track only gives a little (the swipe was the stack's from the start).
    const px = (dx > 0 && at === 0) || (dx < 0 && at === n - 1) ? dx * 0.25 : dx;
    trackTo(els.track.current, px, false);
    paintDots(els.dots.current, at - px / width(), true);
  };
  return {
    onPointerDownCapture: (e: PointerEvent) => {
      sw.current = { id: e.pointerId, x0: e.clientX, y0: e.clientY, mode: "?", samples: [[e.clientX, e.timeStamp]] };
    },
    onPointerMoveCapture: (e: PointerEvent) => {
      const g = sw.current;
      if (!g || g.id !== e.pointerId || g.mode === "no") return;
      if (g.mode === "?") {
        if (!decide(g, e)) return;
        claimPointer(els.strip.current!, e);
        setWide(true);
      }
      follow(g, e);
    },
    onPointerUpCapture: end,
    onPointerCancelCapture: (e: PointerEvent) => {
      // Our own cancel to the content isn't the swipe ending.
      if (!e.isTrusted && e.target !== els.strip.current) return;
      end(e);
    },
  };
}

/**
 * A stack's faces: the member on top, its neighbours mounted only while a finger swipes it (the rest stay unmounted:
 * one live widget per stack at rest). Dots inside the stack say which one shows.
 */
export function StackFaces({ id, members, face }: { id: string; members: HomeItem[]; face: (m: HomeItem) => ComponentChildren }) {
  const s = stacks.value[id];
  const n = members.length;
  const at = Math.max(0, Math.min(n - 1, members.findIndex((m) => m.key === s?.keys[s.shown])));
  const [wide, setWide] = useState(false);
  const els: Els = { strip: useRef<HTMLDivElement>(null), track: useRef<HTMLDivElement>(null), dots: useRef<HTMLDivElement>(null) };
  const may = !editing.value && n > 1;
  const handlers = useStackSwipe(id, { at, n }, els, setWide);
  useLayoutEffect(() => paintDots(els.dots.current, at, false), [at, n]);
  const mounted = wide ? [at - 1, at, at + 1].filter((i) => i >= 0 && i < n) : [at];
  return (
    <div ref={els.strip} class="stack-strip" data-stack={id} data-at={at} data-n={n} data-swipe={may ? "" : undefined} {...(may ? handlers : {})}>
      <div ref={els.track} class="stack-track">
        {mounted.map((i) => (
          <div key={members[i].key} class={`stack-page ${i === at ? "top" : ""}`} data-member={members[i].key} style={{ left: `${(i - at) * 100}%` }}>
            {face(members[i])}
          </div>
        ))}
      </div>
      <div ref={els.dots} class="page-dots stack-dots" aria-label={`widget ${at + 1} of ${n}`}>
        {members.map((m) => (
          <i key={m.key} />
        ))}
      </div>
    </div>
  );
}
