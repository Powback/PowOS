/**
 * What the page changed and the server hasn't confirmed yet: strokes, undo/redo, the picture. Sent in order, one at a
 * time; kept (and in localStorage, so a restart while offline keeps them) until the reducer ran. The page draws the
 * server's strokes with these applied on top, so a stroke shows the moment it ends, connected or not.
 */
import type { Ink } from "./ink";

export type Op =
  | { kind: "add"; key: string; ink: Ink; width: number; height: number }
  | { kind: "adopt"; key: string; id: string }
  | { kind: "hide"; key: string; uids: string[]; hidden: boolean }
  | { kind: "drop"; key: string; uids: string[] }
  | { kind: "thumb"; key: string; image: string };

export type Call = (name: string, args: Record<string, unknown>) => Promise<unknown>;

const STORE = "local.sketch.outbox";

function load(): Op[] {
  try {
    const v = JSON.parse(localStorage.getItem(STORE) || "[]");
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}

function args(op: Op): [string, Record<string, unknown>] {
  switch (op.kind) {
    case "add":
      return ["add_stroke", { key: op.key, s: { ...op.ink, width: op.width, height: op.height } }];
    case "adopt":
      return ["adopt", { id: BigInt(op.id), key: op.key }];
    case "hide":
      return ["set_hidden", { key: op.key, uids: op.uids, hidden: op.hidden }];
    case "drop":
      return ["drop_hidden", { key: op.key, uids: op.uids }];
    case "thumb":
      return ["thumb", { key: op.key, image: op.image }];
  }
}

/** Errors that mean "try again later", never "this op is bad": no connection, or the device's module is older. */
const offline = (e: unknown) =>
  /not connected|closed|disconnect|timed out|older than its UI|no reducer/i.test(String((e as Error)?.message ?? e));
const SEND_MS = 15000;

/** False: the connection refused it (kept for the next flush). A reducer's own error drops the op (logged). */
async function send(op: Op, call: Call): Promise<boolean> {
  const [name, a] = args(op);
  try {
    let t: ReturnType<typeof setTimeout> | undefined;
    const late = new Promise((_, no) => (t = setTimeout(() => no(new Error(`${name} timed out`)), SEND_MS)));
    await Promise.race([call(name, a), late]).finally(() => clearTimeout(t));
  } catch (e) {
    if (offline(e)) return false;
    console.warn(`sketch: ${name} refused, dropped:`, e);
  }
  return true;
}

export class Outbox {
  ops: Op[] = load();
  private busy = false;
  constructor(private changed: () => void) {}

  private keep() {
    try {
      // The picture is made again on the next change: never stored (it can be MBs).
      localStorage.setItem(STORE, JSON.stringify(this.ops.filter((o) => o.kind !== "thumb")));
    } catch {
      /* private mode / full: the ops still go out while the page is open */
    }
  }

  push(op: Op, call: Call) {
    // One picture per drawing is enough: the newest replaces any not sent yet.
    if (op.kind === "thumb") this.ops = this.ops.filter((o) => !(o.kind === "thumb" && o.key === op.key));
    this.ops.push(op);
    this.keep();
    this.changed();
    void this.flush(call);
  }

  /** Send what's waiting, in order; stops at the first one the connection refuses (sent again on the next flush). */
  async flush(call: Call) {
    if (this.busy) return;
    this.busy = true;
    try {
      while (this.ops.length) {
        if (!(await send(this.ops[0], call))) return;
        this.ops.shift();
        this.keep();
        this.changed();
      }
    } finally {
      this.busy = false;
    }
  }
}

export interface Row extends Ink {
  id: bigint;
  hidden: boolean;
}

function apply(op: Op, list: Ink[], seen: Set<string>, hidden: Map<string, boolean>) {
  if (op.kind === "add" && !seen.has(op.ink.uid)) {
    list.push(op.ink);
    seen.add(op.ink.uid);
    hidden.set(op.ink.uid, false);
  }
  if (op.kind === "hide") for (const u of op.uids) hidden.set(u, op.hidden);
}

/** The strokes to draw for drawing `key`: the server's (in order), with the outbox's adds and hides applied. */
export function visible(rows: Row[], ops: Op[], key: string): Ink[] {
  const hidden = new Map<string, boolean>();
  const list: Ink[] = [...rows].sort((a, b) => Number(a.id - b.id));
  for (const r of rows) hidden.set(r.uid, r.hidden);
  const seen = new Set(list.map((r) => r.uid));
  for (const op of ops) if (op.key === key) apply(op, list, seen, hidden);
  return list.filter((k) => !hidden.get(k.uid));
}

export const uid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
