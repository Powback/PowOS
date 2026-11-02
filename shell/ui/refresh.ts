/**
 * The screen's refresh rate while the shell animates without a finger on it. The host asks for the panel's fastest
 * mode only while the page is touched and a moment after (HighRefresh.kt: ColorOS gives an unlisted package 60 Hz
 * otherwise), so a page change's settle, the launcher opening, the shade springing back or the Agents screen's live
 * updates ran at 60. Here, one place for all of them: any CSS animation or transition running holds the fastest
 * mode (PowosNative "boost 1"), given back TAIL ms after the last one ends ("boost 0"; the host holds a moment more).
 * Infinite animations (a spinner, a pulse) never hold it - they would keep 120 Hz on while nothing else moves.
 *
 * Web Animations (element.animate) fire none of those events, and the shell's gesture settles run on them: the
 * launcher's drawer after the finger lets go (gesture.ts "drawer"), the overpull spring-back, the shade's peek, the
 * launch morph. So a named one (its options' `id`: the shell's own motions, not the pet's idle hops) that is playing
 * holds the fastest mode too until it finishes or is cancelled; one paused at its start (a finger scrubbing it) holds
 * nothing - the host's own touch vote covers the finger (HighRefresh.kt).
 */
const TAIL = 300;
/** A running count that lost its end events (an element removed mid-animation fires none): reset after this. */
const STALE = 2500;

type Native = { postMessage(text: string): void };
const host = (window as unknown as { PowosNative?: Native }).PowosNative;

let on = false;
let running = 0;
let tail = 0;
let stale = 0;

function send(v: boolean) {
  if (v === on) return;
  on = v;
  try {
    host?.postMessage(v ? "boost 1" : "boost 0");
  } catch {
    // An older APK without the verb: nothing to hold.
  }
}

function release() {
  clearTimeout(tail);
  tail = window.setTimeout(() => running <= 0 && send(false), TAIL);
}

/** Something moved on the page that no animation event tells of (a live update): fastest for a moment. */
export function holdRefresh() {
  if (!host) return;
  send(true);
  if (running <= 0) release();
}

/**
 * An animation that never ends by time: infinite, or driven by a scroll (animation-timeline: scroll(), the lists' edge
 * fades in shell.css) - "running" for as long as its element lives, so it held the fastest mode until STALE each time a
 * list mounted (the drawer open: 2 s of 120 Hz with nothing moving, perf-1793639664326). The scroll itself is a finger's.
 */
function ambient(a: Animation | undefined): boolean {
  if (!a) return false;
  if (a.effect?.getTiming().iterations === Infinity) return true;
  return !!a.timeline && !(a.timeline instanceof DocumentTimeline);
}

function infinite(e: Event): boolean {
  if (!(e instanceof AnimationEvent)) return false;
  return ambient((e.target as Element).getAnimations?.().find((x) => (x as CSSAnimation).animationName === e.animationName));
}

function started(e: Event) {
  if (infinite(e)) return;
  begin();
}

function begin() {
  running++;
  clearTimeout(tail);
  send(true);
  clearTimeout(stale);
  stale = window.setTimeout(() => {
    running = 0;
    release();
  }, STALE);
}

function ended(e: Event) {
  if (infinite(e)) return;
  finish();
}

function finish() {
  running = Math.max(0, running - 1);
  if (running === 0) release();
}

if (host) {
  const o = { capture: true, passive: true };
  document.addEventListener("animationstart", started, o);
  document.addEventListener("transitionrun", started, o);
  for (const t of ["animationend", "animationcancel", "transitionend", "transitioncancel"]) document.addEventListener(t, ended, o);
}

/** A Web Animation the shell started: held while it plays when it's a named, finite one (see the top). */
function watchAnimation(a: Animation, options: unknown) {
  if (!options || typeof options !== "object" || !(options as KeyframeAnimationOptions).id) return;
  // Next microtask: a scrubbed one is paused right after its animate() (gesture.ts followerOf).
  queueMicrotask(() => {
    if (a.playState !== "running") return;
    if (ambient(a) || !(Number(a.effect?.getComputedTiming().endTime) > 0)) return;
    begin();
    a.finished.then(finish, finish);
  });
}

if (host) {
  const animate = Element.prototype.animate;
  Element.prototype.animate = function (this: Element, ...args: Parameters<Element["animate"]>) {
    const a = animate.apply(this, args);
    watchAnimation(a, args[1]);
    return a;
  };
}
