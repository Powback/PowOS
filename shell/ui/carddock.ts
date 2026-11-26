/**
 * A switcher card lifted and dragged to a screen edge: docked into OxygenOS's Open Canvas (the native split view,
 * com.oplus.pscanvas) on that side, then the user picks the app for the other half (ui/canvaspick.tsx). The user,
 * 11-26: "You should be able to drag the window to the right side, left side, top or bottom. The app should then dock
 * and you should be able to select the other app ... The docking in the home screen works perfectly ... Use that as
 * reference". Not PowOS's desktop split.
 *
 * Pure geometry, no DOM (shell/test/carddock.test.ts): which half the finger targets now (home's edge rule), and what
 * a release does. A drag that never went to a side stays the old removal (switcher.tsx REMOVE / FLICK); a dock drag
 * let go outside a target goes back.
 */

export type DockSide = "left" | "right" | "top" | "bottom";

/**
 * Where the finger has to be for a half to light: within home's own edge band of the screen's edge (webwindows.tsx's
 * bar drag snaps at SNAP_EDGE 24 px - the docking the user called perfect, 11-26), a little wider here because the card
 * under the finger is wide and the switcher has no work-area inset to stop at.
 */
export const DOCK_EDGE_PX = 40;
/** Sideways this much of the screen's width (or ever in a target): a dock drag, let go anywhere else it goes back. */
export const DOCK_DX = 0.14;

export interface CardDrag {
  /** Finger's travel since the press (CSS px; up is negative dy). */
  dx: number;
  dy: number;
  /** Where the finger is now (CSS px from the screen's left / top edge). */
  x: number;
  y?: number;
  /** The card's height and the screen's width / height (CSS px). */
  cardH: number;
  screenW: number;
  screenH?: number;
  /** Open Canvas stacks one over the other here (top / bottom targets; the host's tasks.canvasVertical). */
  vertical?: boolean;
  /** The drag was a dock drag already (it lit a target, or went well sideways): let go outside one, it goes back. */
  docking?: boolean;
}

/**
 * The half a card dragged as [d] targets right now, or null - home's rule: the FINGER at a screen edge (left / right,
 * and top / bottom where the canvas stacks), the nearest edge when it is in two bands (a corner).
 */
export function dockSide(d: CardDrag): DockSide | null {
  const e = DOCK_EDGE_PX;
  const H = d.screenH ?? Infinity;
  const y = d.y ?? H / 2;
  const near: [DockSide, number][] = [
    ["left", d.x],
    ["right", d.screenW - d.x],
  ];
  if (d.vertical && Number.isFinite(H)) near.push(["top", y], ["bottom", H - y]);
  const hit = near.filter(([, dist]) => dist <= e).sort((a, b) => a[1] - b[1])[0];
  return hit ? hit[0] : null;
}

/** A dock drag now ([CardDrag.docking]): it lit a target, or carried the card well sideways. */
export function docking(d: CardDrag): boolean {
  return !!d.docking || dockSide(d) != null || Math.abs(d.dx) >= d.screenW * DOCK_DX;
}

/** Pushed up this far (of its height), or flicked up (px/ms), a card is removed (switcher.tsx's, unchanged). */
export const REMOVE = 0.4;
export const FLICK = 0.5;

export type CardRelease = { kind: "dock"; side: DockSide } | { kind: "remove" } | { kind: "back" };

/**
 * What letting go of a lifted card does. [canDock]: Open Canvas is there (unfolded, supported) - else exactly the old
 * rule. [vy]: the finger's recent speed (px/ms, up negative). The finger in a target docks (the half was shown under
 * it, so even flicked); a dock drag let go anywhere else goes back - a clean cancel, never a removal; anything else is
 * the old removal rule.
 */
export function cardRelease(d: CardDrag, vy: number, canDock: boolean): CardRelease {
  const side = canDock ? dockSide(d) : null;
  if (side) return { kind: "dock", side };
  if (canDock && docking(d)) return { kind: "back" };
  if (vy < -FLICK || (-d.dy > d.cardH * REMOVE && vy < 0.3)) return { kind: "remove" };
  return { kind: "back" };
}

/** The half of a [w] x [h] screen [side] takes (CSS px, the canvas's 8 dp gap between them) - the drop's preview. */
export function halfRect(side: DockSide, w: number, h: number, gap = 8): { x: number; y: number; w: number; h: number } {
  const hw = (w - gap) / 2;
  const hh = (h - gap) / 2;
  if (side === "left") return { x: 0, y: 0, w: hw, h };
  if (side === "right") return { x: w - hw, y: 0, w: hw, h };
  if (side === "top") return { x: 0, y: 0, w, h: hh };
  return { x: 0, y: h - hh, w, h: hh };
}

/** The other half ([side]'s opposite): where the picker for the second app is. */
export const otherSide = (side: DockSide): DockSide => ({ left: "right", right: "left", top: "bottom", bottom: "top" })[side] as DockSide;

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
 * Whether card [dragged] can be docked at all (the picker comes up for the second app), or why not - "dragged": the
 * dragged app itself can't be in split view (OxygenOS's blocklist: Settings). The second app is never picked for the
 * user (the user, 11-26: "it's just randomly selecting the last app you had activated"): they pick it.
 */
export function dockable(list: Card[], dragged: number, sides: Set<number> | null): boolean {
  const card = list.find((c) => c.id === dragged);
  return !!card && canSide(card, sides);
}
