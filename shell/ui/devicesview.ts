/**
 * The AI page's Devices tab, pure (shell/test/devicesview.test.ts): the owner's devices signed in to the Pow account
 * (the realm's GET /v1/devices, PowStation enroll/powos-enroll.py "listed") as rows - this device first, then online,
 * then by last seen; revoked ones apart ("Removed"). The user, 11-25: "The devices page should show the paired devices
 * which are signed in". No token ever reaches the page: the realm never sends one, PowStation.kt holds this phone's.
 */

/** One device of the account as the realm lists it (seconds since the epoch; every field but id may be missing). */
export interface AccountDevice {
  id: string;
  name?: string;
  kind?: string;
  model?: string;
  platform?: string;
  enrolled?: number;
  last_seen?: number | null;
  revoked?: number | null;
  approver?: boolean;
  self?: boolean;
  sync?: { at?: number; ok?: boolean; offline?: boolean; why?: string; missing?: string[]; missing_n?: number } | null;
}

/** Called within this long: online (account sync calls the realm every 30 s, its back-off is 120 s). */
export const ONLINE_S = 180;

/** The icon a kind gets (icons.tsx names). */
export function kindIcon(kind = ""): "cellphone" | "monitor" | "server" | "television" {
  const k = kind.toLowerCase();
  if (/phone|tablet|fold|android/.test(k)) return "cellphone";
  if (/server|hub|vm|nas/.test(k)) return "server";
  if (/tv|television/.test(k)) return "television";
  return "monitor";
}

/** "now", "2 min ago", "3 h ago", "yesterday", "4 days ago": how long ago [t] (seconds) was at [now] (seconds). */
export function relAgo(t: number, now: number) {
  const s = Math.max(0, now - t);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  const d = Math.floor(s / 86400);
  return d === 1 ? "yesterday" : `${d} days ago`;
}

/** Online: this device (it is asking), or it called the realm within ONLINE_S. */
export const isOnline = (d: AccountDevice, now: number) => !!d.self || (!!d.last_seen && now - d.last_seen < ONLINE_S);

/** Its presence line: "online", "seen 3 h ago", "not seen yet". */
export function presence(d: AccountDevice, now: number) {
  if (isOnline(d, now)) return "online";
  return d.last_seen ? `seen ${relAgo(d.last_seen, now)}` : "not seen yet";
}

/** Its account sync in a few words ("" when it never reported): missing apps first, then how fresh. */
export function syncLine(d: AccountDevice, now: number) {
  const s = d.sync;
  if (!s) return "";
  const n = s.missing_n ?? s.missing?.length ?? 0;
  if (n) return `${n} app${n === 1 ? "" : "s"} missing`;
  return s.ok && s.at ? `synced ${relAgo(s.at, now)}` : syncTrouble(s);
}

/** A round that didn't finish: waiting for the LAN/VPN, or another reason. */
const syncTrouble = (s: NonNullable<AccountDevice["sync"]>) => (s.offline ? "sync waits for home" : s.why ? "not syncing" : "");

/** What it is, in its muted line: its model, else its platform, else its kind. */
export const whatIs = (d: AccountDevice) => d.model || d.platform || d.kind || "";

/** The list as shown: signed in (this device, online, most recently seen, name) and removed (most recent first). */
export function devicesView(list: AccountDevice[], now: number) {
  const name = (d: AccountDevice) => (d.name || d.id).toLowerCase();
  const signedIn = list
    .filter((d) => !d.revoked)
    .sort(
      (a, b) =>
        Number(!!b.self) - Number(!!a.self) ||
        Number(isOnline(b, now)) - Number(isOnline(a, now)) ||
        (b.last_seen ?? 0) - (a.last_seen ?? 0) ||
        name(a).localeCompare(name(b)),
    );
  const removed = list.filter((d) => d.revoked).sort((a, b) => (b.revoked ?? 0) - (a.revoked ?? 0));
  return { signedIn, removed, online: signedIn.filter((d) => isOnline(d, now)).length };
}

/** [list] with device [id] changed by [f] (a new array; the rest untouched). */
export const withDevice = (list: AccountDevice[], id: string, f: (d: AccountDevice) => AccountDevice) =>
  list.map((d) => (d.id === id ? f(d) : d));
