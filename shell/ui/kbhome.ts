/**
 * KB2 (board keyboard-resizes-the-window-but-not-the-content, the user 11-26: "it just bugs the page, it doesn't deal
 * with actual windows, it's like scrolling the wrong thing"): the keyboard's inset is home's (--inset-keyboard, which
 * lifts home's bar and dock and shortens its stage and pages) only while home itself is typing. While it types into a
 * web window, the keyboard is that window's: home stays put under it, and only that window ends at the keyboard's top
 * (webwindows.tsx fitted, ui/kbfit.ts) - its host resizes the app's virtual display / KWin window, as adjustResize does.
 * The device showed home's stage shrinking by the keyboard's height (gate ww-keyboard-fit: 767 -> 447 px) under the
 * window being typed into, its tiles re-laid out: the lift went to the page, not the window.
 *
 * app.tsx hands the host's keyboard height here; webwindows.tsx says whether a window is the one typed into (and calls
 * [applyHomeKeyboard] when that changes with the keyboard still up: a press on a window's body, a home field focused).
 */
let keyboard = 0;
let windowTyping: () => boolean = () => false;

/** The host's keyboard height (CSS px, 0: down), from "system.insets". */
export function setHomeKeyboard(px: number) {
  keyboard = px > 0 ? px : 0;
  applyHomeKeyboard();
}

/** Who says a web window, not home, is typed into (webwindows.tsx, home's page only). */
export function setWindowTyping(fn: () => boolean) {
  windowTyping = fn;
  applyHomeKeyboard();
}

/** --inset-keyboard: the keyboard's height while home types, 0 while a web window does (home stays as it is). */
export function applyHomeKeyboard() {
  const px = keyboard && !windowTyping() ? keyboard : 0;
  const root = document.documentElement.style;
  if (root.getPropertyValue("--inset-keyboard") !== `${px}px`) root.setProperty("--inset-keyboard", `${px}px`);
}
