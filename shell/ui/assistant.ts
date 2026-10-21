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
 *     context   the screen as context - the side button's (assist), never the pet's; ignored here for now
 *   askQueued(text)  asks; while a turn is under way it waits for it (PowosAiChat.send drops what's sent meanwhile)
 */
import { effect } from "@preact/signals";
import { chat, chatting, drawer, page, pullKind, query } from "../state.ts";
import { dictate, type MicTarget } from "./bar.tsx";
import { powos } from "../bridge.ts";

/** Asked while the manager was mid-turn: sent when that turn ends. */
let queued: string | null = null;
/** Sent: if another turn took the chat first (an agent's mail), it was dropped - queued again. */
let sent: { text: string; at: number } | null = null;

export function askQueued(text: string) {
  const t = text.trim();
  if (!t) return;
  chatting.value = true;
  query.value = "";
  if (chat.peek().busy) queued = queued ? `${queued}\n${t}` : t;
  else send(t);
}

function send(t: string) {
  sent = { text: t, at: Date.now() };
  powos.ai.send(t, false);
}

/** What's waiting to be asked (the chat shows it, greyed, until it goes). */
export const waitingAsk = () => queued;

effect(() => {
  const c = chat.value;
  if (queued && !c.busy) {
    const q = queued;
    queued = null;
    send(q);
    return;
  }
  if (!sent) return;
  const last = c.items.findLast((i) => i.kind === "user") as { text: string } | undefined;
  const ours = !!last && last.text.startsWith(sent.text);
  if (ours) sent = null;
  else if (c.busy && Date.now() - sent.at < 3000) {
    queued = queued ? `${sent.text}\n${queued}` : sent.text;
    sent = null;
  } else if (Date.now() - sent.at >= 3000) sent = null;
});

/** Dictation into the pill: what's heard goes into its field, or is asked at once. */
function target(autosend: boolean): MicTarget {
  return {
    typed: () => query.value,
    heard: (full, send) => (send || autosend ? askQueued(full) : (query.value = full)),
    started: () => (drawer.value = 1),
  };
}

export interface OpenAssistant {
  listen?: boolean;
  autosend?: boolean;
  text?: string;
  /** The screen as context (the side button's); not used by the home surface yet. */
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
  if (o.listen) dictate(target(!!o.autosend));
}
