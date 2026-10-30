/**
 * Page dots: which page of a swipe shows, for home's pages (PowOS AI's, home's, the app library) and the launcher's
 * (all apps | folders) alike - one component, one style (shell.css .page-dots). The user, 2026-10-30: "We should have
 * like a page indicator on both [the launcher and] the homepage".
 *
 * They follow the finger: [paintDots] takes the swipe's position as a fraction (1.4 = 40% of the way from the second
 * page to the third) and gives each dot its share of "here" (--on, 0..1) - written straight onto the dots, never
 * through a render, so a swipe re-renders nothing. While a finger drags they track it exactly (.live: no transition);
 * let go, they ease to the page it settles on with the page's own settle.
 */
import { useLayoutEffect, useRef } from "preact/hooks";
import { effect } from "@preact/signals";

/** Each dot's share of [pos]: 1 on the page, falling to 0 a page away. [live]: a finger is on it (no easing). */
export function paintDots(el: HTMLElement | null, pos: number, live: boolean) {
  if (!el) return;
  el.classList.toggle("live", live);
  el.querySelectorAll<HTMLElement>(":scope > i").forEach((d, i) => {
    d.style.setProperty("--on", String(Math.max(0, 1 - Math.abs(pos - i)).toFixed(3)));
  });
}

/**
 * [count] dots. [follow] reads the position (signals it reads re-run it: an effect, not a render) and returns
 * [pos, live]; or the owner paints them itself through [dotsRef] (the launcher's pages, kept in a ref).
 */
export function PageDots({ count, follow, dotsRef, class: cls = "" }: {
  count: number;
  follow?: () => [number, boolean];
  dotsRef?: { current: HTMLDivElement | null };
  class?: string;
}) {
  const own = useRef<HTMLDivElement>(null);
  const el = dotsRef ?? own;
  useLayoutEffect(() => {
    if (!follow) return;
    return effect(() => {
      const [pos, live] = follow();
      paintDots(el.current, pos, live);
    });
  }, [count, follow]);
  return (
    <div class={`page-dots ${cls}`} ref={el} aria-hidden="true">
      {Array.from({ length: count }, (_, i) => <i key={i} />)}
    </div>
  );
}
