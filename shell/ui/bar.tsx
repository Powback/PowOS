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
import { chatting, drawer, launcherIsOverlay, openPanel, pullKind, query, sharesBar } from "../state.ts";
import { powos } from "../bridge.ts";
import { askQueued, pillTarget, sending, takeOver } from "./assistant.ts";
import { drop, finish, finishing, forget, hearing, listen, listeningFor, makeHold, release, settle, speech, stopTap, type MicTarget } from "./dictation.ts";
import { remoteHearing, startBarSync } from "./barsync.ts";

/** A press longer than this is a hold (talk, then send); shorter, a tap (dictate). */
const HOLD_MS = 250;
/** Held and moved this far off the mic: cancelled. */
const CANCEL_PX = 64;

export { dictate, hearing, interrupt, speech, type MicTarget } from "./dictation.ts";

/** A mic for [target]: hold to talk and send, tap to dictate; held and dragged well away, cancelled. */
export function Mic({ target }: { target: MicTarget }) {
  const press = useRef<{ x: number; y: number; timer: number; held: boolean; cancelled: boolean } | null>(null);
  // Another window's dictation shows here too (home's, under the launcher overlay): a tap ends it, never a second.
  const on = speech.value.listening || !!speech.value.elsewhere || listeningFor(target);
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
 * Send, right of the mic while the field has text or a dictation is on ([shown]): the form's submit, so it does
 * exactly what Enter does (grow.tsx requestSubmit -> the form's onSubmit) without the keyboard. Empty, it folds to
 * nothing (shell.css .pill .send: width and opacity), so the empty pill's layout is the one it always had.
 * [waiting]: a send tapped mid-dictation waits for the final words (dictation.ts finish): it spins meanwhile.
 */
function Send({ shown, waiting }: { shown: boolean; waiting: boolean }) {
  return (
    <button
      type="submit"
      class={`send ${shown ? "shown" : ""} ${waiting ? "waiting" : ""}`}
      aria-busy={waiting || undefined}
      aria-label="send"
      aria-hidden={!shown || undefined}
      tabIndex={shown ? undefined : -1}
      disabled={!shown}
      // The field keeps its focus (and the keyboard stays as it was); the form's onClick (open, focus) isn't run.
      onPointerDown={(e) => e.preventDefault()}
      onClick={(e) => e.stopPropagation()}
    >
      {waiting ? (
        <svg class="send-spin" viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" aria-hidden="true">
          <path d="M12 3a9 9 0 1 1-9 9" />
        </svg>
      ) : (
        <Icon name="arrowUp" size={22} />
      )}
    </button>
  );
}

/**
 * SB3: a submit of [form] (the send button, Enter) while one of [targets] dictates first ends the dictation and waits
 * for its final words (dictation.ts finish, ~3 s at most), then submits again - the form's own onSubmit then sends the
 * whole text, as Enter does, the mic off. A capture listener on the form runs before its (bubble) onSubmit.
 */
function useSubmitFinishes(box: { current: HTMLDivElement | null }, targets: MicTarget[]) {
  const all = useRef(targets);
  all.current = targets;
  useEffect(() => {
    const form = box.current?.closest("form");
    if (!form) return;
    const onSubmit = (e: Event) => {
      const wait = finish(...all.current);
      if (!wait) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      wait.then(() => form.isConnected && form.requestSubmit());
    };
    // After the form's own onSubmit: sent (its field emptied), the dictation is over - the mic off, nothing pending.
    const sent = () =>
      setTimeout(() => {
        const field = box.current?.querySelector("textarea");
        if (field && !field.value.trim() && !finishing.peek()) settle(...all.current);
      }, 0);
    form.addEventListener("submit", onSubmit, true);
    form.addEventListener("submit", sent);
    return () => (form.removeEventListener("submit", onSubmit, true), form.removeEventListener("submit", sent));
  }, []);
}

/** The pill's send: shown while there's text, or while one of [targets] dictates - before its first words land too
 *  (the field is empty until then) - and spinning while a send waits for a dictation's final words. */
function PillSend({ targets, value }: { targets: MicTarget[]; value: string }) {
  const waiting = !!finishing.value && targets.includes(finishing.value);
  // SI1: the shared bar's text written by another window's dictation (home's, under the launcher): its send shows here.
  const elsewhere = targets.includes(barMic) && remoteHearing.value;
  return <Send shown={!!value.trim() || waiting || elsewhere || targets.some(listeningFor)} waiting={waiting} />;
}

export function Pill({
  target,
  hears = [],
  sending = false,
  send = false,
  class: cls = "",
  ...field
}: {
  target: MicTarget;
  /** Other dictations that write into this field (the bar: the assistant's): a send finishes those too. */
  hears?: MicTarget[];
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
  const box = useRef<HTMLDivElement>(null);
  const targets = [target, ...hears];
  useSubmitFinishes(box, targets);
  return (
    <div ref={box} class={`${cls} pill tile ${sending ? "sending" : ""} ${empty ? "empty" : ""}`}>
      {empty && <span class="prompt" aria-hidden="true">&gt;</span>}
      <GrowField {...(field as { value: string; onInput: (v: string) => void })} />
      <Mic target={target} />
      {send && <PillSend targets={targets} value={field.value} />}
    </div>
  );
}

/** The bar's field: a held mic asks PowOS AI, a tap dictates into the search; the drawer comes up to show either. */
const barMic: MicTarget = {
  typed: () => query.value,
  heard: (full, send) => (send ? askHere(full) : (query.value = full)),
  started: () => openHere(),
};

/** SI1: what the bar shows (barsync.ts writes it to the other window's bar): a dictation's words as heard, else the query. */
const barShown = () => {
  const heard = hearing(barMic) ?? hearing(pillTarget);
  return { text: heard ?? query.value, hearing: heard !== null };
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
  // SI1: home's bar and the launcher overlay's are one input (barsync.ts); another window's edit ends a dictation here.
  useEffect(() => void (sharesBar && startBarSync(barShown, () => drop(barMic, pillTarget))), []);
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
        hears={[pillTarget]}
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
