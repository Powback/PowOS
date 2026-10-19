/**
 * The bar at the bottom: it finds apps and asks PowOS AI. Tapping it types - the keyboard comes up then, not when the
 * drawer is swiped open, which is for browsing. Enter opens the best match; with none, it asks PowOS AI (chat.tsx).
 * The mic (the Compose prompt bar's): hold to talk, let go to ask PowOS AI; a tap dictates into the field instead,
 * ending at the next pause; held and dragged well away, it's cancelled.
 */
import { useRef } from "preact/hooks";
import { signal } from "@preact/signals";
import { matches } from "./drawer.tsx";
import { ask, drawer, launch, query } from "../state.ts";
import { powos } from "../bridge.ts";

/** A press longer than this is a hold (talk, then send); shorter, a tap (dictate). */
const HOLD_MS = 250;
/** Held and moved this far off the mic: cancelled. */
const CANCEL_PX = 64;

/** What the recognizer hears, as it hears it. */
const speech = signal<{ listening: boolean; text: string; error: string | null }>({ listening: false, text: "", error: null });
/** The recognition under way: a hold sends what's heard, a tap leaves it in the field; typed is what was there. */
let pending: { send: boolean; typed: string } | null = null;
/** It asked for the mic first: the press that asked can't still be held, so a yes dictates. */
let askedMic = false;

const join = (...parts: string[]) => parts.map((p) => p.trim()).filter(Boolean).join(" ");

async function listen(hold: boolean) {
  pending = { send: hold, typed: query.value };
  // The drawer up, to show what comes (the chat, matches), without the keyboard over it.
  drawer.value = 1;
  (document.activeElement as HTMLElement | null)?.blur();
  powos.keyboard.hide();
  navigator.vibrate?.(10);
  const r = await powos.speech.start(hold);
  if (r !== "started") pending = null;
  if (r === "asked") askedMic = true;
}

powos.on("speech.state", (s: { listening: boolean; text: string; error: string | null }) => (speech.value = s));
powos.on("speech.done", ({ text }: { text: string }) => {
  const p = pending;
  pending = null;
  if (!p) return;
  const full = join(p.typed, text);
  if (p.send && text.trim()) ask(full);
  else query.value = full;
});
powos.on("speech.permission", ({ granted }: { granted: boolean }) => {
  if (granted && askedMic) listen(false);
  askedMic = false;
});

function Mic() {
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
          listen(true);
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
        if (!p.held) listen(false);
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

export function Bar() {
  const input = useRef<HTMLInputElement>(null);
  const s = speech.value;
  // While it listens, the field shows what's heard after what was typed.
  const shown = s.listening && pending ? join(pending.typed, s.text) : query.value;
  return (
    <form
      class="bar tile"
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
      <span class="prompt">❯</span>
      <input
        ref={input}
        value={shown}
        onInput={(e) => (query.value = (e.currentTarget as HTMLInputElement).value)}
        placeholder={s.listening ? "listening…" : s.error ?? "find an app or ask AI"}
        enterKeyHint={query.value.trim() && !matches.value.length ? "send" : "go"}
        autocomplete="off"
        autoCapitalize="off"
        spellcheck={false}
      />
      <Mic />
    </form>
  );
}
