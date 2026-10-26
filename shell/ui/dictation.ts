/**
 * Dictation, for every field with a mic (bar.tsx's Mic, the pill, the pet, the assistant): the one shared recognizer
 * (Android's, the app's Speech.kt) - what it hears, where the words go (a MicTarget), and how a dictation ends.
 * Continuous: pauses don't end it; a tap's ends after ~4 s with nothing heard (or the next tap), a hold's when let go.
 */
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";

/** What the recognizer hears, as it hears it. */
export const speech = signal<{ listening: boolean; text: string; error: string | null }>({ listening: false, text: "", error: null });

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
let pending: { send: boolean; typed: string; target: MicTarget } | null = null;
/** It asked for the mic first: the press that asked can't still be held, so a yes dictates. */
let asked: MicTarget | null = null;

const join = (...parts: string[]) => parts.map((p) => p.trim()).filter(Boolean).join(" ");

/** What a field shows while it listens: what was typed, then what's heard so far. */
export const hearing = (target: MicTarget) => (speech.value.listening && pending?.target === target ? join(pending.typed, speech.value.text) : null);

export async function listen(hold: boolean, target: MicTarget) {
  // The recognizer first, then the UI: the call is on its way before anything else runs.
  const starting = powos.speech.start(hold);
  pending = { send: hold, typed: target.typed(), target };
  // Listening shows in this frame, not when the recognizer reports it.
  speech.value = { listening: true, text: "", error: null };
  target.started?.();
  (document.activeElement as HTMLElement | null)?.blur();
  powos.keyboard.hide();
  navigator.vibrate?.(10);
  const r = await starting;
  if (r !== "started") {
    if (pending?.target === target) pending = null;
    speech.value = { ...speech.value, listening: false };
  }
  if (r === "asked") asked = target;
}

/**
 * Dictates into [target] as a tap on its mic does (ends after ~4 s of silence), unless it's listening; [send]: its end
 * comes to target.heard as a send (as a held mic's does) - an interruption never does.
 */
export function dictate(target: MicTarget, send = false) {
  if (pending || asked || speech.value.listening) return;
  listen(false, target).then(() => {
    if (send && pending?.target === target) pending.send = true;
  });
}

/** [target]'s dictation is under way (or starting). */
export const listeningFor = (target: MicTarget) => pending?.target === target;

/** [target]'s dictation becomes a hold's: it goes on until stop(), and its end is a send. */
export function makeHold(target: MicTarget) {
  if (pending?.target !== target) return;
  pending.send = true;
  powos.speech.hold();
}

/** Forgets [target]'s dictation (it was cancelled): nothing goes to it. */
export function forget(target: MicTarget) {
  if (pending?.target === target) pending = null;
}

/**
 * Stops listening for [target] (any, without one) without waiting for the end: what's heard so far goes into its field
 * (as a dictation, never sent) - the user started typing, tapped the field, or the field went away.
 */
export function interrupt(target?: MicTarget) {
  const p = pending;
  if (!p || (target && p.target !== target)) return;
  const now = join(p.typed, speech.value.text);
  pending = null;
  powos.speech.cancel();
  p.target.heard(now, false);
}

/**
 * Push-to-talk's release: what's been heard up to now - the finished segments and the words still pending in the
 * current one - goes to [target] as a send AT ONCE, and the recognizer is let go. No waiting for its final result (that
 * waited up to 2 s; the partial already holds the last words), no silence, no preview.
 */
export function release(target?: MicTarget) {
  const p = pending;
  if (!p || (target && p.target !== target)) return;
  const now = join(p.typed, speech.value.text);
  pending = null;
  powos.speech.cancel();
  p.target.heard(now, !!now.trim());
}

powos.on("speech.state", (s: { listening: boolean; text: string; error: string | null }) => (speech.value = s));
powos.on("speech.done", ({ text }: { text: string }) => {
  const p = pending;
  pending = null;
  if (p) p.target.heard(join(p.typed, text), p.send && !!text.trim());
});
// The page went away mid-dictation (the assist closed, an app came up over home): a release that never comes would
// leave the recognizer listening until the native watchdog or cap. What's heard stays in the field; nothing is sent.
document.addEventListener("visibilitychange", () => {
  if (document.hidden && pending) interrupt();
});
powos.on("speech.permission",({ granted }: { granted: boolean }) => {
  if (granted && asked) listen(false, asked);
  asked = null;
});

