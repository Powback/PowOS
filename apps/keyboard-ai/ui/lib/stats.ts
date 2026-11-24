/**
 * What the page shows, as pure functions over the module's rows (apps/keyboard-ai/module/src/lib.rs): per app the
 * profiles, recent committed replies and learning switch; over time the pick rate (presses that ended in a pick) and the
 * mean edit distance from the picked draft to what was sent (0 = sent as drafted), per week from `day_stat`.
 */
export interface ReplyRow {
  id: string;
  session: string;
  app: string;
  contact: string;
  hint: string;
  drafts: string;
  action: string;
  picked: number;
  finalText: string;
  edit: number;
  sent: boolean;
  at: bigint;
  doneAt: bigint;
}
export interface ProfileRow { id: string; app: string; contact: string; text: string; outcomes: number; at: bigint }
export interface PrefRow { app: string; learn: boolean }
export interface StatRow { id: string; day: bigint; app: string; sessions: number; picks: number; editSum: number; editN: number }

export interface Totals { sessions: number; picks: number; pickRate: number | null; edit: number | null }
export interface Week extends Totals { start: number }

const DAY = 86_400_000;
const WEEK = 7 * DAY;

export function totals(stats: StatRow[]): Totals {
  let sessions = 0, picks = 0, editSum = 0, editN = 0;
  for (const s of stats) {
    sessions += s.sessions;
    picks += s.picks;
    editSum += s.editSum;
    editN += s.editN;
  }
  return { sessions, picks, pickRate: sessions ? picks / sessions : null, edit: editN ? editSum / editN : null };
}

/** The last [n] weeks (oldest first), each with its pick rate and mean edit distance. */
export function weeks(stats: StatRow[], now: number, n = 8): Week[] {
  const end = Math.floor(now / DAY) * DAY + DAY;
  return Array.from({ length: n }, (_, i) => {
    const start = end - (n - i) * WEEK;
    return { start, ...totals(stats.filter((s) => Number(s.day) >= start && Number(s.day) < start + WEEK)) };
  });
}

export interface AppView {
  app: string;
  learn: boolean;
  profile?: ProfileRow;
  contacts: ProfileRow[];
  recent: ReplyRow[];
  totals: Totals;
}

/** One entry per app the keyboard learned in or was switched off for, most recently used first. */
export function apps(replies: ReplyRow[], profiles: ProfileRow[], prefs: PrefRow[], stats: StatRow[]): AppView[] {
  const names = new Set([...replies, ...profiles, ...prefs, ...stats].map((r) => r.app));
  const last = (a: string) => Math.max(0, ...replies.filter((r) => r.app === a).map((r) => Number(r.at)));
  return [...names]
    .map((app) => ({
      app,
      learn: !prefs.some((p) => p.app === app && !p.learn),
      profile: profiles.find((p) => p.app === app && !p.contact),
      contacts: profiles.filter((p) => p.app === app && p.contact).sort((a, b) => Number(b.at - a.at)),
      recent: replies
        .filter((r) => r.app === app && r.action === "picked" && r.finalText.trim())
        .sort((a, b) => Number(b.at - a.at))
        .slice(0, 5),
      totals: totals(stats.filter((s) => s.app === app)),
    }))
    .sort((a, b) => last(b.app) - last(a.app) || a.app.localeCompare(b.app));
}

/** "com.whatsapp" -> "Whatsapp", "org.telegram.messenger" -> "Telegram". */
export function appName(pkg: string): string {
  const parts = pkg.split(".").filter((p) => !["com", "org", "net", "android", "app", "messenger", "apps"].includes(p));
  const w = parts[0] ?? pkg;
  return w.charAt(0).toUpperCase() + w.slice(1);
}

export const pct = (x: number | null) => (x == null ? "–" : `${Math.round(x * 100)}%`);
