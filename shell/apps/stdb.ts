/**
 * The device's SpacetimeDB, for the shell and the PowOS apps' islands it hosts (docs/POWOS-APPS-FEASIBILITY.md
 * section 3): a direct WebSocket to ws://127.0.0.1:3410 - loopback is a secure context, so an https page may open it,
 * and the port is locked to the PowOS uid (rooted/powos-start.sh), which this WebView runs as.
 *
 * One connection per database for the whole page, however many islands use it, opened on first use and closed
 * 5 s after the last user lets go - or after the page has been hidden (home off screen, screen off) for 5 s, so a
 * home nobody looks at holds no socket and SpacetimeDB can unload the database (the supervisor's idle policy).
 * Hidden -> visible connects again and resubscribes.
 *
 * Identity: the server's own token per database, kept in this page's storage. HACK: the shell should mint each app's
 * token as the trusted issuer (section 3, "one issuer per device set"), so one user is one identity on every device;
 * until that exists the server issues anonymous ones.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { openUrl, power, useLayoutSize, useOnScreen, useQuiet } from "./onscreen.ts";
import { useSurface, type Surface } from "./native.ts";
import { openApp } from "./pages.ts";
import { net, type Net } from "./net.ts";
import { DetailSheet, type DetailSheetProps } from "./sheet.ts";

export const STDB_URL = "ws://127.0.0.1:3410";
const GRACE_MS = 5000;

export type Status = "connecting" | "connected" | "disconnected" | "error";

/** What an island needs from the host: its database's connection and live rows. */
export interface IslandHost {
  /**
   * [schema]: the bindings' fingerprint (`powos app build` defines it): another one than the connection was made with
   * (the module's schema changed, the UI rebuilt with its new bindings) makes the connection again with these.
   */
  useDb(database: string, DbConnection: Builder, schema?: string): Db;
  useRows<T = any>(db: Db, table: string, query: string): T[];
  /** The element on screen, home shown and uncovered (apps/onscreen.ts): an island that animates stops without it. */
  useOnScreen?(ref: { current: Element | null }): boolean;
  /** Opens a link outside the shell (the browser). */
  openUrl?(url: string): Promise<unknown>;
  /** The battery: level, charging, battery saver (apps/onscreen.ts). */
  power?(): Promise<{ level: number | null; charging: boolean; saver: boolean | null }>;
  /** The element's laid-out size (CSS px, no transforms), measured again on resume (apps/onscreen.ts). */
  useLayoutSize?(ref: { current: HTMLElement | null }): { width: number; height: number };
  /** A native surface at the element's place (apps/native.ts): frames to it cost no page composite. */
  useSurface?(ref: { current: Element | null }, wanted: boolean): Surface;
  /** Home quiet - nothing else open or moving, no long frames lately (apps/onscreen.ts): animate only then. */
  useQuiet?(): boolean;
  /** Opens an installed PowOS app's full-screen page (apps/pages.ts) - a widget's tap opening its app. */
  openApp?(id: string): void;
  /** The devices and services the app's manifest declares in "net" (apps/net.ts): fetch, server-sent events, mDNS. */
  net?: Net;
  /** The widget detail sheet (apps/sheet.ts): a widget's other controls in a frosted popup anchored to it. */
  DetailSheet?: (p: DetailSheetProps) => null;
}

export interface Builder {
  builder(): any;
}

export interface Db {
  conn: any | null;
  status: Status;
  error?: string;
  /** Bumped on every (re)connect: a hook keyed on it resubscribes. */
  epoch: number;
  /** Tables whose bindings don't match the server's (undecodable): not subscribed (see undecodable). */
  stale?: string[];
}

interface Entry extends Db {
  database: string;
  make: Builder;
  schema?: string;
  users: number;
  listeners: Set<() => void>;
  drop?: number;
}

const entries = new Map<string, Entry>();
const tokenKey = (db: string) => `powos.stdb.token.${db}`;

function changed(e: Entry) {
  for (const l of e.listeners) l();
}

/**
 * A message the SDK couldn't decode (its rows don't fit the bindings: a module published with other tables than the
 * bindings were generated from - local-pet's `overlay` column, 2026-10-21 - or a truncated message). The SDK throws it
 * out of its socket handler, an unhandled rejection with no name on it. Instead: which tables differ from the server's
 * (its schema over HTTP), reported with the database's name; those aren't subscribed again, and the database gets a
 * new connection - everyone else on it resubscribes.
 */
async function undecodable(e: Entry, conn: unknown, err: unknown) {
  if (e.conn !== conn) return;
  try {
    e.conn?.disconnect();
  } catch {}
  e.conn = null;
  e.status = "error";
  e.error = String((err as Error)?.message ?? err);
  changed(e);
  const stale: string[] = [];
  try {
    const s = await (await fetch(`${STDB_URL.replace("ws", "http")}/v1/database/${e.database}/schema?version=9`)).json();
    for (const t of Object.values<any>(e.make.builder().remoteModule.tables)) {
      const live = s.tables.find((x: any) => x.name === t.sourceName);
      const want = live ? s.typespace.types[live.product_type_ref].Product.elements.map((c: any) => c.name.some) : [];
      const have = Object.entries<any>(t.columns).map(([k, c]) => c.columnMetadata?.name ?? k);
      if (want.join() !== have.join()) stale.push(`${t.sourceName} (bindings: ${have.join(", ")}; server: ${want.join(", ") || "no such table"})`);
    }
  } catch {}
  e.stale = stale.map((t) => t.split(" ")[0]);
  (window as any).__powosBoot?.report(
    "stdb",
    `${e.database}: a message didn't decode (${e.error}) - ` +
      (stale.length ? `bindings stale for ${stale.join("; ")}: not subscribed` : "reconnecting"),
  );
  window.setTimeout(() => {
    if (entries.get(e.database) === e && e.users > 0 && !e.conn) connect(e);
  }, 3000);
}

/** The SDK's socket, its message handler in a try (undecodable): through the builder's public connection factory. */
function guarded(b: any, e: Entry) {
  const make = b.dbConnectionCtor;
  let conn: unknown;
  b.dbConnectionCtor = (cfg: any) =>
    (conn = make({
      ...cfg,
      createWSFn: async (args: unknown) => {
        const ws = await cfg.createWSFn(args);
        return {
          get protocol() {
            return ws.protocol;
          },
          get readyState() {
            return ws.readyState;
          },
          set onopen(f: any) {
            ws.onopen = f;
          },
          set onclose(f: any) {
            ws.onclose = f;
          },
          set onerror(f: any) {
            ws.onerror = f;
          },
          set onmessage(f: any) {
            ws.onmessage = (m: unknown) => {
              try {
                f(m);
              } catch (err) {
                void undecodable(e, conn, err);
              }
            };
          },
          send: (d: unknown) => ws.send(d),
          close: () => ws.close(),
        };
      },
    }));
  return b;
}

function connect(e: Entry) {
  let token: string | undefined;
  try {
    token = localStorage.getItem(tokenKey(e.database)) ?? undefined;
  } catch {}
  e.status = "connecting";
  const mine = (c: unknown) => c === e.conn;
  e.conn = guarded(e.make.builder(), e)
    .withUri(STDB_URL)
    .withDatabaseName(e.database)
    .withToken(token)
    // A dropped socket (the screen off, Doze, a server restart - the supervisor's idle unload) comes back by itself,
    // its subscriptions with it.
    .withAutomaticReconnect()
    .onAutomaticReconnect((c: unknown) => {
      if (!mine(c)) return;
      e.status = "connected";
      e.error = undefined;
      changed(e);
    })
    .onConnect((c: unknown, _id: unknown, tok: string) => {
      if (!mine(c)) return;
      try {
        localStorage.setItem(tokenKey(e.database), tok);
      } catch {}
      e.status = "connected";
      e.error = undefined;
      e.epoch++;
      changed(e);
    })
    // A replaced connection's callbacks (undecodable, new bindings) no longer speak for the database.
    .onDisconnect((c: unknown) => {
      if (!mine(c)) return;
      e.status = "disconnected";
      changed(e);
    })
    .onConnectError((c: unknown, err: Error) => {
      if (!mine(c)) return;
      // A token from another server (its keys changed): forget it and try anonymously once.
      if (token) {
        try {
          localStorage.removeItem(tokenKey(e.database));
        } catch {}
      }
      e.status = "error";
      e.error = String(err?.message ?? err);
      changed(e);
      // A first connection isn't retried by the SDK: again in 3 s while anyone still uses it.
      window.setTimeout(() => {
        if (entries.get(e.database) === e && e.users > 0 && e.status === "error") connect(e);
      }, 3000);
    })
    .build();
  changed(e);
}

function release(e: Entry) {
  e.users--;
  if (e.users > 0) return;
  clearTimeout(e.drop);
  e.drop = window.setTimeout(() => {
    if (e.users > 0) return;
    try {
      e.conn?.disconnect();
    } catch {}
    entries.delete(e.database);
  }, GRACE_MS);
}

function acquire(database: string, make: Builder, schema?: string): Entry {
  let e = entries.get(database);
  if (!e) {
    e = { database, make, schema, users: 0, listeners: new Set(), conn: null, status: "connecting", epoch: 0 };
    entries.set(database, e);
    connect(e);
  } else if (schema && schema !== e.schema) {
    // The app's UI hot-reloaded with new bindings: the rows of the new schema need them (the old ones would misread
    // a new column). Everyone on it gets the new connection (epoch: their subscriptions are made again).
    try {
      e.conn?.disconnect();
    } catch {}
    e.make = make;
    e.schema = schema;
    e.stale = undefined;
    connect(e);
  }
  clearTimeout(e.drop);
  e.users++;
  return e;
}

/** True while the page is shown (home on screen). */
function useVisible() {
  const [v, setV] = useState(!document.hidden);
  useEffect(() => {
    const on = () => setV(!document.hidden);
    document.addEventListener("visibilitychange", on);
    return () => document.removeEventListener("visibilitychange", on);
  }, []);
  return v;
}

export function useDb(database: string, make: Builder, schema?: string): Db {
  const visible = useVisible();
  const [, force] = useState(0);
  const ref = useRef<Entry | null>(null);
  useEffect(() => {
    if (!visible) return;
    const e = acquire(database, make, schema);
    ref.current = e;
    const l = () => force((n) => n + 1);
    e.listeners.add(l);
    force((n) => n + 1);
    return () => {
      e.listeners.delete(l);
      release(e);
      ref.current = null;
      force((n) => n + 1);
    };
  }, [database, visible, schema]);
  const e = ref.current;
  return e ? { conn: e.conn, status: e.status, error: e.error, epoch: e.epoch, stale: e.stale } : { conn: null, status: "disconnected", epoch: 0 };
}

/** A table's rows as [query] subscribes them, live: re-rendered on every insert, update and delete. */
/** The SDK's accessor for a table: its name in camelCase (shopping_item -> shoppingItem). */
const accessor = (conn: any, table: string) => conn.db[table] ?? conn.db[table.replace(/_([a-z0-9])/g, (_, c: string) => c.toUpperCase())];

export function useRows<T = any>(db: Db, table: string, query: string): T[] {
  const [rows, setRows] = useState<T[]>([]);
  useEffect(() => {
    if (!db.conn || db.status !== "connected" || db.stale?.includes(table)) return;
    const t = accessor(db.conn, table);
    if (!t) return;
    const refresh = () => setRows([...t.iter()] as T[]);
    t.onInsert(refresh);
    t.onDelete(refresh);
    t.onUpdate?.(refresh);
    const sub = db.conn.subscriptionBuilder().onApplied(refresh).subscribe(query);
    return () => {
      t.removeOnInsert(refresh);
      t.removeOnDelete(refresh);
      t.removeOnUpdate?.(refresh);
      try {
        sub.unsubscribe();
      } catch {}
    };
  }, [db.conn, db.epoch, db.status, table, query]);
  return rows;
}

/**
 * A table's rows outside any component (the shell's own lists - the registry's apps in the drawer): [onRows] on every
 * change, subscribed while the page is shown, let go 5 s after it's hidden like an island's (so a home nobody looks
 * at holds no socket). Returns a stop.
 */
export function watchRows<T = any>(database: string, make: Builder, table: string, query: string, onRows: (rows: T[]) => void) {
  let e: Entry | null = null;
  let detach: (() => void) | null = null;
  let seen: { conn: any; epoch: number; status: Status } | null = null;
  const attach = () => {
    detach?.();
    detach = null;
    const t = e?.conn ? accessor(e.conn, table) : null;
    if (!e || !t || e.status !== "connected" || e.stale?.includes(table)) return;
    const refresh = () => onRows([...t.iter()] as T[]);
    t.onInsert(refresh);
    t.onDelete(refresh);
    t.onUpdate?.(refresh);
    const sub = e.conn.subscriptionBuilder().onApplied(refresh).subscribe(query);
    detach = () => {
      t.removeOnInsert(refresh);
      t.removeOnDelete(refresh);
      t.removeOnUpdate?.(refresh);
      try {
        sub.unsubscribe();
      } catch {}
    };
  };
  // As useRows: subscribed again on a new connection, a reconnect, or connected again.
  const listener = () => {
    if (!e) return;
    const now = { conn: e.conn, epoch: e.epoch, status: e.status };
    if (seen && seen.conn === now.conn && seen.epoch === now.epoch && seen.status === now.status) return;
    seen = now;
    attach();
  };
  const start = () => {
    if (e) return;
    e = acquire(database, make);
    e.listeners.add(listener);
    listener();
  };
  const stop = () => {
    if (!e) return;
    detach?.();
    detach = null;
    e.listeners.delete(listener);
    release(e);
    e = null;
    seen = null;
  };
  const visibility = () => (document.hidden ? stop() : start());
  document.addEventListener("visibilitychange", visibility);
  visibility();
  return () => {
    document.removeEventListener("visibilitychange", visibility);
    stop();
  };
}

export const host: IslandHost = {
  useDb,
  useRows,
  useOnScreen,
  openUrl,
  power,
  useLayoutSize,
  useSurface,
  useQuiet,
  openApp: (id) => openApp(id),
  net,
  DetailSheet,
};
