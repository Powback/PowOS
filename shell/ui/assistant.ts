/**
 * The one assistant surface (docs/DESIGN-LANGUAGE.md, "One assistant"): ONE conversation - the manager's, PowOS AI's
 * chat - and ONE chat UI for it, the home search pill's chat mode (the drawer's ChatView: typing searches, asking turns
 * it into the chat in place). Everything that opens "the assistant" opens that: the pet's tap, the side button, a
 * notification's reply. PowOS AI's page (left of home) is the same conversation's history and the work board, not a
 * chat of its own; the pet is its face and notifier.
 *
 *   openAssistant({ listen, autosend, text, context })
 *     listen    the shared recognizer starts (bar.tsx's), heard words go into the pill's field
 *     autosend  what's heard is asked at once (else it waits in the field)
 *     text      put into the field
 *     context   the screen as context - the side button's (assist.tsx registers it: setAskContext), never the pet's
 * The side button's panel over an app (assist.tsx) is this same chat: the conversation (chat.tsx ChatView) and asks
 * through askQueued, with the screen, its circled part and live frames as context - its crop screen kept around it.
 *   askQueued(text)  asks; while a turn is under way it waits for it, shown as a queued bubble (waiting, unqueue)
 *
 * Autosend: when the dictation ends (~4 s with nothing heard, the mic tapped, a hold let go) the words show in the
 * pill for PREVIEW_MS, then go ("sending"); touching the pill in that moment - or typing, or tapping it while it
 * listens - keeps them there to edit (takeOver).
 */
import { computed, effect, signal } from "@preact/signals";
import { chat, chatting, drawer, openPanel, page, pullKind, query } from "../state.ts";
import { dictate, interrupt, type MicTarget } from "./dictation.ts";
import { powos } from "../bridge.ts";

/**
 * Asked while the manager was mid-turn. The host queues it (PowosAiChat.queued: one queue for every chat, this page's
 * and the side button's); an older host drops it, so then this page keeps it here and sends it when the turn ends.
 */
const pageQueue = signal<string[]>([]);
const hostQueues = () => Array.isArray(chat.peek().queued);
/** Sent to a host that drops mid-turn asks: if another turn took the chat first (an agent's mail), queued again. */
let sent: { text: string; at: number } | null = null;

export function askQueued(text: string) {
  const t = text.trim();
  if (!t) return;
  chatting.value = true;
  query.value = "";
  if (chat.peek().busy && !hostQueues()) pageQueue.value = [...pageQueue.value, t];
  else send(t);
}

/** Everything waiting for its turn, oldest first (the chats show each as a dimmed bubble with a x). */
export const waiting = computed(() => {
  const q = chat.value.queued;
  return Array.isArray(q) ? q : pageQueue.value.map((text, i) => ({ id: -1 - i, text }));
});

/** Takes one back before its turn: out of the host's queue (it's never sent), or the page's own. */
export function unqueue(id: number) {
  if (id < 0) {
    pageQueue.value = pageQueue.value.filter((_, i) => -1 - i !== id);
    return;
  }
  chat.value = { ...chat.value, queued: (chat.value.queued ?? []).filter((q) => q.id !== id) };
  powos.ai.unqueue?.(id);
}

/**
 * The stop button (the pill's send, turned, while a turn runs: bar.tsx Send). Optimistic both ways (the user's rule: no
 * silence over 100 ms): it shows the instant a send goes - before the host's busy arrives - and turns back to send the
 * instant it's tapped, before the turn has ended. A host that never takes the stop (busy, not stopping, 10 s on) gets it
 * back, so the turn can be stopped again. Hosts from before ai.stop (no `stoppable`): never shown.
 */
const sentAt = signal(0);
const stopAt = signal(0);
const SEND_SHOWS_MS = 4000;
const STOP_ROLLBACK_MS = 10000;
const tick = signal(0);
let ticking: ReturnType<typeof setTimeout> | null = null;
/** Re-evaluates [answering] when an optimistic window ends (a timer, not polling: one per window). */
function expireAt(ms: number) {
  if (ticking) clearTimeout(ticking);
  ticking = setTimeout(() => ((ticking = null), tick.value++), ms + 20);
}

/** A turn runs that the pill's stop can end (pure: the page's state machine, test-ai-stop.ts). */
export function stopShown(c: { busy: boolean; stoppable?: boolean; stopping?: boolean }, now: number, sent: number, stop: number): boolean {
  // An older host, or a stop under way: no stop. Tapped: back to send at once, until the turn has ended - or rolled
  // back past STOP_ROLLBACK_MS when the host never took it.
  if (!c.stoppable || c.stopping || tappedRecently(stop, now)) return false;
  return c.busy || justSent(sent, now);
}
const tappedRecently = (stop: number, now: number) => stop > 0 && now - stop < STOP_ROLLBACK_MS;
const justSent = (sent: number, now: number) => sent > 0 && now - sent < SEND_SHOWS_MS;

export const answering = computed(() => {
  tick.value;
  return stopShown(chat.value, Date.now(), sentAt.value, stopAt.value);
});

// The host's busy arrived (the send's window is over) / the turn ended (the stop's is): the optimistic marks go.
effect(() => {
  const c = chat.value;
  if (c.busy && sentAt.peek()) sentAt.value = 0;
  if (!c.busy && !c.stopping && stopAt.peek()) stopAt.value = 0;
});

/** The stop button's tap: the turn under way ends (ai.stop); what it said stays, a "stopped" line follows. */
export function stopAnswer() {
  if (!answering.peek()) return;
  stopAt.value = Date.now();
  sentAt.value = 0;
  expireAt(STOP_ROLLBACK_MS);
  powos.ai.stop?.().catch(() => (stopAt.value = 0));
}

/** What goes along with a question (the side button's screen, crop, live frames: assist.tsx); null: nothing. */
let askContext: ((text: string) => Promise<string>) | null = null;
/** Asks also put the chat in the app switcher (ai.send's recents): over an app (assist mode), not from home. */
let askRecents = false;

/**
 * The page that has context to add to every question (assist mode) registers it here; [recents]: its asks also put
 * the chat in the app switcher (from home that briefly covered home with the chat activity, so home never does).
 */
export function setAskContext(f: ((text: string) => Promise<string>) | null, recents = false) {
  askContext = f;
  askRecents = recents;
}

async function send(t: string) {
  sent = { text: t, at: Date.now() };
  // The stop shows now, not when the host's busy comes back (see answering).
  if (!chat.peek().busy) (sentAt.value = Date.now(), expireAt(SEND_SHOWS_MS));
  // The question first, the context after it: the chat shows the question (powai.tsx), and `sent` matches it by prefix.
  powos.ai.send(askContext ? await askContext(t) : t, askRecents);
}

effect(() => {
  const c = chat.value;
  // The host queues: nothing for the page to do.
  if (Array.isArray(c.queued)) return void (sent = null);
  if (pageQueue.value.length && !c.busy) {
    const [q, ...rest] = pageQueue.value;
    pageQueue.value = rest;
    send(q);
    return;
  }
  if (!sent) return;
  const last = c.items.findLast((i) => i.kind === "user") as { text: string } | undefined;
  const ours = !!last && last.text.startsWith(sent.text);
  if (ours) sent = null;
  else if (c.busy && Date.now() - sent.at < 3000) {
    pageQueue.value = [sent.text, ...pageQueue.value];
    sent = null;
  } else if (Date.now() - sent.at >= 3000) sent = null;
});

/** The words of an autosend dictation are on show, about to go (the pill marks it: bar.tsx). */
export const sending = signal(false);
/** How long they show before they go. */
const PREVIEW_MS = 300;
let sendTimer = 0;
/** This dictation sends by itself when it ends (openAssistant's autosend), until the user takes over. */
let autosend = false;

/** The user took over the pill (a touch, typing): no sending by itself; a dictation stops, its words stay. */
export function takeOver() {
  autosend = false;
  clearTimeout(sendTimer);
  sending.value = false;
  interrupt();
}

/**
 * Dictation into the pill (one target, so the pill shows what it hears: bar.tsx): the words go into its field; a send
 * (a held mic let go, or autosend's end) asks them - autosend's after showing them for PREVIEW_MS.
 */
export const pillTarget: MicTarget = {
  typed: () => query.value,
  heard: (full, send) => {
    query.value = full;
    if (!send || !full.trim()) return;
    if (!autosend) return askQueued(full);
    autosend = false;
    sending.value = true;
    sendTimer = window.setTimeout(() => {
      sending.value = false;
      askQueued(full);
    }, PREVIEW_MS);
  },
  started: () => openPanel("apps"),
};

export interface OpenAssistant {
  listen?: boolean;
  autosend?: boolean;
  text?: string;
  /** The screen as context (the side button's): what setAskContext registered goes with each question. */
  context?: boolean;
}

/** Opens the chat surface: home's drawer in chat mode (from PowOS AI's page, home slides back first). */
export function openAssistant(o: OpenAssistant = {}) {
  if (page.value === -1) page.value = 0;
  // The chat surface is the drawer's (from PowOS AI's pull-up panel too).
  pullKind.value = "apps";
  drawer.value = 1;
  chatting.value = true;
  if (o.text != null) query.value = o.text;
  if (!o.listen) return;
  clearTimeout(sendTimer);
  sending.value = false;
  autosend = !!o.autosend;
  dictate(pillTarget, autosend);
}
