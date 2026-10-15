// How fast does the resumed guest run in the browser? Logs in on the serial console and reads the guest's own clock
// (/proc/uptime) 30 s of wall time apart: guest seconds per wall second, plus what is busy (top).
//   URL, OUT
import { chromium } from 'playwright';
import fs from 'node:fs';

const url = process.env.URL || 'https://powos-web.pow/';
const out = process.env.OUT || '/out';
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ channel: process.env.CHANNEL || undefined, args: [`--host-resolver-rules=MAP powos-web.pow ${process.env.RESOLVE || 'traefik'}`] });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 800 } });
const log = fs.createWriteStream(`${out}/speed-console.log`);
page.on('console', (m) => log.write(m.text() + '\n'));

const term = () => page.evaluate(() => {
  const b = window.powosTerm?.buffer.active;
  if (!b) return '';
  const l = [];
  for (let i = 0; i < b.length; i++) l.push(b.getLine(i)?.translateToString(true) ?? '');
  return l.join('\n');
});
const type = async (s) => { await page.evaluate(() => window.powosTerm?.focus()); await page.keyboard.type(s); await page.keyboard.press('Enter'); };
async function until(re, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const t = await term(); if (re.test(t)) return t; await page.waitForTimeout(500); }
  return null;
}

await page.goto(url, { waitUntil: 'load' });
const t0 = Date.now();
if (!await until(/login:/, 120000)) { console.log('no login prompt; terminal:\n' + (await term()).trim().split('\n').slice(-12).join('\n')); process.exit(1); }
console.log(`login prompt at ${((Date.now() - t0) / 1000).toFixed(1)} s`);
await type('powos');
if (!await until(/Password:/, 300000)) { console.log('no password prompt'); process.exit(1); }
await type('powos');
if (!await until(/\]\$\s*$/m, 400000)) { console.log('no shell prompt'); process.exit(1); }
console.log(`shell at ${((Date.now() - t0) / 1000).toFixed(1)} s`);

const uptime = async (tag) => {
  await type(`echo ${tag} $(cut -d' ' -f1 /proc/uptime)`);
  const t = await until(new RegExp(`^${tag} ([0-9.]+)`, 'm'), 120000);
  return t ? [Date.now(), parseFloat(t.match(new RegExp(`^${tag} ([0-9.]+)`, 'm'))[1])] : null;
};
const a = await uptime('UPA');
await page.waitForTimeout(30000);
const b = await uptime('UPB');
if (a && b) console.log(`guest speed: ${((b[1] - a[1]) / ((b[0] - a[0]) / 1000)).toFixed(2)} guest s per wall s`);
await type('top -b -n1 -w 120 | head -16');
await page.waitForTimeout(20000);
console.log((await term()).split('\n').slice(-20).join('\n'));
await browser.close();
