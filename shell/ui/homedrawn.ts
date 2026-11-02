/**
 * Home alive is not home drawn (10-31 02:50, folded: only the wallpaper and the status bar, "0 fps" - "The UI seems to
 * crashed or something."). __powosAlive was true and no error was reported, but home's window had kept the inner
 * display's 2268x2440 px after a fold (OxygenOS's canvas left its task's bounds): the page laid out at 821x883 on a
 * 404x900 screen, its dock and bar off the screen. [homeBlank] says why home shows nothing, or "" when it is drawn:
 * - the page's viewport is not the screen's (width off by more than 5%, or taller than it: a keyboard only shortens it);
 * - neither the dock nor the bar has a box on the screen - unless a full-screen sheet covers them on purpose ([covered]).
 * Read by tools/phone/ship-guard.sh (window.__powosHomeBlank, with __powosAlive) and checked here every few seconds
 * while home shows: blank twice in a row is reported through the boot guard (index.html), so `powos shell errors` and
 * the manager hear of it. Hidden home is never judged (it draws nothing on purpose).
 */
import { drawerOpen, notifOpen } from "./gesture.ts";
import { editing, page, pullPage } from "../state.ts";
import { screens } from "../screens.ts";

const TOL = 0.05;
const EVERY_MS = 3000;

const onScreen = (sel: string, w: number, h: number) =>
  [...document.querySelectorAll<HTMLElement>(sel)].some((el) => {
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && r.right > 0 && r.bottom > 0 && r.left < w && r.top < h && getComputedStyle(el).visibility !== "hidden";
  });

/**
 * What covers home by design, from the signals that open it: Settings (and the screens over it), edit mode, the launcher
 * in place (home's .adopts drawer; the pull window is not home, never judged), the shade. The PowOS AI page (page -1)
 * slides the dock off: homeBlank judges it by its own box.
 */
const covered = () => screens.value.length > 0 || editing.value || drawerOpen.value || notifOpen.value || layered();

/**
 * Any other full-screen layer, generically (11-01 06:13: an App API page, p:<id>, over home folded - not in the list
 * above): the topmost element in the middle and near the bottom of the screen is not part of .home, so home isn't what
 * shows. Only a page element counts as a cover: an empty point (html/body) is judged, as a blank home would be.
 */
function layered(): boolean {
  const pts = [[0.5, 0.5], [0.5, 0.92]];
  return pts.some(([fx, fy]) => {
    const el = document.elementFromPoint(innerWidth * fx, innerHeight * fy);
    return !!el && el !== document.body && el !== document.documentElement && !el.closest(".home");
  });
}

/** PowOS AI's page (page -1) not on the [sw]x[sh] screen: why, or "". */
function aiPageOff(sw: number, sh: number) {
  return onScreen(".ai-screen", Math.min(innerWidth, sw), Math.min(innerHeight, sh)) ? "" : `the PowOS AI page is not on the ${sw}x${sh} screen`;
}

export function homeBlank(): string {
  if (document.hidden || pullPage || !(screen.width > 0)) return "";
  const vw = innerWidth, vh = innerHeight, sw = screen.width, sh = screen.height;
  if (Math.abs(vw - sw) > sw * TOL || vh > sh * (1 + TOL)) return `viewport ${vw}x${vh} is not the screen's ${sw}x${sh}`;
  if (!document.querySelector(".home")) return "no .home on the page";
  // A full-screen sheet over home hides its dock and bar on purpose (false "blank"s: 10-31 14:14 the AI page, 20:05
  // Settings › style): judged only when home itself shows.
  // The PowOS AI page (page -1) slides the dock off on purpose: judged by its own box instead. Exempting it outright
  // hid a blank screen (11-02 21:55, RT1: "I rotated my phone and know it's in a bad state" - only the status bar
  // showed, home's DOM on the AI page, nothing reported, and the user rebooted).
  if (page.value < 0) return aiPageOff(sw, sh);
  if (covered()) return "";
  // The dock (or the bar, which the dock's search face replaces on some layouts) inside the screen's own box.
  if (!onScreen(".home .dock:not(.dock-tray), .home .bar", Math.min(vw, sw), Math.min(vh, sh))) return `neither the dock nor the bar on the ${sw}x${sh} screen`;
  return "";
}

const rect = (q: string) => {
  const r = document.querySelector(q)?.getBoundingClientRect();
  return r ? [r.left, r.top, r.right, r.bottom].map(Math.round).join(",") : "none";
};

/**
 * What home's page looks like now, for the evidence of a blank (RT1, 11-02 21:55: the user rebooted, logcat was gone):
 * the viewport, window.screen, the page, the AI page's and home's boxes. In the blank report (the host's BlankCapture
 * writes it with logcat into powos-ai-shared/blank-<ts>.txt) and window.__powosHomeState (tools/phone/verify/rotate-repro.sh).
 */
export function homeState() {
  return { w: innerWidth, h: innerHeight, sw: screen.width, sh: screen.height, dpr: devicePixelRatio, o: screen.orientation?.type ?? "", page: page.value, hidden: document.hidden, ai: rect(".ai-screen"), home: rect(".home") };
}

export function watchHomeDrawn() {
  (window as unknown as { __powosHomeBlank?: () => string }).__powosHomeBlank = homeBlank;
  (window as unknown as { __powosHomeState?: () => ReturnType<typeof homeState> }).__powosHomeState = homeState;
  let prev = "", told = "";
  setInterval(() => {
    const why = homeBlank();
    // Twice in a row: a fold's resize lands before window.screen catches up (wide.ts screenNow), never one check.
    if (why && prev && why !== told) {
      told = why;
      const boot = (window as unknown as { __powosBoot?: { report: (kind: string, err: unknown) => void } }).__powosBoot;
      boot?.report("blank", new Error(`home is blank: ${why} | state ${JSON.stringify(homeState())}`));
    }
    if (!why) told = "";
    prev = why;
  }, EVERY_MS);
}
