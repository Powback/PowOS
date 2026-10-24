// PORTED from SpaceTimeAI agents/worker/codemode/offthread.ts (9aa4c87). Changes: the job's limits ride along, and a
// wall-clock guard: QuickJS's deadline only interrupts code that is running, so a job parked on a host call past its
// deadline (plus GRACE_MS) has its thread terminated and fails, instead of holding the tool call open.
// [d.runtime.14] Code mode's eval, run on a sandbox thread (sandbox-thread.ts) instead of the worker's main thread. The
// main thread holds the database's websocket; an eval that computed for 30 s (QuickJS runs to its five-minute deadline
// without yielding) left STDB's pings unanswered, and STDB dropped the worker with every session it ran. The host
// functions stay here, with the session's state: the thread asks for each call, and gets its value or its error.
// A thread runs one eval at a time and is kept for the next (loading the TypeScript checker costs about a second); a
// busy pool starts another, so an eval waiting on a host function that runs a recipe (another eval) never waits on
// itself.
import { Worker } from 'node:worker_threads';
import { DEFAULT_LIMITS, SandboxError, type Hosts, type Limits } from './sandbox.ts';

type Done = { kind: 'done'; ok: boolean; value?: unknown; stdout?: string; sandbox?: boolean; message?: string; thrown?: SandboxError['thrown'] };
type Call = { kind: 'call'; id: number; name: string; params: unknown };
const KEEP = 2, GRACE_MS = 5000, idle: Worker[] = [];
const thread = () => idle.pop() ?? new Worker(new URL('./sandbox-thread.ts', import.meta.url));
function keep(w: Worker) {
  if (idle.length >= KEEP) return void w.terminate();
  w.unref();
  idle.push(w);
}

// A value the structured clone refuses (a function inside it) goes as JSON, as the sandbox would have seen it anyway.
function reply(w: Worker, id: number, value: unknown) {
  try { w.postMessage({ kind: 'reply', id, ok: true, value }); } catch { w.postMessage({ kind: 'reply', id, ok: true, value: JSON.parse(JSON.stringify(value ?? null)) }); }
}
async function serve(w: Worker, hosts: Hosts, m: Call) {
  try { reply(w, m.id, await Promise.resolve().then(() => hosts[m.name]!(m.params))); } catch (e) {
    w.postMessage({ kind: 'reply', id: m.id, ok: false, error: e instanceof Error ? e.message : String(e) });
  }
}
const outcome = (m: Done) => (m.ok ? { value: m.value, stdout: m.stdout ?? '' } : null);
const failure = (m: Done) => (m.sandbox ? new SandboxError(m.message ?? '', m.thrown) : new Error(m.message));

export function evalOffThread(code: string, hosts: Hosts, root = '', args: Record<string, unknown> = {}, limits: Limits = DEFAULT_LIMITS): Promise<{ value: unknown; stdout: string }> {
  const w = thread();
  w.ref();
  return new Promise((resolve, reject) => {
    const guard = setTimeout(() => {
      settle(); void w.terminate();
      reject(new SandboxError(`the job ran past its deadline (${Math.round(limits.timeoutMs / 1000)} s) waiting on a host function: stopped`));
    }, limits.timeoutMs + GRACE_MS);
    const settle = () => { clearTimeout(guard); w.off('message', onMessage); w.off('error', onError); };
    const onMessage = (m: Call | Done) => {
      if (m.kind === 'call') return void serve(w, hosts, m);
      settle(); keep(w);
      const r = outcome(m);
      if (r) resolve(r); else reject(failure(m));
    };
    const onError = (e: Error) => { settle(); void w.terminate(); reject(new SandboxError(`the sandbox thread failed: ${e.message}`)); };
    w.on('message', onMessage);
    w.on('error', onError);
    w.postMessage({ kind: 'eval', code, names: Object.keys(hosts), root, args, limits });
  });
}
