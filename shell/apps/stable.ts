/**
 * Stable rows: a table's rows (or anything mapped from them) delivered again with equal content keep the objects they
 * had, so a SpacetimeDB message - or a reconnect resubscribing a table - re-renders only the rows that really changed.
 * Perf trace 5 (2026-10-31): one stdb message (apps/stdb.ts run) re-rendered 30 Tiles and 14 AppCells in a 51 ms
 * frame, 28 of them needless ("app~": a new App with the same content).
 *
 * No imports: state.ts, pages.ts and stdb.ts all use it.
 */

/** Two objects worth comparing key by key: one kind (same prototype), not a Map, Set or Date. */
const comparable = (a: object, b: object) =>
  Object.getPrototypeOf(a) === Object.getPrototypeOf(b) && !(a instanceof Map || a instanceof Set || a instanceof Date);

/** Same content: equal primitives, or objects of one kind with the same keys and same values (a few levels down). */
export function same(a: unknown, b: unknown, depth = 0): boolean {
  if (a === b) return true;
  if (!a || !b || typeof a !== "object" || typeof b !== "object" || depth > 4 || !comparable(a, b)) return false;
  return sameKeys(a as Record<string, unknown>, b as Record<string, unknown>, depth);
}

function sameKeys(x: Record<string, unknown>, y: Record<string, unknown>, depth: number): boolean {
  const ka = Object.keys(x);
  if (ka.length !== Object.keys(y).length) return false;
  return ka.every((k) => k in y && same(x[k], y[k], depth + 1));
}

/** A row's identity across deliveries: its id (or key), else its place. */
const keyOf = (r: unknown, i: number): unknown => {
  const o = r as { id?: unknown; key?: unknown } | null;
  const k = o && typeof o === "object" ? (o.id ?? o.key) : undefined;
  return k === undefined || (typeof k === "object" && k !== null) ? `#${i}` : k;
};

/**
 * [next] with each row equal to its [prev] counterpart (same id, same content) replaced by that previous object - and
 * [prev] itself when nothing changed at all (same rows, same order), so a signal or setState holding it doesn't fire.
 */
export function stableRows<T>(prev: readonly T[] | null | undefined, next: readonly T[]): T[] {
  if (!prev?.length) return next.length || !prev ? (next as T[]) : (prev as T[]);
  const was = new Map<unknown, T>();
  prev.forEach((r, i) => was.set(keyOf(r, i), r));
  let changed = prev.length !== next.length;
  const out = next.map((r, i) => {
    const p = was.get(keyOf(r, i));
    const keep = p !== undefined && same(p, r) ? p : r;
    if (keep !== prev[i]) changed = true;
    return keep;
  });
  return changed ? out : (prev as T[]);
}
