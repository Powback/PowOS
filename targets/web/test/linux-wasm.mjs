// Boots Linux/Wasm (https://powos-web.pow/linux-wasm/) and times a CPU-bound shell loop - the same loop
// test/bench-native.sh times natively, for a speed ratio. URL, OUT, LOOP (iterations, default 200000)
import { chromium } from 'playwright';
import fs from 'node:fs';

const url = process.env.URL || 'https://powos-web.pow/linux-wasm/';
const out = process.env.OUT || '/out';
const loop = Number(process.env.LOOP || 200000);
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ channel: process.env.CHANNEL || undefined, args: [`--host-resolver-rules=MAP powos-web.pow ${process.env.RESOLVE || 'traefik'}`] });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 800 } });
const log = fs.createWriteStream(`${out}/linux-wasm-console.log`);
page.on('console', (m) => log.write(m.text() + '\n'));
page.on('pageerror', (e) => log.write('PAGEERROR ' + e.message + '\n'));
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
const t0 = Date.now();
await page.goto(url, { waitUntil: 'load' });
const prompt = await until(/^~ # *$/m, 120000); // BusyBox ash's prompt, once /init has started the shell
const tBoot = (Date.now() - t0) / 1000;
if (!prompt) {
  console.log('no shell prompt within 120 s; terminal:\n' + (await text()).split('\n').slice(-15).join('\n'));
  await browser.close(); process.exit(1);
}
console.log(`shell prompt after ${tBoot.toFixed(1)} s (page load to prompt)`);
await page.locator('#terminal').click();
// No $(...) in the command: command substitution needs vfork(), which Linux/Wasm doesn't implement yet. Timed
// from the page instead.
const cmd = `i=0; while [ $i -lt ${loop} ]; do i=$((i+1)); done; echo LOOP-DONE 0`;
const t1 = Date.now();
await page.keyboard.type(cmd);
await page.keyboard.press('Enter');
const done = await until(/^LOOP-DONE (\d+)/m, 600000);
const wall = (Date.now() - t1) / 1000;
console.log(done ? `loop of ${loop}: ${wall.toFixed(2)} s wall` : 'loop did not finish in 600 s');
fs.writeFileSync(`${out}/terminal.txt`, await text());
await page.screenshot({ path: `${out}/linux-wasm.png` });
await browser.close();
