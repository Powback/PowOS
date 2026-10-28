/**
 * A composed widget's runtime (lib/apps/powos-compose, docs/COMPOSER.md): it reads the composition's building blocks
 * and turns what they return into rows. Generated with the app - edit composition.json, then `powos compose build`.
 *
 * The one way it reaches another app: App API's call path on this device (tools/app-api/appcap_serve.py on
 * 127.0.0.1:3411, the manifest's only "net" host) with consumer "widget" - the runtime itself refuses anything but a
 * `read` action for that consumer, so a widget can't change a light or spend, whatever this code asked. It never
 * writes another app's tables; what it read is kept in ITS OWN database (the snapshot table, reducer keep), so the
 * last state shows greyed while a block is away, and other compositions can subscribe to it.
 */
import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import { useApp, type Host } from "./app";

export interface Use {
  as: string;
  block: "appcap";
  app: string;
  action: string;
  /** The block's own name ("Philips Hue"): what a failure line names. */
  name?: string;
  args?: Record<string, string | number | boolean>;
}
/**
 * An Android app's own widget as a block (source "widget"): read in this island through the host's bridge
 * (host.appWidget: the widget's view tree as data), so what it shows never leaves the phone. [appWidgetId] is the
 * placed widget's id; when it's gone (re-added) the host finds it again by [provider].
 */
export interface AndroidUse {
  as: string;
  block: "android";
  source: "widget";
  provider: string;
  appWidgetId?: number;
  name?: string;
}
/** The native-card template's composition: one android block drawn as a PowOS glass card. */
export interface CardComposition {
  spec: "powos.compose/v1";
  kind: "widget";
  id: string;
  name: string;
  words?: string;
  uses: AndroidUse[];
  show: { template: "native-card"; title: string; from: string; empty?: string };
  open?: string;
}
export interface RowSpec {
  from: string;
  path?: string;
  key?: string;
  label: string;
  fields?: Record<string, string>;
  unit?: string;
}
export interface Join {
  from: string;
  path?: string;
  key: string;
  fields: Record<string, string>;
}
export interface Composition {
  spec: "powos.compose/v1";
  kind: "widget";
  id: string;
  name: string;
  words?: string;
  uses: Use[];
  show: { template: "status-list"; title: string; rows: RowSpec; join?: Join[]; empty?: string };
  refresh?: { poll_s?: number };
  open?: string;
}
export interface Row {
  key: string;
  label: string;
  on?: boolean;
  level?: number;
  value?: string;
}

/** App API's runtime on this device: never the Mac, never the cloud (on the phone its port is the PowOS uid's). */
export const API = "http://127.0.0.1:3411";

/** [path] in [o]: "metadata.name", "data.0.id"; "" = [o] itself. */
export function get(o: unknown, path = ""): unknown {
  let v = o;
  for (const p of path ? path.split(".") : []) {
    if (v === null || typeof v !== "object") return undefined;
    v = (v as Record<string, unknown>)[p];
  }
  return v;
}

/** The rows at [path]: a list as it is, one object as one row. */
export function rowsOf(o: unknown, path?: string): Record<string, unknown>[] {
  const v = get(o, path);
  if (Array.isArray(v)) return v.filter((x) => x && typeof x === "object") as Record<string, unknown>[];
  return v && typeof v === "object" ? [v as Record<string, unknown>] : [];
}

const text = (v: unknown) => (v === undefined || v === null ? "" : typeof v === "number" ? String(Math.round(v * 10) / 10) : String(v));

function fieldsOf(r: Record<string, unknown>, fields: Record<string, string> = {}): Partial<Row> {
  const out: Partial<Row> = {};
  if (fields.on) out.on = get(r, fields.on) === true;
  const lv = Number(get(r, fields.level ?? "\0"));
  if (fields.level && Number.isFinite(lv)) out.level = Math.max(0, Math.min(100, lv));
  if (fields.value) out.value = text(get(r, fields.value));
  return out;
}

/** The composition's rows from what each block returned ([data] by `uses[].as`): the rows, their joins' fields. */
export function build(c: Composition, data: Record<string, unknown>): Row[] {
  const spec = c.show.rows;
  const joins = (c.show.join ?? []).map((j) => {
    const by = new Map<string, Record<string, unknown>>();
    for (const r of rowsOf(data[j.from], j.path)) by.set(text(get(r, j.key)), r);
    return { j, by };
  });
  return rowsOf(data[spec.from], spec.path).map((r, i) => {
    const key = spec.key ? text(get(r, spec.key)) : String(i);
    const label = spec.label.startsWith("=") ? spec.label.slice(1) : text(get(r, spec.label));
    const row: Row = { key, label, ...fieldsOf(r, spec.fields) };
    for (const { j, by } of joins) {
      const hit = by.get(key);
      if (hit) Object.assign(row, fieldsOf(hit, j.fields));
    }
    if (row.value && spec.unit) row.value += spec.unit;
    return row;
  });
}

/** The call path said no (not linked, not allowed, not running): its reason, said calmly. */
export class Refused extends Error {}

/** One read of [use], through App API as a widget. */
export async function read(host: Host, app: string, use: Use): Promise<unknown> {
  if (!host.net) throw new Refused("Update the PowOS app to show this");
  const q = `app=${encodeURIComponent(use.app)}&action=${encodeURIComponent(use.action)}`;
  const r = await host.net.fetch(app, `${API}/call?${q}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: { app: use.app, action: use.action, args: use.args ?? {}, send: true, consumer: "widget" },
  });
  const j = r.json<{ refused?: string; error?: string; response?: unknown; response_sample?: string; preview?: { status?: unknown } }>();
  if (!j || j.error || j.refused) throw new Refused(String(j?.refused ?? j?.error ?? "no answer").replace(/^REFUSED:\s*/, ""));
  const st = Number(j.preview?.status);
  if (!(st >= 200 && st < 400)) throw new Refused(`couldn't read it (${text(j.preview?.status) || "no answer"})`);
  if (j.response !== undefined) return j.response;
  try {
    return JSON.parse(j.response_sample ?? "null");
  } catch {
    throw new Refused("its answer was cut off");
  }
}

/** One short line for the tile (two at most on a small one): never a raw IP or a stack. */
export function calm(e: unknown, name: string): string {
  const m = String((e as Error)?.message ?? e);
  const short = name.split(/\s+/).pop() || name;
  if (e instanceof Refused) {
    if (/link .* in App API|no pinned certificate|needs /i.test(m)) return `Link ${short} in App API`;
    if (/not enabled|allowlist/i.test(m)) return `${short} is off in App API`;
    if (/no app|no action|no such/i.test(m)) return "Not in App API yet";
    if (/update the powos app/i.test(m)) return "Update the PowOS app";
    return `Can't read ${short}`;
  }
  if (/refused|failed to connect|ECONNREFUSED|offline/i.test(m)) return "App API isn't running";
  return `Can't read ${short}`;
}

type Retry = { useRetry?: (load: () => unknown, failing: boolean) => () => void };

export type Phase = "loading" | "live" | "stale" | "failed";

interface Snapshot {
  source: string;
  json: string;
}

function parsed(s: Snapshot[]): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const x of s) {
    try {
      out[x.source] = JSON.parse(x.json);
    } catch {
      /* a snapshot that doesn't parse is no snapshot */
    }
  }
  return out;
}

/** Every block of [c] read now; the first source's failure is the composition's, a join's only loses its fields. */
async function readAll(host: Host, app: string, c: Composition) {
  const got: Record<string, unknown> = {};
  let fail: unknown = null;
  await Promise.all(
    c.uses.map(async (u) => {
      try {
        got[u.as] = await read(host, app, u);
      } catch (e) {
        if (u.as === c.show.rows.from) fail = e;
      }
    }),
  );
  return { got, fail };
}

/**
 * The composition, live: rows read every refresh.poll_s (at least 5 s) while the tile is on screen, a failing read
 * retried with host.net.useRetry's backoff, and the last good reads kept in this composition's own database.
 */
export function useComposition(host: Host, app: string, c: Composition, box: { current: Element | null }) {
  const db = useApp(host);
  const snaps = db.useTable<Snapshot>("snapshot");
  const keep = db.useReducer<{ source: string; json: string }>("keep");
  const kept = useMemo(() => parsed(snaps), [snaps]);
  const [live, setLive] = useState<Record<string, unknown> | null>(null);
  const [fail, setFail] = useState<unknown>(null);
  const onScreen = host.useOnScreen ? host.useOnScreen(box) : true;
  const busy = useRef(false);
  const load = async () => {
    if (busy.current) return;
    busy.current = true;
    try {
      const r = await readAll(host, app, c);
      setFail(r.fail);
      if (!r.fail) setLive(r.got);
      for (const [source, v] of Object.entries(r.got)) {
        const json = JSON.stringify(v);
        if (json.length < 256 * 1024 && JSON.stringify(kept[source]) !== json) keep({ source, json }).catch(() => {});
      }
    } finally {
      busy.current = false;
    }
  };
  // Read once when it mounts (a tile below the fold has its rows when it's scrolled to), then poll while it shows.
  useEffect(() => void load(), []);
  useEffect(() => {
    if (!onScreen) return;
    const t = window.setInterval(load, Math.max(5, c.refresh?.poll_s ?? 30) * 1000);
    return () => window.clearInterval(t);
  }, [onScreen]);
  const net = host.net as (Host["net"] & Retry) | undefined;
  const retry = net?.useRetry ? net.useRetry(load, !!fail) : load;
  const first = c.uses.find((u) => u.as === c.show.rows.from);
  const source = fail ? kept : (live ?? kept);
  const rows = build(c, source);
  const phase: Phase = fail ? (rows.length ? "stale" : "failed") : live ? "live" : rows.length ? "stale" : "loading";
  return { rows, phase, message: fail ? calm(fail, first?.name ?? c.name) : "", detail: fail ? String((fail as Error)?.message ?? fail) : "", retry };
}

// ------------------------------------------------------------------------------------------------ android blocks

type Box = [number, number, number, number];
export interface WidgetTree {
  w: number;
  h: number;
  texts: { t: string; role: "title" | "value" | "label"; size: number; b: Box }[];
  images: { ref: string; b: Box; d?: string }[];
  progress: { v: number; max: number; indeterminate: boolean; b: Box }[];
  lists: { b: Box; rows: string[][] }[];
  targets: { b: Box; label: string }[];
}
interface AndroidHost {
  idOf(provider: string): Promise<number | null>;
  data(id: number, on: (d: { id: number; at: number; tree: WidgetTree }) => void): () => void;
  frames(id: number, width: number, height: number, on: (url: string) => void): () => void;
  image(ref: string): Promise<string | null>;
  tap(id: number, x: number, y: number, size: [number, number]): Promise<void>;
}

/** Nothing the card can draw: the tree has no text, picture, progress or list rows. */
export const emptyTree = (t: WidgetTree | null) => !t || !(t.texts.length || t.images.length || t.progress.length || t.lists.some((l) => l.rows.length));

/**
 * An android block, live: its tree (null until the widget answers), its pictures by ref (data URLs, fetched once),
 * and - only while the tree is empty - the widget's own pixels as the fallback tile. "unavailable": this host can't
 * read widgets (older PowOS), "missing": the widget isn't on home any more.
 */
export function useAndroidBlock(host: Host, use: AndroidUse, size: [number, number]) {
  const ah = (host as Host & { appWidget?: AndroidHost }).appWidget;
  const [id, setId] = useState<number | null>(use.appWidgetId ?? null);
  const [tree, setTree] = useState<WidgetTree | null>(null);
  const [images, setImages] = useState<Record<string, string>>({});
  const [frame, setFrame] = useState<string | null>(null);
  const [late, setLate] = useState(false);
  const [missing, setMissing] = useState(false);
  useEffect(() => {
    if (!ah) return;
    let live = true;
    // The id written into the composition can be stale (the widget was removed and added again): look it up by provider.
    ah.idOf(use.provider).then((now) => {
      if (!live) return;
      if (now !== null) setId(now);
      else if (use.appWidgetId === undefined) setMissing(true);
    }).catch(() => {});
    return () => void (live = false);
  }, [use.provider]);
  useEffect(() => {
    if (!ah || id === null) return;
    const t = window.setTimeout(() => setLate(true), 4000);
    const off = ah.data(id, (d) => setTree(d.tree));
    return () => {
      window.clearTimeout(t);
      off();
    };
  }, [id]);
  useEffect(() => {
    if (!ah || !tree) return;
    for (const im of tree.images) {
      if (im.d || images[im.ref]) continue;
      ah.image(im.ref).then((u) => u && setImages((m) => ({ ...m, [im.ref]: u }))).catch(() => {});
    }
  }, [tree]);
  const fallback = !!ah && id !== null && (tree ? emptyTree(tree) : late);
  const [w, h] = size;
  useEffect(() => {
    if (!ah || id === null || !fallback || !w || !h) return;
    return ah.frames(id, Math.round(w), Math.round(h), setFrame);
  }, [id, fallback, Math.round(w), Math.round(h)]);
  const tap = (x: number, y: number, size: [number, number]) => (ah && id !== null ? ah.tap(id, x, y, size) : Promise.resolve());
  const phase = !ah ? "unavailable" : missing ? "missing" : fallback ? "fallback" : tree ? "live" : "loading";
  return { tree, images, frame, phase: phase as "unavailable" | "missing" | "fallback" | "live" | "loading", tap };
}
