/**
 * The bar at the bottom: it finds apps and asks PowOS AI. Tapping it types - the keyboard comes up then, not when the
 * drawer is swiped open, which is for browsing. Enter opens the best match; with none, it asks PowOS AI (chat.tsx).
 * The mic (the Compose prompt bar's): hold to talk, let go to ask PowOS AI; a tap dictates into the field instead,
 * ending at the next pause; held and dragged well away, it's cancelled.
 */
import { useRef, useState } from "preact/hooks";
import { GrowField } from "./grow.tsx";
import { signal } from "@preact/signals";
import { matches } from "./drawer.tsx";
import { ask, drawer, launch, query } from "../state.ts";
import { powos } from "../bridge.ts";

/** A press longer than this is a hold (talk, then send); shorter, a tap (dictate). */
const HOLD_MS = 250;
/** Held and moved this far off the mic: cancelled. */
const CANCEL_PX = 64;

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

async function listen(hold: boolean, target: MicTarget) {
  pending = { send: hold, typed: target.typed(), target };
  target.started?.();
  (document.activeElement as HTMLElement | null)?.blur();
  powos.keyboard.hide();
  navigator.vibrate?.(10);
  const r = await powos.speech.start(hold);
  if (r !== "started") pending = null;
  if (r === "asked") asked = target;
}

/** Dictates into [target] as a tap on its mic does (ends at the next pause, nothing is sent), unless it's listening. */
export function dictate(target: MicTarget) {
  if (pending || asked || speech.value.listening) return;
  listen(false, target);
}

/**
 * Stops listening for [target] without waiting for the end: what's heard so far goes into its field (as a dictation,
 * never sent) - the user started typing, tapped the field, or the field went away.
 */
export function interrupt(target: MicTarget) {
  const p = pending;
  if (!p || p.target !== target) return;
  const now = join(p.typed, speech.value.text);
  pending = null;
  powos.speech.cancel();
  p.target.heard(now, false);
}

powos.on("speech.state", (s: { listening: boolean; text: string; error: string | null }) => (speech.value = s));
powos.on("speech.done", ({ text }: { text: string }) => {
  const p = pending;
  pending = null;
  if (p) p.target.heard(join(p.typed, text), p.send && !!text.trim());
});
powos.on("speech.permission", ({ granted }: { granted: boolean }) => {
  if (granted && asked) listen(false, asked);
  asked = null;
});

/** A mic for [target]: hold to talk and send, tap to dictate; held and dragged well away, cancelled. */
export function Mic({ target }: { target: MicTarget }) {
  const press = useRef<{ x: number; y: number; timer: number; held: boolean; cancelled: boolean } | null>(null);
  const on = speech.value.listening;
  return (
    <button
      type="button"
      class={`mic ${on ? "on" : ""}`}
      aria-label="speak"
      onClick={(e) => e.stopPropagation()}
      onPointerDown={(e) => {
        e.stopPropagation();
        (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
        // Listening already (a tap's dictation): this press ends it.
        if (on) {
          press.current = null;
          powos.speech.stop();
          return;
        }
        const p = { x: e.clientX, y: e.clientY, timer: 0, held: false, cancelled: false };
        p.timer = window.setTimeout(() => {
          p.held = true;
          listen(true, target);
        }, HOLD_MS);
        press.current = p;
      }}
      onPointerMove={(e) => {
        const p = press.current;
        if (!p?.held || p.cancelled) return;
        if (Math.hypot(e.clientX - p.x, e.clientY - p.y) > CANCEL_PX) {
          p.cancelled = true;
          pending = null;
          powos.speech.cancel();
          navigator.vibrate?.(5);
        }
      }}
      onPointerUp={() => {
        const p = press.current;
        press.current = null;
        if (!p) return;
        clearTimeout(p.timer);
        if (!p.held) listen(false, target);
        else if (!p.cancelled) powos.speech.stop();
      }}
      onPointerCancel={() => {
        const p = press.current;
        press.current = null;
        if (p) clearTimeout(p.timer);
      }}
    >
      <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
        <rect x="9" y="2" width="6" height="12" rx="3" />
        <path d="M5 11a7 7 0 0 0 14 0M12 18v4M8 22h8" />
      </svg>
    </button>
  );
}

/** The bar's field: a held mic asks PowOS AI, a tap dictates into the search; the drawer comes up to show either. */
const barMic: MicTarget = {
  typed: () => query.value,
  heard: (full, send) => (send ? ask(full) : (query.value = full)),
  started: () => (drawer.value = 1),
};

/**
 * The search/ask bar. At rest it's no surface at all - a faint "› search" and the mic over the wallpaper; focused,
 * holding text or dictating, it becomes a lifted glass pill (a .tile: frosted, the native blur's region too), whose
 * field grows to three rows (ui/grow.tsx) upward over home without moving anything under it.
 */
export function Bar() {
  const input = useRef<HTMLTextAreaElement>(null);
  const [focused, setFocused] = useState(false);
  const s = speech.value;
  // While it listens, the field shows what's heard after what was typed.
  const shown = hearing(barMic) ?? query.value;
  const active = focused || !!shown || s.listening;
  return (
    <form
      class={`bar ${active ? "active" : ""}`}
      onSubmit={(e) => {
        e.preventDefault();
        const best = matches.value[0];
        if (best) launch(best.key);
        else ask(query.value);
      }}
      onClick={() => {
        drawer.value = 1;
        input.current?.focus();
        powos.keyboard.show();
      }}
    >
      {/* The pill: its own box over the bar's place, growing upward - the bar's height (home's layout) never changes. */}
      <div class={`bar-pill ${active ? "tile" : ""}`}>
        <span class="prompt">❯</span>
        <GrowField
          inputRef={input}
          value={shown}
          onInput={(v) => (query.value = v)}
          onFocus={() => setFocused(true)}
          onBlur={() => setFocused(false)}
          placeholder={s.listening ? "listening…" : s.error ?? "search"}
          enterKeyHint={query.value.trim() && !matches.value.length ? "send" : "go"}
          autocomplete="off"
          autoCapitalize="off"
          spellcheck={false}
        />
        <Mic target={barMic} />
      </div>
    </form>
  );
}
