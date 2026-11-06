import { Component, h, type ComponentType, type FunctionComponent } from "preact";

/** Shallow equality of two props objects: the same keys, each value identical (Object.is). */
export function sameProps(a: object, b: object): boolean {
  const x = a as Record<string, unknown>, y = b as Record<string, unknown>;
  const ka = Object.keys(x);
  if (ka.length !== Object.keys(y).length) return false;
  return ka.every((k) => Object.is(x[k], y[k]));
}

/**
 * [C], re-rendered only when its props change (shallowly, or by [same] - for a prop rebuilt equal on every render): Preact core has no memo (preact/compat's would pull in the
 * whole compat layer). For leaves a parent re-renders every frame with the same props - a dragged window's edges and
 * bar buttons (render scan 10-31). Its own state, hooks and signals still re-render it as usual.
 */
export function memo<P extends object>(C: ComponentType<P>, same: (a: P, b: P) => boolean = sameProps): FunctionComponent<P> {
  class Memo extends Component<P> {
    static displayName = `memo(${C.displayName || C.name})`;
    shouldComponentUpdate(next: P) {
      return !same(this.props, next);
    }
    render(p: P) {
      return h(C, p);
    }
  }
  return Memo as unknown as FunctionComponent<P>;
}

const plain = (v: unknown): v is Record<string, unknown> => {
  if (!v || typeof v !== "object") return false;
  const p = Object.getPrototypeOf(v);
  return (p === Object.prototype || p === Array.prototype) && !("props" in v && "type" in v); // never a vnode
};
/** The same content: identical, or plain objects/arrays of equal content a few levels down (64 keys at most each). */
function sameValue(a: unknown, b: unknown, depth: number): boolean {
  if (Object.is(a, b)) return true;
  if (depth > 3 || !plain(a) || !plain(b) || Array.isArray(a) !== Array.isArray(b)) return false;
  const ka = Object.keys(a);
  if (ka.length !== Object.keys(b).length || ka.length > 64) return false;
  return ka.every((k) => k in b && sameValue(a[k], b[k], depth + 1));
}
/**
 * Props equal by content: a prop rebuilt equal each parent render (a filtered list, a row object made afresh - the
 * render scan's "name~", react-scan's needless render) counts as unchanged; a new function is a change (its closure
 * may differ). For pure leaves fed derived lists (PowOS AI's status sections, the pill's send).
 */
export function sameContent<T extends object>(a: T, b: T): boolean {
  const x = a as Record<string, unknown>, y = b as Record<string, unknown>;
  const ka = Object.keys(x);
  return ka.length === Object.keys(y).length && ka.every((k) => k in y && sameValue(x[k], y[k], 0));
}
