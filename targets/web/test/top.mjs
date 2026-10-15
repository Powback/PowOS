// What is the resumed guest spending its (emulated) CPU on in the browser? Prints each new "TOP ..." block the
// snapshot's heartbeat writes to the serial console (every 30 s), for SECS seconds. LOGIN=1 also types a user name.
//   URL, OUT, SECS (default 240)
import { chromium } from 'playwright';
import fs from 'node:fs';

const url = process.env.URL || 'https://powos-web.pow/';
const out = process.env.OUT || '/out';
const secs = Number(process.env.SECS || 240);
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ args: ['--host-resolver-rules=MAP powos-web.pow traefik'] });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 800 } });
const t0 = Date.now();
await page.goto(url, { waitUntil: 'load' });
const lines = () => page.evaluate(() => {
  const b = window.powosTerm?.buffer.active, l = [];
  if (b) for (let i = 0; i < b.length; i++) l.push((b.getLine(i)?.translateToString(true) || '').trimEnd());
  return l;
});
let seen = 0, typed = false;
while (Date.now() - t0 < secs * 1000) {
  await page.waitForTimeout(5000);
  const l = await lines();
  const tops = l.filter((x) => x.startsWith('TOP '));
  if (tops.length > seen) {
    console.log(`--- ${Math.round((Date.now() - t0) / 1000)} s`);
    for (const x of tops.slice(seen)) console.log(x.slice(4));
    seen = tops.length;
  }
  if (process.env.LOGIN === '1' && !typed && l.some((x) => x.startsWith('HB '))) {
    typed = true;
    await page.evaluate(() => window.powosTerm?.focus());
    await page.keyboard.type('powos');
    await page.keyboard.press('Enter');
    console.log(`--- ${Math.round((Date.now() - t0) / 1000)} s typed: powos`);
  }
}
await browser.close();
