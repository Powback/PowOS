/**
 * What needs me's history (v2): a conversation stays a row after its notification goes - dismissed, marked read,
 * answered or cancelled by its app - with its last few messages, newest first, the user's own replies marked.
 *
 * The source is the notifications themselves, remembered on this phone as they come (this app's own localStorage,
 * nothing sent anywhere, no account): Discord, WhatsApp and Gmail have no App API data source with a message history
 * (docs/APP-API.md, "Streamlined consumer path": their providers are the AA2 gap, and a provider must stay ban-safe -
 * no token-replay of their servers), so what the phone was shown is the history there is. When App API grows a
 * provider for one of them, its rows merge in here by the same conversation id (model.ts groupKey).
 *
 * Bounded: [PER] messages per conversation, [CONVOS] conversations, nothing older than [DAYS] days.
 */
import { signal, type Signal } from "@preact/signals";
import { mdPlain } from "@powos/shared/mdplain";
import { entry, groupKey, sourceOf, type Group, type Notif } from "./model";

export const PER = 6;
export const CONVOS = 40;
export const DAYS = 7;
const ICON_MAX = 16_000;

/** One remembered message: [from] "" is the user's own. Unix ms. */
export interface Said {
  from: string;
  text: string;
  time: number;
}
/** One conversation as remembered: who, which apps (source names) and their icons, its messages oldest first. */
export interface Convo {
  id: string;
  who: string;
  apps: string[];
  icon: string | null;
  said: Said[];
}

type Store = Record<string, Convo>;

/** Per app id (the shell may host the app's islands in one origin): its store, loaded on first use. */
const stores = new Map<string, Signal<Store>>();
const keyOf = (app: string) => `${app}:history`;

function load(app: string): Store {
  try {
    const v = JSON.parse(localStorage.getItem(keyOf(app)) ?? "{}");
    return v && typeof v === "object" ? v : {};
  } catch {
    return {};
  }
}

function save(app: string, s: Store) {
  try {
    localStorage.setItem(keyOf(app), JSON.stringify(s));
  } catch {
    // A full or blocked storage: the history lives this session only; the live list is unaffected.
  }
}

export function store(app: string): Signal<Store> {
  let s = stores.get(app);
  if (!s) stores.set(app, (s = signal<Store>(load(app))));
  return s;
}

/** [s] bounded: old messages out, each conversation's last [PER], the newest [CONVOS] conversations. */
export function prune(s: Store, now = Date.now()): Store {
  const since = now - DAYS * 86400e3;
  const kept = Object.values(s)
    .map((c) => ({ ...c, said: c.said.filter((m) => m.time >= since).slice(-PER) }))
    .filter((c) => c.said.length)
    .sort((a, b) => b.said[b.said.length - 1].time - a.said[a.said.length - 1].time)
    .slice(0, CONVOS);
  return Object.fromEntries(kept.map((c) => [c.id, c]));
}

const same = (a: Said, b: Said) => a.from === b.from && a.text === b.text && Math.abs(a.time - b.time) < 2000;

function add(c: Convo, m: Said): boolean {
  if (!m.text || c.said.some((x) => same(x, m))) return false;
  c.said.push(m);
  c.said.sort((a, b) => a.time - b.time);
  return true;
}

/** What a notification says, as messages: its MessagingStyle ones, else its one line from its title. */
function saidIn(n: Notif): Said[] {
  if (n.messages?.length) return n.messages.map((m) => ({ from: m.sender, text: mdPlain(m.text), time: m.time || n.time * 1000 }));
  const text = mdPlain(n.text || n.title);
  return text ? [{ from: n.title || n.app, text, time: n.time * 1000 }] : [];
}

/** [was] with what [n] says added (the conversation [id], new when [was] is none); null when nothing was new. */
function withNotif(was: Convo | undefined, id: string, who: string, n: Notif): Convo | null {
  const c: Convo = was ? { ...was, apps: [...was.apps], said: [...was.said] } : { id, who, apps: [], icon: null, said: [] };
  let changed = !was;
  const app = sourceOf(n);
  if (!c.apps.includes(app)) {
    c.apps.push(app);
    changed = true;
  }
  // The app's picture for a past row, while it's a small one (a big avatar would fill the app's storage).
  if (n.icon && n.icon.length <= ICON_MAX && c.icon !== n.icon) {
    c.icon = n.icon;
    changed = true;
  }
  for (const m of saidIn(n)) changed = add(c, m) || changed;
  return changed ? c : null;
}

/** [s] with every message of [items] in it (a new object only when something was new). */
export function merge(s: Store, items: Notif[], now = Date.now()): Store {
  let next: Store | null = null;
  for (const n of items) {
    const e = entry(n);
    const id = groupKey(e);
    const c = withNotif((next ?? s)[id], id, e.who, n);
    if (c) (next ??= { ...s })[id] = c;
  }
  return next ? prune(next, now) : s;
}

/** The live notifications remembered (called as each list arrives). */
export function remember(app: string, items: Notif[]) {
  const s = store(app);
  const next = merge(s.value, items);
  if (next !== s.value) (s.value = next), save(app, next);
}

/** A reply the user sent from here, remembered at once (the app's notification shows it later, or never). */
export function rememberReply(app: string, g: Group, text: string) {
  const s = store(app);
  const c: Convo = s.value[g.id] ? { ...s.value[g.id], said: [...s.value[g.id].said] } : { id: g.id, who: g.who, apps: [], icon: null, said: [] };
  if (!add(c, { from: "", text, time: Date.now() })) return;
  const next = prune({ ...s.value, [g.id]: c });
  s.value = next;
  save(app, next);
}

/** A conversation forgotten (a past row swiped away): out of the history, back with its next message. */
export function forget(app: string, id: string) {
  const s = store(app);
  if (!s.value[id]) return;
  const { [id]: _, ...rest } = s.value;
  s.value = rest;
  save(app, rest);
}

/** The user's own message is the conversation's last: they answered it. */
export const replied = (c: Convo | undefined) => !!c?.said.length && c.said[c.said.length - 1].from === "";

/** "You: …" for the user's own, "Kai: …" in a group, else the text. */
export function lineOf(c: Convo, m: Said): string {
  if (m.from === "") return `You: ${m.text}`;
  return m.from && m.from !== c.who ? `${m.from}: ${m.text}` : m.text;
}

/**
 * The rows: the live ones (with their history) and a past row for each remembered conversation with nothing live,
 * all newest first. A past row needs nothing (count 0): the header's count and the icon's dot stay the live unread.
 */
export function withHistory(live: Group[], s: Store): Group[] {
  const ids = new Set(live.map((g) => g.id));
  const out: Group[] = live.map((g) => ({ ...g, history: s[g.id] ?? null, replied: false }));
  for (const c of Object.values(s)) {
    if (ids.has(c.id) || !c.said.length) continue;
    out.push({ id: c.id, who: c.who, entries: [], time: c.said[c.said.length - 1].time, count: 0, history: c, replied: replied(c) });
  }
  return out.sort((a, b) => b.time - a.time);
}
