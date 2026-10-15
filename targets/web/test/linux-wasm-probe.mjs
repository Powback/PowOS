// What works in Linux/Wasm's userspace today? Boots it and runs a list of typical shell operations, each followed by
// an "OK-<n>" marker; prints which produced their marker. URL, OUT
import { chromium } from 'playwright';
import fs from 'node:fs';

const url = process.env.URL || 'https://powos-web.pow/linux-wasm/';
const out = process.env.OUT || '/out';
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ channel: process.env.CHANNEL || undefined, args: [`--host-resolver-rules=MAP powos-web.pow ${process.env.RESOLVE || 'traefik'}`] });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 800 } });
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
if (!await until(/^~ # *$/m, 120000)) { console.log('no shell'); process.exit(1); }
await page.locator('#terminal').click();
const probes = [
  ['builtin echo', 'echo hello'],
  ['external program', 'uname -a'],
  ['pipeline', 'echo hi | cat'],
  ['command substitution', 'echo $(echo sub)'],
  ['subshell', '(echo in-subshell)'],
  ['sh -c', "sh -c 'echo child'"],
  ['background job', 'sleep 1 & wait'],
  ['file write/read', 'echo data > /tmp/f && cat /tmp/f'],
  ['proc', 'cat /proc/meminfo | head -1'],
  ['nproc', 'grep -c processor /proc/cpuinfo'],
  ['wget (network)', 'wget -q -O - http://example.com | head -1'],
];
for (const [i, [name, cmd]] of probes.entries()) {
  await page.keyboard.type(`${cmd} && echo OK-${i}`);
  await page.keyboard.press('Enter');
  const ok = await until(new RegExp(`^OK-${i}$`, 'm'), 15000);
  console.log(`${ok ? 'works ' : 'FAILS '} ${name.padEnd(22)} ${cmd}`);
  await page.waitForTimeout(500);
}
fs.writeFileSync(`${out}/terminal.txt`, await text());
await browser.close();
