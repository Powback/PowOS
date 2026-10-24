// The PowOS capabilities a sandbox job can be granted (powos.d.ts declares their functions). The model's code never
// gets a process, a file, the network or an environment variable: it gets only these host functions, and each one
// runs ONE fixed PowOS command as an argv (no shell), its inputs checked first. No capability reads or returns a
// secret: a secret stays a reference in the services that hold it.
//
// Where each command comes from (this file's layout: <ai>/sandbox/caps.ts, <ai> = lib/ai or /usr/lib/powos/ai):
//   comms        python3 <ai>/comms/comms-mcp.py     (the `powos comms` CLI; the identity is COMMS_AGENT_ID, inherited)
//   board        python3 <ai>/agents/powos-agents-cli (the `powos agents` CLI; on the Mac it reaches the phone's board)
//   checks       <repo>/tools/phone/verify/queue.sh  (only where the verify queue lives: a PowOS checkout on the Mac)
//   phone state  `powos <view>` where powos is on PATH (the phone), else <repo>/tools/phone/adb.sh -> powos-run.sh
// POWOS_SANDBOX_{COMMS,AGENTS,QUEUE,PHONE} (a JSON array: the argv prefix) override one; the tests point them at stubs.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { delimiter, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Hosts } from './engine/sandbox.ts';

export const CAPS = ['comms.read', 'comms.send', 'board.read', 'board.write', 'checks.queue', 'phone.read'] as const;
export type Cap = (typeof CAPS)[number];

const AI_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REPO = resolve(AI_DIR, '..', '..');
const CALL_TIMEOUT_MS = 30_000;
const OUTPUT_CAP = 4 * 1024 * 1024;
// [the handbook: never poll the phone] a job reads the phone's state a few times at most, wherever it runs.
export const PHONE_READS_PER_JOB = 5;

export type Backends = { comms?: string[]; agents?: string[]; queue?: string[]; phone?: (words: string[]) => string[] };

const onPath = (bin: string) => (process.env.PATH ?? '').split(delimiter).some(d => d && existsSync(join(d, bin)));
function prefix(name: string, fallback: () => string[] | undefined): string[] | undefined {
  const set = process.env[`POWOS_SANDBOX_${name}`];
  if (set === undefined) return fallback();
  if (set === '' || set === 'off') return undefined;
  const argv = JSON.parse(set);
  if (!Array.isArray(argv) || !argv.length || !argv.every(a => typeof a === 'string')) throw new Error(`POWOS_SANDBOX_${name} must be a JSON array of strings`);
  return argv;
}
const file = (p: string) => (existsSync(p) ? p : undefined);

export function backends(): Backends {
  const comms = prefix('COMMS', () => (file(join(AI_DIR, 'comms', 'comms-mcp.py')) ? ['python3', join(AI_DIR, 'comms', 'comms-mcp.py')] : undefined));
  const agents = prefix('AGENTS', () => (file(join(AI_DIR, 'agents', 'powos-agents-cli')) ? ['python3', join(AI_DIR, 'agents', 'powos-agents-cli')] : undefined));
  const queue = prefix('QUEUE', () => (file(join(REPO, 'tools', 'phone', 'verify', 'queue.sh')) ? [join(REPO, 'tools', 'phone', 'verify', 'queue.sh')] : undefined));
  const phonePrefix = prefix('PHONE', () => (onPath('powos') ? ['powos'] : undefined));
  const adb = file(join(REPO, 'tools', 'phone', 'adb.sh'));
  // The words are always one of PHONE_VIEWS' constants, never the job's input, so quoting them for su -c is safe.
  const phone = phonePrefix ? (w: string[]) => [...phonePrefix, ...w]
    : adb ? (w: string[]) => [adb, 'shell', 'su', '-c', `sh /data/powos/powos-run.sh 'powos ${w.join(' ')}'`] : undefined;
  return { comms, agents, queue, phone };
}

// The capabilities this host can serve (a backend found for each).
export function available(b: Backends): Cap[] {
  const has: Record<Cap, boolean> = {
    'comms.read': !!b.comms, 'comms.send': !!b.comms, 'board.read': !!b.agents, 'board.write': !!b.agents,
    'checks.queue': !!b.queue, 'phone.read': !!b.phone,
  };
  return CAPS.filter(c => has[c]);
}

// ---- running one command -------------------------------------------------------------------------------------------

export function run(argv: string[], input?: string, timeoutMs = CALL_TIMEOUT_MS): Promise<string> {
  return new Promise((done, fail) => {
    const p = spawn(argv[0]!, argv.slice(1), { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '', err = '', killed = false;
    const timer = setTimeout(() => { killed = true; p.kill('SIGKILL'); }, timeoutMs);
    p.stdout.on('data', (b: Buffer) => { if (out.length < OUTPUT_CAP) out += b.toString(); });
    p.stderr.on('data', (b: Buffer) => { if (err.length < 64 * 1024) err += b.toString(); });
    p.on('error', e => { clearTimeout(timer); fail(new Error(`cannot run ${argv[0]}: ${e.message}`)); });
    p.on('close', code => {
      clearTimeout(timer);
      if (killed) return fail(new Error(`${argv[0]} took longer than ${timeoutMs / 1000} s: stopped`));
      if (code !== 0) return fail(new Error(`exit ${code}: ${(err || out).trim().slice(-600)}`));
      done(out);
    });
    p.stdin.end(input ?? '');
  });
}

// ---- checking what a job passes in ---------------------------------------------------------------------------------

const AGENT = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$/;   // comms-mcp.py's _SAFE_NAME
const ID = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,95}$/;
const CHECK = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}\.sh$/;
const PRIORITIES = ['low', 'normal', 'high', 'urgent'];

function str(v: unknown, what: string, re?: RegExp): string {
  if (typeof v !== 'string' || v === '') throw new Error(`${what} must be a non-empty string`);
  if (v.includes('\0')) throw new Error(`${what} must not hold a NUL character`);
  if (re && !re.test(v)) throw new Error(`${what} is not valid: ${JSON.stringify(v).slice(0, 80)}`);
  return v;
}
// A free-text value goes as --key=value, so a value that starts with "-" stays a value.
const opt = (key: string, v: unknown) => (v === undefined ? [] : [`--${key}=${str(v, key)}`]);
const words = (text: string, what: string) => {
  if (text.startsWith('-')) throw new Error(`${what} must not start with "-"`);
  return text;
};
const jsonOf = (text: string) => (text.trim() ? JSON.parse(text) : null);
const jsonLines = (text: string) => text.split('\n').filter(l => l.trim()).map(l => JSON.parse(l));

const PHONE_VIEWS: Record<string, { words: string[]; json: boolean }> = {
  overview: { words: ['overview', '--json'], json: true },
  status: { words: ['status'], json: false },
  units: { words: ['units', 'list', '--json'], json: true },
  sleep: { words: ['sleep', 'status', '--json'], json: true },
  'apps.running': { words: ['android', 'running'], json: false },
  'shell.errors': { words: ['shell', 'errors'], json: false },
};

// ---- the host functions, by capability -----------------------------------------------------------------------------

type P = Record<string, unknown>;
export function capHosts(cap: Cap, b: Backends, counter: { phone: number }): Hosts {
  switch (cap) {
    case 'comms.read':
      return {
        commsInbox: async (p?: P) => {
          const all = jsonLines(await run([...b.comms!, 'inbox', '--peek', '--json']));
          const limit = p?.limit === undefined ? all.length : Math.max(0, Number(p.limit));
          return all.slice(0, limit);
        },
      };
    case 'comms.send':
      return {
        sendMessage: async (p: P) => {
          const to = str(p?.to, 'to', AGENT), body = str(p?.body, 'body');
          const priority = p.priority === undefined ? 'normal' : str(p.priority, 'priority');
          if (!PRIORITIES.includes(priority)) throw new Error(`priority is one of ${PRIORITIES.join(', ')}`);
          await run([...b.comms!, 'send', '--priority', priority, '--', to, '-'], body + '\n');
          return { sent: true, to };
        },
      };
    case 'board.read':
      return {
        boardTasks: async (p?: P) => jsonOf(await run([...b.agents!, 'task', 'list', '--json',
          ...(p?.all ? ['--all'] : []), ...opt('state', p?.state), ...opt('owner', p?.owner), ...opt('project', p?.project)])) ?? [],
        boardChecks: async (p?: P) => jsonOf(await run([...b.agents!, 'check', 'list', '--json',
          ...(p?.task === undefined ? [] : [str(p.task, 'task', ID)])])) ?? [],
      };
    case 'board.write':
      return {
        boardSetTask: async (p: P) => {
          const task = str(p?.task, 'task', ID);
          const flags = ['step', 'note', 'progress', 'plan', 'status', 'owner'].flatMap(k => opt(k, p[k]));
          if (!flags.length) throw new Error('boardSetTask needs at least one of step, note, progress, plan, status, owner');
          return (await run([...b.agents!, 'task', 'set', task, ...flags])).trim();
        },
        boardAddTask: async (p: P) => {
          const title = words(str(p?.title, 'title'), 'title');
          return (await run([...b.agents!, 'task', 'add', ...opt('owner', p.owner), ...opt('note', p.note), ...opt('project', p.project), title])).trim();
        },
      };
    case 'checks.queue':
      return {
        queueCheck: async (p: P) => {
          const task = str(p?.task, 'task', ID), check = str(p.check, 'check', CHECK);
          const script = join(dirname(b.queue!.at(-1)!), check);
          if (!existsSync(script)) throw new Error(`no check ${check} in tools/phone/verify/`);
          const args = p.args === undefined ? [] : p.args;
          if (!Array.isArray(args)) throw new Error('args must be an array of strings, one word each');
          const argv = args.map((a, i) => str(a, `args[${i}]`));
          const flags = [...(p.close ? ['--close'] : []),
            ...(p.name === undefined ? [] : ['--name', words(str(p.name, 'name'), 'name')]),
            ...(p.screen === undefined ? [] : ['--screen', str(p.screen, 'screen', /^(inner|cover)$/)]),
            ...(p.budgetS === undefined ? [] : ['--budget', String(Math.max(1, Math.floor(Number(p.budgetS)) || 300))])];
          return (await run([...b.queue!, 'add', ...flags, task, script, ...argv])).trim();
        },
        checkQueue: async () => (await run([...b.queue!, 'list'])).trim(),
      };
    case 'phone.read':
      return {
        phoneState: async (p: P) => {
          const view = PHONE_VIEWS[str(p?.what, 'what')];
          if (!view) throw new Error(`what is one of ${Object.keys(PHONE_VIEWS).join(', ')}`);
          if (++counter.phone > PHONE_READS_PER_JOB) throw new Error(`at most ${PHONE_READS_PER_JOB} phone reads per job (never poll the phone)`);
          const out = await run(b.phone!(view.words));
          return view.json ? jsonOf(out) : out.trim();
        },
      };
  }
}
