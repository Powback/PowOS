/**
 * The notification shade's motion (notifications.tsx; the user, 11-01: "the show-more thing just pops them in
 * instantly; the whole thing doesn't adhere to our design principles"): nothing in the list appears or vanishes in
 * one frame. A change - a group's "+N more", a card tapped open or folded, a new list from the host - goes through
 * [animateLayout]: every row, group and card is measured before it, and after the render each one whose height
 * changed grows or shrinks to it on the shell's spring (ui/spring.ts), clipped as it goes, while the cards that just
 * came into view fade and slide in, ~30 ms apart. A group folding plays that in reverse first ([foldAway]); a card
 * slid away closes its gap the same way ([closeGap]). Reduced motion: all of it instant.
 */
import { spring, springFast } from "./spring.ts";

/** What grows and shrinks: the cascade's rows, the groups, the singles' list, a group's rest, each card. */
const BOXES = ".notif-items > .cascade, .notif-stack, .notif-singles, .notif-rest, .notif-items .notif";
/** What fades in when it comes into view: a card, a group's "+N more". */
const ITEMS = ".notif-items .notif, .notif-items .notif-show-more";
/** The cards' fade and slide, and how far apart they start. */
const FADE_MS = 240;
const STAGGER_MS = 30;
const SLIDE_PX = 12;

export const reducedMotion = () => typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;

/** Laid out and not folded away (a group's rest while folded is inert, 0 tall). */
const visible = (el: Element) => el.getBoundingClientRect().height > 0 && !el.closest("[inert]");

const GROW = "notif-grow";

/**
 * [a] (an animation on [el]'s size) with [el] clipped while it runs - overflow itself doesn't animate - and, [held]
 * (one that stays at its end: a fold, a closed gap), until it's cancelled.
 */
function clipped(el: HTMLElement, a: Animation, held = false) {
  // A held one is never dropped by a later change's [settle]: a closed gap stays closed.
  a.id = held ? `${GROW}-held` : GROW;
  el.style.overflow = "clip";
  const end = () => el.getAnimations().some((x) => x.id.startsWith(GROW) && x !== a && x.playState === "running") || (el.style.overflow = "");
  if (!held) a.addEventListener("finish", end);
  a.addEventListener("cancel", end);
  return a;
}

/** [el]'s height from [from] to its own, on the spring, clipped while it moves. */
const grow = (el: HTMLElement, from: number, to: number) =>
  clipped(el, el.animate([{ height: `${from}px` }, { height: `${to}px` }], { duration: spring.ms, easing: spring.easing }));

/** [el]'s size animations from an earlier change, dropped so its new height can be read. */
const settle = (el: HTMLElement) => el.getAnimations().forEach((a) => a.id === GROW && a.cancel());

/**
 * [els] (in their order) faded and slid in, each [STAGGER_MS] after the one before - the lists' arrival (also the
 * control center's members as a category unfolds, control.tsx Members).
 */
export function fadeIn(els: Element[]) {
  els.forEach((el, i) =>
    el.animate([{ opacity: 0, transform: `translateY(${-SLIDE_PX}px)` }, { opacity: 1, transform: "none" }], {
      duration: FADE_MS,
      delay: i * STAGGER_MS,
      easing: spring.easing,
      fill: "backwards",
    }),
  );
}

/**
 * A list's arrivals (any list, not only the shade's: the launcher's search results, drawer.tsx): [els], in the order
 * they should come, fade and slide in [STAGGER_MS] apart. Reduced motion: they're just there.
 */
export function arrive(els: Element[]) {
  if (!els.length || reducedMotion() || typeof Element.prototype.animate !== "function") return;
  fadeIn(els);
}

/** Each box's height, and the items in view, under [root]. */
function snapshot(root: ParentNode) {
  const heights = new Map<HTMLElement, number>();
  for (const el of root.querySelectorAll<HTMLElement>(BOXES)) heights.set(el, el.getBoundingClientRect().height);
  const seen = new Set([...root.querySelectorAll(ITEMS)].filter(visible));
  return { heights, seen };
}

/** After the render: what changed height grows to it, what came into view fades in. */
function play(root: ParentNode, before: ReturnType<typeof snapshot>) {
  for (const el of before.heights.keys()) if (el.isConnected) settle(el);
  for (const [el, from] of before.heights) {
    if (!el.isConnected) continue;
    const to = el.getBoundingClientRect().height;
    if (Math.abs(to - from) > 1) grow(el, from, to);
  }
  fadeIn([...root.querySelectorAll(ITEMS)].filter((el) => !before.seen.has(el) && visible(el)));
}

/** The open shade's notification list, or null (shut: nothing to animate). */
const shownList = () => document.querySelector<HTMLElement>(".notif-panel.shown .notif-items");

/**
 * [change] (a signal set) animated: measured before, played after its render (the render runs in a microtask, so
 * by the next frame, before it's painted, the new layout is there to measure). Shut, or reduced motion: just [change].
 */
export function animateLayout(change: () => void) {
  const root = shownList();
  if (!root || reducedMotion() || typeof Element.prototype.animate !== "function") return change();
  const before = snapshot(root);
  change();
  requestAnimationFrame(() => play(root, before));
}

/**
 * A group folding: its rest's cards fade out (the last first, [STAGGER_MS] apart) while the rest shrinks to nothing on
 * the spring - then [done] folds it (nothing left to jump). Reduced motion: [done] at once.
 */
export function foldAway(rest: HTMLElement | null | undefined, done: () => void) {
  if (!rest || reducedMotion() || !visible(rest)) return done();
  const cards = [...rest.querySelectorAll(".notif")].reverse();
  cards.forEach((el, i) =>
    el.animate([{ opacity: 1 }, { opacity: 0, transform: `translateY(${-SLIDE_PX}px)` }], {
      duration: FADE_MS,
      delay: i * STAGGER_MS,
      easing: springFast.easing,
      fill: "forwards",
    }),
  );
  const h = rest.getBoundingClientRect().height;
  const a = clipped(rest, rest.animate([{ height: `${h}px` }, { height: "0px" }], { duration: spring.ms, easing: spring.easing, fill: "forwards" }), true);
  a.onfinish = () => {
    done();
    // After the fold's render: nothing held at its end any more.
    requestAnimationFrame(() => {
      a.cancel();
      for (const el of cards) el.getAnimations().forEach((x) => x.cancel());
    });
  };
}

/**
 * A card slid away: it closes up to nothing - its height, its padding and the gap after it - on the spring, so the
 * cards around it move into its place; then [done] dismisses it. Held closed until the list drops it; still there a
 * while later (the dismiss didn't take), it comes back.
 */
export function closeGap(card: HTMLElement, done: () => void) {
  if (reducedMotion()) return done();
  const cs = getComputedStyle(card);
  const gap = parseFloat(getComputedStyle(card.parentElement ?? card).rowGap) || 0;
  const from = { height: `${card.offsetHeight}px`, paddingTop: cs.paddingTop, paddingBottom: cs.paddingBottom, marginBottom: cs.marginBottom };
  const to = { height: "0px", paddingTop: "0px", paddingBottom: "0px", marginBottom: `${-gap}px` };
  const a = clipped(card, card.animate([from, to], { duration: spring.ms, easing: spring.easing, fill: "forwards" }), true);
  a.onfinish = () => {
    done();
    setTimeout(() => card.isConnected && (a.cancel(), (card.style.transform = ""), (card.style.opacity = "")), 3000);
  };
}
