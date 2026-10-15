// Canvas input reaches Linux/Wasm: reads /dev/input/event0 in the guest while the test clicks, types and moves on the
// canvas, then counts the input_event records the guest got (16 bytes each on wasm32). URL, OUT
import { chromium } from 'playwright';
import fs from 'node:fs';

const url = process.env.URL || 'https://powos-web.pow/linux-wasm/';
const out = process.env.OUT || '/out';
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ channel: process.env.CHANNEL || undefined, args: [`--host-resolver-rules=MAP powos-web.pow ${process.env.RESOLVE || 'traefik'}`] });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 900 } });
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
if (!await until(/^~ #( |$)/m, 120000)) { console.log('no shell'); process.exit(1); }
const term = page.locator('#terminal');
await term.click();
const run = async (cmd) => { await page.keyboard.type(cmd); await page.keyboard.press('Enter'); await page.waitForTimeout(800); };
await run('ls -la /dev/input/; cat /proc/bus/input/devices | grep -E "^N:|^H:"');
await run('cat /dev/input/event0 > /tmp/ev &');
// Input on the canvas.
const canvas = page.locator('#screen');
const box = await canvas.boundingBox();
console.log(`canvas box: x ${box.x.toFixed(0)} y ${box.y.toFixed(0)} w ${box.width.toFixed(0)} h ${box.height.toFixed(0)}`);
await canvas.click({ position: { x: 200, y: 150 } });
await page.keyboard.type('powos');
// Two known points: a quarter and three quarters across/down the canvas (expect ABS ~8192 and ~24575).
await page.mouse.move(box.x + box.width / 4, box.y + box.height / 4);
await page.waitForTimeout(300);
await page.mouse.move(box.x + box.width * 3 / 4, box.y + box.height * 3 / 4);
await page.waitForTimeout(1500);
const events = await page.evaluate(() => globalThis.powosInputEvents);
await term.click();
await run('kill %1; wc -c /tmp/ev');
// input_event on wasm32: 4+4 time, u16 type, u16 code, s32 value. Print type code value of each EV_ABS (type 3).
await run("od -An -tu2 -w16 /tmp/ev | awk '$5 == 3 {print \"ABS code\", $6, \"value\", $7 + $8 * 65536}' | tail -6");
const t = await text();
const m = /^\s*(\d+) \/tmp\/ev/m.exec(t);
console.log(t.split('\n').slice(-12).join('\n'));
console.log(`page pushed ${events} events; guest read ${m ? m[1] : '?'} bytes = ${m ? Number(m[1]) / 16 : '?'} input_event records`);
await page.screenshot({ path: `${out}/page.png` });
await browser.close();
