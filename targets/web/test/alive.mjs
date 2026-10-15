// Is the resumed guest alive in the browser? Prints, every 15 s for SECS seconds: frames received, input events,
// the input ring, disk fetches so far, and the last serial line - after pressing Enter on the serial console.
//   URL, OUT, SECS (default 240)
import { chromium } from 'playwright';
import fs from 'node:fs';

const url = process.env.URL || 'https://powos-web.pow/';
const out = process.env.OUT || '/out';
const secs = Number(process.env.SECS || 240);
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ args: ['--host-resolver-rules=MAP powos-web.pow traefik'] });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 800 } });
let fetched = '(none)';
const hb = []; // [wall ms, guest uptime s] from the snapshot's heartbeat on the serial console
const log = fs.createWriteStream(`${out}/alive-console.log`);
page.on('console', (m) => { const t = m.text(); log.write(t + '\n'); if (t.startsWith('chunked: fetched')) fetched = t; });

await page.goto(url, { waitUntil: 'load' });
const t0 = Date.now();
await page.waitForTimeout(8000);
await page.evaluate(() => window.powosTerm?.focus());
await page.keyboard.press('Enter');
let typed = false;
while (Date.now() - t0 < secs * 1000) {
  await page.waitForTimeout(15000);
  const s = await page.evaluate(() => {
    const m = window.Module || {}, st = m.powosStats, b = window.powosTerm?.buffer.active;
    let last = '';
    if (b) for (let i = b.length - 1; i >= 0 && !last; i--) last = (b.getLine(i)?.translateToString(true) || '').trim();
    let disk = null; // QEMU's stderr shares the terminal: the chunked disk's progress lines are there, not in the console
    if (b) for (let i = b.length - 1; i >= 0 && !disk; i--) { const m = /chunked: fetched (\d+) blocks, ([\d.]+) MB/.exec(b.getLine(i)?.translateToString(true) || ''); if (m) disk = `${m[1]} blocks ${m[2]} MB`; }
    let h = null;
    if (b) for (let i = b.length - 1; i >= 0 && !h; i--) { const m = /^HB ([0-9.]+)/.exec((b.getLine(i)?.translateToString(true) || '').trim()); if (m) h = parseFloat(m[1]); }
    return { frames: st?.frames, events: st?.events, last: last.slice(0, 60), hb: h, disk };
  });
  if (s.hb !== null) hb.push([Date.now(), s.hb]);
  // LOGIN=1: type the user name once the guest answers - a login has to read /bin/login & co. from the disk.
  if (process.env.LOGIN === '1' && !typed && s.hb !== null) {
    typed = true;
    await page.evaluate(() => window.powosTerm?.focus());
    await page.keyboard.type('powos');
    await page.keyboard.press('Enter');
    console.log('typed: powos');
  }
  const rate = hb.length > 1 ? ((hb.at(-1)[1] - hb[0][1]) / ((hb.at(-1)[0] - hb[0][0]) / 1000)).toFixed(3) : '?';
  console.log(`${Math.round((Date.now() - t0) / 1000)}s frames=${s.frames} guest=${s.hb ?? '-'}s speed=${rate} disk=[${s.disk ?? 'none'}] serial="${s.last}"`);
}
await page.screenshot({ path: `${out}/alive.png` });
await browser.close();
