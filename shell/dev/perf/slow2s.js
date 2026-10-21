(async () => {
  const raf = () => new Promise((r) => requestAnimationFrame(r));
  const L = document.querySelector(".home .launcher");
  if (!L || innerHeight === 0 || document.hidden) return { error: "home not visible" };
  if (document.querySelector(".home").classList.contains("open")) return { error: "drawer open" };
  const W = innerWidth, H = innerHeight, x = W * 0.75;
  const fire = (tgt, type, y) => { const t = new Touch({ identifier: 9, target: tgt, clientX: x, clientY: y }); tgt.dispatchEvent(new TouchEvent(type, { touches: type === "touchend" ? [] : [t], changedTouches: [t], bubbles: true, cancelable: true })); };
  let iv0 = []; let l0 = await raf(); for (let i = 0; i < 30; i++) { const t = await raf(); iv0.push(t - l0); l0 = t; } iv0.sort((a, b) => a - b); const vs = iv0[15];
  let tgt = document.elementFromPoint(x, H * 0.7); let y = H * 0.7; fire(tgt, "touchstart", y); await raf();
  const iv = []; const t0 = performance.now(); let last = await raf();
  while (performance.now() - t0 < 2000) { y -= H * 0.45 / (2000 / vs); fire(tgt, "touchmove", y); const t = await raf(); iv.push(t - last); last = t; }
  fire(tgt, "touchend", y);
  await new Promise((r) => setTimeout(r, 500));
  const dropped = iv.reduce((n, d) => n + Math.max(0, Math.round(d / vs) - 1), 0);
  const res = { vsync: +vs.toFixed(2), frames: iv.length, dropped, worst: +Math.max(...iv).toFixed(1), opened: document.querySelector(".home").classList.contains("open") };
  tgt = document.querySelector(".drawer-list") || L; y = H * 0.3; fire(tgt, "touchstart", y); await raf();
  for (let i = 0; i < 20; i++) { y += 25; fire(tgt, "touchmove", y); await raf(); }
  fire(tgt, "touchend", y); await new Promise((r) => setTimeout(r, 500));
  res.closedAfter = !document.querySelector(".home").classList.contains("open");
  return res;
})()
