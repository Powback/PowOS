/**
 * SI1: home's bar (and the search widget, its face) and the launcher overlay's bar (pull.tsx, its own page) are ONE
 * input (the user, 2026-10-31 01:16: "The text inside the search widget and the launcher should be the same"). The host
 * keeps it (ShellBridge "bar.publish" / "bar.get") and sends every write it keeps to the other windows ("bar.input").
 * Each page writes what its bar shows - the typed text, or with a dictation the words as heard - and its `query`
 * follows the others' writes, so a dictation in home streams into the launcher, and a send or a clear in either empties
 * both. The cursor stays the focused page's own: a page never gets its own writes back.
 *
 * Order-proof, not timing-proof:
 *  - [seq]: the host numbers every write it keeps. A page adopts a state only if its seq is newer than the one it knows,
 *    so late or reordered deliveries (a broadcast, a write's answer, a get) never put an older text back.
 *  - [gen]: a clear (a send, an emptied field) or an edit over another window's dictation starts a new generation. The
 *    host refuses any write from an older one, so words a dictation heard before it (a late partial, its final result)
 *    never come back; the dictating page ends that dictation when it adopts the newer generation.
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

/**
 * What this page knows: the last state it adopted ([own] false: its seq is the host's), or wrote ([own]: seq is still the
 * one before it, until the host's answer). [hearing] is always THIS page's dictation (an adopted one's is remoteHearing).
 */
type Known = { text: string; hearing: boolean; gen: number; seq: number; own: boolean };
let last: Known = { text: "", hearing: false, gen: 0, seq: 0, own: false };
let timer = 0;
let started = false;

/** Adopts [v] if the host kept it after what this page knows: the field shows it; a newer generation ends a dictation here. */
function adopt(v: BarInput | null, endDictation: () => void) {
  if (!v || typeof v.text !== "string" || !(v.seq > last.seq)) return;
  const newer = v.gen > last.gen;
  clearTimeout(timer);
  timer = 0;
  last = { text: v.text, hearing: false, gen: v.gen, seq: v.seq, own: false };
  // One step: the field has the new text before this page's dictation ends, so its end writes nothing old.
  batch(() => {
    remoteHearing.value = !!v.hearing;
    query.value = v.text;
    if (newer) endDictation();
  });
}

/** Sends [sent] (this page's latest write); the host's answer is what it kept, or its newer state if it refused it. */
function send(sent: Known, endDictation: () => void) {
  timer = 0;
  void powos.bar
    ?.publish({ text: sent.text, hearing: sent.hearing, gen: sent.gen, seq: 0 })
    .then((r) => {
      if (!r) return;
      // Kept and still this page's latest: only its number is new.
      if (last === sent && r.gen === sent.gen && r.text === sent.text) return void (last.seq = Math.max(last.seq, r.seq));
      // Refused (a newer generation), or adopted something older meanwhile: the host's state stands.
      if (!last.own || r.gen > last.gen) adopt(r, endDictation);
    })
    .catch(() => {});
}

/**
 * Starts the sync for this page's bar, once (bar.tsx Bar): [shown] is what the bar shows (the dictation's words as heard,
 * else the query) and whether a dictation here is writing it; [endDictation] ends this page's dictation without writing
 * its words back, when another window starts a newer generation (a send, a clear, an edit over it).
 */
export function startBarSync(shown: () => { text: string; hearing: boolean }, endDictation: () => void) {
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
    // A clear, or an edit over another window's dictation: a new generation - that dictation's later words are refused.
    const bump = (!text && !!last.text) || (!hearing && remoteHearing.peek());
    const now = !text || bump || hearing !== last.hearing;
    remoteHearing.value = false;
    const sent: Known = { text, hearing, gen: last.gen + (bump ? 1 : 0), seq: last.seq, own: true };
    last = sent;
    clearTimeout(timer);
    if (now) send(sent, endDictation);
    else timer = window.setTimeout(() => send(sent, endDictation), TYPE_MS);
  });
}
