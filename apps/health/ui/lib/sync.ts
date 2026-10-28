/**
 * The sync loop: pulls what Health Connect has (powos.health, through the host) and gives it to this app's `ingest`
 * reducer. It runs in the app's own surfaces - the page and the widget - while one is mounted (an app has no process
 * of its own): at once, every few minutes, when the page is shown again, and when a Health Connect grant comes back. One loop at a time however many surfaces.
 *
 * First run: a changes token is taken, then the last 30 days (all Health Connect lets an app read without the history
 * permission) are read in week windows and ingested. After: only the changes since the token. An expired token
 * (not synced for about 30 days) reads again from the newest sample kept and starts a fresh token.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import type { HealthBridge, HealthRecord, HealthType, Host } from "./app";

export type Phase = "idle" | "syncing" | "ok" | "needs-grant" | "update" | "none" | "unsupported" | "error";
export interface SyncState {
  phase: Phase;
  message?: string;
  /** How many samples the last run took in. */
  took?: number;
  at?: number;
}

export interface CursorRow {
  token: string;
  newest: bigint;
  synced: bigint;
}

export type Ingest = (a: { batch: { samples: IncomingRow[]; deleted: string[]; token: string; tzMin: number; now: bigint } }) => Promise<unknown>;
interface IncomingRow {
  id: string;
  kind: string;
  start: bigint;
  end: bigint;
  value: number;
  unit: string;
  source: string;
  detail: string;
}

const DAY = 86_400_000;
const WINDOW = 7 * DAY;
const FIRST_BACKFILL = 30 * DAY;
const CHUNK = 4000;
const EVERY_MS = 5 * 60_000;

let running = false;

const row = (r: HealthRecord): IncomingRow => ({
  id: r.id,
  kind: r.type,
  start: BigInt(Math.round(r.start)),
  end: BigInt(Math.round(r.end)),
  value: r.value,
  unit: r.unit,
  source: r.source,
  detail: r.detail ?? "",
});

/** The token is kept with the types it was made for: a new grant (more types) starts over from the newest sample. */
const pack = (token: string, types: HealthType[]) => JSON.stringify({ types, t: token });
function unpack(s: string): { types: HealthType[]; t: string } | null {
  try {
    const j = JSON.parse(s);
    return Array.isArray(j.types) && typeof j.t === "string" ? j : null;
  } catch {
    return null;
  }
}

interface Pass {
  h: HealthBridge;
  types: HealthType[];
  tz: number;
  now: number;
  ingest: Ingest;
}

/** Ingests [records] (and [deleted]) in chunks; the token goes with the last one. Resolves how many samples. */
async function send(p: Pass, records: HealthRecord[], deleted: string[], token: string): Promise<number> {
  const rows = records.map(row);
  let n = 0;
  do {
    const last = n + CHUNK >= rows.length;
    await p.ingest({ batch: { samples: rows.slice(n, n + CHUNK), deleted: n === 0 ? deleted : [], token: last ? token : "", tzMin: p.tz, now: BigInt(p.now) } });
    n += CHUNK;
  } while (n < rows.length);
  return rows.length;
}

/** Reads [from, now) in week windows and ingests each. */
async function backfill(p: Pass, from: number): Promise<number> {
  let took = 0;
  for (let t = from; t < p.now; t += WINDOW) took += await send(p, await p.h.read(p.types, t, Math.min(p.now, t + WINDOW)), [], "");
  return took;
}

/** Continues from a kept token: only what changed; an expired one reads again from the newest sample kept. */
async function follow(p: Pass, token: string, cursor: CursorRow | undefined): Promise<number> {
  const ch = await p.h.changes(p.types, token);
  if (!ch.expired) return send(p, ch.records, ch.deleted, pack(ch.token, p.types));
  const took = await backfill(p, Math.max(p.now - FIRST_BACKFILL, Number(cursor?.newest ?? 0n) - DAY));
  return took + (await send(p, [], [], pack(ch.token, p.types)));
}

/** The first pass (or after a new grant): a token first - a record written while reading comes with the first changes - then the reads. */
async function start(p: Pass, cursor: CursorRow | undefined): Promise<number> {
  const tok = await p.h.token(p.types);
  const newest = Number(cursor?.newest ?? 0n);
  const took = await backfill(p, newest > 0 ? newest - DAY : p.now - FIRST_BACKFILL);
  return took + (await send(p, [], [], pack(tok.token, p.types)));
}

const sameTypes = (kept: { types: HealthType[] } | null, types: HealthType[]) =>
  !!kept && kept.types.length === types.length && types.every((t) => kept.types.includes(t));

/** What a failed pass means for the page. */
function failure(e: unknown): SyncState {
  const message = String((e as Error)?.message ?? e);
  // A host whose APK lacks the call: the same as no bridge.
  if (/no such call/i.test(message)) return { phase: "unsupported", message: "The PowOS app on this phone has no Health Connect yet." };
  if (/permission|denied|SecurityException/i.test(message)) return { phase: "needs-grant", message };
  return { phase: "error", message };
}

/** The status, asking for the permission when [ask]; the granted types, or the state to show instead. */
async function grantedTypes(h: HealthBridge, ask: boolean): Promise<HealthType[] | SyncState> {
  let st = await h.status();
  if (st.state !== "ok") return { phase: st.state, message: st.state === "update" ? "Health Connect needs an update." : "This phone has no Health Connect." };
  if (st.missing.length && ask) st = await h.grant();
  return st.granted.length ? st.granted : { phase: "needs-grant", message: "Allow PowOS to read Health Connect." };
}

/** Reads and ingests one pass. [ask]: show Health Connect's permission dialog when something isn't granted yet. */
export async function syncOnce(host: Host, cursor: CursorRow | undefined, ingest: Ingest, ask: boolean): Promise<SyncState> {
  const h = host.health;
  if (!h) return { phase: "unsupported", message: "This PowOS has no Health Connect bridge (update the PowOS app)." };
  if (running) return { phase: "syncing" };
  running = true;
  try {
    const types = await grantedTypes(h, ask);
    if (!Array.isArray(types)) return types;
    const p: Pass = { h, types, tz: -new Date().getTimezoneOffset(), now: Date.now(), ingest };
    const kept = cursor?.token ? unpack(cursor.token) : null;
    const took = kept && sameTypes(kept, types) ? await follow(p, kept.t, cursor) : await start(p, cursor);
    return { phase: "ok", took, at: Date.now() };
  } catch (e) {
    return failure(e);
  } finally {
    running = false;
  }
}

/**
 * Keeps [syncOnce] going while the calling surface is mounted. [ready]: the database is connected and [cursor] is its
 * first read. [ask]: this surface may show the permission dialog (the page; the widget just says to open the app).
 */
export function useHealthSync(host: Host, o: { cursor: CursorRow | undefined; ready: boolean; ingest: Ingest; ask: boolean }) {
  const { cursor, ready, ingest, ask } = o;
  const [state, setState] = useState<SyncState>({ phase: "idle" });
  const latest = useRef({ cursor, ingest, ask });
  latest.current = { cursor, ingest, ask };
  const asked = useRef(false);
  const run = async (force = false) => {
    const { cursor: c, ingest: i, ask: a } = latest.current;
    const mayAsk = a && (force || !asked.current);
    if (mayAsk) asked.current = true;
    setState((s) => (s.phase === "ok" ? s : { phase: "syncing" }));
    const next = await syncOnce(host, c, i, mayAsk);
    if (next.phase !== "syncing") setState(next);
  };
  useEffect(() => {
    if (!ready) return;
    void run();
    const timer = window.setInterval(() => void run(), EVERY_MS);
    const shown = () => document.visibilityState === "visible" && void run();
    document.addEventListener("visibilitychange", shown);
    // A grant from any surface (Health Connect's sheet closed, HealthConnectBridge.kt): sync at once, not in 5 minutes.
    const granted = () => void run();
    window.addEventListener("powos:health-granted", granted);
    return () => {
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", shown);
      window.removeEventListener("powos:health-granted", granted);
    };
  }, [ready]);
  return { state, syncNow: () => run(true) };
}
