/**
 * What needs me's model: the notifications Discord, WhatsApp and Gmail posted on this phone (host.notifications, the
 * packages powos-app.json permits), made into rows - who, one line, when - grouped per person or conversation, and
 * across apps when it's clearly the same person (the same display name). Pure: no host calls here.
 *
 * Which of a notification's own buttons does what: the reply is its action taking typed text (RemoteInput; the one the
 * app marks SEMANTIC_ACTION_REPLY first), mark-as-read is SEMANTIC_ACTION_MARK_AS_READ (or a button so named).
 */

export interface Message {
  sender: string;
  text: string;
  time: number;
}
export interface Notif {
  key: string;
  app: string;
  icon: string | null;
  title: string;
  text: string;
  /** Unix seconds. */
  time: number;
  clearable: boolean;
  pkg?: string;
  actions?: { title: string; input: boolean; semantic?: number }[];
  messages?: Message[];
  conversationTitle?: string | null;
  groupConversation?: boolean;
  tappable?: boolean;
}
export interface NotifList {
  available: boolean;
  items: Notif[];
}

/** The apps it reads, by package, as the filters name them. */
export const SOURCES: Record<string, string> = {
  "com.discord": "Discord",
  "com.whatsapp": "WhatsApp",
  "com.whatsapp.w4b": "WhatsApp",
  "com.google.android.gm": "Gmail",
};
export const sourceOf = (n: Notif) => SOURCES[n.pkg ?? ""] ?? n.app;

const REPLY = 1;
const MARK_READ = 2;
const READ_TITLE = /^(mark( as)? read|als gelesen markieren|marquer comme lu|marcar como le[ií]do|segna come letto)$/i;

/** One notification as a row's part. */
export interface Entry {
  n: Notif;
  who: string;
  line: string;
  /** Unix ms. */
  time: number;
  /** Messages waiting in it (after the user's own last one), at least 1. */
  count: number;
  /** Its reply action's index, -1: none. */
  reply: number;
  /** Its mark-as-read action's index, -1: none (a swipe dismisses it instead). */
  read: number;
  /** The user's own message is its last (they answered: nothing needs them there). */
  answered: boolean;
}

/** A row: one person or conversation, newest first inside. */
export interface Group {
  id: string;
  who: string;
  entries: Entry[];
  time: number;
  count: number;
}

export function replyIndex(n: Notif): number {
  const a = n.actions ?? [];
  const best = a.findIndex((x) => x.input && x.semantic === REPLY);
  return best >= 0 ? best : a.findIndex((x) => x.input);
}

export function readIndex(n: Notif): number {
  const a = n.actions ?? [];
  const best = a.findIndex((x) => x.semantic === MARK_READ);
  return best >= 0 ? best : a.findIndex((x) => !x.input && READ_TITLE.test(x.title.trim()));
}

const lastOther = (ms: Message[]) => [...ms].reverse().find((m) => m.sender !== "");

/** Who it's from: a group conversation's title, else the last sender, else the notification's title. */
function who(n: Notif, ms: Message[]): string {
  if (n.groupConversation && n.conversationTitle) return n.conversationTitle;
  return lastOther(ms)?.sender || n.conversationTitle || n.title || n.app;
}

function line(n: Notif, ms: Message[]): string {
  const last = ms[ms.length - 1];
  if (!last) return n.text || n.title;
  if (last.sender === "") return `You: ${last.text}`;
  return n.groupConversation ? `${last.sender}: ${last.text}` : last.text;
}

function waiting(ms: Message[]): number {
  let c = 0;
  for (let i = ms.length - 1; i >= 0 && ms[i].sender !== ""; i--) c++;
  return Math.max(1, c);
}

export function entry(n: Notif): Entry {
  const ms = n.messages ?? [];
  const last = ms[ms.length - 1];
  return {
    n,
    who: who(n, ms),
    line: line(n, ms),
    time: last?.time || n.time * 1000,
    count: ms.length ? waiting(ms) : 1,
    reply: replyIndex(n),
    read: readIndex(n),
    answered: last?.sender === "",
  };
}

/** A display name compared loosely: case, accents, emoji and punctuation aside. */
export const sameName = (s: string) =>
  s
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim()
    .toLowerCase();

const groupKey = (e: Entry) => (e.n.groupConversation ? `c:${e.n.pkg}:${e.who}` : `p:${sameName(e.who)}`);

/** The rows, newest first: notifications the user already answered left out. */
export function groups(items: Notif[]): Group[] {
  const by = new Map<string, Group>();
  for (const e of items.map(entry)) {
    if (e.answered) continue;
    const id = groupKey(e);
    const g = by.get(id) ?? { id, who: e.who, entries: [], time: 0, count: 0 };
    g.entries.push(e);
    g.count += e.count;
    g.time = Math.max(g.time, e.time);
    by.set(id, g);
  }
  const out = [...by.values()];
  for (const g of out) g.entries.sort((a, b) => b.time - a.time);
  return out.sort((a, b) => b.time - a.time);
}

/** The entry a reply goes to: the newest one that takes one. */
export const replyTarget = (g: Group) => g.entries.find((e) => e.reply >= 0) ?? null;

/** "now", "5m", "2h", "Mon", "12 Oct". */
export function ago(ms: number, now = Date.now()): string {
  const s = Math.max(0, (now - ms) / 1000);
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  const d = new Date(ms);
  return s < 6 * 86400 ? d.toLocaleDateString([], { weekday: "short" }) : d.toLocaleDateString([], { day: "numeric", month: "short" });
}
