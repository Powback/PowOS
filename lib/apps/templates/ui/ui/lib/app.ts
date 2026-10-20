/**
 * __NAME__'s connection to its database, through the host the PowOS shell gives every page and widget: one socket per
 * database for the whole shell however many of the app's surfaces show, opened while one is on screen. The hooks are
 * the spacetimedb-astro template's (useStatus / useTable / useReducer), on that host.
 *
 *   const app = useApp(host);
 *   const items = app.useTable<Entry>("entry");            // live rows: re-rendered on every change
 *   const add = app.useReducer("add");                     // await add({ text }) - throws the reducer's Err
 *
 * The bindings (../bindings) are generated from the module by `powos app build`: never edit them.
 */
import { DbConnection } from "../bindings";

/** The database `powos app install` publishes the module to (powos-app.json: module.database). */
export const DATABASE = "__DB__";

/** The bindings' fingerprint (`powos app build` defines it): a new schema makes the host reconnect with new bindings. */
declare const __POWOS_SCHEMA__: string;
const SCHEMA = typeof __POWOS_SCHEMA__ === "string" ? __POWOS_SCHEMA__ : undefined;

/** What the shell hands a page or a widget (shell/apps/stdb.ts IslandHost). */
export interface Host {
  useDb(database: string, make: unknown, schema?: string): Db;
  useRows<T = any>(db: Db, table: string, query: string): T[];
  /** Opens an installed app's full-screen page (this one's: openApp(app)). */
  openApp?(id: string): void;
  /** Opens a link outside the shell (the browser). */
  openUrl?(url: string): Promise<unknown>;
  /** The element on screen, home shown and uncovered: stop animating without it. */
  useOnScreen?(ref: { current: Element | null }): boolean;
  /** Nothing else open or moving on home: animate only then. */
  useQuiet?(): boolean;
}

export interface Db {
  conn: any | null;
  status: "connecting" | "connected" | "disconnected" | "error";
  error?: string;
  epoch: number;
}

/** Props of a page (ui/pages/*.tsx) and a widget (ui/widgets/*.tsx). */
export interface Props {
  host: Host;
  /** The app's id. */
  app: string;
  /** The app's UI dir as a URL ("./_app/<id>/"), for its own files: images, sounds. */
  base: string;
  /** A widget's size on home in cells, [w, h]. */
  cells?: [number, number];
  /** A page: closes it (Back does too). */
  close?: () => void;
}

/** The SDK names reducers and tables in camelCase (set_qty -> setQty); the module's own names work here too. */
const camel = (s: string) => s.replace(/_([a-z0-9])/g, (_, c: string) => c.toUpperCase());

export function useApp(host: Host) {
  const db = host.useDb(DATABASE, DbConnection, SCHEMA);
  return {
    db,
    /** "connected" once it's live. */
    useStatus: () => db.status,
    /** A table's rows, live (default query: the whole table). */
    useTable: <T = any>(table: string, query = `SELECT * FROM ${table}`) =>
      host.useRows<T>(db, db.conn && !db.conn.db?.[table] ? camel(table) : table, query),
    /** A reducer as an async function: resolves once the server ran it, throws its error message. */
    useReducer:
      <A extends object = Record<string, unknown>>(name: string) =>
      async (args: A = {} as A) => {
        if (!db.conn) throw new Error(`not connected (${db.status})`);
        const r = db.conn.reducers[name] ?? db.conn.reducers[camel(name)];
        if (!r) throw new Error(`this app's bindings have no reducer ${name} - rebuild it: powos app install <its folder>`);
        try {
          return await r.call(db.conn.reducers, args);
        } catch (e) {
          const msg = String((e as Error)?.message ?? e);
          // The module live on this device is another (older) one than the UI was built against.
          if (/no such reducer|reducer .*not found|unknown reducer/i.test(msg))
            throw new Error(`The app's module on this device is older than its UI (it has no ${name}): powos app install <its folder>`);
          throw e;
        }
      },
  };
}
