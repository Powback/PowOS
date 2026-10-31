/**
 * What needs me's actions - each one a press of a notification's OWN button, through host.notifications, and only ever
 * called from the user's tap or swipe (the widget and the page never act on their own, nothing is batched behind the
 * user's back, nothing talks to Discord's, WhatsApp's or Gmail's servers: the official apps do, as from the shade).
 *
 * Optimistic: a marked-read row goes at once (kept out while its notification is unchanged, back with the error if
 * the press failed); a sent reply shows "Sent" until the app updates the notification (then the user's reply is its
 * last message and the row leaves, model.ts) or cancels it.
 */
import { signal } from "@preact/signals";
import { replyTarget, type Entry, type Group, type NotifList } from "./model";

export interface ReplyFieldProps {
  value: string;
  onInput(v: string): void;
  onSend(): void;
  placeholder?: string;
  sending?: boolean;
}
export interface NotificationsHost {
  useList(app: string): NotifList | null;
  action(app: string, key: string, index: number, text?: string): Promise<void>;
  open(app: string, key: string): Promise<void>;
  dismiss(app: string, key: string): Promise<void>;
  access(): Promise<void>;
  /** The bar's pill (field, mic, send); an older shell: none - a plain field instead. */
  ReplyField?: (p: ReplyFieldProps) => any;
}
/** What the shell hands a page or a widget (shell/apps/stdb.ts IslandHost): the parts this app uses. */
export interface Host {
  openApp?(id: string): void;
  notifications?: NotificationsHost;
}
export interface Props {
  host: Host;
  app: string;
  base: string;
  cells?: [number, number];
  close?: () => void;
}

/** [time]: the row's newest message then - a newer one (or the app's update) and the state is over. */
export type RowState = { state: "sending" | "sent" | "error"; time: number; message?: string };
/** Per row (Group.id): a reply on its way, sent, or a press that failed. */
export const rowState = signal<Record<string, RowState>>({});
/** Notifications marked read (key -> the time it had): out of the list while unchanged. */
export const marked = signal<Record<string, number>>({});

const setRow = (id: string, s: RowState) => {
  rowState.value = { ...rowState.value, [id]: s };
};
const say = (e: unknown) => String((e as Error)?.message ?? e);

/** Whether [e] was marked read and hasn't changed since. */
export const isMarked = (e: Entry) => marked.value[e.n.key] === e.n.time;

/** The typed reply through the newest entry's own reply action: one press, [text] in its RemoteInput. */
export async function sendReply(host: Host, app: string, g: Group, text: string): Promise<boolean> {
  const n = host.notifications;
  const t = replyTarget(g);
  if (!n || !t || !text.trim()) return false;
  setRow(g.id, { state: "sending", time: g.time });
  try {
    await n.action(app, t.n.key, t.reply, text.trim());
    setRow(g.id, { state: "sent", time: g.time });
    return true;
  } catch (e) {
    setRow(g.id, { state: "error", time: g.time, message: say(e) });
    return false;
  }
}

/** One entry read: its mark-as-read action, or dismissed when it has none. */
async function readOne(n: NotificationsHost, app: string, e: Entry) {
  if (e.read >= 0) await n.action(app, e.n.key, e.read);
  else await n.dismiss(app, e.n.key);
}

/** A row read (its swipe): each of its notifications' own mark-as-read, one press each, in turn. */
export async function markRead(host: Host, app: string, g: Group) {
  const n = host.notifications;
  if (!n) return;
  marked.value = { ...marked.value, ...Object.fromEntries(g.entries.map((e) => [e.n.key, e.n.time])) };
  for (const e of g.entries) {
    try {
      await readOne(n, app, e);
    } catch (err) {
      const { [e.n.key]: _, ...rest } = marked.value;
      marked.value = rest;
      setRow(g.id, { state: "error", time: g.time, message: say(err) });
    }
  }
}

/** "Mark all read" (the page's one tap): every row shown, each notification its own press, one after another. */
export async function markAll(host: Host, app: string, gs: Group[]) {
  for (const g of gs) await markRead(host, app, g);
}

/** The app's own tap action (contentIntent): opens the conversation in Discord / WhatsApp / Gmail. */
export function openEntry(host: Host, app: string, e: Entry) {
  void host.notifications?.open(app, e.n.key).catch((err) => console.warn("[needs-me] open", say(err)));
}

/** [g]'s state, while its newest message is the one it was about. */
export function stateOf(g: Group): RowState | null {
  const s = rowState.value[g.id];
  return s && s.time === g.time ? s : null;
}
