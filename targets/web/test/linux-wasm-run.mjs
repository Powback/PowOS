// Runs one command in the Linux/Wasm shell and waits for its output: CMDS (the command line), WAIT_FOR (a regex the
// terminal must show), TIMEOUT (s). Prints the command's last lines; exit 1 when WAIT_FOR never shows. URL
//   SCRIPT=linux-wasm-run.mjs CMDS=/powos/apps/cxxcheck WAIT_FOR='CXXCHECK OK' test/boot.sh
import { chromium } from 'playwright';

const url = process.env.URL || 'https://powos-web.pow/linux-wasm/';
const cmd = process.env.CMDS, want = new RegExp(process.env.WAIT_FOR || '^~ # *$', 'm');
const browser = await chromium.launch({ channel: process.env.CHANNEL || undefined, args: [`--host-resolver-rules=MAP powos-web.pow ${process.env.RESOLVE || 'traefik'}`] });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 900 } });
const errors = [];
page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
page.on('pageerror', (e) => errors.push(String(e)));
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
// The prompt comes up while the other CPUs are still starting; a command typed then is lost. Wait for quiet.
for (let last = '', same = 0; same < 10; await page.waitForTimeout(200)) { const t = await text(); same = t === last ? same + 1 : 0; last = t; }
await page.locator('#terminal').click();
await page.keyboard.type(cmd);
await page.keyboard.press('Enter');
const t0 = Date.now();
const got = await until(want, (Number(process.env.TIMEOUT) || 60) * 1000);
const out = (got || await text()).split('\n');
const at = out.findLastIndex((l) => l.includes(cmd));
console.log(out.slice(at >= 0 ? at : -15).filter(Boolean).slice(0, 30).join('\n'));
if (errors.length) console.log('page errors:\n' + errors.slice(-5).join('\n'));
console.log(got ? `OK: ${want} after ${Date.now() - t0} ms` : `FAILED: ${want} not seen`);
await browser.close();
process.exit(got ? 0 : 1);
