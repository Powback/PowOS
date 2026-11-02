/**
 * The shade opened where the finger started (align.ts anchorPull / pullAt; the user, 11-01: "if I'm on the homepage and
 * I open it by swiping ... close to the bottom, then the notification center shows up close to the bottom where I like
 * opened it"). Once per pull - never per frame - the panel's content height is measured and --anchor-top set on the
 * panel (data-anchored): the one panel and the two columns start that much lower, the panels apart are a card that much
 * lower (shell.css). An attribute and a custom property, not a class: the panel's class is Preact's to rewrite.
 */
import { useLayoutEffect, type MutableRef } from "preact/hooks";
import { panel } from "../state.ts";
import { anchorTop, pullAt } from "./align.ts";

const px = (cs: CSSStyleDeclaration, k: "rowGap" | "paddingTop" | "paddingBottom") => parseFloat(cs[k]) || 0;

/** [el]'s height as its content would make it (not what its flex/grid stretches it to): its rows, gaps and padding. */
function natural(el: HTMLElement | null): number {
  if (!el) return 0;
  const cs = getComputedStyle(el);
  const kids = [...el.children] as HTMLElement[];
  const rows = kids.reduce((sum, k) => sum + (k.classList.contains("notif-items") ? natural(k) : k.offsetHeight), 0);
  return rows + px(cs, "rowGap") * Math.max(0, kids.length - 1) + px(cs, "paddingTop") + px(cs, "paddingBottom");
}

/** The shade's content height: the taller column (two), the card and the list (one panel), or the panel's own content. */
function contentHeight(body: HTMLElement, together: boolean, two: boolean): number {
  const part = (sel: string) => body.querySelector<HTMLElement>(sel);
  const cc = part(":scope > .cc, :scope > .cc-col > .cc");
  if (two) return Math.max(natural(part(":scope > .notif-col")), natural(cc));
  const list = natural(part(".notif-list"));
  if (together) return (cc?.offsetHeight ?? 0) + px(getComputedStyle(body), "rowGap") + list;
  return cc ? natural(cc) : (part(":scope > .notif-bar")?.offsetHeight ?? 0) + list;
}

/** NotificationPanel's: the panel [panelEl] placed for this pull's start, or as aligned (no start, the toggle off). */
export function useAnchoredOpen(panelEl: MutableRef<HTMLDivElement | null>, together: boolean, two: boolean) {
  const at = pullAt.value;
  useLayoutEffect(() => {
    const p = panelEl.current;
    const body = p?.querySelector<HTMLElement>(":scope > .panel-body");
    if (!p || !body) return;
    const top = at == null ? 0 : anchorTop(at, contentHeight(body, together, two), innerHeight);
    p.toggleAttribute("data-anchored", top > 0);
    if (top > 0) p.style.setProperty("--anchor-top", `${top}px`);
    else p.style.removeProperty("--anchor-top");
  }, [at, panel.value, together, two]);
}
