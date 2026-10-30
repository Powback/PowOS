// Headless: the render scan (ui/renderscan.ts) across a page swipe there and back on home: which components rendered,
// which of those renders were needless (props/state/hooks unchanged, no signal). `shell/dev/perf/run.sh renders.js`.
(async () => {
  const R = await importShim("./ui/renderscan.ts"), S = await importShim("./state.ts");
  const raf = () => new Promise((r) => requestAnimationFrame(r));
  const H = innerHeight, W = innerWidth, y = H * 0.5;
  const tgt = document.elementFromPoint(W * 0.5, y);
  const fire = (type, x) => { const t = new Touch({ identifier: 11, target: tgt, clientX: x, clientY: y }); tgt.dispatchEvent(new TouchEvent(type, { touches: type === "touchend" ? [] : [t], changedTouches: [t], bubbles: true, cancelable: true })); };
  const swipe = async (from, to) => { fire("touchstart", from); await raf(); for (let i = 1; i <= 16; i++) { fire("touchmove", from + ((to - from) * i) / 16); await raf(); } fire("touchend", to); await new Promise((r) => setTimeout(r, 600)); };
  R.startScan("probe");
  const p0 = S.page.value;
  await swipe(W * 0.8, W * 0.2);
  const p1 = S.page.value;
  await swipe(W * 0.2, W * 0.8);
  const rep = R.renderReport();
  R.stopScan("probe");
  return { pages: S.pages.value.length, p0, p1, renders: rep.renders, needless: rep.needlessRenders, renderMs: rep.renderMs, commits: rep.commits,
    byCount: rep.byCount.slice(0, 12), needlessTop: rep.needless.slice(0, 12) };
})()
