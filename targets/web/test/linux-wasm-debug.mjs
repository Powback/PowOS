// Debugger for a crashing Linux/Wasm program: runs CMDS in the page's shell with Chrome's debugger attached to every
// Web Worker (each CPU/task is one), pauses on exceptions, and when the throwing frame is in PROGRAM (a wasm module
// name, e.g. qmlhello - built with KEEP_NAMES=1 for function names) prints the Wasm locals of the top FRAMES frames.
// The runtime's own control-flow exceptions just resume.   PROGRAM=qmlhello CMDS='qmlhello &' boot-mac.sh ...
import { chromium } from 'playwright';

const url = process.env.URL || 'https://powos-web.pow/linux-wasm/';
const program = process.env.PROGRAM || 'qmlhello', cmd = process.env.CMDS || `${program} &`;
const frames = Number(process.env.FRAMES || 3), port = 9339;
const browser = await chromium.launch({
  channel: process.env.CHANNEL || undefined,
  args: [`--host-resolver-rules=MAP powos-web.pow ${process.env.RESOLVE || 'traefik'}`, `--remote-debugging-port=${port}`],
});
const { webSocketDebuggerUrl } = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
const ws = new WebSocket(webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let nextId = 1;
const pending = new Map();
const send = (method, params = {}, sessionId) => new Promise((resolve) => {
  const id = nextId++;
  pending.set(id, resolve);
  ws.send(JSON.stringify({ id, method, params, sessionId }));
});
let reported = false, workers = 0, pauses = 0;
const scripts = new Map(); // scriptId -> url (wasm frames carry no url themselves)
const done = new Promise((resolveDone) => {
  ws.addEventListener('message', async (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); return; }
    if (m.method === 'Target.attachedToTarget') {
      const s = m.params.sessionId, type = m.params.targetInfo.type;
      await send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, s);
      if (type === 'worker') {
        workers++;
        await send('Debugger.enable', {}, s);
        await send('Debugger.setPauseOnExceptions', { state: 'all' }, s);
      }
      await send('Runtime.runIfWaitingForDebugger', {}, s);
    } else if (m.method === 'Debugger.scriptParsed') {
      scripts.set(m.params.scriptId, m.params.url);
    } else if (m.method === 'Debugger.paused') {
      const s = m.sessionId, cf = m.params.callFrames;
      pauses++;
      if (process.env.VERBOSE) console.log('pause', cf[0]?.url, cf[0]?.functionName);
      const ours = cf.length && (scripts.get(cf[0].location.scriptId) || '').includes(`/${program}-`);
      if (ours && !reported) {
        reported = true;
        console.log(`paused: ${m.params.data?.description?.split('\n')[0] || m.params.reason}`);
        // DEREF=var0,var1: the top frame's i32 locals to read memory at (and one level further).
        const top = cf[0].scopeChain.find((x) => x.type === 'local');
        const tl = top ? (await send('Runtime.getProperties', { objectId: top.object.objectId, ownProperties: true }, s)).result : [];
        for (const name of (process.env.DEREF || '').split(',').filter(Boolean)) {
          const prop = tl.find((q) => q.name === '$' + name);
          if (!prop) continue;
          const inner = await send('Runtime.getProperties', { objectId: prop.value.objectId, ownProperties: true }, s);
          const addr = Number((inner.result || []).find((q) => q.name === 'value')?.value?.value);
          const w = await words(addr);
          const d = parseInt(w.split(' ')[0], 16);
          console.log(`  *${name} (0x${addr.toString(16)}) = ${w}   **${name} (0x${d.toString(16)}) = ${await words(d)}`);
        }
        for (const f of cf.slice(0, frames)) {
          console.log(`--- ${f.functionName}`);
          for (const scope of f.scopeChain.filter((x) => x.type === 'local' || x.type === 'wasm-expression-stack')) {
            const props = await send('Runtime.getProperties', { objectId: scope.object.objectId, ownProperties: true }, s);
            for (const p of props.result || []) {
              const v = p.value;
              if (!v) continue;
              let shown = v.description ?? v.value;
              if (v.objectId && v.type === 'object') {
                const inner = await send('Runtime.getProperties', { objectId: v.objectId, ownProperties: true }, s);
                shown = (inner.result || []).filter((q) => q.value && q.enumerable)
                  .map((q) => `${q.name}=${q.value.description ?? q.value.value}`).join(' ');
              }
              console.log(`  [${scope.type}] ${p.name} = ${shown}`);
            }
          }
        }
        resolveDone();
      }
      await send('Debugger.resume', {}, s);
    }
  });
});
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 1000 } });
// The shared WebAssembly.Memory, captured when the runtime hands it to the page's framebuffer hook - so pointers in
// a paused frame can be read (the paused worker shares it with the page).
await page.addInitScript(() => {
  let hook;
  Object.defineProperty(globalThis, 'powosFramebuffer', {
    configurable: true,
    get: () => hook,
    set: (f) => { hook = (m, ...a) => { globalThis.__powosMemory = m; return f(m, ...a); }; },
  });
});
const words = (addr, n = 4) => page.evaluate(([a, k]) => {
  const m = globalThis.__powosMemory; if (!m) return 'no memory';
  const v = new DataView(m.buffer); const out = [];
  for (let i = 0; i < k; i++) out.push('0x' + v.getUint32(a + 4 * i, true).toString(16));
  return out.join(' ');
}, [addr, n]);
const pageTarget = (await send('Target.getTargets')).targetInfos.find((t) => t.type === 'page' && t.url === 'about:blank');
const attached = await send('Target.attachToTarget', { targetId: pageTarget.targetId, flatten: true });
await send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, attached.sessionId);
const text = () => page.evaluate(() => {
  const b = window.lwTerm?.buffer.active, l = [];
  if (b) for (let i = 0; i < b.length; i++) l.push((b.getLine(i)?.translateToString(true) || '').trimEnd());
  return l.join('\n');
});
await page.goto(url, { waitUntil: 'load' });
for (let end = Date.now() + 120000; Date.now() < end && !/^~ #( |$)/m.test(await text()); ) await page.waitForTimeout(200);
for (let last = '', same = 0; same < 10; await page.waitForTimeout(200)) { const t = await text(); same = t === last ? same + 1 : 0; last = t; }
await page.locator('#terminal').click();
await page.keyboard.type(cmd);
await page.keyboard.press('Enter');
await Promise.race([done, page.waitForTimeout((Number(process.env.TIMEOUT) || 120) * 1000)]);
if (!reported) console.log(`no exception in ${program} (workers ${workers}, pauses ${pauses})\n` + (await text()).split('\n').slice(-6).join('\n'));
await browser.close();
process.exit(0);
