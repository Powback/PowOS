/**
 * The bar at the bottom: it finds apps and asks PowOS AI. Tapping it types - the keyboard comes up then, not when the
 * drawer is swiped open, which is for browsing. Enter opens the best match; with none, it asks PowOS AI (chat.tsx).
 * The mic (the Compose prompt bar's): hold to talk, let go to ask PowOS AI; a tap dictates into the field instead,
 * until ~4 s with nothing heard or the next tap (pauses don't end either); held and dragged well away, it's cancelled.
 * It listens from the moment the finger lands: a press that lasts becomes a hold (speech.hold) - no first words lost
 * to deciding which it is.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { GrowField } from "./grow.tsx";
import { matches } from "./drawer.tsx";
import { drawer, launch, pullKind, query } from "../state.ts";
import { powos } from "../bridge.ts";
import { askQueued, pillTarget, sending, takeOver } from "./assistant.ts";
import { forget, hearing, listen, listeningFor, makeHold, speech, type MicTarget } from "./dictation.ts";

/** A press longer than this is a hold (talk, then send); shorter, a tap (dictate). */
const HOLD_MS = 250;
/** Held and moved this far off the mic: cancelled. */
const CANCEL_PX = 64;

export { dictate, hearing, interrupt, speech, type MicTarget } from "./dictation.ts";

/** A mic for [target]: hold to talk and send, tap to dictate; held and dragged well away, cancelled. */
export function Mic({ target }: { target: MicTarget }) {
  const press = useRef<{ x: number; y: number; timer: number; held: boolean; cancelled: boolean } | null>(null);
  const on = speech.value.listening || listeningFor(target);
  // Shown: the recognizer bound and ready (it doesn't listen), so a press starts at once.
  useEffect(() => void powos.speech.warm(), []);
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
        // Listens now, as a tap's dictation; still down after HOLD_MS, it's a hold: it sends when let go.
        const p = { x: e.clientX, y: e.clientY, timer: 0, held: false, cancelled: false };
        listen(false, target);
        p.timer = window.setTimeout(() => {
          p.held = true;
          makeHold(target);
        }, HOLD_MS);
        press.current = p;
      }}
      onPointerMove={(e) => {
        const p = press.current;
        if (!p?.held || p.cancelled) return;
        if (Math.hypot(e.clientX - p.x, e.clientY - p.y) > CANCEL_PX) {
          p.cancelled = true;
          forget(target);
          powos.speech.cancel();
          navigator.vibrate?.(5);
        }
      }}
      onPointerUp={() => {
        const p = press.current;
        press.current = null;
        if (!p) return;
        clearTimeout(p.timer);
        // A hold ends (and sends) when let go; a tap's dictation goes on until its silence or the next tap.
        if (p.held && !p.cancelled) powos.speech.stop();
      }}
      onPointerCancel={() => {
        const p = press.current;
        press.current = null;
        if (!p) return;
        clearTimeout(p.timer);
        // The press was taken away (the panel went, a gesture): a hold must not stay listening without its release.
        if (p.held && !p.cancelled) powos.speech.stop();
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
  heard: (full, send) => (send ? askHere(full) : (query.value = full)),
  started: () => openHere(),
};

/** Up from the pill: the drawer, unless the pull-up panel is already up (PowOS AI's stays). */
function openHere() {
  if (drawer.value === 0) pullKind.value = "apps";
  drawer.value = 1;
}

/** Asked from the pill: the one chat surface (the drawer's chat) takes it - from PowOS AI's panel too. */
function askHere(text: string) {
  pullKind.value = "apps";
  askQueued(text);
}

/**
 * The search/ask bar: the pill PowOS AI's page asks in (shell.css .pill - the reference material, the field growing to
 * three rows upward over home without moving anything under it, the mic on its right), "search" its placeholder.
 */
export function Bar() {
  const input = useRef<HTMLTextAreaElement>(null);
  const [focused, setFocused] = useState(false);
  const s = speech.value;
  // While it listens, the field shows what's heard after what was typed.
  // The assistant's dictation (the side button, the pet) writes into this field too.
  const shown = hearing(barMic) ?? hearing(pillTarget) ?? query.value;
  const active = focused || !!shown || s.listening;
  return (
    <form
      class={`bar ${active ? "active" : ""}`}
      onSubmit={(e) => {
        e.preventDefault();
        const best = pullKind.value === "apps" ? matches.value[0] : null;
        if (best) launch(best.key);
        else askHere(query.value);
      }}
      onClick={() => {
        openHere();
        input.current?.focus();
        powos.keyboard.show();
      }}
    >
      {/* The pill (shell.css .pill, as PowOS AI's compose): its own box over the bar's place, growing upward - the bar's
          height (home's layout) never changes. */}
      <div class={`bar-pill pill tile ${sending.value ? "sending" : ""}`}>
        <GrowField
          inputRef={input}
          value={shown}
          onInput={(v) => {
            // Typing over a dictation: it stops, what it heard stays (and nothing sends by itself).
            takeOver();
            query.value = v;
          }}
          onFocus={() => (takeOver(), setFocused(true))}
          onBlur={() => setFocused(false)}
          placeholder={s.listening ? "listening…" : (s.error ?? (pullKind.value === "ai" && drawer.value > 0 ? "ask PowOS AI" : "search"))}
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
