// One sandbox job: the code (or a script saved in the virtual workspace), the capabilities it is GRANTED, its limits.
// What a job can reach is decided here, before anything runs:
//   - the ceiling: what this agent may ever grant (POWOS_SANDBOX_CEILING, set by the launcher per role, never by the
//     model) and what this host can serve (caps.ts available());
//   - the grants: the subset this one job asks for. Only their functions exist in the VM and in its declarations, so a
//     call to any other is a type error before it runs (engine/sandbox.ts declarationsFor);
//   - the limits: deadline and heap, clamped to the engine's ceilings, and at most maxCalls host calls.
// Every job is logged (who, grants, a hash of the code, calls, outcome) to $XDG_STATE_HOME/powos/sandbox/jobs.jsonl.
// The result format is SpaceTimeAI's eval tool's (worker/session/tools.ts): the last expression plus console output,
// capped at MAX_CHARS with the rest spilled to the virtual workspace.
import { createHash } from 'node:crypto';
import { appendFileSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { declarationsFor as engineDeclarations, DEFAULT_LIMITS, MAX_LIMITS, SandboxError, type Hosts, type Limits } from './engine/sandbox.ts';
import { evalOffThread } from './engine/offthread.ts';
import { Vfs } from './engine/vfs.ts';
import { available, backends, capHosts, CAPS, type Backends, type Cap } from './caps.ts';

export const MAX_CHARS = 30_000;
export const DEFAULT_CALLS = 40, MAX_CALLS = 400;

export type JobInput = { code?: string; path?: string; args?: Record<string, unknown>; grants?: string[]; timeoutS?: number; memoryMB?: number; maxCalls?: number };
export type JobResult = { ok: boolean; text: string };

export function ceiling(b: Backends = backends()): Cap[] {
  const set = process.env.POWOS_SANDBOX_CEILING;
  const allowed = set === undefined || set.trim() === '' ? [...CAPS] : set.split(',').map(s => s.trim()).filter(Boolean);
  const unknown = allowed.filter(c => !(CAPS as readonly string[]).includes(c));
  if (unknown.length) throw new Error(`POWOS_SANDBOX_CEILING names unknown capabilities: ${unknown.join(', ')}`);
  const here = available(b);
  return (allowed as Cap[]).filter(c => here.includes(c));
}

const vfsHosts = (vfs: Vfs): Hosts => ({
  readVfs: p => vfs.read(p), writeVfs: p => vfs.write(p), editVfs: p => vfs.edit(p),
  deleteVfs: p => vfs.delete(p), searchVfs: p => vfs.search(p), listVfs: p => vfs.list(p),
});

function grantsOf(asked: unknown, max: Cap[]): Cap[] {
  if (asked === undefined) return [];
  if (!Array.isArray(asked)) throw new SandboxError('grants must be an array of capability names');
  const bad = asked.filter(g => !max.includes(g));
  if (bad.length) {
    throw new SandboxError(`not grantable here: ${bad.join(', ')} (this agent may grant: ${max.join(', ') || 'nothing'}; ` +
      `all capabilities: ${CAPS.join(', ')})`);
  }
  return [...new Set(asked as Cap[])];
}

export function limitsOf(i: JobInput): Limits {
  const t = i.timeoutS === undefined ? DEFAULT_LIMITS.timeoutMs : Number(i.timeoutS) * 1000;
  const m = i.memoryMB === undefined ? DEFAULT_LIMITS.memoryBytes : Number(i.memoryMB) * 1024 * 1024;
  const clamp = (v: number, d: number, max: number) => (Number.isFinite(v) && v > 0 ? Math.min(v, max) : d);
  return { timeoutMs: clamp(t, DEFAULT_LIMITS.timeoutMs, MAX_LIMITS.timeoutMs), memoryBytes: clamp(m, DEFAULT_LIMITS.memoryBytes, MAX_LIMITS.memoryBytes) };
}

// Each host function counts against the job's calls; past the cap it fails (and the code sees an Error).
function counted(hosts: Hosts, cap: number, tally: { calls: number }): Hosts {
  return Object.fromEntries(Object.entries(hosts).map(([name, fn]) => [name, (p: unknown) => {
    if (++tally.calls > cap) throw new Error(`this job used its ${cap} host calls (maxCalls)`);
    return fn(p);
  }]));
}

function formatValue(value: unknown): string {
  if (value === undefined) return 'undefined';
  if (typeof value === 'string') return value;
  return JSON.stringify(value, null, 2) ?? String(value);
}
function deliver(text: string, vfs: Vfs) {
  if (text.length <= MAX_CHARS) return text;
  const file = vfs.saveOutput(text);
  return `${text.slice(0, MAX_CHARS)}\n\n[output is ${text.length} characters, full text written to ${file} in the virtual workspace]`;
}

function audit(entry: Record<string, unknown>) {
  try {
    const dir = join(process.env.XDG_STATE_HOME || join(homedir(), '.local', 'state'), 'powos', 'sandbox');
    mkdirSync(dir, { recursive: true });
    appendFileSync(join(dir, 'jobs.jsonl'), JSON.stringify(entry) + '\n');
  } catch { /* the log is a record, never a reason to fail the job */ }
}

export async function runJob(i: JobInput, vfs: Vfs, b: Backends = backends()): Promise<JobResult> {
  const started = Date.now(), tally = { calls: 0 };
  let grants: Cap[] = [], code = '';
  try {
    if (!i.code === !i.path) throw new SandboxError('give either code or path, not both');
    code = i.code ?? vfs.read({ path: i.path! });
    grants = grantsOf(i.grants, ceiling(b));
    const counter = { phone: 0 };
    const cap = Math.min(Math.max(1, Math.floor(Number(i.maxCalls ?? DEFAULT_CALLS)) || DEFAULT_CALLS), MAX_CALLS);
    const hosts = counted(Object.assign(vfsHosts(vfs), ...grants.map(g => capHosts(g, b, counter))), cap, tally);
    const { value, stdout } = await evalOffThread(code, hosts, '', i.args ?? {}, limitsOf(i));
    const out = stdout.trimEnd();
    const text = !out ? formatValue(value) : value === undefined ? out : `${out}\n=> ${formatValue(value)}`;
    audit({ at: new Date(started).toISOString(), agent: process.env.COMMS_AGENT_ID ?? '', grants, sha: sha(code), calls: tally.calls, ms: Date.now() - started, ok: true });
    return { ok: true, text: deliver(text, vfs) };
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    audit({ at: new Date(started).toISOString(), agent: process.env.COMMS_AGENT_ID ?? '', grants, sha: sha(code), calls: tally.calls, ms: Date.now() - started, ok: false, error: message.slice(0, 300) });
    return { ok: false, text: deliver(message, vfs) };
  }
}
const sha = (code: string) => createHash('sha256').update(code).digest('hex').slice(0, 16);

// The declarations a job with these grants is checked against (what the `declarations` tool shows the model).
export function declarationsFor(grants: string[] | undefined, b: Backends = backends()): string {
  const names = grantsOf(grants, ceiling(b)).reduce((h, g) => Object.assign(h, capHosts(g, b, { phone: 0 })), vfsHosts(new Vfs()));
  return engineDeclarations(names).text;
}

// Each capability's function names, for the tool's description and `powos sandbox caps`.
export function functionsByCap(b: Backends = backends()): Record<string, string[]> {
  return Object.fromEntries(CAPS.map(c => [c, Object.keys(capHosts(c, b, { phone: 0 }))]));
}
