/**
 * KB1 (the user 11-23: "The keyboard resizes the window, but it doesn't resize the content ... I don't see where I'm
 * typing"): the web window the keyboard is typing into ends at the keyboard's top, so its app lays out above it.
 *
 * Why the page has to: an Android app in a web window sits on its own virtual display, and its keyboard shows on the
 * phone's screen (DISPLAY_IME_POLICY_FALLBACK_DISPLAY, WebWindows.imePolicy). Android gives a window IME insets only on
 * the IME's display, so the app on the virtual display never learns the keyboard is there: its adjustResize does
 * nothing and its text field stays under the keyboard. A Linux window's keyboard is home's (SystemIME): KWin's window
 * is never told either. Home's own insets ("system.insets" keyboard) see it, so the window's frame ends at the
 * keyboard's top while it shows: the body is the app's size ("w.f" sizeOf), so the host resizes the virtual display /
 * KWin's window to the room left - the app relayouts there, as a full-screen app does over its own keyboard. The
 * stored frame is untouched: the keyboard down, the window is its old size again.
 *
 * Pure (no DOM, no signals): webwindows.tsx feeds it; shell/test/kbfit.test.ts covers it.
 */

export interface Frame {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** Where the frame is fitted: the keyboard's top, the page's top, the highest a frame may go, its least height. */
export interface Fit {
  /** The keyboard's top, viewport CSS px (Infinity: no keyboard). */
  kbTop: number;
  /** The page's top on screen (frames are page px). */
  originY: number;
  /** The highest a frame's top may go (viewport px: the status bar's bottom). */
  topLimit: number;
  /** The least frame height (unscaled) kept above the keyboard before the frame moves up. */
  minH: number;
}

/**
 * Frame [f] (page px, unscaled; [scale]: its zoom, about its top left) fitted above the keyboard ([o]). The frame keeps
 * its top while at least minH is left above the keyboard; less, it moves up to keep minH, never above topLimit - and
 * only shrinks further when even that doesn't fit. Unchanged (the same object) when its bottom is above the keyboard.
 */
export function fitAboveKeyboard(f: Frame, scale: number, o: Fit): Frame {
  const { kbTop, originY, topLimit, minH } = o;
  if (!Number.isFinite(kbTop)) return f;
  const s = scale > 0 ? scale : 1;
  const top = originY + f.y;
  if (top + f.h * s <= kbTop) return f;
  const room = (kbTop - top) / s;
  if (room >= minH) return { ...f, h: Math.floor(room) };
  // Too little left under its top: up by what's missing, its top never past the limit.
  const want = Math.min(minH, f.h);
  const newTop = Math.max(topLimit, Math.min(top, kbTop - want * s));
  return { ...f, y: newTop - originY, h: Math.max(1, Math.floor(Math.min(f.h, (kbTop - newTop) / s))) };
}

/** The keyboard's top in viewport px from home's insets: [keyboard] px tall at the bottom of a [viewH] px viewport. */
export function keyboardTop(keyboard: number | undefined, viewH: number): number {
  return keyboard && keyboard > 0 ? viewH - keyboard : Infinity;
}
