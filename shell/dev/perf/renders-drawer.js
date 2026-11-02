// Headless: the render scan (ui/renderscan.ts) across a launcher drawer drag up from home (and back): which components
// rendered, and the first touchmove's own cost (script + the layout it forced). `shell/dev/perf/run.sh renders-drawer.js`.
(async () => {
  const R = await importShim("./ui/renderscan.ts");
  const raf = () => new Promise((r) => requestAnimationFrame(r));
  const W = innerWidth, H = innerHeight, x = W * 0.75;
  const tgt = document.elementFromPoint(x, H * 0.7);
  const fire = (type, y) => { const t = new Touch({ identifier: 9, target: tgt, clientX: x, clientY: y });
    tgt.dispatchEvent(new TouchEvent(type, { touches: type === "touchend" ? [] : [t], changedTouches: [t], bubbles: true, cancelable: true })); };
  const runs = [];
  let rep = null;
  for (let run = 0; run < 3; run++) {
    if (run === 2) R.startScan("probe");
    let y = H * 0.7; fire("touchstart", y); await raf();
    const firsts = [];
    for (let i = 0; i < 20; i++) {
      const a = performance.now(); y -= 6; fire("touchmove", y);
      const b = performance.now(); void document.body.offsetHeight;
      const c = performance.now();
      if (i < 3) firsts.push([+(b - a).toFixed(1), +(c - b).toFixed(1)]);
      await raf();
    }
    fire("touchmove", H * 0.95); fire("touchend", H * 0.95);
    await new Promise((r) => setTimeout(r, 700));
    if (run === 2) { rep = R.renderReport(); R.stopScan("probe"); }
    runs.push(firsts);
  }
  return { firstMoves: runs, renders: rep.renders, needless: rep.needlessRenders, renderMs: rep.renderMs, byCount: rep.byCount.slice(0, 14) };
})()
