// Diagnoses a Linux/Wasm boot that never reaches the shell: logs page/worker console errors, failed requests, workers
// coming and going, and the terminal's last lines. URL, TIMEOUT (s, default 40)
import { chromium } from 'playwright';
import fs from 'node:fs';

const url = process.env.URL || 'https://powos-web.pow/linux-wasm/';
const browser = await chromium.launch({ channel: process.env.CHANNEL || undefined, args: [`--host-resolver-rules=MAP powos-web.pow ${process.env.RESOLVE || 'traefik'}`] });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 900 } });
const t0 = Date.now(), at = () => ((Date.now() - t0) / 1000).toFixed(1);
page.on('console', (m) => { if (m.type() !== 'log' && m.type() !== 'debug') console.log(at(), 'console', m.type(), m.text().slice(0, 300)); });
page.on('pageerror', (e) => console.log(at(), 'pageerror', e.message));
page.on('requestfailed', (r) => console.log(at(), 'requestfailed', r.url(), r.failure()?.errorText));
page.on('response', (r) => { if (r.status() >= 400) console.log(at(), 'http', r.status(), r.url()); });
let workers = 0;
page.on('worker', (w) => { workers++; w.on('close', () => workers--); });
const text = () => page.evaluate(() => {
  const b = window.lwTerm?.buffer.active, l = [];
  if (b) for (let i = 0; i < b.length; i++) l.push((b.getLine(i)?.translateToString(true) || '').trimEnd());
  return l.join('\n');
});
await page.goto(url, { waitUntil: 'load' });
const end = Date.now() + (Number(process.env.TIMEOUT) || 40) * 1000;
let ok = false;
while (Date.now() < end) { if (/^~ #( |$)/m.test(await text())) { ok = true; break; } await page.waitForTimeout(250); }
console.log(at(), ok ? 'SHELL' : 'NO SHELL', `live workers ${workers}`);
console.log((await text()).split('\n').filter(Boolean).slice(-6).join('\n'));
if (process.env.OUT) fs.writeFileSync(`${process.env.OUT}/terminal.txt`, await text());
await browser.close();
