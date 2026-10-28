/**
 * App API's client: the local runtime on this device (tools/app-api/appcap_serve.py, the system tier's
 * lib/apps/services/app-api.json), reached through host.net - never the Mac, never the cloud. On the phone the port
 * is locked to the PowOS uid, so only PowOS reaches it. Everything it returns is handles, never a token.
 */
export const BASE = "http://127.0.0.1:3411";

export type Safety = "read" | "reversible-write" | "spend";

export interface Schema {
  type?: string;
  properties?: Record<string, Schema>;
  items?: Schema;
  required?: string[];
  minimum?: number;
  maximum?: number;
}

export interface Action {
  summary: string;
  safety: Safety;
  origin: string;
  enabled: boolean;
  widget?: boolean;
  confirm_template?: string;
  undo?: string;
  inputs?: Schema;
  output?: Schema;
  endpoint: string;
  auth?: string;
}

export interface AppSpec {
  app: string;
  name: string;
  description: string;
  enabled: boolean;
  base: string;
  /** This app's origin (official/captured/drafted), and its auth handle if any - appcap_serve.summary() sets
   * both (from the spec's own app-level fields, or derived from its actions for a spec that predates them). */
  origin: string;
  auth: string | null;
  actions: Record<string, Action>;
  /** An Android draft's analysed home-screen widgets (spec.android.widgets). */
  widgets?: AppWidget[];
  error?: string;
}

export interface Views {
  api: string;
  tools: string;
  cli: string;
  widgets: string;
}

export interface CallResult {
  preview?: Record<string, unknown>;
  response_sample?: string;
  refused?: string;
}

export interface AuditRow {
  ts: string;
  app: string;
  action: string;
  safety?: Safety;
  sent?: boolean;
  status?: number | string;
  refused?: string;
}

export interface TrackerSeen {
  tracker: string;
  host: string;
  category: string;
  blocked: number;
  allowed: number;
}

export interface Trackers {
  apps: { app: string; allow: boolean; seen: TrackerSeen[] }[];
  total: { apps: number; trackers: number; blocked: number; allowed: number };
}

/** A draft in review ("+ add app", appcap_add.py): never one of your apps until added. */
export interface DraftInfo {
  app: string;
  name: string;
  description: string;
  actions: number;
  reads: number;
  writes: number;
  /** An app of this id is in your apps already: adding is refused. */
  exists: boolean;
}

export interface InstalledPowos {
  id: string;
  name: string;
  database: string;
}

export interface AppLinks {
  pkg: string;
  label: string;
  links: { uri: string; activity?: string }[];
  widgets?: AppWidget[];
}

/** An Android app's home-screen widget (AppWidgetProvider); sizes in dp, targetCell* in grid cells. */
export interface AppWidget {
  provider: string;
  label: string;
  minWidth: number;
  minHeight: number;
  minResizeWidth?: number;
  minResizeHeight?: number;
  targetCellWidth?: number;
  targetCellHeight?: number;
  resize: string[];
  categories: string[];
  updatePeriodMs: number;
  preview: "image" | "layout" | "none";
  configure?: string;
}

/** What App API's page gets from the shell (apps/stdb.ts IslandHost): the runtime's net, and "+ add app"'s helpers. */
export interface Host {
  net?: Net;
  askAssistant?(text: string): void;
  androidApps?(): Promise<{ pkg: string; label: string }[]>;
  appLinks?(pkg: string): Promise<AppLinks>;
  /** Older shells lack it (feature-detect). */
  addAppWidget?(provider: string): Promise<"added">;
}

export interface Net {
  fetch(app: string, url: string, init?: { method?: string; headers?: Record<string, string>; body?: string | object }): Promise<{
    status: number;
    json<T = any>(): T;
  }>;
}

/** One call to the runtime: its JSON, or an Error with the runtime's own words. */
export async function call<T>(net: Net | undefined, app: string, path: string, body?: object): Promise<T> {
  if (!net) throw new Error("this PowOS app is too old for App API (no host.net)");
  const init = body ? { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) } : {};
  const r = await net.fetch(app, BASE + path, init);
  const data = r.json<T & { error?: string }>();
  if (r.status >= 400) throw new Error(data?.error || `runtime answered ${r.status}`);
  return data;
}

export const SAFETY: { id: Safety; label: string; note: string }[] = [
  { id: "read", label: "Read", note: "looks only, changes nothing" },
  { id: "reversible-write", label: "Reversible", note: "changes something you can undo" },
  { id: "spend", label: "Spend", note: "costs money or contacts others: always your yes in chat" },
];

/** A schema as one short line: "rooms: array of {id, name, on, brightness}". */
export function shape(s?: Schema): string {
  if (!s) return "-";
  if (s.type === "array") return `array of ${shape(s.items)}`;
  const p = s.properties && Object.keys(s.properties);
  if (p?.length) return `{${p.map((k) => `${k}: ${s.properties![k].type ?? "any"}`).join(", ")}}`;
  return s.type ?? "any";
}
