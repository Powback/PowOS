/**
 * A filmstrip of shots (dev/shots.mjs) - one row per prefix, its frames side by side in name order - as one PNG, to
 * judge a motion driven by --p/--q at a glance. Mounted: /in (the shots), /out. Env: STRIP_ROWS ("prefix,prefix"),
 * STRIP_SIZE (folded|unfolded), STRIP_NAME, STRIP_TITLE.
 */
import fs from "node:fs";
import puppeteer from "puppeteer";
const size = process.env.STRIP_SIZE || "folded";
const rows = (process.env.STRIP_ROWS || "").split(",").filter(Boolean);
const files = fs.readdirSync("/in").filter((f) => f.endsWith(`-${size}.png`)).sort();
const img = (f) => `<figure><img src="data:image/png;base64,${fs.readFileSync("/in/" + f).toString("base64")}"><figcaption>${f.replace(`-${size}.png`, "")}</figcaption></figure>`;
const html = `<html><body style="margin:0;background:#111;color:#ccc;font:13px monospace"><h3 style="margin:10px">${process.env.STRIP_TITLE ?? ""}</h3>${rows
  .map((r) => `<div style="display:flex;gap:6px;padding:6px">${files.filter((f) => f.startsWith(r)).map(img).join("")}</div>`)
  .join("")}<style>img{width:180px;display:block}figure{margin:0}figcaption{text-align:center}</style></body></html>`;
const b = await puppeteer.launch({ executablePath: process.env.CHROME || "/usr/bin/chromium-browser", headless: true, args: ["--no-sandbox"] });
const p = await b.newPage();
await p.setViewport({ width: 1400, height: 800 });
await p.setContent(html, { waitUntil: "load" });
await p.screenshot({ path: `/out/${process.env.STRIP_NAME || "strip.png"}`, fullPage: true });
await b.close();
