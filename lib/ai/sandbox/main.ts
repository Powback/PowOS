// powos sandbox: the entry point (sandbox.sh starts it with bun, else node).
//   main.ts mcp                      the MCP server (stdio, newline-delimited JSON-RPC 2.0, as comms-mcp.py): tools
//                                    `eval` (run a job) and `declarations` (what a set of grants gives the code)
//   main.ts run [--grant CAP]... [--args JSON] [--timeout S] [--memory MB] [--max-calls N] FILE|-
//                                    one job from the command line (scripts, tests); exit 0 ok, 1 the job failed
//   main.ts caps [--json]            what this agent may grant here, and each capability's functions
//   main.ts declarations [CAP...]    the declarations those grants give
// SpaceTimeAI's eval tool (worker/session/tools.ts) is one in-process SDK tool; PowOS's agents are `claude` processes,
// so the same tool is served over MCP's stdio contract, one server (and one virtual workspace) per agent session.
import { readFileSync } from 'node:fs';
import { Vfs } from './engine/vfs.ts';
import { CAPS } from './caps.ts';
import { ceiling, DEFAULT_CALLS, declarationsFor, functionsByCap, MAX_CALLS, runJob, type JobInput } from './job.ts';
import { DEFAULT_LIMITS, MAX_LIMITS } from './engine/sandbox.ts';

const PROTOCOL_VERSION = '2024-11-05';

function evalDescription(): string {
  const fns = functionsByCap(), may = ceiling();
  const caps = CAPS.map(c => `${c}${may.includes(c) ? '' : ' (not grantable here)'}: ${fns[c]!.join(', ')}`).join('; ');
  return 'Runs a TypeScript job in the PowOS sandbox (QuickJS, top-level await): the code itself, or a .ts file saved in ' +
    'the virtual workspace by path, with optional args the code reads as `args`. Use it instead of long tool-call chains ' +
    'for scripted phone jobs, data checks and small automations. The code gets NOTHING but the functions of the ' +
    'capabilities you grant this job (plus console and the virtual workspace: readVfs/writeVfs/editVfs/deleteVfs/' +
    `searchVfs/listVfs); no process, file, network or environment. Capabilities -> functions: ${caps}. Grant only ` +
    'what the job needs; a call to anything not granted is a type error before it runs (the `declarations` tool shows ' +
    `the exact types). Limits: timeout_s (default ${DEFAULT_LIMITS.timeoutMs / 1000}, max ${MAX_LIMITS.timeoutMs / 1000}), memory_mb ` +
    `(default ${DEFAULT_LIMITS.memoryBytes >> 20}, max ${MAX_LIMITS.memoryBytes >> 20}), max_calls host calls (default ${DEFAULT_CALLS}, max ${MAX_CALLS}). ` +
    'Returns the last expression plus anything printed with console.log, or the type errors / what the code threw.';
}

const TOOLS = () => [
  {
    name: 'eval',
    description: evalDescription(),
    inputSchema: {
      type: 'object',
      properties: {
        code: { type: 'string', description: 'The TypeScript code to run.' },
        path: { type: 'string', description: 'Instead of code: a .ts file in the virtual workspace, relative to its root.' },
        args: { type: 'object', description: 'Inputs the code reads as the global `args`.' },
        grants: { type: 'array', items: { type: 'string', enum: [...CAPS] }, description: 'The capabilities this job gets (none: only console and the virtual workspace).' },
        timeout_s: { type: 'number' }, memory_mb: { type: 'number' }, max_calls: { type: 'number' },
      },
    },
  },
  {
    name: 'declarations',
    description: 'The TypeScript declarations a sandbox job with these grants is type-checked against: every function it may call, with its parameters and result.',
    inputSchema: { type: 'object', properties: { grants: { type: 'array', items: { type: 'string', enum: [...CAPS] } } } },
  },
];

const jobOf = (a: Record<string, any>): JobInput => ({
  code: a.code, path: a.path, args: a.args, grants: a.grants, timeoutS: a.timeout_s, memoryMB: a.memory_mb, maxCalls: a.max_calls,
});

async function mcp() {
  const vfs = new Vfs();
  const send = (m: unknown) => process.stdout.write(JSON.stringify(m) + '\n');
  const text = (t: string, isError = false) => ({ content: [{ type: 'text', text: t }], ...(isError ? { isError: true } : {}) });
  async function handle(m: any) {
    const reply = (result: unknown) => m.id !== undefined && send({ jsonrpc: '2.0', id: m.id, result });
    const error = (code: number, message: string) => m.id !== undefined && send({ jsonrpc: '2.0', id: m.id, error: { code, message } });
    switch (m.method) {
      case 'initialize':
        return reply({ protocolVersion: PROTOCOL_VERSION, capabilities: { tools: {} }, serverInfo: { name: 'powos-sandbox', version: '1.0.0' } });
      case 'tools/list':
        return reply({ tools: TOOLS() });
      case 'tools/call': {
        const a = m.params?.arguments ?? {};
        if (m.params?.name === 'eval') {
          const r = await runJob(jobOf(a), vfs);
          return reply(text(r.text, !r.ok));
        }
        if (m.params?.name === 'declarations') {
          try { return reply(text(declarationsFor(a.grants))); } catch (e) { return reply(text((e as Error).message, true)); }
        }
        return error(-32602, `unknown tool: ${m.params?.name}`);
      }
      case 'ping':
        return reply({});
      default:
        if (m.id !== undefined && !String(m.method ?? '').startsWith('notifications/')) return error(-32601, `method not found: ${m.method}`);
    }
  }
  let buf = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk: string) => {
    buf += chunk;
    for (let nl = buf.indexOf('\n'); nl >= 0; nl = buf.indexOf('\n')) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line) continue;
      let m: any;
      try { m = JSON.parse(line); } catch { send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }); continue; }
      // Calls run concurrently (one sandbox thread each), as the client may send the next before a job ends.
      void handle(m).catch(e => m.id !== undefined && send({ jsonrpc: '2.0', id: m.id, error: { code: -32603, message: String(e?.message ?? e) } }));
    }
  });
  process.stdin.on('end', () => process.exit(0));
}

async function cli(argv: string[]) {
  const grants: string[] = [];
  const job: JobInput = {};
  let source: string | undefined;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!, next = () => { const v = argv[++i]; if (v === undefined) throw new Error(`${a} needs a value`); return v; };
    if (a === '--grant') grants.push(next());
    else if (a === '--args') job.args = JSON.parse(next());
    else if (a === '--timeout') job.timeoutS = Number(next());
    else if (a === '--memory') job.memoryMB = Number(next());
    else if (a === '--max-calls') job.maxCalls = Number(next());
    else if (source === undefined) source = a;
    else throw new Error(`unexpected argument: ${a}`);
  }
  if (source === undefined) throw new Error('run needs a FILE or - (stdin)');
  job.code = readFileSync(source === '-' ? 0 : source, 'utf8');
  job.grants = grants;
  const r = await runJob(job, new Vfs());
  (r.ok ? process.stdout : process.stderr).write(r.text.endsWith('\n') ? r.text : r.text + '\n');
  process.exit(r.ok ? 0 : 1);
}

function caps(json: boolean) {
  const fns = functionsByCap(), may = ceiling();
  if (json) return console.log(JSON.stringify({ grantable: may, functions: fns }, null, 1));
  for (const c of CAPS) console.log(`${may.includes(c) ? '+' : '-'} ${c.padEnd(13)} ${fns[c]!.join(', ')}`);
  console.log('(+ grantable by this agent on this host; - not: outside its ceiling or no backend here)');
}

const [verb, ...rest] = process.argv.slice(2);
try {
  if (verb === 'mcp') await mcp();
  else if (verb === 'run') await cli(rest);
  else if (verb === 'caps') caps(rest.includes('--json'));
  else if (verb === 'declarations') console.log(declarationsFor(rest));
  else { console.error('usage: main.ts mcp | run [--grant CAP]... FILE|- | caps [--json] | declarations [CAP...]'); process.exit(2); }
} catch (e) {
  console.error(`powos sandbox: ${(e as Error).message}`);
  process.exit(1);
}
