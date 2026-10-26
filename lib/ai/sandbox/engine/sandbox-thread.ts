// PORTED from SpaceTimeAI agents/worker/codemode/sandbox-thread.ts (9aa4c87); the only change: the job's limits ride along.
// The code-mode sandbox's thread (offthread.ts starts it): type-checks and runs a session's eval in QuickJS here, off
// the worker's main thread, and asks the main thread for each host function call. Model-written code may run for up to
// the sandbox's deadline (five minutes) without yielding; on the main thread that held the database's websocket, and
// STDB dropped the worker after 30 s without an answer to its pings, with every session it was running.
import { parentPort } from 'node:worker_threads';
import { evalCode, SandboxError, type Limits } from './sandbox.ts';

type Eval = { kind: 'eval'; code: string; names: string[]; root: string; args: Record<string, unknown>; limits: Limits };
type Reply = { kind: 'reply'; id: number; ok: boolean; value?: unknown; error?: string };
const port = parentPort!;
const waiting = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
let next = 0;

// A host function here is a request to the main thread, which runs the session's own and answers.
const call = (name: string, params: unknown) => new Promise((resolve, reject) => {
  const id = next++;
  waiting.set(id, { resolve, reject });
  port.postMessage({ kind: 'call', id, name, params });
});
function answered(m: Reply) {
  const w = waiting.get(m.id);
  waiting.delete(m.id);
  if (m.ok) w?.resolve(m.value); else w?.reject(new Error(m.error));
}
async function evaluate(m: Eval) {
  const hosts = Object.fromEntries(m.names.map(n => [n, (params: unknown) => call(n, params)]));
  try {
    const { value, stdout } = await evalCode(m.code, hosts, m.root, m.args, m.limits);
    port.postMessage({ kind: 'done', ok: true, value, stdout });
  } catch (e) {
    const sandbox = e instanceof SandboxError;
    port.postMessage({ kind: 'done', ok: false, sandbox, message: (e as Error).message, thrown: sandbox ? (e as SandboxError).thrown : undefined });
  }
}
port.on('message', (m: Eval | Reply) => (m.kind === 'reply' ? answered(m) : void evaluate(m)));
