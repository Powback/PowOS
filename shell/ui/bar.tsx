/**
 * The bar at the bottom: it finds apps and asks PowOS AI. Tapping it types - the keyboard comes up then, not when the
 * drawer is swiped open, which is for browsing. Enter opens the best match; with none, it asks PowOS AI (chat.tsx).
 * The mic (the Compose prompt bar's): hold to talk, let go to ask PowOS AI; a tap dictates into the field instead,
 * until ~4 s with nothing heard or the next tap (pauses don't end either); held and dragged well away, it's cancelled.
 * It listens from the moment the finger lands: a press that lasts becomes a hold (speech.hold) - no first words lost
 * to deciding which it is.
 */
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { computed } from "@preact/signals";
import type { Ref } from "preact";
import { GrowField } from "./grow.tsx";
import { Icon } from "./icons.tsx";
import { searchResults, searchPending, openSearchResult } from "../search.ts";
import { followOpenness, pageDrag } from "./gesture.ts";
import { chatting, drawer, homePage, launcherIsOverlay, openPanel, page, pullKind, pullPage, query, sharesBar } from "../state.ts";
import { powos } from "../bridge.ts";
import { tick } from "./haptics.ts";
import { askQueued, pillTarget, sending, takeOver } from "./assistant.ts";
import { dictate, drop, finish, finishing, forget, hearing, listen, listeningFor, makeHold, micOn, release, settle, speech, stopTap, type MicTarget } from "./dictation.ts";
import { remoteHearing, startBarSync } from "./barsync.ts";

/**
 * OB1 (the user, 2026-11-01 17:52 / 18:24 / 18:25: "one single search bar that acts differently depending on which page
 * you're on"): the one bar's role, from the page it's on - home searches everything and asks PowOS AI, the launcher
 * filters its apps, PowOS AI's page (and the launcher's AI panel) messages the manager: a send goes into the chat thread.
 */
export type BarRole = "search" | "apps" | "ai";
export const barRole = computed<BarRole>(() => {
  if (drawer.value > 0 || pullPage) return pullKind.value === "ai" ? "ai" : "apps";
  return homePage && page.value === -1 ? "ai" : "search";
});
/** What the role says in the empty field (home's says nothing: the prompt glyph alone, as it always had). */
const ROLE_HINT: Record<BarRole, string | undefined> = { search: undefined, apps: "Search apps", ai: "Message the manager" };
const ROLE_LABEL: Record<BarRole, string> = { search: "Search", apps: "Search apps", ai: "Message the manager" };

/** The AI page's send into the chat thread: the one its own field had (powai.tsx registers it: onManagerSend). */
let managerSend = (text: string) => askQueued(text);
export const onManagerSend = (fn: (text: string) => void) => void (managerSend = fn);
function sendToManager(text: string) {
  const t = text.trim();
  if (!t) return;
  query.value = "";
  managerSend(t);
}

/** The pill's role-dependent props (hint, glyph, label, Enter's key). */
function roleProps(role: BarRole) {
  const sendKey = role === "ai" || (query.value.trim() && !searchResults.value.length && !searchPending.value);
  return {
    hint: ROLE_HINT[role],
    icon: role === "apps" ? ("apps" as const) : role === "ai" ? ("robotOutline" as const) : undefined,
    "aria-label": ROLE_LABEL[role],
    enterKeyHint: sendKey ? "send" : "go",
  };
}

/** A press longer than this is a hold (talk, then send); shorter, a tap (dictate). */
const HOLD_MS = 250;
/** Held and moved this far off the mic: cancelled. */
const CANCEL_PX = 64;

export { dictate, hearing, interrupt, speech, type MicTarget } from "./dictation.ts";

/** A mic for [target]: hold to talk and send, tap to dictate; held and dragged well away, cancelled. */
export function Mic({ target }: { target: MicTarget }) {
  const press = useRef<{ x: number; y: number; timer: number; held: boolean; cancelled: boolean } | null>(null);
  // Another window's dictation shows here too (home's, under the launcher overlay): a tap ends it, never a second.
  const on = micOn.value || listeningFor(target);
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
          tick();
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

/**
 * SB5 (the user, 2026-10-31 02:46: "we should have an x to clear on the left side of the inputs"): the pill's leading
 * slot. Empty, the prompt glyph `>` (its placeholder); with text, an × that clears it - through the field's onInput, so
 * the shared bar (barsync.ts) empties the other window's too - and ends a dictation into it without writing its words
 * back (dictation.ts drop). One 40 px slot either way (shell.css .pill .lead): the text never moves as it turns.
 */
function Lead({ empty, filled, clear, icon }: { empty: boolean; filled: boolean; clear: () => void; icon?: "apps" | "robotOutline" }) {
  return (
    <button
      type="button"
      class={`lead ${filled ? "filled" : ""}`}
      aria-label="clear"
      aria-hidden={!filled}
      tabIndex={filled ? undefined : -1}
      disabled={!filled}
      // The field keeps its focus (and the keyboard stays as it was); the form's onClick (open, focus) isn't run.
      onPointerDown={(e) => e.preventDefault()}
      onClick={(e) => (e.stopPropagation(), filled && clear())}
    >
      {icon ? (
        <span class={`prompt role-icon ${empty ? "" : "off"}`} aria-hidden="true">
          <Icon name={icon} size={18} />
        </span>
      ) : (
        <span class={`prompt ${empty ? "" : "off"}`} aria-hidden="true">&gt;</span>
      )}
      <Icon name="close" size={20} class="x" />
    </button>
  );
}

export function Pill({
  target,
  hears = [],
  sending = false,
  send = false,
  hint,
  icon,
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
  /** OB1: the role's hint - a placeholder that keeps the leading glyph (the role's [icon]) beside it. */
  hint?: string;
  icon?: "apps" | "robotOutline";
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
      <Lead empty={empty} filled={!!field.value} icon={icon} clear={() => (drop(...targets), field.onInput(""))} />
      <GrowField {...(field as { value: string; onInput: (v: string) => void })} placeholder={field.placeholder ?? hint} />
      <Mic target={target} />
      {send && <PillSend targets={targets} value={field.value} />}
    </div>
  );
}

/** The bar's field: a held mic asks PowOS AI, a tap dictates into the search; the drawer comes up to show either. */
const barMic: MicTarget = {
  typed: () => query.value,
  // OB1: on PowOS AI's page a hold is push-to-talk to the manager (the chat thread), never the launcher.
  heard: (full, send) => (!send ? (query.value = full) : barRole.peek() === "ai" ? sendToManager(full) : askHere(full)),
  started: () => barRole.peek() !== "ai" && openHere(),
};

/** DS2: the launcher's bar dictating (home's dock search button held: pull.begin { listen }, or the overlay's own button). */
export const dictateBar = () => dictate(barMic);

/** The launcher's bar field focused, the keyboard up (ShellBridge.overlayKeyboard makes the overlay the IME's target). */
export function focusBar(tries = 10) {
  requestAnimationFrame(() => {
    // Home's bar in dock-button mode mounts with the launcher's open (home.tsx HomeSearch): a few frames for it.
    const field = document.querySelector<HTMLTextAreaElement>(".home > .bar textarea");
    if (!field && tries > 0) return focusBar(tries - 1);
    field?.focus();
    void powos.keyboard.show();
  });
}

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
 * PT1: a finger's click on the bar whose pointerdown it didn't see is another press's (a hold on the dock button that
 * brought the launcher up under the finger), never a tap on the bar. A keyboard's or a script's click is the bar's.
 */
function useOwnPress(onClick: () => void) {
  const pressed = useRef(false);
  const onPointerDown = () => void (pressed.current = true);
  const click = (e: MouseEvent) => {
    const seen = pressed.current || !e.isTrusted || !e.detail;
    pressed.current = false;
    if (seen) onClick();
  };
  return { onPointerDown, onClick: click };
}

/** The bar's send (Enter, the send button) in [role]: the manager's chat, a search hit, or asking PowOS AI. */
function submit(role: BarRole) {
  if (role === "ai") return sendToManager(query.value);
  // In a chat, Enter sends the next message - never opens a search hit.
  const best = pullKind.value === "apps" && !chatting.value ? searchResults.value[0] : null;
  if (best) openSearchResult(best);
  else if (searchPending.value) return;
  else askHere(query.value);
}

/**
 * OB1: on PowOS AI's page the bar - still home's own element, inside home, which slid a screen to the right - is held
 * where it is on home by a translate that counters home's slide (gesture.ts applyTrack), with home's slide curve.
 * OE1 (the user, 11-03 21:14: "we need to reuse the search [bar] on all pages. Why is the search [bar] just under the
 * chat here?"): the bar never moves or resizes between pages - same x, width, height and foot as home's, folded and
 * unfolded (the keyboard up, it sits on the keyboard: keyboardY) - the pages lay out around it. It was
 * fitted to the page's .ai-bar-slot (the chat column unfolded). Now the page reserves the bar's room: --bar-room (the
 * pill's top to the page's content foot) sizes the slot under the tabs and keeps the unfolded columns above it (shell.css).
 * dev/dock-search-check.js barFootSame proves the rect identical on home, the AI page (every tab) and the launcher.
 */
function seatOnAi(bar: HTMLElement) {
  const home = bar.closest<HTMLElement>(".home");
  // The page, whichever tab or screen it shows (a screen with no slot - Friction - still has the bar where home's is).
  const ai = document.querySelector<HTMLElement>(".ai-screen");
  if (heldSeated(bar, home)) return;
  if (page.peek() !== -1 || !home || !ai) return unseat(bar);
  bar.style.removeProperty("width");
  // Measured at home's place (no translate, no transition: a running one would keep its old translate in the rect).
  const was = bar.style.translate;
  bar.style.transition = "none";
  bar.style.translate = "none";
  const pill = (bar.querySelector(".bar-pill") ?? bar).getBoundingClientRect();
  bar.style.translate = was;
  void bar.offsetWidth;
  bar.style.removeProperty("transition");
  const y = keyboardY(home, pill);
  bar.classList.add("seated");
  bar.style.translate = `${-home.offsetWidth}px ${Math.round(y)}px`;
  barRoom(ai, pill.top + y);
  // The threads under it keep clear of it (powai.tsx useBarClear; its translate's end re-measures).
  bar.dispatchEvent(new Event("bar-seated", { bubbles: true }));
}

/** The keyboard up (the host's --inset-keyboard, app.tsx). */
const keyboardPx = () => parseFloat(document.documentElement.style.getPropertyValue("--inset-keyboard")) || 0;

/**
 * The keyboard up, the field sits on it (--pill-foot over its top: P1 11-01, never behind it, never 88 px over it -
 * folded home's own bar is the dock's button then, parked off its foot); down, 0: home's own place, never moved.
 */
function keyboardY(home: HTMLElement, pill: DOMRect) {
  const kb = keyboardPx();
  if (kb <= 0) return 0;
  const foot = parseFloat(getComputedStyle(home).getPropertyValue("--pill-foot")) || 0;
  return innerHeight - kb - foot - pill.bottom;
}

/** The page's room for the bar: from the pill's top (where it's held) to the page's content foot. */
function barRoom(ai: HTMLElement, pillTop: number) {
  const a = ai.getBoundingClientRect();
  const foot = a.bottom - (parseFloat(getComputedStyle(ai).paddingBottom) || 0);
  ai.style.setProperty("--bar-room", `${Math.max(0, Math.ceil(foot - pillTop))}px`);
  ai.dataset.barRoom = "";
}

/** BM1: on the way home from the page the bar stays seated while it morphs back into the button (docksearch.tsx). */
const heldSeated = (bar: HTMLElement, home: HTMLElement | null) => page.peek() !== -1 && bar.classList.contains("seated") && !!home?.classList.contains("button-morph");

function unseat(bar: HTMLElement) {
  bar.classList.remove("seated");
  bar.style.removeProperty("translate");
  bar.style.removeProperty("width");
}

/**
 * "ai.focus": the page's one field, this bar, takes the keys. Hosts since 11-02 don't send it - the side button opens
 * the assist overlay over the page too (the user: "I tried to open like the AI overlay with the side button on the AI
 * page and it doesn't work"); kept for a host that asks the page's field to focus.
 */
if (homePage)
  powos.on("ai.focus", () => {
    if (page.peek() !== -1) return;
    document.querySelector<HTMLTextAreaElement>(".home > .bar[data-role=ai] textarea")?.focus();
    void powos.keyboard.show();
  });

/** Seats the bar on PowOS AI's page while that's the page (and re-seats it as the page's layout changes). */
function useAiSeat(proxy: boolean) {
  const form = useRef<HTMLFormElement | null>(null);
  // One callback for the element's life (a new one each render re-runs the ref: null, then the element).
  const formRef = useRef((el: HTMLFormElement | null) => {
    form.current = el;
    if (!proxy) followOpenness(el);
  }).current;
  const at = homePage && !proxy ? page.value : 0;
  const dragging = homePage && !proxy && pageDrag.value != null;
  useLayoutEffect(() => {
    const el = form.current;
    if (!el || !homePage || proxy) return;
    el.classList.toggle("sliding", dragging);
    seatOnAi(el);
    if (at !== -1) return;
    const ai = document.querySelector(".ai-screen");
    const ro = new ResizeObserver(() => seatOnAi(el));
    if (ai) ro.observe(ai);
    ro.observe(document.documentElement);
    // Home's foot changing under the bar (the keyboard's room, the recents strip coming or going) moves the bar's own
    // place without resizing it: home's stage, over the bar, resizes then - the seat follows.
    const stage = el.parentElement?.querySelector(":scope > .stage");
    if (stage) ro.observe(stage);
    // The pill growing (a long ask wraps up to three rows).
    const pill = el.querySelector(".bar-pill");
    if (pill) ro.observe(pill);
    // The keyboard lifts home's bar (home's padding) and ends the page at its top (shell.css .ai-screen.stacked): the
    // page's room for the bar is measured again (P1 11-01: never the field behind the keyboard).
    const off = powos.on("system.insets", () => requestAnimationFrame(() => seatOnAi(el)));
    return () => (ro.disconnect(), off());
  }, [at, dragging]);
  return formRef;
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
  const role = proxy ? "search" : barRole.value;
  const formRef = useAiSeat(proxy);
  return (
    <form
      class={`bar ${active ? "active" : ""} role-${role}`}
      data-role={proxy ? undefined : role}
      data-p={!proxy || undefined}
      ref={formRef}
      onSubmit={(e) => (e.preventDefault(), submit(role))}
      {...useOwnPress(() => {
        // OB1: PowOS AI's page types here, in place - no launcher over it.
        if (role === "ai" && !drawer.value) return void (input.current?.focus(), powos.keyboard.show());
        openHere();
        if (launcherIsOverlay) return;
        // The search widget on the grid is the pill's face only: the typing is the foot's pill (home.tsx, parked
        // there while the widget is on the grid), which comes up with the drawer as the original did.
        (proxy ? footField() : input.current)?.focus();
        powos.keyboard.show();
      })}
    >
      {/* The pill (shell.css .pill, as PowOS AI's compose): its own box over the bar's place, growing upward - the bar's
          height (home's layout) never changes. */}
      <Pill
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
          if (launcherIsOverlay && drawer.value === 0 && barRole.peek() !== "ai") return void (e.target as HTMLElement | null)?.blur();
          takeOver();
          setFocused(true);
        }}
        onBlur={(e: FocusEvent) => (logBlur(e, input.current), setFocused(false))}
        placeholder={s.listening ? "listening…" : (s.error ?? undefined)}
        // The form's role-* class: the hint fades in anew as the page changes the role (shell.css bar-role-*).
        class="bar-pill"
        {...roleProps(role)}
        autocomplete="off"
        autoCapitalize="off"
        spellcheck={false}
        readOnly={proxy}
        tabIndex={proxy ? -1 : undefined}
      />
    </form>
  );
}
