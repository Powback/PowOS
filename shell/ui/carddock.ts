/**
 * A switcher card dragged up and toward a side: docked into OxygenOS's Open Canvas (the native split view,
 * com.oplus.pscanvas) on that side - the user, 11-23: "When I use the switcher and I drag a window up and to the side
 * it should be docked to that side ... the split view native thing". Not PowOS's desktop split.
 *
 * Pure geometry, no DOM (shell/test/carddock.test.ts): which half a card dragged by (dx, dy) targets now, and what its
 * release does. A mostly vertical drag stays a removal exactly as before (switcher.tsx REMOVE / FLICK); only a drag that
 * is clearly diagonal AND has carried the finger into the outer part of the screen on that side docks.
 */

export type DockSide = "left" | "right";

/** Up at least this much of the card's height before a side counts (a sideways nudge at the start never docks). */
export const DOCK_UP = 0.18;
/** Sideways at least this much of the screen's width. */
export const DOCK_DX = 0.14;
/** The finger in the outer part of the screen on that side: x <= EDGE * width (left), >= (1 - EDGE) * width (right). */
export const DOCK_EDGE = 0.36;
/** Diagonal enough: |dx| at least this times the distance up (~27 degrees off vertical). */
export const DOCK_SLANT = 0.5;

export interface CardDrag {
  /** Finger's travel since the press (CSS px; up is negative dy). */
  dx: number;
  dy: number;
  /** Where the finger is now (CSS px from the left edge of the screen). */
  x: number;
  /** The card's height and the screen's width (CSS px). */
  cardH: number;
  screenW: number;
}

/** The half a card dragged as [d] targets right now, or null: a removal / spring-back as before. */
export function dockSide(d: CardDrag): DockSide | null {
  const up = -d.dy;
  if (up < d.cardH * DOCK_UP) return null;
  if (Math.abs(d.dx) < d.screenW * DOCK_DX) return null;
  if (Math.abs(d.dx) < up * DOCK_SLANT) return null;
  if (d.dx < 0 && d.x <= d.screenW * DOCK_EDGE) return "left";
  if (d.dx > 0 && d.x >= d.screenW * (1 - DOCK_EDGE)) return "right";
  return null;
}

/** Pushed up this far (of its height), or flicked up (px/ms), a card is removed (switcher.tsx's, unchanged). */
export const REMOVE = 0.4;
export const FLICK = 0.5;

export type CardRelease = { kind: "dock"; side: DockSide } | { kind: "remove" } | { kind: "back" };

/**
 * What letting go of an upward card drag does. [canDock]: Open Canvas is there (unfolded, supported) - else exactly the
 * old rule. [vy]: the finger's recent speed (px/ms, up negative). A drag in a dock zone docks even when flicked (the
 * half was shown under the finger); anything else is the old removal rule.
 */
export function cardRelease(d: CardDrag, vy: number, canDock: boolean): CardRelease {
  const side = canDock ? dockSide(d) : null;
  if (side) return { kind: "dock", side };
  if (vy < -FLICK || (-d.dy > d.cardH * REMOVE && vy < 0.3)) return { kind: "remove" };
  return { kind: "back" };
}

type Card = { id: number; key?: string | null; split?: unknown };

/**
 * A card that can be a side of Open Canvas. [sides]: the host's answer (tasks.canvasSides - Android apps OxygenOS lets
 * into split view: not on its blocklist, resizeable, not PowOS's own tasks), the truth when there is one. Without it (an
 * older APK): a single Android app's card ("a:" key) that isn't PowOS - never a Linux window ("l:", a PowOS task), a
 * PowOS app open in home (negative id), the lock face or home (PowOS tasks with no key), or a split card.
 */
export function canSide(c: Card, sides: Set<number> | null): boolean {
  if (c.id < 0 || c.split) return false;
  if (sides) return sides.has(c.id);
  const key = c.key ?? "";
  return key.startsWith("a:") && !key.startsWith("a:com.powos.app");
}

/**
 * The app beside the docked one: the newest OTHER card that can be a side ([canSide]). [list] is the switcher's order,
 * newest first after the lead.
 */
export function dockPartner(list: Card[], dragged: number, sides: Set<number> | null = null): number | null {
  const t = list.find((c) => c.id !== dragged && canSide(c, sides));
  return t ? t.id : null;
}

/**
 * What a card let go in a dock zone does: dock beside [other], or why not - "dragged": the dragged app itself can't be in
 * split view (OxygenOS's blocklist: Settings), "partner": no other open app can. Both are said to the user.
 */
export type DockPick = { other: number } | { why: "dragged" | "partner" };

export function dockPick(list: Card[], dragged: number, sides: Set<number> | null): DockPick {
  const card = list.find((c) => c.id === dragged);
  if (!card || !canSide(card, sides)) return { why: "dragged" };
  const other = dockPartner(list, dragged, sides);
  return other == null ? { why: "partner" } : { other };
}
