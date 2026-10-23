/**
 * The pull-up's second stage. Pulled on past the drawer's open place - or up again at the end of its list - the
 * drawer's content lifts a little further on a rubber band; past its threshold a haptic tick says stage 2 is armed, and let go
 * there the search field takes the focus and the keyboard comes up, in the release's own event. Let go short of it,
 * it eases back: stage 1, no keyboard (a plain swipe up never raises one).
 *
 * The lift is one paused Web Animation on .launcher-inner (as gesture.ts's followers): the finger sets its
 * currentTime, so no style is written per frame (nativeglass.ts's MutationObserver re-measures on style writes).
 */
import { powos } from "../bridge.ts";

/**
 * Finger px past the open place where stage 2 is armed: a quarter of the screen, so an ordinary swipe up (the drawer
 * opens in ~90 px of finger at 15vh) stays stage 1 - about a third of the screen of finger in all from home.
 */
const overAt = () => Math.max(120, innerHeight * 0.25);
/** The rubber band: at most MAX px of lift, most of it by the threshold. */
const MAX = 48;
const band = (d: number) => MAX * (1 - Math.exp(-Math.max(0, d) / 160));
const SPAN = 1000;
const BACK_MS = 180;
const BACK_EASE = "cubic-bezier(0.1, 0.8, 0.2, 1)";

let anim: Animation | null = null;
let armed = false;

/** The finger [d] CSS px past the open place (0 or less: none). */
export function overPull(d: number) {
  if (!anim) {
    if (d <= 0) return;
    const el = document.querySelector<HTMLElement>(".launcher-inner");
    if (!el) return;
    anim = el.animate([{ transform: "none" }, { transform: `translateY(${-MAX}px)` }], { duration: SPAN, fill: "both", easing: "linear", id: "overpull" });
    anim.pause();
  }
  anim.currentTime = (band(d) / MAX) * SPAN;
  const now = d >= overAt();
  if (now && !armed) navigator.vibrate?.(10);
  armed = now;
}

/** The finger up: true when it was let go armed - the search has the keyboard now. [raise] false: dropped, no search. */
export function overRelease(raise = true): boolean {
  const go = armed && raise;
  armed = false;
  if (go) raiseSearch();
  const a = anim;
  anim = null;
  if (!a) return go;
  const from = (Number(a.currentTime ?? 0) / SPAN) * MAX;
  const el = (a.effect as KeyframeEffect | null)?.target as HTMLElement | null;
  a.cancel();
  el?.animate([{ transform: `translateY(${-from}px)` }, { transform: "none" }], { duration: BACK_MS, easing: BACK_EASE, id: "overpull" });
  return go;
}

/**
 * The open panel's field focused, then the keyboard asked for (bar.tsx's tap does the same): the foot's search - or,
 * on the wide home, PowOS AI's compose, since its panel hides the foot's bar (shell.css) and a hidden field takes no
 * focus. No field took it: no keyboard (one with nothing to type into).
 */
function raiseSearch() {
  for (const sel of [".home > .bar textarea", ".ai-panel .ai-compose textarea"]) {
    const field = document.querySelector<HTMLTextAreaElement>(sel);
    field?.focus();
    if (field && document.activeElement === field) return void powos.keyboard.show();
  }
}
