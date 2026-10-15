// Where is QEMU stuck in the browser? Resumes the snapshot, types a login name (the guest then freezes), waits, and
// pauses every QEMU worker thread through the Chrome DevTools Protocol: prints each thread's call stack (the wasm
// build keeps function names). URL, OUT, WAIT (seconds after typing, default 40)
import { chromium } from 'playwright';
import fs from 'node:fs';

const url = process.env.URL || 'https://powos-web.pow/';
const out = process.env.OUT || '/out';
const wait = Number(process.env.WAIT || 40);
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ channel: process.env.CHANNEL || undefined, args: [`--host-resolver-rules=MAP powos-web.pow ${process.env.RESOLVE || 'traefik'}`, '--remote-debugging-port=9333'] });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 800 } });
await page.goto(url, { waitUntil: 'load' });
const term = () => page.evaluate(() => {
  const b = window.powosTerm?.buffer.active, l = [];
  if (b) for (let i = 0; i < b.length; i++) l.push((b.getLine(i)?.translateToString(true) || '').trimEnd());
  return l;
});
for (let i = 0; i < 60 && !(await term()).some((x) => x.startsWith('HB ')); i++) await page.waitForTimeout(2000);
if (process.env.NOTYPE !== '1') {
  await page.evaluate(() => window.powosTerm?.focus());
  await page.keyboard.type('powos');
  await page.keyboard.press('Enter');
  console.log('typed: powos');
}
await page.waitForTimeout(wait * 1000);

// Raw CDP on the browser endpoint: attach to every worker, pause it, print its stack.
const ver = await (await fetch('http://127.0.0.1:9333/json/version')).json();
const ws = new WebSocket(ver.webSocketDebuggerUrl);
await new Promise((ok) => ws.addEventListener('open', ok));
let id = 0;
const pending = new Map(), waiters = [];
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  else for (const w of waiters.slice()) w(m);
});
const send = (method, params = {}, sessionId) => new Promise((ok) => {
  const i = ++id; pending.set(i, ok); ws.send(JSON.stringify({ id: i, method, params, sessionId }));
});
const targets = (await send('Target.getTargets')).result.targetInfos;
const workers = targets.filter((t) => t.type === 'worker');
console.log(`${workers.length} workers`);
for (const w of workers) {
  const s = (await send('Target.attachToTarget', { targetId: w.targetId, flatten: true })).result.sessionId;
  await send('Debugger.enable', {}, s);
  const paused = new Promise((ok) => {
    const f = (m) => { if (m.method === 'Debugger.paused' && m.sessionId === s) { waiters.splice(waiters.indexOf(f), 1); ok(m.params); } };
    waiters.push(f);
    setTimeout(() => ok(null), 8000);
  });
  await send('Debugger.pause', {}, s);
  const p = await paused;
  console.log(`=== worker ${w.title || w.url}`);
  if (!p) { console.log('  (did not pause within 8 s)'); continue; }
  for (const f of p.callFrames.slice(0, 18)) console.log(`  ${f.functionName || '(anonymous)'}  ${f.url.split('/').pop()}:${f.location.lineNumber}`);
  await send('Debugger.resume', {}, s);
}
// SAMPLES=N: profile the vCPU thread (the one in mttcg_cpu_thread_fn): pause N times, count stack functions.
const n = Number(process.env.SAMPLES || 0);
if (n) {
  const counts = new Map(); let got = 0;
  for (const w of workers) {
    const s = (await send('Target.attachToTarget', { targetId: w.targetId, flatten: true })).result.sessionId;
    await send('Debugger.enable', {}, s);
    for (let i = 0; i < n; i++) {
      const paused = new Promise((ok) => {
        const f = (m) => { if (m.method === 'Debugger.paused' && m.sessionId === s) { waiters.splice(waiters.indexOf(f), 1); ok(m.params); } };
        waiters.push(f); setTimeout(() => ok(null), 3000);
      });
      await send('Debugger.pause', {}, s);
      const p = await paused;
      if (!p) break;
      const names = p.callFrames.map((f) => f.functionName);
      await send('Debugger.resume', {}, s);
      if (!names.includes('$mttcg_cpu_thread_fn')) break; // not the vCPU thread
      got++;
      for (const name of new Set(names)) counts.set(name, (counts.get(name) || 0) + 1);
      await new Promise((r) => setTimeout(r, 700));
    }
    if (got) break;
  }
  console.log(`vCPU profile, ${got} samples (share of samples whose stack contains the function):`);
  for (const [k, v] of [...counts].sort((a, b) => b[1] - a[1]).slice(0, 30)) console.log(`  ${String(Math.round(100 * v / got)).padStart(3)}%  ${k}`);
}
ws.close();
await browser.close();
