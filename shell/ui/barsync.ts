/**
 * SI1: home's bar (and the search widget, its face) and the launcher overlay's bar (pull.tsx, its own page) are ONE
 * input (the user, 2026-10-31 01:16: "The text inside the search widget and the launcher should be the same"). The host
 * keeps it (ShellBridge "bar.publish" / "bar.get", the latest by its time) and sends every write to the other windows
 * ("bar.input"). Each page writes what its bar shows - the typed text, or with a dictation the words as heard - and its
 * `query` follows the others' writes, so a dictation in home streams into the launcher, and a send or a clear in either
 * empties both. The cursor stays the focused page's own: a page never gets its own writes back.
 *
 * Only home's page and the overlay's share it. PowOS AI's page compose (aiDraft) is a different conversation surface,
 * with its own draft: it is not this input.
 */
import { batch, effect, signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { query } from "../state.ts";
import type { BarInput } from "../types.ts";

/** Typing is sent this long after the last key (one write per burst); a clear or a dictation's start/end at once. */
const TYPE_MS = 40;

/** Another window's dictation is writing the shared text (its send button shows here too, before its first words). */
export const remoteHearing = signal(false);

/** What this page last wrote or adopted, and its time: the same again isn't written, an older write isn't adopted.
 *  [hearing] is always THIS page's dictation (an adopted write's is remoteHearing): a page showing another's dictation
 *  never writes it back as its own edit. */
let last: BarInput = { text: "", hearing: false, at: 0 };
let timer = 0;
let started = false;

/** Adopts [v] (another window's write, or the host's on load): the field shows it; an edit there ends a dictation here. */
function adopt(v: BarInput | null, endDictation: (at: number) => void) {
  if (!v || typeof v.text !== "string" || v.at < last.at) return;
  last = { text: v.text, hearing: false, at: v.at };
  // One step: the field has the new text before this page's dictation ends, so its end doesn't write the old words.
  batch(() => {
    remoteHearing.value = !!v.hearing;
    query.value = v.text;
    if (!v.hearing) endDictation(v.at);
  });
}

function write(v: BarInput) {
  clearTimeout(timer);
  last = v;
  void powos.bar?.publish(v).catch(() => {});
}

/**
 * Starts the sync for this page's bar, once (bar.tsx Bar): [shown] is what the bar shows (the dictation's words as heard,
 * else the query) and whether a dictation here is writing it; [endDictation] ends this page's dictation, its words
 * already in the shared text, when another window edits, sends or clears it.
 */
export function startBarSync(shown: () => { text: string; hearing: boolean }, endDictation: (at: number) => void) {
  if (started || !powos.bar) return;
  started = true;
  const refresh = () => void powos.bar?.get().then((v) => adopt(v, endDictation), () => {});
  powos.on("bar.input", (v: BarInput | null) => adopt(v, endDictation));
  // A window that slept (the overlay hidden, home under an app) may have missed a write: it asks when it shows again.
  document.addEventListener("visibilitychange", () => void (!document.hidden && refresh()));
  powos.on("pull.begin", refresh);
  refresh();
  effect(() => {
    const { text, hearing } = shown();
    if (text === last.text && hearing === last.hearing) return;
    // This page writes it now: another window's dictation no longer is.
    remoteHearing.value = false;
    const v = { text, hearing, at: Date.now() };
    clearTimeout(timer);
    if (!text || hearing !== last.hearing) write(v);
    else timer = window.setTimeout(() => write({ ...v, at: Date.now() }), TYPE_MS);
  });
}
