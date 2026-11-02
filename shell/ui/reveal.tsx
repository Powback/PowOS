/**
 * Folds and menus without pop-ins (docs/DESIGN-LANGUAGE.md §6 "Nothing pops in"; design wave 5, the AI page): what a
 * toggle shows or hides grows and fades in, and shrinks and fades out before it leaves the DOM, on the shell's spring
 * (ui/spring.ts). The AI page's folds were `{open && …}`: there in one frame, gone in the next. lint-design blocks
 * that pattern in the AI page's files; use these instead.
 *
 * - [Reveal]: a fold's body. Its box animates its height 0 <-> its own (clipped while it moves) and its opacity, on
 *   springSlow (a group folding); first render as it is (a fold open at first doesn't animate in).
 * - [usePresence]: for something positioned on its own (a menu): keeps it mounted while it leaves; the caller adds
 *   `.leaving` and its CSS plays the exit on --spring-fast.
 *
 * Reduced motion: both jump to their end state, same code path.
 */
import type { ComponentChildren } from "preact";
import { useLayoutEffect, useRef, useState } from "preact/hooks";
import { reducedMotion } from "./notifmotion.ts";
import { springFast, springSlow } from "./spring.ts";

/** [el]'s height to its own ([open]) or to 0, fading, on springSlow, clipped while it moves; [done] when it ends. */
function fold(el: HTMLElement, open: boolean, done: () => void) {
  const from = open ? 0 : el.offsetHeight;
  const to = open ? el.scrollHeight : 0;
  el.style.overflow = "clip";
  const a = el.animate(
    [
      { height: `${from}px`, opacity: open ? 0 : 1 },
      { height: `${to}px`, opacity: open ? 1 : 0 },
    ],
    { duration: springSlow.ms, easing: springSlow.easing, fill: open ? "none" : "forwards" },
  );
  a.onfinish = () => ((el.style.overflow = ""), done());
  return a;
}

/** [children] shown while [open], growing in and shrinking out; [class] names the box (no layout of its own). */
export function Reveal({ open, children, class: cls = "" }: { open: boolean; children: ComponentChildren; class?: string }) {
  const ref = useRef<HTMLDivElement>(null);
  const was = useRef(open);
  const anim = useRef<Animation | null>(null);
  // Closed and done leaving: unmounted. Mounted while open, and while a close plays.
  const [gone, setGone] = useState(!open);
  useLayoutEffect(() => {
    if (was.current === open) return;
    was.current = open;
    anim.current?.cancel();
    anim.current = null;
    if (open) setGone(false);
    const el = ref.current;
    if (!el || reducedMotion()) return void (open || setGone(true));
    const a = fold(el, open, () => anim.current === a && ((anim.current = null), open || setGone(true)));
    anim.current = a;
  }, [open]);
  if (!open && gone) return null;
  return (
    <div ref={ref} class={`reveal ${cls}`} aria-hidden={!open || undefined} inert={!open || undefined}>
      {children}
    </div>
  );
}

/** [open] kept mounted for the exit: { on: render it, leaving: it is closing (add `.leaving`) }. */
export function usePresence(open: boolean, ms = springFast.ms) {
  const [on, setOn] = useState(open);
  useLayoutEffect(() => {
    if (open) return void setOn(true);
    if (reducedMotion()) return void setOn(false);
    const t = setTimeout(() => setOn(false), ms);
    return () => clearTimeout(t);
  }, [open, ms]);
  return { on: open || on, leaving: !open && on };
}
