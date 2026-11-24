/**
 * Keyboard AI's connection to its database, through the host the PowOS shell gives every page (shell/apps/stdb.ts
 * IslandHost): one socket per database for the whole shell. The hooks are the spacetimedb-astro template's, as in
 * apps/health/ui/lib/app.ts. The bindings (../bindings) are generated from the module by `powos app build`.
 */
import { DbConnection } from "../bindings";

/** The database `powos app install` publishes the module to (powos-app.json: module.database). */
export const DATABASE = "powos-keyboard-ai";

declare const __POWOS_SCHEMA__: string;
const SCHEMA = typeof __POWOS_SCHEMA__ === "string" ? __POWOS_SCHEMA__ : undefined;

export interface Host {
  useDb(database: string, make: unknown, schema?: string): Db;
  useRows<T = any>(db: Db, table: string, query: string): T[];
}

export interface Db {
  conn: any | null;
  status: "connecting" | "connected" | "disconnected" | "error";
  error?: string;
  epoch: number;
}

export interface Props {
  host: Host;
  app: string;
  base: string;
  close?: () => void;
}

const camel = (s: string) => s.replace(/_([a-z0-9])/g, (_, c: string) => c.toUpperCase());

export function useApp(host: Host) {
  const db = host.useDb(DATABASE, DbConnection, SCHEMA);
  return {
    db,
    useTable: <T = any>(table: string, query = `SELECT * FROM ${table}`) =>
      host.useRows<T>(db, db.conn && !db.conn.db?.[table] ? camel(table) : table, query),
    useReducer:
      <A extends object = Record<string, unknown>>(name: string) =>
      async (args: A = {} as A) => {
        if (!db.conn) throw new Error(`not connected (${db.status})`);
        const r = db.conn.reducers[name] ?? db.conn.reducers[camel(name)];
        if (!r) throw new Error(`this app's bindings have no reducer ${name}`);
        return await r.call(db.conn.reducers, args);
      },
  };
}
