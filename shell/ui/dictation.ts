/**
 * Dictation, for every field with a mic (bar.tsx's Mic, the pill, the pet, the assistant): the one shared recognizer
 * (Android's, the app's Speech.kt) - what it hears, where the words go (a MicTarget), and how a dictation ends.
 * Continuous: pauses don't end it; a tap's ends after ~4 s with nothing heard (or the next tap), a hold's when let go.
 */
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";

/** What the recognizer hears, as it hears it; [elsewhere]: another window's dictation has the mic (one in the app). */
export interface SpeechState {
  listening: boolean;
  text: string;
  error: string | null;
  elsewhere?: boolean;
}
export const speech = signal<SpeechState>({ listening: false, text: "", error: null });

/** Where a recognition's words go: the field it's for (what was typed before it, and what to do with the whole). */
export interface MicTarget {
  /** What the field held when it started: the words go after it. */
  typed(): string;
  /** The whole text once it ends; [send]: it was held (talk, then send), else a tap (dictate into the field). */
  heard(full: string, send: boolean): void;
  /** It started listening (the bar opens the drawer to show what comes). */
  started?(): void;
}

/** The recognition under way, and whether it sends what's heard; typed is what its field had before it. */
let pending: { send: boolean; typed: string; target: MicTarget; at: number; retried?: boolean } | null = null;
/** It asked for the mic first: the press that asked can't still be held, so a yes dictates. */
let asked: MicTarget | null = null;

const join = (...parts: string[]) => parts.map((p) => p.trim()).filter(Boolean).join(" ");

/** A send tapped while dictating into this target: the recognizer is stopping and its final words are awaited. */
export const finishing = signal<MicTarget | null>(null);
/** The send's wait for those final words; past it, what's heard so far is what's sent. */
const FINISH_MS = 3000;
/** The finishing dictation's promise (one per send, a second tap shares it) and its end. */
let finished: { done: Promise<void>; end: (text?: string) => void } | null = null;

/** What a field shows while it listens: what was typed, then what's heard so far - kept while a send finishes it. */
export const hearing = (target: MicTarget) =>
  (speech.value.listening || finishing.value === target) && pending?.target === target ? join(pending.typed, speech.value.text) : null;

/** In logcat (the page's console): every start, and whose dictation it ends. */
const logStart = (hold: boolean) =>
  console.info(`dictation start (${hold ? "hold" : "tap"})${pending ? " over this page's own" : ""}${speech.value.elsewhere ? " over another window's" : ""}`);

/**
 * In logcat: every end, with why (VS1, the user 2026-11-01 18:26: "it activates and then instantly deactivates") - a
 * stop the user never asked for is visible as its reason, never a silent flicker.
 */
const logEnd = (why: string) =>
  console.info(`dictation end: ${why}${pending ? ` after ${Math.round(performance.now() - pending.at)} ms` : ""}`);

/** A start that ends by itself, nothing heard, this soon (ms) never really listened: one retry, then a message. */
const STILLBORN_MS = 2000;
/** What the field shows when the mic couldn't start (after its one retry). */
const NO_START = "the mic didn't start - tap to try again";

/**
 * Idempotent (VS1): a second start for the dictation under way (the side button's summoning and its own mic, a double
 * tap) is a no-op - never a cancel and a restart, which flickered it off. True: it was one (a hold makes it a hold's).
 */
function already(hold: boolean, target: MicTarget) {
  if (pending?.target !== target || !speech.value.listening) return false;
  console.info(`dictation start (${hold ? "hold" : "tap"}) ignored: already listening for it`);
  if (hold) makeHold(target);
  return true;
}

/** The recognizer didn't start ([r]: asked for the mic, unavailable): the UI lets go of it. */
function notStarted(r: string, target: MicTarget) {
  console.info(`dictation start: ${r}`);
  if (pending?.target === target) pending = null;
  speech.value = { ...speech.value, listening: false };
  if (r === "asked") asked = target;
}

export async function listen(hold: boolean, target: MicTarget) {
  if (already(hold, target)) return;
  // The recognizer first, then the UI: the call is on its way before anything else runs. One dictation at a time
  // (AO3): this start ends any other, here or in another window (the native side's SessionSlot).
  const starting = powos.speech.start(hold);
  logStart(hold);
  pending = { send: hold, typed: target.typed(), target, at: performance.now() };
  // Listening shows in this frame, not when the recognizer reports it.
  speech.value = { listening: true, text: "", error: null };
  target.started?.();
  (document.activeElement as HTMLElement | null)?.blur();
  powos.keyboard.hide();
  navigator.vibrate?.(10);
  const r = await starting;
  if (r !== "started") notStarted(r, target);
}

/**
 * Dictates into [target] as a tap on its mic does (ends after ~4 s of silence), unless it's listening; [send]: its end
 * comes to target.heard as a send (as a held mic's does) - an interruption never does.
 */
export function dictate(target: MicTarget, send = false) {
  // Already this target's (or the mic permission asked): nothing new. A stale "listening" with nothing pending (a
  // dictation that ended unseen) no longer refuses it - the side button's summoning started nothing (AO3).
  if (pending?.target === target || asked) return void console.info(`dictate refused: ${asked ? "mic permission asked" : "already listening for it"}`);
  if (pending) interrupt();
  listen(false, target).then(() => {
    if (send && pending?.target === target) pending.send = true;
  });
}

/**
 * A send (the button, Enter) while one of [targets] dictates (SB3, the user 2026-10-30: "I can't press send like it
 * doesn't disable the transcription and then send"): the recognizer stops, its final words come (speech.done) - or
 * FINISH_MS passes and what's heard so far stands - and the whole goes into the field as a dictation (heard(full,
 * false)); the promise resolves once it's there, so the caller then submits it as Enter does. Not dictating: null.
 */
export function finish(...targets: MicTarget[]): Promise<void> | null {
  if (finished) return finished.done;
  const p = pending;
  if (!p || !targets.includes(p.target)) return null;
  p.send = false;
  // The last partial: a recognizer whose final result comes back empty (stopped mid-word) still sends what showed.
  const partial = speech.value.text;
  let resolve = () => {};
  const done = new Promise<void>((r) => (resolve = r));
  const timer = window.setTimeout(() => finished?.end(), FINISH_MS);
  finished = {
    done,
    end: (text) => {
      clearTimeout(timer);
      finished = null;
      finishing.value = null;
      if (pending === p) {
        pending = null;
        speech.value = { ...speech.value, listening: false };
        // Timed out: the recognizer never ended - let it go.
        if (text === undefined) (logEnd("send: final words timed out"), powos.speech.cancel());
        p.target.heard(join(p.typed, text?.trim() ? text : speech.value.text || partial), false);
      }
      resolve();
    },
  };
  finishing.value = p.target;
  powos.speech.stop();
  return done;
}

/**
 * A send went from a field dictated into by one of [targets] (bar.tsx Pill): nothing of that dictation is left - no
 * pending recognition to write the old words back (hearing() would keep showing them), the mic off. A send still
 * waiting for its final words (finish) is left to finish.
 */
export function settle(...targets: MicTarget[]) {
  if (finished) return;
  const p = pending;
  if (p && targets.includes(p.target)) (logEnd("settled: sent from its field"), (pending = null));
  if (!pending && speech.value.listening) stopNow();
  forgetWords();
}

/** The sent (or cleared) words leave the transcript too: the next mic start never shows them again. */
function forgetWords() {
  if (!pending && speech.value.text) speech.value = { ...speech.value, text: "" };
}

/**
 * SI1: another window started a newer generation of the shared bar (barsync.ts: a send, a clear, an edit over this
 * dictation) while one of [targets] dictates here: its words up to now are already in that text (published as heard),
 * so the dictation ends without writing them back - the recognizer let go, nothing sent, a send waiting here for its
 * final words given up (its field is empty now).
 */
export function drop(...targets: MicTarget[]) {
  const p = pending;
  if (!p || !targets.includes(p.target)) return forgetWords();
  logEnd("dropped: another window edited the bar");
  pending = null;
  stopNow();
  finished?.end("");
  forgetWords();
}

/** [target]'s dictation is under way (or starting). */
export const listeningFor = (target: MicTarget) => pending?.target === target;

/** [target]'s dictation becomes a hold's: it goes on until stop(), and its end is a send. */
export function makeHold(target: MicTarget) {
  if (pending?.target !== target) return void console.info("dictation hold: nothing listening for it");
  pending.send = true;
  powos.speech.hold();
}

/** Forgets [target]'s dictation (it was cancelled): nothing goes to it. */
export function forget(target: MicTarget) {
  if (pending?.target === target) (logEnd("forgotten: cancelled"), (pending = null));
  speech.value = { ...speech.value, listening: false };
}

/** Ends the recognizer and resets the UI in this frame (optimistic; speech.state confirms), whatever state it was in. */
function stopNow() {
  speech.value = { ...speech.value, listening: false };
  powos.speech.cancel();
}

/** A tap on a mic that is listening: it ends now - what's heard goes to its field; a stuck "listening" with nothing pending resets too. */
export function stopTap() {
  if (pending) (logEnd("stop tap"), interrupt(undefined, "stop tap"));
  // Another window's dictation (home's, under the launcher overlay that came up for it): this tap ends it - never a
  // second one (AO3, 2026-10-31 00:11:12: a second tap here started one, superseding home's). Its words go to its field.
  else if (speech.value.elsewhere) (console.info("dictation stop: another window's"), void powos.speech.stop());
  else stopNow();
}

/**
 * Stops listening for [target] (any, without one) without waiting for the end: what's heard so far goes into its field
 * (as a dictation, never sent) - the user started typing, tapped the field, or the field went away.
 */
export function interrupt(target?: MicTarget, why = "interrupted") {
  const p = pending;
  if (p && (!target || p.target === target)) logEnd(why);
  // The mic shows "off" at once, whatever the recognizer reports later (it never reported the end: a stuck button).
  if (!p && !target) return void stopNow();
  if (!p || (target && p.target !== target)) return;
  const now = join(p.typed, speech.value.text);
  pending = null;
  stopNow();
  p.target.heard(now, false);
}

/**
 * Push-to-talk's release: what's been heard up to now - the finished segments and the words still pending in the
 * current one - goes to [target] as a send AT ONCE, and the recognizer is let go. No waiting for its final result (that
 * waited up to 2 s; the partial already holds the last words), no silence, no preview.
 */
export function release(target?: MicTarget) {
  const p = pending;
  if (!p || (target && p.target !== target)) return void console.info("dictation release: nothing listening for it");
  logEnd("released (push-to-talk)");
  const now = join(p.typed, speech.value.text);
  pending = null;
  stopNow();
  p.target.heard(now, !!now.trim());
}

powos.on("speech.state", (s: SpeechState) => (speech.value = s));
// Another window's start ended this page's dictation (one in the app at a time, AO3): no speech.done comes for it.
// What was heard stays in its field; nothing is sent.
powos.on("speech.cancelled", ({ why }: { why: string }) => {
  console.info(`dictation cancelled: ${why}`);
  // A send waiting for its final words: what showed is what's sent.
  if (finished) return finished.end(speech.value.text);
  logEnd(`cancelled by the host: ${why}`);
  const p = pending;
  pending = null;
  speech.value = { ...speech.value, listening: false };
  if (p) p.target.heard(join(p.typed, speech.value.text), false);
});
/**
 * The dictation ended by itself at once, nothing heard (the recognizer busy or refusing - not a stop of ours, which
 * clears pending first): one retry (VS1), and if that dies too the field says so instead of a silent flicker. True: it
 * was handled here.
 */
function stillborn(text: string) {
  const p = pending;
  if (!p || text.trim() || performance.now() - p.at >= STILLBORN_MS) return false;
  const error = speech.value.error ?? "no error";
  if (p.retried) {
    logEnd(`ended by itself at once again (${error}): giving up`);
    pending = null;
    speech.value = { ...speech.value, listening: false, error: speech.value.error ?? NO_START };
    p.target.heard(p.typed, false);
    return true;
  }
  logEnd(`ended by itself at once (${error}): retrying once`);
  p.retried = true;
  p.at = performance.now();
  speech.value = { listening: true, text: "", error: null };
  void powos.speech.start(p.send).then((r) => {
    if (r === "started" || pending !== p) return;
    pending = null;
    speech.value = { ...speech.value, listening: false, error: NO_START };
  });
  return true;
}

powos.on("speech.done", ({ text }: { text: string }) => {
  if (finished) return finished.end(text);
  if (stillborn(text)) return;
  const p = pending;
  logEnd(`done by the recognizer (${text.length} chars)`);
  pending = null;
  speech.value = { ...speech.value, listening: false };
  if (p) p.target.heard(join(p.typed, text), p.send && !!text.trim());
});
// The page went away mid-dictation (the assist closed, an app came up over home): a release that never comes would
// leave the recognizer listening until the native watchdog or cap. What's heard stays in the field; nothing is sent.
// A grace first (VS1): the side button's panel re-attaches its warm page to a new window on every summoning, and the
// page can read hidden for a moment while its new window comes up - an at-once interrupt ended the summoning's
// dictation as it started. Still hidden after the grace: it really went.
const HIDDEN_GRACE_MS = 800;
document.addEventListener("visibilitychange", () => {
  if (!document.hidden || !(pending || speech.value.listening)) return;
  const p = pending;
  window.setTimeout(() => {
    if (document.hidden && pending === p && (pending || speech.value.listening)) interrupt(undefined, "the page went hidden");
  }, HIDDEN_GRACE_MS);
});
powos.on("speech.permission",({ granted }: { granted: boolean }) => {
  if (granted && asked) listen(false, asked);
  asked = null;
});

