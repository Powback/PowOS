/**
 * Widget stacks as data (Samsung's "stack widgets"): several widgets in ONE slot of the home grid, one shown at a time,
 * a sideways swipe on the slot shows the next. Pure functions over the store's value - no DOM, no bridge - so they are
 * tested on their own (shell/test/stackmodel.test.ts) and ui/stacks.tsx only wires them to signals and the host.
 *
 * The host's layout (ShellHome.kt / hosts/layout.ts / hosts/wide.ts) stays the one truth for every widget: each member
 * keeps its own item, key, config and state there. A stack is shell-only, store "home.stacks":
 *   { v: 1, stacks: { <id>: { keys: [member keys, in swipe order], shown: <index on top>, anchor: <member key> } } }
 * The ANCHOR's cell and page are the stack's slot (members are placed there too, but a member whose own cell differs -
 * wide vs folded, or an older shell moved it - still shows in the slot: the anchor decides). No store, an empty or
 * malformed one = no stacks: an older layout loads unchanged (the migration is "nothing to migrate").
 */

export interface WidgetStack {
  /** Member item keys, in swipe order (left to right). */
  keys: string[];
  /** Index of the member on top. */
  shown: number;
  /** The member whose cell/page is the stack's slot. */
  anchor: string;
}
export type Stacks = Record<string, WidgetStack>;

/** Most widgets one stack holds (Samsung's limit is 7; the dots stay readable on a 2-cell tile). */
export const STACK_MAX = 7;

/** What the model needs of a home item. */
export interface StackItem {
  key: string;
  kind: string;
  name?: string;
  page: number;
  cell: { x: number; y: number; w: number; h: number } | null;
  resizable: boolean;
  pending?: string;
  stack?: string;
}

/** A widget that can be in a stack: any boxed widget kind (OWL, Android, a shell panel or app island) - never an app,
 * a folder, the search bar (its pill is the foot's) or a widget still being made. */
export function stackable(i: StackItem | undefined): boolean {
  if (!i || !i.cell || i.pending || !i.resizable) return false;
  if (i.kind === "widget" || i.kind === "appwidget") return true;
  return i.kind === "panel" && i.name !== "search" && i.name !== "creation";
}

/** The stack [key] is in, or null. */
export function stackOf(stacks: Stacks, key: string): string | null {
  for (const [id, s] of Object.entries(stacks)) if (s.keys.includes(key)) return id;
  return null;
}

const clampShown = (s: WidgetStack): WidgetStack => ({ ...s, shown: Math.max(0, Math.min(s.keys.length - 1, s.shown | 0)) });

/** A stack after its member list changed: anchor kept if it's still in, shown kept on the same key where possible. */
function settle(stacks: Stacks, id: string, change: { s: WidgetStack; keys: string[]; show?: string }): Stacks {
  const { s, keys, show: showKey } = change;
  const next = { ...stacks };
  if (keys.length < 2) {
    delete next[id];
    return next;
  }
  const want = showKey ?? s.keys[s.shown];
  const shown = Math.max(0, keys.indexOf(want));
  next[id] = clampShown({ keys, shown: keys.includes(want) ? shown : Math.min(s.shown, keys.length - 1), anchor: keys.includes(s.anchor) ? s.anchor : keys[0] });
  return next;
}

/** [key] out of whatever stack it's in (a stack left with one widget is a plain widget again). */
export function removeFromStack(stacks: Stacks, key: string): Stacks {
  const id = stackOf(stacks, key);
  if (!id) return stacks;
  const s = stacks[id];
  return settle(stacks, id, { s, keys: s.keys.filter((k) => k !== key) });
}

/**
 * [moving] (a widget, or every member of the stack it's in) dropped on [target]: into target's stack, or both into a new
 * one anchored at the target's slot. The dropped one shows on top (as Samsung's: you see what you just added).
 * Returns null when that would pass STACK_MAX or makes no sense (onto itself / its own stack).
 */
export function stackOnto(stacks: Stacks, target: string, moving: string, newId: string): { stacks: Stacks; id: string } | null {
  if (target === moving) return null;
  const into = stackOf(stacks, target);
  const from = stackOf(stacks, moving);
  if (into && into === from) return null;
  const adding = from ? stacks[from].keys : [moving];
  const base = into ? stacks[into].keys : [target];
  if (base.length + adding.length > STACK_MAX) return null;
  let next = { ...stacks };
  if (from) delete next[from];
  const id = into ?? newId;
  const keys = [...base, ...adding];
  const s = into ? next[into] : { keys: base, shown: 0, anchor: target };
  next = settle(next, id, { s, keys, show: moving });
  return { stacks: next, id };
}

/** Adds the new widget [key] at the end of stack [id], shown on top. */
export function addToStack(stacks: Stacks, id: string, key: string): Stacks | null {
  const s = stacks[id];
  if (!s || s.keys.includes(key) || s.keys.length >= STACK_MAX) return null;
  const cleared = removeFromStack(stacks, key);
  return settle(cleared, id, { s, keys: [...s.keys, key], show: key });
}

/** Moves the member at [from] to [to] (the edit sheet's arrows); the same widget stays on top. */
export function reorderStack(stacks: Stacks, id: string, from: number, to: number): Stacks {
  const s = stacks[id];
  if (!s || from === to || from < 0 || to < 0 || from >= s.keys.length || to >= s.keys.length) return stacks;
  const keys = [...s.keys];
  const [k] = keys.splice(from, 1);
  keys.splice(to, 0, k);
  return settle(stacks, id, { s, keys });
}

/** Every member a plain widget again. */
export function unstack(stacks: Stacks, id: string): Stacks {
  if (!stacks[id]) return stacks;
  const next = { ...stacks };
  delete next[id];
  return next;
}

/** Which member is on top (a swipe), clamped. */
export function showIndex(stacks: Stacks, id: string, i: number): Stacks {
  const s = stacks[id];
  if (!s) return stacks;
  const shown = Math.max(0, Math.min(s.keys.length - 1, i));
  return shown === s.shown ? stacks : { ...stacks, [id]: { ...s, shown } };
}

/**
 * The store's value read back: only well-formed stacks of 2+ distinct string keys survive, a key in two stacks stays in
 * the first. Anything else (no store yet = an older layout, a garbled one) = no stacks.
 */
export function parseStacks(raw: unknown): Stacks {
  const v = raw as { v?: number; stacks?: Record<string, unknown> } | null;
  if (!v || typeof v !== "object" || v.v !== 1 || !v.stacks || typeof v.stacks !== "object") return {};
  const out: Stacks = {};
  const seen = new Set<string>();
  for (const [id, s0] of Object.entries(v.stacks)) {
    const s = parseOne(s0, seen);
    if (s) out[id] = s;
  }
  return out;
}

/** One stored stack, or null: 2+ distinct string keys not already in an earlier stack (added to [seen]). */
function parseOne(raw: unknown, seen: Set<string>): WidgetStack | null {
  const s = raw as Partial<WidgetStack> | null;
  if (!s || !Array.isArray(s.keys)) return null;
  const keys = [...new Set(s.keys.filter((k): k is string => typeof k === "string" && !seen.has(k)))];
  if (keys.length < 2) return null;
  keys.forEach((k) => seen.add(k));
  const anchor = typeof s.anchor === "string" && keys.includes(s.anchor) ? s.anchor : keys[0];
  return clampShown({ keys, shown: typeof s.shown === "number" ? s.shown : 0, anchor });
}

export const serializeStacks = (stacks: Stacks) => ({ v: 1, stacks });

/** Drops the keys that left home (removed elsewhere) from [stacks]; a stack down to one widget dissolves. */
export function pruneStacks(stacks: Stacks, present: Set<string>): Stacks {
  let next = stacks;
  for (const s of Object.values(stacks)) for (const k of s.keys) if (!present.has(k)) next = removeFromStack(next, k);
  return next;
}

/**
 * Home's items as the grid shows them: per stack, ONE item - the member on top, in the anchor's cell and page, marked
 * with its stack id - and no other member. Members missing from home are skipped (shown falls to the next present one);
 * a stack whose anchor is gone or unplaced shows nothing special (its members as they are). Pure; the caller memoizes.
 */
export function stackView<T extends StackItem>(items: T[], stacks: Stacks): T[] {
  if (!Object.keys(stacks).length) return items;
  const byKey = new Map(items.map((i) => [i.key, i]));
  const hidden = new Set<string>();
  const top = new Map<string, T>();
  for (const [id, s] of Object.entries(stacks)) {
    const t = topOf(id, s, byKey);
    if (!t) continue;
    t.members.forEach((k) => hidden.add(k));
    top.set(t.item.key, t.item);
  }
  return items.flatMap((i) => (top.has(i.key) ? [top.get(i.key)!] : hidden.has(i.key) ? [] : [i]));
}

/** Stack [s]'s tile (the top member in the anchor's slot) and its present members; null when it can't show as one. */
function topOf<T extends StackItem>(id: string, s: WidgetStack, byKey: Map<string, T>): { item: T; members: string[] } | null {
  const anchor = byKey.get(s.anchor);
  const members = s.keys.filter((k) => byKey.has(k));
  if (!anchor?.cell || members.length < 2) return null;
  const want = s.keys[s.shown];
  const showKey = byKey.has(want) ? want : members[0];
  return { item: { ...byKey.get(showKey)!, cell: { ...anchor.cell }, page: anchor.page, stack: id }, members };
}

/**
 * The swipe's decision (ui/stacks.tsx and gesture.ts both ask, so home's pager and the stack never both move): a
 * sideways drag of [dx] px on a stack at [at] of [n] is the stack's while there is a widget that way; at the first/last
 * widget it passes on to home's pages (no rubber band: Samsung's stack hands the swipe on too). dx < 0 = finger left =
 * the next widget.
 */
export const stackTakesSwipe = (at: number, n: number, dx: number) => (dx < 0 ? at < n - 1 : dx > 0 ? at > 0 : false);

/** Where a released swipe lands: the next/previous widget past 30% of the width or a flick, else back. */
export function swipeTarget(at: number, n: number, release: { dx: number; width: number; vx: number }): number {
  const { dx, width, vx } = release;
  const far = Math.abs(dx) > width * 0.3 || Math.abs(vx) > 0.35;
  if (!far || Math.sign(dx) !== Math.sign(vx || dx)) return at;
  return Math.max(0, Math.min(n - 1, at + (dx < 0 ? 1 : -1)));
}

/** Sideways enough to be a swipe across (gesture.ts VERTICAL_RATIO: vertical only past 1.4x). */
export const sideways = (dx: number, dy: number) => !(Math.abs(dy) > Math.abs(dx) * 1.4);

/** What else owns a sideways drag inside a widget (gesture.ts OWN): a slider, a strip of its own. */
const OWNED = "input[type=range], [role=slider], [data-owns-gesture], .resize-handle, .menu, .strip";

/**
 * Asked by gesture.ts at a sideways claim: is this swipe the stack's under the finger? Same rule as the stack's own
 * handler, from the same attributes (data-at / data-n, data-swipe only when it may swipe).
 */
export function stackSwipeAt(target: Element | null, dx: number): boolean {
  const el = target?.closest?.<HTMLElement>(".stack-strip[data-swipe]");
  if (!el || target!.closest(OWNED)) return false;
  return stackTakesSwipe(Number(el.dataset.at), Number(el.dataset.n), dx);
}

