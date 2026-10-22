/**
 * The control center's whole view, in the one panel (notifications.tsx, together): the panel open, a further pull down
 * shows every category's members inside its tile (control.tsx GroupTile); up, or scrolling the notifications, folds them
 * back. gesture.ts follows the finger ([stretch]: the rows below spread apart, a rubber band - --cc-pull on the panel,
 * a translate only, nothing laid out per frame) and lets go with [settle]: past the threshold or a flick it's committed
 * - laid out once, the rows and the notifications played from where the finger left them to their place (a FLIP).
 */
import { signal } from "@preact/signals";

/** Every category's members shown (only in the one panel, only while it's open). */
export const ccExpanded = signal(false);

/** The finger's travel (CSS px) to the rows' spread: easy at first, firmer the further it goes. */
const band = (d: number) => Math.sign(d) * 120 * (1 - Math.exp(-Math.abs(d) / 200));
/** Pulled this far (CSS px, the finger's travel) it commits on its own; a flick (gesture.ts FLICK) does too. */
export const EXPAND_AT = 56;
const MS = 260;
const EASE = "cubic-bezier(0.2, 0.9, 0.3, 1)";

const panelEl = () => document.querySelector<HTMLElement>(".notif-panel");
/** What moves: each row of tiles, and what's under the control center (the notifications' header and list). */
const movers = () => [
  ...document.querySelectorAll<HTMLElement>(".panel-body.together .cc-main > .cc-grid, .panel-body.together .cc ~ *"),
];

/** Following the finger: [dy] its travel, down to show (positive), up to fold (negative). */
export function stretch(dy: number) {
  const p = panelEl();
  if (!p) return;
  p.classList.add("cc-pulling");
  p.style.setProperty("--cc-pull", `${band(dy)}px`);
  p.style.setProperty("--cc-k", `${band(dy) / 120}`);
}

/** Let go: [commit] to the other state, or back to this one. */
export function settle(commit: boolean) {
  const p = panelEl();
  if (!p) return;
  if (!commit) {
    p.classList.remove("cc-pulling");
    p.style.setProperty("--cc-pull", "0px");
    p.style.setProperty("--cc-k", "0");
    return;
  }
  setExpanded(!ccExpanded.value);
}

/**
 * Laid out once in the new state, each mover played from where it was on screen (the finger's spread included) to its
 * place. [anchor] (scrolling folds it): the notifications stay where they are on screen instead - the list's scroll
 * takes up what the rows above gave back - and nothing animates.
 */
export function setExpanded(on: boolean, anchor?: HTMLElement | null) {
  if (on === ccExpanded.value) return;
  const p = panelEl();
  const before = new Map(movers().map((el) => [el, el.getBoundingClientRect().top]));
  const items = anchor ? document.querySelector<HTMLElement>(".panel-body.together .cc ~ .notif-items") : null;
  const itemsTop = items?.getBoundingClientRect().top ?? 0;
  if (p) {
    p.classList.remove("cc-pulling");
    p.style.setProperty("--cc-pull", "0px");
    p.style.setProperty("--cc-k", "0");
  }
  ccExpanded.value = on;
  // After the render, before the paint.
  requestAnimationFrame(() => {
    if (anchor && items) {
      anchor.scrollTop += items.getBoundingClientRect().top - itemsTop;
      return;
    }
    const moved: HTMLElement[] = [];
    for (const el of movers()) {
      const was = before.get(el);
      if (was == null) continue;
      const d = was - el.getBoundingClientRect().top;
      if (Math.abs(d) < 0.5) continue;
      el.style.transition = "none";
      el.style.translate = `0 ${d}px`;
      moved.push(el);
    }
    if (!moved.length) return;
    void moved[0].offsetWidth;
    for (const el of moved) {
      el.style.transition = `translate ${MS}ms ${EASE}`;
      el.style.translate = "";
    }
    window.setTimeout(() => moved.forEach((el) => (el.style.transition = "")), MS + 40);
  });
}
