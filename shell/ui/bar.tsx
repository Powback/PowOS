/**
 * The bar at the bottom: it finds apps and asks PowOS AI. Tapping it types - the keyboard comes up then, not when the
 * drawer is swiped open, which is for browsing. Enter opens the best match; with none, it asks PowOS AI (chat.tsx).
 * The mic (the Compose prompt bar's): hold to talk, let go to ask PowOS AI; a tap dictates into the field instead,
 * until ~4 s with nothing heard or the next tap (pauses don't end either); held and dragged well away, it's cancelled.
 * It listens from the moment the finger lands: a press that lasts becomes a hold (speech.hold) - no first words lost
 * to deciding which it is.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import type { Ref } from "preact";
import { GrowField } from "./grow.tsx";
import { Icon } from "./icons.tsx";
import { searchResults, searchPending, openSearchResult } from "../search.ts";
import { followOpenness } from "./gesture.ts";
import { chatting, drawer, launcherIsOverlay, openPanel, pullKind, query } from "../state.ts";
import { powos } from "../bridge.ts";
import { askQueued, pillTarget, sending, takeOver } from "./assistant.ts";
import { forget, hearing, listen, listeningFor, makeHold, release, speech, stopTap, type MicTarget } from "./dictation.ts";

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
          stopTap();
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
        // Push to talk: let go, and what's heard is sent at once (release); a tap's dictation goes on until its
        // silence or the next tap.
        if (p.held && !p.cancelled) release(target);
      }}
      onPointerCancel={() => {
        const p = press.current;
        press.current = null;
        if (!p) return;
        clearTimeout(p.timer);
        // The press was taken away (the panel went, a gesture): a hold must not stay listening without its release.
        if (p.held && !p.cancelled) release(target);
      }}
    >
      <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
        <rect x="9" y="2" width="6" height="12" rx="3" />
        <path d="M5 11a7 7 0 0 0 14 0M12 18v4M8 22h8" />
      </svg>
    </button>
  );
}

/**
 * The pill (shell.css .pill): THE compose field - home's search, PowOS AI's page, the side button's panel. Its field
 * grows to three rows, then scrolls inside, newest words in view (grow.tsx); the mic on its right ([target]: hold to
 * talk and send, tap to dictate). [value] is what it shows - the caller passes hearing(target) ?? its text, so what's
 * heard streams in as it's said and stays editable. [sending]: an autosend's words, about to go.
 */
/** The search field's blur, in logcat: who took the focus (relatedTarget), whether the field was unmounted, and the
 *  stack (a re-mount or a focus() elsewhere) - the keyboard went down ~0.9 s after it came up in wide home (2026-10-28). */
function logBlur(e: FocusEvent, field: HTMLTextAreaElement | null) {
  const to = e.relatedTarget as HTMLElement | null;
  const name = to ? `${to.tagName.toLowerCase()}.${String(to.className).split(" ").join(".")}` : "none";
  console.info(`search blur to=${name} connected=${!!field?.isConnected} drawer=${drawer.value} windowFocus=${document.hasFocus()}`);
  console.trace("search blur");
}

/**
 * Send, right of the mic while the field has text ([shown]): the form's submit, so it does exactly what Enter does
 * (grow.tsx requestSubmit -> the form's onSubmit) without the keyboard. Empty, it folds to nothing (shell.css .pill
 * .send: width and opacity), so the empty pill's layout is the one it always had.
 */
function Send({ shown }: { shown: boolean }) {
  return (
    <button
      type="submit"
      class={`send ${shown ? "shown" : ""}`}
      aria-label="send"
      aria-hidden={!shown || undefined}
      tabIndex={shown ? undefined : -1}
      disabled={!shown}
      // The field keeps its focus (and the keyboard stays as it was); the form's onClick (open, focus) isn't run.
      onPointerDown={(e) => e.preventDefault()}
      onClick={(e) => e.stopPropagation()}
    >
      <Icon name="arrowUp" size={22} />
    </button>
  );
}

export function Pill({
  target,
  sending = false,
  send = false,
  class: cls = "",
  ...field
}: {
  target: MicTarget;
  value: string;
  onInput: (v: string) => void;
  sending?: boolean;
  /** A send button right of the mic while there's text (the bar's pill): submits the pill's form, as Enter does. */
  send?: boolean;
  class?: string;
  inputRef?: Ref<HTMLTextAreaElement>;
  [attr: string]: any;
}) {
  // Empty and no status to say (listening, an error): the prompt glyph stands in for a placeholder (shell.css .prompt).
  const empty = !field.value && !field.placeholder;
  return (
    <div class={`${cls} pill tile ${sending ? "sending" : ""} ${empty ? "empty" : ""}`}>
      {empty && <span class="prompt" aria-hidden="true">&gt;</span>}
      <GrowField {...(field as { value: string; onInput: (v: string) => void })} />
      <Mic target={target} />
      {send && <Send shown={!!field.value.trim()} />}
    </div>
  );
}

/** The bar's field: a held mic asks PowOS AI, a tap dictates into the search; the drawer comes up to show either. */
const barMic: MicTarget = {
  typed: () => query.value,
  heard: (full, send) => (send ? askHere(full) : (query.value = full)),
  started: () => openHere(),
};

/**
 * Up from the pill: the drawer, unless the pull-up panel is already up (PowOS AI's stays). On home: the launcher
 * overlay (state.ts openPanel), its own pill focused - home's pill is only its face.
 */
function openHere() {
  if (launcherIsOverlay) return openPanel("apps", { search: true });
  if (drawer.value === 0) pullKind.value = "apps";
  drawer.value = 1;
}

/** The foot's pill field (home.tsx: always there, parked while the search widget is on the grid). */
const footField = () => document.querySelector<HTMLTextAreaElement>(".home > .bar textarea");

/** Asked from the pill: the one chat surface (the drawer's chat) takes it - from PowOS AI's panel too. */
function askHere(text: string) {
  pullKind.value = "apps";
  askQueued(text);
}

/**
 * The search/ask bar: the pill PowOS AI's page asks in (shell.css .pill - the reference material, the field growing to
 * three rows upward over home without moving anything under it, the mic on its right), the prompt glyph its placeholder.
 */
export function Bar({ proxy = false }: { proxy?: boolean }) {
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
      data-p={!proxy || undefined}
      ref={proxy ? undefined : followOpenness}
      onSubmit={(e) => {
        e.preventDefault();
        // In a chat, Enter sends the next message - never opens a search hit.
        const best = pullKind.value === "apps" && !chatting.value ? searchResults.value[0] : null;
        if (best) openSearchResult(best);
        else if (searchPending.value) return;
        else askHere(query.value);
      }}
      onClick={() => {
        openHere();
        if (launcherIsOverlay) return;
        // The search widget on the grid is the pill's face only: the typing is the foot's pill (home.tsx, parked
        // there while the widget is on the grid), which comes up with the drawer as the original did.
        (proxy ? footField() : input.current)?.focus();
        powos.keyboard.show();
      }}
    >
      {/* The pill (shell.css .pill, as PowOS AI's compose): its own box over the bar's place, growing upward - the bar's
          height (home's layout) never changes. */}
      <Pill
        class="bar-pill"
        target={barMic}
        send
        sending={sending.value}
        inputRef={input}
        value={shown}
        onInput={(v: string) => {
          // Typing over a dictation: it stops, what it heard stays (and nothing sends by itself).
          takeOver();
          query.value = v;
        }}
        // Logged (console -> logcat): desktop mode's launcher search lost its keyboard as the user typed (2026-10-28);
        // the blur's relatedTarget says who took the focus.
        onFocus={(e: FocusEvent) => {
          console.info(`search focus drawer=${drawer.value}`);
          // Home's pill types nowhere: the overlay's pill does (openHere, from the click). The desktop's own launcher
          // (an APK without the overlay forward: state.ts openPanel) is open by the time its pill is focused.
          if (launcherIsOverlay && drawer.value === 0) return void (e.target as HTMLElement | null)?.blur();
          takeOver();
          setFocused(true);
        }}
        onBlur={(e: FocusEvent) => (logBlur(e, input.current), setFocused(false))}
        placeholder={s.listening ? "listening…" : (s.error ?? undefined)}
        aria-label={pullKind.value === "ai" && drawer.value > 0 ? "Ask PowOS AI" : "Search"}
        enterKeyHint={query.value.trim() && !searchResults.value.length && !searchPending.value ? "send" : "go"}
        autocomplete="off"
        autoCapitalize="off"
        spellcheck={false}
        readOnly={proxy}
        tabIndex={proxy ? -1 : undefined}
      />
    </form>
  );
}
