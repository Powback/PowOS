/**
 * Home's search as a dock button (state.ts searchInDock; the user, 2026-10-31 01:24-01:26: "instead of being like a
 * bar, it's just like... An app ... placed in like the middle of the dock"). The dock's centre slot (3 apps | the
 * button | 3 apps; an odd count puts the extra one on the right) is a round face with the prompt glyph the bar shows
 * empty (bar.tsx Pill .prompt) and a small mic badge (a hold dictates).
 * A side column (unfolded right / left) has it after its pinned apps instead: the separator between them and the recent
 * ones (the user, 13:31; dockdrop.ts buttonSlot). Unfolded with no choice of its own follows the folded one (state.ts).
 *
 * DS2 (the user, 01:53: "clicking the button The launcher button should open the launcher. and if I hold it It should
 * activate the launcher with the voice button. And then... if I continue holding it, it's push to talk"):
 *  - a tap opens the launcher with its field focused, the keyboard up;
 *  - held HOLD_MS it opens the launcher dictating (the launcher's own bar dictates: its field shows the words);
 *  - still held at PTT_MS it's push-to-talk: let go, the dictation stops and its words stay in the field (not sent);
 *    let go before PTT_MS, the dictation goes on as a tap's (tap the mic to stop);
 *  - a swipe up from it brings the launcher with the finger (the host's pull, driven from here: pull.drive).
 * The launcher opens FROM the button (launchmorph.ts): the overlay's dock has the same slot (dockButton there too), its
 * bar's glass grows out of the button's circle sideways and up into the bar while the panel rises on the launcher
 * swipe's settle; closed, it goes back into the button.
 */
import { useRef } from "preact/hooks";
import { computed } from "@preact/signals";
import { powos } from "../bridge.ts";
import { closeDrawer, dockPosition, drawer, homePage, openPanel, pullKind, pullPage, searchInDock } from "../state.ts";
import { drawerDrag } from "./gesture.ts";
import { wideHome } from "../hosts/wide.ts";
import { dictateBar, focusBar } from "./bar.tsx";
import { speech } from "./dictation.ts";
import { morphFrom } from "./launchmorph.ts";

/** A press on the button held this long dictates (shorter: a tap, which opens the launcher to type). */
const HOLD_MS = 300;
/** Still held this long, it's push-to-talk: let go and the dictation stops (its words stay in the field). */
const PTT_MS = 700;
/** A press that moves this far is the dock's scroll (sideways) or the launcher's swipe (up), not the button's. */
const SLOP_PX = 10;
/** gesture.ts / PanelPull.kt: the panel's openness for a finger's travel (GAIN over TRAVEL of the window's height). */
const GAIN = 1.5;
const TRAVEL = 0.15;
const OPEN_AT = 0.15;
const OPEN_FLICK = 0.2;

/**
 * The button in the dock: home's page, and the launcher overlay's bottom dock over it (pull.tsx), so the overlay's
 * dock lies exactly over home's and the morph starts from its own button (not the desktop's; side/wide docks of the
 * overlay keep their own layout - the morph starts from home's measured rect there).
 */
export const dockButton = computed(() => searchInDock.value && (homePage || (pullPage && dockPosition.value === "bottom" && !wideHome.value)));

/** The button's face on this page, as a rect (the morph's start). */
export function faceRect() {
  const r = document.querySelector(".home .dock .dock-search-face")?.getBoundingClientRect();
  return r && r.width > 0 ? { left: r.left, top: r.top, width: r.width, height: r.height } : undefined;
}

/** Opens the launcher from the button, in place (home's grid adopts its dock and bar; the overlay's own button too). */
function launch(listen: boolean) {
  if (homePage) openPanel("apps");
  return listen ? dictateBar() : focusBar();
}

/** A swipe up from the button: home's own launcher follows the finger (gesture.ts drawerDrag), as its body's swipe does. */
function drive(phase: "begin" | "drag" | "end", arg?: unknown) {
  if (phase === "begin") return void (pullKind.value = "apps", (drawerDrag.value = 0));
  if (phase === "drag") return void (drawerDrag.value = arg as number);
  drawerDrag.value = null;
  if (!arg) return closeDrawer();
  drawer.value = 1;
  focusBar();
}

interface Press {
  x: number;
  y: number;
  hold: number;
  ptt: number;
  /** "tap" (nothing yet), "held" (dictating), "ptt" (push-to-talk), "swipe" (the launcher follows). */
  kind: "tap" | "held" | "ptt" | "swipe";
  last: [number, number];
}

const openness = (y: number, p: Press) => Math.max(0, Math.min(1, ((p.y - y) * GAIN) / (innerHeight * TRAVEL)));
const clear = (p: Press) => (clearTimeout(p.hold), clearTimeout(p.ptt));

/** A finger down: a tap until HOLD_MS (then dictating), push-to-talk from PTT_MS. */
function down(e: PointerEvent): Press {
  try {
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  } catch {
    // A pointer the browser doesn't know as active (synthetic): nothing to capture.
  }
  const p: Press = { x: e.clientX, y: e.clientY, hold: 0, ptt: 0, kind: "tap", last: [e.clientY, performance.now()] };
  p.hold = window.setTimeout(() => {
    p.kind = "held";
    navigator.vibrate?.(10);
    launch(true);
  }, HOLD_MS);
  p.ptt = window.setTimeout(() => {
    if (p.kind !== "held") return;
    p.kind = "ptt";
    // The recognizer goes on through pauses until the release's stop().
    void powos.speech.hold();
    navigator.vibrate?.(5);
  }, PTT_MS);
  return p;
}

/** It moved: the launcher's swipe follows; past the slop a tap is a swipe up (home only) or the dock's (false). */
function move(p: Press, e: PointerEvent): boolean {
  if (p.kind === "swipe") {
    drive("drag", openness(e.clientY, p));
    p.last = [e.clientY, performance.now()];
    return true;
  }
  if (p.kind !== "tap") return true;
  const up = p.y - e.clientY;
  const dx = Math.abs(e.clientX - p.x);
  if (Math.hypot(dx, up) <= SLOP_PX) return true;
  clear(p);
  // Sideways (or on the overlay's own dock): the dock's scroll, not the button's.
  if (!homePage || up <= dx * 1.2) return false;
  p.kind = "swipe";
  drive("begin", { search: true, from: faceRect(), drag: true });
  drive("drag", openness(e.clientY, p));
  p.last = [e.clientY, performance.now()];
  return true;
}

/** Let go (or taken away: [cancelled]). */
function up(p: Press, cancelled: boolean, y: number) {
  clear(p);
  if (p.kind === "tap" && !cancelled) return launch(false);
  // Push-to-talk let go: the dictation stops, its words stay in the launcher's field (its page dictates: its
  // speech.done writes them as a tap's dictation does, never a send). A cancel (the press taken away) too.
  if (p.kind === "ptt") return void powos.speech.stop();
  if (p.kind !== "swipe") return;
  const [ly, lt] = p.last;
  const v = (ly - y) / Math.max(1, performance.now() - lt);
  drive("end", !cancelled && (v > OPEN_FLICK || openness(y, p) > OPEN_AT));
}

/** The button's face: the dock's cell in the centre slot (home.tsx Dock places it). */
export function DockSearchButton() {
  const press = useRef<Press | null>(null);
  const listening = speech.value.listening || !!speech.value.elsewhere;
  const end = (cancelled: boolean, y: number) => {
    const p = press.current;
    press.current = null;
    if (p) up(p, cancelled, y);
  };
  return (
    <div
      class={`app dock-search ${morphFrom.value ? "away" : ""} ${listening ? "on" : ""}`}
      data-key=" search"
      role="button"
      aria-label="search"
      tabIndex={0}
      onPointerDown={(e) => (press.current = down(e))}
      onPointerMove={(e) => press.current && !move(press.current, e) && (press.current = null)}
      onPointerUp={(e) => end(false, e.clientY)}
      onPointerCancel={(e) => end(true, e.clientY)}
      onKeyDown={(e) => (e.key === "Enter" || e.key === " ") && (e.preventDefault(), launch(false))}
    >
      <span class="dock-search-face dsb-glass tile">
        <span class="dock-search-glyph" aria-hidden="true">&gt;</span>
      </span>
      <span class="mic" aria-hidden="true">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
          <rect x="9" y="2" width="6" height="12" rx="3" />
          <path d="M5 11a7 7 0 0 0 14 0M12 18v4M8 22h8" />
        </svg>
      </span>
    </div>
  );
}
