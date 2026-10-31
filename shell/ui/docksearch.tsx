/**
 * Home's search as a dock button (state.ts searchInDock; the user, 2026-10-31 01:24-01:26: "instead of being like a
 * bar, it's just like... An app ... placed in like the middle of the dock" - "we activate it and EXPAND it by pressing
 * the app-sized [button]"). The dock's centre slot (3 apps | the button | 3 apps; an odd count puts the extra one on
 * the right) is a round face with the prompt glyph the bar shows empty (bar.tsx Pill .prompt) and a small mic.
 *
 * A tap expands it in place into the search bar (DockSearchBar): the pill grows out of the button over the dock's
 * icons, which fade under it (a side dock's grows out of its column to the foot), focused, the keyboard up. What's
 * typed shows its results as the bar's do: in the launcher overlay, which takes the field over (pull.tsx, the text
 * carried). Enter opens the best hit or asks PowOS AI, as the bar. A hold on the button, or a tap on its mic, dictates
 * into the expanded bar. Dismissed (a touch elsewhere, back/Escape, sent, the launcher up) it folds back into the button.
 *
 * Bar and Pill are used as they are: this is only another face and another place for the same Pill.
 */
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import { computed, effect, signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { chatting, homePage, launcherIsOverlay, openPanel, pullKind, query, searchInDock, dockPosition } from "../state.ts";
import { searchResults, searchPending, openSearchResult } from "../search.ts";
import { askQueued, openAssistant, pillTarget, sending, takeOver } from "./assistant.ts";
import { dictate, hearing, speech, type MicTarget } from "./dictation.ts";
import { Mic, Pill } from "./bar.tsx";
import { drawerOpen } from "./gesture.ts";

/** A press on the button held this long dictates (shorter: a tap, which expands it to type). */
const HOLD_MS = 350;
/** A press that moves this far is the dock's scroll, not the button's. */
const SLOP_PX = 10;
/** The morph between the button and the bar, either way. */
const MORPH_MS = 200;
const EASE = "cubic-bezier(0.2, 0.8, 0.2, 1)";

/** The button in the dock: home's page only (not the launcher overlay's dock, which has its bar; not the desktop's). */
export const dockButton = computed(() => homePage && searchInDock.value);

/** "closed" (the button), "open" (the bar, in the dock's place), "closing" (folding back, then closed). */
export const dockSearch = signal<"closed" | "open" | "closing">("closed");
/** The next expand focuses the field (a tap) or not (a dictation: no keyboard for it). */
let focusNext = false;

/** Where a mic of the button or the expanded bar writes: the bar's own target's behaviour, its own identity. */
export const dockMic: MicTarget = {
  typed: () => query.value,
  heard: (full, send) => (send ? ask(full) : (query.value = full)),
  started: () => expand(false),
};

export function expand(focus: boolean) {
  focusNext = focus;
  if (dockSearch.value !== "open") dockSearch.value = "open";
  else if (focus) focusField();
}

export function collapse() {
  if (dockSearch.value === "open") dockSearch.value = "closing";
}

/** Asked (Enter with no hit, a held mic): PowOS AI takes it, its chat shown (on home: the launcher overlay's). */
function ask(text: string) {
  pullKind.value = "apps";
  askQueued(text);
  if (homePage) openAssistant({});
  collapse();
}

/** What's typed shows its results where the bar's do: the launcher overlay, its pill taking the field over. */
function showResults(text: string) {
  if (!launcherIsOverlay) return;
  openPanel("apps", { search: true, text });
  collapse();
}

const field = () => document.querySelector<HTMLTextAreaElement>(".home > .dock-search-bar textarea");
function focusField() {
  requestAnimationFrame(() => {
    field()?.focus();
    void powos.keyboard.show();
  });
}

// Folded back when the launcher comes up over home, or the option is switched off.
effect(() => {
  if (dockSearch.peek() === "open" && (drawerOpen.value || !dockButton.value)) collapse();
});

/** The button's face: the dock's cell in the centre slot (home.tsx Dock places it). */
export function DockSearchButton() {
  const press = useRef<{ x: number; y: number; timer: number; held: boolean } | null>(null);
  const open = dockSearch.value !== "closed";
  const listening = speech.value.listening && !!hearing(dockMic);
  const end = () => {
    const p = press.current;
    press.current = null;
    if (p) clearTimeout(p.timer);
    return p;
  };
  return (
    <div
      class={`app dock-search ${open ? "away" : ""} ${listening ? "on" : ""}`}
      data-key=" search"
      role="button"
      aria-label="search"
      tabIndex={0}
      onPointerDown={(e) => {
        const p = { x: e.clientX, y: e.clientY, timer: 0, held: false };
        p.timer = window.setTimeout(() => {
          p.held = true;
          navigator.vibrate?.(10);
          expand(false);
          dictate(dockMic);
        }, HOLD_MS);
        press.current = p;
      }}
      onPointerMove={(e) => {
        const p = press.current;
        if (p && !p.held && Math.hypot(e.clientX - p.x, e.clientY - p.y) > SLOP_PX) end();
      }}
      onPointerUp={() => {
        const p = end();
        if (p && !p.held) expand(true);
      }}
      onPointerCancel={end}
      onKeyDown={(e) => (e.key === "Enter" || e.key === " ") && (e.preventDefault(), expand(true))}
    >
      <span class="dock-search-face dsb-glass tile">
        <span class="dock-search-glyph" aria-hidden="true">&gt;</span>
      </span>
      <Mic target={dockMic} />
    </div>
  );
}

/** The bar's place as the button expands: over the bottom dock's row (measured), or the foot's for a side dock (CSS). */
function placeOver(form: HTMLElement) {
  const home = form.parentElement?.getBoundingClientRect();
  const dock = form.parentElement?.querySelector(":scope > .dock:not(.dock-tray)")?.getBoundingClientRect();
  if (!home || !dock || dockPosition.peek() !== "bottom") return;
  form.style.setProperty("--dsb-l", `${dock.left - home.left}px`);
  form.style.setProperty("--dsb-r", `${home.right - dock.right}px`);
}

/** The morph: the bar's pill clipped to the button's circle (moved onto it) and grown out to its own shape. */
function morph(form: HTMLElement, opening: boolean) {
  const pill = form.querySelector<HTMLElement>(".pill");
  const face = document.querySelector<HTMLElement>(".home .dock .dock-search-face");
  if (!pill || !face || matchMedia("(prefers-reduced-motion: reduce)").matches) return null;
  const r = pill.getBoundingClientRect();
  const b = face.getBoundingClientRect();
  const d = Math.min(b.width, r.height, r.width);
  // The circle inside the pill nearest the button, then moved onto the button.
  const cx = Math.max(r.left + d / 2, Math.min(r.right - d / 2, b.left + b.width / 2));
  const cy = r.top + r.height / 2;
  const dx = b.left + b.width / 2 - cx;
  const dy = b.top + b.height / 2 - cy;
  const at = (left: number) => `inset(${(r.height - d) / 2}px ${r.right - left - d}px ${(r.height - d) / 2}px ${left - r.left}px round ${d / 2}px)`;
  const small = { clipPath: at(cx - d / 2), transform: `translate(${dx}px, ${dy}px)`, opacity: 0.6 };
  const full = { clipPath: `inset(0px 0px 0px 0px round ${Math.min(20, r.height / 2)}px)`, transform: "translate(0px, 0px)", opacity: 1 };
  return pill.animate(opening ? [small, full] : [full, small], { duration: MORPH_MS, easing: EASE, fill: "both" });
}

/** The bar grown out of the button as it opens (focused, for a tap), folded back into it as it closes. */
function useMorph(form: { current: HTMLFormElement | null }, phase: string) {
  useLayoutEffect(() => {
    const el = form.current;
    if (!el) return;
    if (phase === "open") {
      placeOver(el);
      morph(el, true);
      if (focusNext) focusField();
      focusNext = false;
      return;
    }
    if (phase !== "closing") return;
    field()?.blur();
    const a = morph(el, false);
    const done = () => dockSearch.value === "closing" && (dockSearch.value = "closed");
    if (a) a.finished.then(done, done);
    else done();
  }, [phase]);
}

/** A touch anywhere else, or back (Escape), folds it back. */
function useDismiss(form: { current: HTMLFormElement | null }, phase: string) {
  useEffect(() => {
    if (phase !== "open") return;
    const away = (e: PointerEvent) => {
      const t = e.target as Node | null;
      if (t && (form.current?.contains(t) || (t as Element).closest?.(".dock-search"))) return;
      collapse();
    };
    const key = (e: KeyboardEvent) => e.key === "Escape" && collapse();
    document.addEventListener("pointerdown", away, true);
    document.addEventListener("keydown", key);
    return () => (document.removeEventListener("pointerdown", away, true), document.removeEventListener("keydown", key));
  }, [phase]);
}

/** Enter (or send): the best hit opens, else PowOS AI is asked - as bar.tsx's form; in a chat it's never a hit. */
function submit(e: Event) {
  e.preventDefault();
  const best = pullKind.value === "apps" && !chatting.value ? searchResults.value[0] : null;
  if (best) (openSearchResult(best), collapse());
  else if (searchPending.value) return;
  else if (query.value.trim()) ask(query.value);
  else collapse();
}

/** The search bar the button expands into: the bar's Pill, in its own form (home.tsx renders it while not closed). */
export function DockSearchBar() {
  const form = useRef<HTMLFormElement>(null);
  const input = useRef<HTMLTextAreaElement>(null);
  const phase = dockSearch.value;
  const shown = hearing(dockMic) ?? hearing(pillTarget) ?? query.value;
  const s = speech.value;
  useMorph(form, phase);
  useDismiss(form, phase);
  if (phase === "closed") return null;
  return (
    <form
      ref={form}
      class={`dock-search-bar ${phase}`}
      onSubmit={submit}
    >
      <Pill
        class="dsb-glass dock-search-pill"
        target={dockMic}
        hears={[pillTarget]}
        send
        sending={sending.value}
        inputRef={input}
        value={shown}
        onInput={(v: string) => {
          takeOver();
          query.value = v;
          if (v.trim()) showResults(v);
        }}
        placeholder={s.listening ? "listening…" : (s.error ?? undefined)}
        aria-label="Search"
        enterKeyHint="go"
        autocomplete="off"
        autoCapitalize="off"
        spellcheck={false}
      />
    </form>
  );
}
