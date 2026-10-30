import { Component, h, type FunctionComponent } from "preact";

/** Shallow equality of two props objects: the same keys, each value identical (Object.is). */
export function sameProps(a: object, b: object): boolean {
  const x = a as Record<string, unknown>, y = b as Record<string, unknown>;
  const ka = Object.keys(x);
  if (ka.length !== Object.keys(y).length) return false;
  return ka.every((k) => Object.is(x[k], y[k]));
}

/**
 * [C], re-rendered only when its props change (shallowly): Preact core has no memo (preact/compat's would pull in the
 * whole compat layer). For leaves a parent re-renders every frame with the same props - a dragged window's edges and
 * bar buttons (render scan 10-31). Its own state, hooks and signals still re-render it as usual.
 */
export function memo<P extends object>(C: FunctionComponent<P>): FunctionComponent<P> {
  class Memo extends Component<P> {
    static displayName = `memo(${C.displayName || C.name})`;
    shouldComponentUpdate(next: P) {
      return !sameProps(this.props, next);
    }
    render(p: P) {
      return h(C, p);
    }
  }
  return Memo as unknown as FunctionComponent<P>;
}
