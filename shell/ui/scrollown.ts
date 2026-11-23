/**
 * Who owns a drag along one axis: an element that can still scroll that way (the user, 11-23: "some widgets have a
 * left/right scroller, but using it changes the home PAGE instead of scrolling the widget's content"; "scrolling the
 * recent-apps bar on home SOMETIMES activates the notification screen").
 *
 * The rule, one for every scroller on home - a DOM one (the recent apps' strip, a widget's sideways row or list) and a
 * native one inside an Android widget (AppWidgets.kt sends each view that scrolls, with its room, beside every frame):
 * a drag along an axis an element under the finger scrolls, with room left that way, is that element's - home's page
 * swipe, a stack's swipe and the shade's pull keep off it. At its edge (no room that way) the drag passes on, as a
 * widget stack's does at its first/last widget (stackmodel.ts stackTakesSwipe): only for a drag decided there, never
 * mid-drag (no rubber band, no jump). Pure reads: style and scroll sizes at the moment of the claim.
 */

/** The axis of a drag: x sideways, y up and down. */
export type Axis = "x" | "y";

/**
 * A scroller inside a native widget, as AppWidgets.kt sends it: its box as fractions of the widget's, and whether its
 * content can still move each way ([x]: [toward the start (left), toward the end (right)]; [y]: [up, down]).
 */
export interface NativeScroller {
  l: number;
  t: number;
  w: number;
  h: number;
  x: [boolean, boolean];
  y: [boolean, boolean];
}

/** The native scrollers of a widget face (appwidget.tsx registers each face with its latest frame's list). */
const natives = new WeakMap<Element, () => NativeScroller[] | undefined>();
/** Where the faces with native scrollers are: the walk stops at the first one up from the finger. */
export const NATIVE_FACE = ".aw-face";

export function registerNative(face: Element, read: () => NativeScroller[] | undefined) {
  natives.set(face, read);
}

/** [el] scrolls along [axis] by its style (overflow auto / scroll) and has more to show along it. */
function scrollsAlong(el: Element, axis: Axis): boolean {
  const s = getComputedStyle(el);
  if (!/auto|scroll/.test(axis === "x" ? s.overflowX : s.overflowY)) return false;
  return axis === "x" ? el.scrollWidth > el.clientWidth + 1 : el.scrollHeight > el.clientHeight + 1;
}

/**
 * Whether [el]'s content can still move for a finger going [d] px along [axis] (d < 0: finger left / up - the content
 * scrolls toward its end). A row-reverse / column-reverse scroller counts from the other side (scrollLeft/Top <= 0).
 */
export function roomFor(el: Element, axis: Axis, d: number): boolean {
  if (!d) return false;
  const pos = axis === "x" ? el.scrollLeft : el.scrollTop;
  const span = axis === "x" ? el.scrollWidth - el.clientWidth : el.scrollHeight - el.clientHeight;
  const s = getComputedStyle(el);
  const reversed = axis === "x" ? s.direction === "rtl" || s.flexDirection === "row-reverse" : s.flexDirection === "column-reverse";
  // Normalised to 0 (start) .. span (end); a reversed scroller runs 0 .. -span.
  const at = reversed ? -pos : pos;
  const towardEnd = d < 0 !== reversed;
  return towardEnd ? at < span - 1 : at > 1;
}

/** A drag to ask about: started at ([x], [y]) (client px), [d] px along [axis] so far; [stop]: the walk ends there. */
export interface DragAsk {
  x: number;
  y: number;
  axis: Axis;
  d: number;
  stop?: Element | null;
}

/** The native scroller at the drag's start in widget face [face] with room for it. */
function nativeRoom(face: Element, q: DragAsk): boolean {
  const list = natives.get(face)?.();
  if (!list?.length || !q.d) return false;
  const r = face.getBoundingClientRect();
  if (!r.width || !r.height) return false;
  const fx = (q.x - r.left) / r.width;
  const fy = (q.y - r.top) / r.height;
  const way = q.d < 0 ? 1 : 0;
  return list.some((s) => fx >= s.l && fx <= s.l + s.w && fy >= s.t && fy <= s.t + s.h && (q.axis === "x" ? s.x : s.y)[way]);
}

/** [el] takes drag [q]: a widget face by its native scrollers, anything else by its own scroll and room. */
const takes = (el: Element, q: DragAsk) => (el.matches(NATIVE_FACE) ? nativeRoom(el, q) : scrollsAlong(el, q.axis) && roomFor(el, q.axis, q.d));

/**
 * The element under [target] (up to [q].stop, exclusive) that owns drag [q]: the nearest scroller along its axis with
 * room left that way, or a widget face whose native scroller under the finger has room. Null: none - the drag is
 * home's (or the stack's). Scrollers at their edge are passed over, so an outer one with room still takes it.
 */
export function scrollOwner(target: Element | null, q: DragAsk): Element | null {
  for (let el: Element | null = target; el && el !== q.stop && el !== document.documentElement; el = el.parentElement) if (takes(el, q)) return el;
  return null;
}

/** For each axis, whether something under the finger takes a drag that way: [finger right/down, finger left/up]. */
export interface Room {
  x: [boolean, boolean];
  y: [boolean, boolean];
}
export const NO_ROOM: Room = { x: [false, false], y: [false, false] };

/**
 * [scrollOwner] for all four ways at once, read at the finger's DOWN (gesture.ts startGesture: before the drag writes
 * anything, so the claim on a later move reads nothing - a style or size read there forced a layout per move, HP4).
 */
export function roomAt(target: Element | null, x: number, y: number, stop?: Element | null): Room {
  const way = (axis: Axis, d: number) => !!scrollOwner(target, { x, y, axis, d, stop });
  return { x: [way("x", 1), way("x", -1)], y: [way("y", 1), way("y", -1)] };
}

/** Whether [room] gives a drag of [d] along [axis] to a scroller. */
export const roomTakes = (room: Room, axis: Axis, d: number) => !!d && room[axis][d < 0 ? 1 : 0];

/** Every native scroller of [face] that scrolls along [axis] at all, in client px (home's claim regions for the host). */
export function nativeRects(face: Element, axis: Axis): DOMRect[] {
  const list = natives.get(face)?.();
  if (!list?.length) return [];
  const r = face.getBoundingClientRect();
  return list
    .filter((s) => (axis === "x" ? s.x : s.y).some(Boolean))
    .map((s) => new DOMRect(r.left + s.l * r.width, r.top + s.t * r.height, s.w * r.width, s.h * r.height));
}
