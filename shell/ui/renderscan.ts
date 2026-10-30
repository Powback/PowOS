/**
 * Render scan (react-scan for Preact): which components render, how long, and which renders were needless. Built on
 * Preact's options hooks (the vendored build's mangled names: __r = _render, diffed, __c = _commit, __e = _catchError).
 * Zero cost when off: the hooks are installed only while someone uses it (a meter recording: perfrec.ts; the live
 * overlay: renderoverlay.ts; a dev/cdp session: window.__powosRenders) and the originals are put back after - the
 * gate checks options is untouched once the last user stops.
 *
 * A needless render: not the first (a mount), not triggered by a signal the component reads (@preact/signals sets
 * bit 1 of __$f before its setState), props shallow-equal to the last render's, state shallow-equal, and every hook's
 * value (useState/useReducer/useMemo/useRef: hook.__) the same object; a prop rebuilt with equal content (an array or
 * object made afresh each parent render) counts as unchanged, marked "name~". What did change is counted per prop
 * name, so a new inline function each parent render shows up as "onClick".
 * Times: inclusive (the component's whole subtree diff) and self (minus the child components' inclusive time).
 */
import { Fragment, options } from "preact";

type Hook = (...a: unknown[]) => void;
type Comp = { props: Record<string, unknown>; state: Record<string, unknown>; __$f?: number; __H?: { __: { __?: unknown }[] } };
type VNode = { type: unknown; __c?: Comp | null; __e?: Node | null };
type Frame = { v: VNode; t: number; child: number };
export type Stat = { name: string; renders: number; needless: number; selfMs: number; totalMs: number; signal: number; changed: Record<string, number> };
type Snap = { props: Record<string, unknown>; state: Record<string, unknown>; hooks: unknown[] };
type Commit = { t: number; ms: number; names: Record<string, number> };

const O = options as unknown as Record<string, Hook | undefined>;
const KEYS = ["__r", "diffed", "__c", "__e"] as const;
const MAX_COMMITS = 3000;

let saved: Record<string, Hook | undefined> | null = null, mine: Record<string, Hook> | null = null;
const users = new Set<string>();
let t0 = 0, stats = new Map<unknown, Stat>(), snaps = new WeakMap<Comp, Snap>(), stack: Frame[] = [];
let commits: Commit[] = [], pending: Record<string, number> = {}, pendingMs = 0;
/** Called per rendered component with its first DOM node (the overlay's outline). */
let onRendered: ((dom: Node | null | undefined, name: string, needless: boolean) => void) | null = null;

function nameOf(type: unknown): string {
  if (type === Fragment) return "Fragment"; // minified in the vendored build ("S")
  const f = type as { displayName?: string; name?: string };
  return f.displayName || f.name || "anonymous";
}
const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object";
const isVNode = (v: Record<string, unknown>) => v.type !== undefined && "props" in v;
/** Two objects worth comparing by content: plain objects or arrays of one kind (never vnodes, Sets, class instances). */
function comparable(a: Record<string, unknown>, b: Record<string, unknown>) {
  return Array.isArray(a) === Array.isArray(b) && !isVNode(a) && !isVNode(b) && !(a instanceof Set) && Object.getPrototypeOf(a) === Object.getPrototypeOf(b);
}
/** Same content in a new object (an array or object rebuilt each render): a few levels, a bounded number of keys. */
function sameValue(a: unknown, b: unknown, depth: number): boolean {
  if (a === b) return true;
  if (!isObj(a) || !isObj(b) || depth > 3) return false;
  if (a instanceof Map || b instanceof Map) return sameMap(a, b, depth);
  if (!comparable(a, b)) return false;
  const ka = Object.keys(a);
  if (ka.length !== Object.keys(b).length || ka.length > 64) return false;
  return ka.every((k) => sameValue(a[k], b[k], depth + 1));
}
function sameMap(a: object, b: object, depth: number): boolean {
  if (!(a instanceof Map) || !(b instanceof Map) || a.size !== b.size || a.size > 64) return false;
  for (const [k, v] of a) if (!b.has(k) || !sameValue(v, b.get(k), depth + 1)) return false;
  return true;
}
/**
 * The keys that changed, "~" marked when only the identity did (equal content: a rebuilt array/object) - those make a
 * render needless too (react-scan's rule); a new function is a real change (its closure may differ).
 */
function shallowDiff(a: Record<string, unknown>, b: Record<string, unknown>, out: string[], prefix: string) {
  for (const k in a) if (a[k] !== b[k]) out.push(prefix + k + (k in b && sameValue(a[k], b[k], 0) ? "~" : ""));
  for (const k in b) if (!(k in a)) out.push(prefix + k);
}
function hookValues(c: Comp): unknown[] {
  return (c.__H?.__ ?? []).map((h) => h.__).filter((v) => typeof v !== "function");
}
/** What changed since the component's last render (empty: nothing - needless unless a signal triggered it). */
function changes(c: Comp, prev: Snap): string[] {
  const out: string[] = [];
  shallowDiff(c.props, prev.props, out, "");
  shallowDiff(c.state ?? {}, prev.state ?? {}, out, "state.");
  const h = hookValues(c);
  if (h.length !== prev.hooks.length || h.some((v, i) => v !== prev.hooks[i])) out.push("hooks");
  return out;
}
function statOf(type: unknown): Stat {
  let s = stats.get(type);
  if (!s) stats.set(type, (s = { name: nameOf(type), renders: 0, needless: 0, selfMs: 0, totalMs: 0, signal: 0, changed: {} }));
  return s;
}
/** Before the component renders (after signals' and hooks' own _render: hook updates applied). */
function beforeRender(v: VNode, signal: boolean) {
  const c = v.__c;
  if (!c || typeof v.type !== "function") return;
  const s = statOf(v.type), prev = snaps.get(c);
  s.renders++;
  if (signal) s.signal++;
  let needless = false;
  if (prev && !signal) {
    const ch = changes(c, prev);
    needless = ch.every((k) => k.endsWith("~"));
    if (needless) s.needless++;
    for (const k of ch) s.changed[k] = (s.changed[k] ?? 0) + 1;
  }
  (v as VNode & { __rsN?: boolean }).__rsN = needless;
  stack.push({ v, t: performance.now(), child: 0 });
}
function afterDiff(v: VNode) {
  const top = stack[stack.length - 1];
  if (!top || top.v !== v) return; // not rendered (shouldComponentUpdate said no), or a DOM vnode
  stack.pop();
  const total = performance.now() - top.t, self = total - top.child, s = statOf(v.type), c = v.__c!;
  s.totalMs += total; s.selfMs += self; pendingMs += self;
  if (stack.length) stack[stack.length - 1].child += total;
  snaps.set(c, { props: c.props, state: c.state, hooks: hookValues(c) });
  pending[s.name] = (pending[s.name] ?? 0) + 1;
  onRendered?.(v.__e, s.name, !!(v as VNode & { __rsN?: boolean }).__rsN);
}
function onCommit() {
  stack = [];
  if (pendingMs === 0 && !Object.keys(pending).length) return;
  if (commits.length < MAX_COMMITS) commits.push({ t: Math.round((performance.now() - t0) * 10) / 10, ms: Math.round(pendingMs * 100) / 100, names: pending });
  pending = {}; pendingMs = 0;
}

function install() {
  saved = Object.fromEntries(KEYS.map((k) => [k, O[k]]));
  const p = saved;
  mine = {
    __r: (v) => { const sig = !!(((v as VNode).__c?.__$f ?? 0) & 1); p.__r?.(v); beforeRender(v as VNode, sig); },
    diffed: (v) => { afterDiff(v as VNode); p.diffed?.(v); },
    __c: (root, queue) => { onCommit(); p.__c?.(root, queue); },
    __e: (...a) => { stack = []; p.__e?.(...a); },
  };
  Object.assign(O, mine);
}
/** Puts the originals back; a hook someone else wrapped over ours since stays, passing through (theirs kept). */
function uninstall() {
  if (!saved || !mine) return;
  for (const k of KEYS) {
    if (O[k] === mine[k]) O[k] = saved[k];
    else { const p = saved[k]; mine[k] = (...a: unknown[]) => p?.(...a); }
  }
  saved = null; mine = null; stack = [];
}

/** Starts collecting for `who` (stats reset when the first user starts). */
export function startScan(who: string) {
  if (users.has(who)) return;
  if (!users.size) { reset(); install(); }
  users.add(who);
}
/** Stops `who`; the hooks go when nobody uses them. */
export function stopScan(who: string) {
  users.delete(who);
  if (!users.size) uninstall();
}
export function scanning() { return users.size > 0; }
export function reset() { t0 = performance.now(); stats = new Map(); snaps = new WeakMap(); commits = []; pending = {}; pendingMs = 0; }
export function setOnRendered(f: typeof onRendered) { onRendered = f; }
export function scanStats(): Stat[] { return [...stats.values()]; }
export function scanClock() { return t0; }

const r2 = (x: number) => Math.round(x * 100) / 100;
function topChanged(c: Record<string, number>) {
  return Object.entries(c).sort((a, b) => b[1] - a[1]).slice(0, 4).map(([k, n]) => `${k}:${n}`).join(" ");
}
/** The top components, merged by name (two functions of one name are one row). */
export function topRenders(n = 15) {
  const by = new Map<string, Stat>();
  for (const s of stats.values()) {
    const m = by.get(s.name);
    if (!m) { by.set(s.name, { ...s, changed: { ...s.changed } }); continue; }
    m.renders += s.renders; m.needless += s.needless; m.selfMs += s.selfMs; m.totalMs += s.totalMs; m.signal += s.signal;
    for (const k in s.changed) m.changed[k] = (m.changed[k] ?? 0) + s.changed[k];
  }
  const rows = [...by.values()].map((s) => ({ name: s.name, renders: s.renders, needless: s.needless, signal: s.signal, selfMs: r2(s.selfMs), totalMs: r2(s.totalMs), changed: topChanged(s.changed) }));
  return {
    byCount: [...rows].sort((a, b) => b.renders - a.renders).slice(0, n),
    byTime: [...rows].sort((a, b) => b.selfMs - a.selfMs).slice(0, n),
    needless: rows.filter((r) => r.needless > 0).sort((a, b) => b.needless - a.needless).slice(0, n),
  };
}
/** Which components rendered inside each window [start, start+dur] (ms on the scan's clock offset by `shift`). */
export function rendersIn(frames: { start: number; dur: number }[], shift = 0) {
  return frames.map((f) => {
    const names: Record<string, number> = {};
    let ms = 0;
    for (const c of commits) {
      const t = c.t + shift;
      if (t < f.start || t > f.start + f.dur) continue;
      ms += c.ms;
      for (const k in c.names) names[k] = (names[k] ?? 0) + c.names[k];
    }
    const top = Object.entries(names).sort((a, b) => b[1] - a[1]).slice(0, 8).map(([k, v]) => `${k}x${v}`).join(" ");
    return { start: f.start, dur: f.dur, renderMs: r2(ms), components: top };
  });
}
/** The trace's "renders" section: totals, the top lists, needless ones flagged, and per janky frame what rendered. */
export function renderReport(janky: { start: number; dur: number }[] = [], shift = 0) {
  let renders = 0, needlessRenders = 0, ms = 0;
  for (const s of stats.values()) { renders += s.renders; needlessRenders += s.needless; ms += s.selfMs; }
  return { v: 1, durationMs: Math.round(performance.now() - t0), commits: commits.length, renders, needlessRenders, renderMs: r2(ms),
    ...topRenders(), jankyFrames: rendersIn(janky, shift), commitList: commits.slice(0, 600) };
}

/** For a dev page / cdp session: start, read, stop. */
(window as unknown as { __powosRenders?: unknown }).__powosRenders = {
  start: () => startScan("dev"), stop: () => stopScan("dev"), reset, top: topRenders, report: renderReport,
  hooked: () => KEYS.some((k) => mine && O[k] === mine[k]), installed: () => !!saved,
};

type Report = ReturnType<typeof renderReport>;
/** The mailed summary's renders entry: the totals, the top five each way, the long frames' renders (or why none). */
export function rendersSummary(r: Report | { error: string } | undefined) {
  if (!r) return "no renders section (home's shell predates the render scan, or home sent no detail)";
  if ("error" in r) return r.error;
  const row = (x: Report["byCount"][number]) => `${x.name} ${x.renders}r ${x.needless}n ${x.selfMs}ms${x.changed ? " (" + x.changed + ")" : ""}`;
  return { renders: r.renders, needless: r.needlessRenders, renderMs: r.renderMs, commits: r.commits,
    byCount: r.byCount.slice(0, 5).map(row), byTime: r.byTime.slice(0, 5).map(row), needlessTop: r.needless.slice(0, 5).map(row),
    jankyFrames: [...r.jankyFrames].sort((a, b) => b.dur - a.dur).slice(0, 5) };
}
