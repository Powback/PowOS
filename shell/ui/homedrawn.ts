/**
 * Home alive is not home drawn (10-31 02:50, folded: only the wallpaper and the status bar, "0 fps" - "The UI seems to
 * crashed or something."). __powosAlive was true and no error was reported, but home's window had kept the inner
 * display's 2268x2440 px after a fold (OxygenOS's canvas left its task's bounds): the page laid out at 821x883 on a
 * 404x900 screen, its dock and bar off the screen. [homeBlank] says why home shows nothing, or "" when it is drawn:
 * - the page's viewport is not the screen's (width off by more than 5%, or taller than it: a keyboard only shortens it);
 * - neither the dock nor the bar has a box on the screen.
 * Read by tools/phone/ship-guard.sh (window.__powosHomeBlank, with __powosAlive) and checked here every few seconds
 * while home shows: blank twice in a row is reported through the boot guard (index.html), so `powos shell errors` and
 * the manager hear of it. Hidden home is never judged (it draws nothing on purpose).
 */
const TOL = 0.05;
const EVERY_MS = 3000;

const onScreen = (sel: string, w: number, h: number) =>
  [...document.querySelectorAll<HTMLElement>(sel)].some((el) => {
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && r.right > 0 && r.bottom > 0 && r.left < w && r.top < h && getComputedStyle(el).visibility !== "hidden";
  });

export function homeBlank(): string {
  if (document.hidden || !(screen.width > 0)) return "";
  const vw = innerWidth, vh = innerHeight, sw = screen.width, sh = screen.height;
  if (Math.abs(vw - sw) > sw * TOL || vh > sh * (1 + TOL)) return `viewport ${vw}x${vh} is not the screen's ${sw}x${sh}`;
  if (!document.querySelector(".home")) return "no .home on the page";
  // The dock (or the bar, which the dock's search face replaces on some layouts) inside the screen's own box.
  if (!onScreen(".home .dock:not(.dock-tray), .home .bar", Math.min(vw, sw), Math.min(vh, sh))) return `neither the dock nor the bar on the ${sw}x${sh} screen`;
  return "";
}

export function watchHomeDrawn() {
  (window as unknown as { __powosHomeBlank?: () => string }).__powosHomeBlank = homeBlank;
  let prev = "", told = "";
  setInterval(() => {
    const why = homeBlank();
    // Twice in a row: a fold's resize lands before window.screen catches up (wide.ts screenNow), never one check.
    if (why && prev && why !== told) {
      told = why;
      const boot = (window as unknown as { __powosBoot?: { report: (kind: string, err: unknown) => void } }).__powosBoot;
      boot?.report("blank", new Error(`home is blank: ${why}`));
    }
    if (!why) told = "";
    prev = why;
  }, EVERY_MS);
}
