/**
 * The screen's refresh rate while the shell animates without a finger on it. The host asks for the panel's fastest
 * mode only while the page is touched and a moment after (HighRefresh.kt: ColorOS gives an unlisted package 60 Hz
 * otherwise), so a page change's settle, the launcher opening, the shade springing back or the Agents screen's live
 * updates ran at 60. Here, one place for all of them: any CSS animation or transition running holds the fastest
 * mode (PowosNative "boost 1"), given back TAIL ms after the last one ends ("boost 0"; the host holds a moment more).
 * Infinite animations (a spinner, a pulse) never hold it - they would keep 120 Hz on while nothing else moves.
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

function infinite(e: Event): boolean {
  if (!(e instanceof AnimationEvent)) return false;
  const a = (e.target as Element).getAnimations?.().find((x) => (x as CSSAnimation).animationName === e.animationName);
  return a?.effect?.getTiming().iterations === Infinity;
}

function started(e: Event) {
  if (infinite(e)) return;
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
  running = Math.max(0, running - 1);
  if (running === 0) release();
}

if (host) {
  const o = { capture: true, passive: true };
  document.addEventListener("animationstart", started, o);
  document.addEventListener("transitionrun", started, o);
  for (const t of ["animationend", "animationcancel", "transitionend", "transitioncancel"]) document.addEventListener(t, ended, o);
}
