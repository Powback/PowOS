// The streamed PowOS disk in Linux/Wasm: boots, then reads /powos (mounted by initramfs/init from the disk the page
// streams on demand) and counts the Range requests the worker made. URL, OUT
import { chromium } from 'playwright';
import fs from 'node:fs';

const url = process.env.URL || 'https://powos-web.pow/linux-wasm/';
const out = process.env.OUT || '/out';
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ channel: process.env.CHANNEL || undefined, args: [`--host-resolver-rules=MAP powos-web.pow ${process.env.RESOLVE || 'traefik'}`] });
const context = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 800 } });
let ranges = 0, rangeBytes = 0;
context.on('response', async (r) => {
  if (r.url().endsWith('powos.erofs') && r.status() === 206) {
    ranges++;
    rangeBytes += Number((await r.headerValue('content-length')) || 0);
  }
});
const page = await context.newPage();
const text = () => page.evaluate(() => {
  const b = window.lwTerm?.buffer.active, l = [];
  if (b) for (let i = 0; i < b.length; i++) l.push((b.getLine(i)?.translateToString(true) || '').trimEnd());
  return l.join('\n');
});
async function until(re, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const t = await text(); if (re.test(t)) return t; await page.waitForTimeout(200); }
  return null;
}
await page.goto(url, { waitUntil: 'load' });
const t = await until(/^~ # *$/m, 120000);
if (!t) { console.log('no shell:\n' + (await text()).split('\n').slice(-15).join('\n')); process.exit(1); }
console.log((t.match(/^(PowOS.*|wasmblk0.*)$/mg) || []).join('\n'));
await page.locator('#terminal').click();
const cmds = process.env.CMDS ? process.env.CMDS.split(';;') : ['ls /powos', 'ls /powos/bin | head -5', 'head -3 /powos/bin/powos', 'du -sh /powos'];
for (const cmd of cmds) {
  await page.keyboard.type(`${cmd}; echo DONE-$((6*7))`);
  await page.keyboard.press('Enter');
  await until(new RegExp(`DONE-42\\n(.*\\n)*~ #`, 'm'), 30000);
  await page.waitForTimeout(300);
}
const all = await text();
console.log(all.split('\n').slice(-24).join('\n'));
console.log(`disk: ${ranges} range requests, ${(rangeBytes / 1024).toFixed(0)} KiB of ${(fs.existsSync('/dev/null') ? '' : '')}the image`);
fs.writeFileSync(`${out}/terminal.txt`, all);
await browser.close();
