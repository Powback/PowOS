// Headless: the render scan (ui/renderscan.ts) over a web window moved, then resized, 30 frames each, a second
// window beside it (ui/webwindows.tsx update(), as its title bar drag and edges do). `shell/dev/perf/run.sh renders-window.js`.
(async () => {
  const R = await importShim("./ui/renderscan.ts"), W = await importShim("./ui/webwindows.tsx"), S = await importShim("./state.ts");
  const raf = () => new Promise((r) => requestAnimationFrame(r));
  const page = S.pages.value[S.page.value] ?? 1;
  W.webWins.value = [{ id: 9001, key: "a:gate.one/.Main", label: "One", page, x: 20, y: 80, w: 300, h: 260, live: true },
    { id: 9002, key: "a:gate.two/.Main", label: "Two", page, x: 60, y: 400, w: 280, h: 220, live: true }];
  for (let i = 0; i < 10; i++) await raf();
  const run = async (f) => { R.startScan("probe"); R.reset(); for (let i = 0; i < 30; i++) { f(i); await raf(); } const r = R.renderReport(); R.stopScan("probe");
    return { renders: r.renders, needless: r.needlessRenders, renderMs: r.renderMs, commits: r.commits, byCount: r.byCount.slice(0, 10), needlessTop: r.needless.slice(0, 8) }; };
  const move = await run((i) => W.update(9001, { x: 20 + i * 3, y: 80 + i * 2 }));
  const resize = await run((i) => W.update(9001, { w: 300 + i * 3, h: 260 + i * 2 }));
  W.webWins.value = [];
  return { move, resize };
})()
