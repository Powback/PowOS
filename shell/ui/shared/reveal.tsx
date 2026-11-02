/**
 * Folds and menus without pop-ins (docs/DESIGN-LANGUAGE.md §6 "Nothing pops in"): what a toggle shows or hides grows
 * and fades in, and shrinks and fades out before it leaves the DOM, on the shell's spring. The AI page's folds were
 * `{open && …}` (design wave 5), App API's sections `{open && …}` and native <details>: there in one frame, gone in
 * the next. lint-design blocks that pattern in the AI page's files; use these instead.
 *
 * This is `@powos/shared/reveal` (friction f179, as `@powos/shared/pending`): framework-neutral Preact, the springs
 * read from theme.css's tokens (--spring-slow / --spring-slow-ms ..., which shell/ui/spring.ts sets to the real
 * springs at load) - so a PowOS app's own UI moves on the same spring as the shell, and the shell's ui/reveal.tsx is
 * this module.
 *
 * - [Reveal]: a fold's body. Its box animates its height 0 <-> its own (clipped while it moves) and its opacity, on
 *   the slow spring (a group folding); first render as it is (a fold open at first doesn't animate in).
 * - [Details]: a native <details> (its summary, `open`, keyboard and find-in-page kept) whose body opens and closes
 *   as a [Reveal] does - the browser's own toggle is instant.
 * - [usePresence]: for something positioned on its own (a menu): keeps it mounted while it leaves; the caller adds
 *   `.leaving` and its CSS plays the exit on --spring-fast.
 *
 * Reduced motion: all of it jumps to its end state, same code path.
 */
import type { ComponentChildren, JSX } from "preact";
import { useLayoutEffect, useRef, useState } from "preact/hooks";

export const reducedMotion = () => typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;

/** One of the spring set ("spring-fast" | "spring" | "spring-slow") as theme.css's tokens hold it; unset: no motion. */
export function springToken(name: "spring-fast" | "spring" | "spring-slow"): { easing: string; ms: number } {
  const cs = typeof document === "undefined" ? null : getComputedStyle(document.documentElement);
  const easing = cs?.getPropertyValue(`--${name}`).trim() ?? "";
  const ms = parseFloat(cs?.getPropertyValue(`--${name}-ms`) ?? "") || 0;
  return easing ? { easing, ms } : { easing: "linear", ms: 0 };
}

const animates = () => !reducedMotion() && typeof Element !== "undefined" && typeof Element.prototype.animate === "function";

/** [el]'s height to its own ([open]) or to 0, fading, on the slow spring, clipped while it moves; [done] when it ends. */
function fold(el: HTMLElement, open: boolean, done: () => void) {
  const s = springToken("spring-slow");
  const from = open ? 0 : el.offsetHeight;
  const to = open ? el.scrollHeight : 0;
  el.style.overflow = "clip";
  const a = el.animate(
    [
      { height: `${from}px`, opacity: open ? 0 : 1 },
      { height: `${to}px`, opacity: open ? 1 : 0 },
    ],
    { duration: s.ms, easing: s.easing, fill: open ? "none" : "forwards" },
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
    if (!el || !animates()) return void (open || setGone(true));
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

/**
 * A native <details> whose body (a box of [bodyStyle]) grows open and shrinks shut on the slow spring instead of the
 * browser's one-frame toggle. [onToggle] hears open/closed: at the tap when opening, once shut when closing.
 */
export function Details(p: {
  summary: ComponentChildren;
  children: ComponentChildren;
  style?: JSX.CSSProperties;
  summaryStyle?: JSX.CSSProperties;
  bodyStyle?: JSX.CSSProperties;
  fold?: string;
  onToggle?: (open: boolean) => void;
}) {
  const box = useRef<HTMLDetailsElement>(null);
  const body = useRef<HTMLDivElement>(null);
  const anim = useRef<Animation | null>(null);
  const click = (e: MouseEvent) => {
    const d = box.current;
    const b = body.current;
    if (!d || !b || !animates()) return;
    e.preventDefault();
    // Mid-way, a tap turns it back: closing while it opens, opening while it closes.
    const closing = anim.current ? anim.current.id === "open" : d.open;
    anim.current?.cancel();
    if (!closing) d.open = true;
    const a = fold(b, !closing, () => {
      if (anim.current !== a) return;
      anim.current = null;
      if (closing) (d.open = false), a.cancel();
    });
    a.id = closing ? "close" : "open";
    anim.current = a;
  };
  return (
    <details ref={box} style={p.style} data-fold={p.fold} onToggle={(e) => p.onToggle?.((e.currentTarget as HTMLDetailsElement).open)}>
      <summary style={p.summaryStyle} onClick={click}>
        {p.summary}
      </summary>
      <div ref={body} style={p.bodyStyle}>
        {p.children}
      </div>
    </details>
  );
}

/** [open] kept mounted for the exit: { on: render it, leaving: it is closing (add `.leaving`) }. */
export function usePresence(open: boolean, ms?: number) {
  const [on, setOn] = useState(open);
  useLayoutEffect(() => {
    if (open) return void setOn(true);
    if (reducedMotion()) return void setOn(false);
    const t = setTimeout(() => setOn(false), ms ?? springToken("spring-fast").ms);
    return () => clearTimeout(t);
  }, [open, ms]);
  return { on: open || on, leaving: !open && on };
}
