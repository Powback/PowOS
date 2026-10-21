// cdp.ts <pageUrlSuffix> <expression>: evaluate in a PowOS shell WebView page (adb forward tcp:9333 in powos-vadb)
const [suffix, expr] = [process.argv[2], process.argv[3]];
const pages = await (await fetch("http://127.0.0.1:" + (process.env.PORT||"9333") + "/json")).json();
const p = pages.find((x: any) => x.url.endsWith(suffix));
if (!p) { console.log("no page", pages.map((x: any) => x.url)); process.exit(1); }
const ws = new WebSocket(p.webSocketDebuggerUrl);
ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression: expr, awaitPromise: true, returnByValue: true } }));
ws.onmessage = (m) => { const d = JSON.parse(String(m.data)); if (d.id === 1) { console.log(JSON.stringify(d.result?.result?.value ?? d.result, null, 1)); ws.close(); process.exit(0); } };
setTimeout(() => { console.log("timeout"); process.exit(2); }, 8000);
