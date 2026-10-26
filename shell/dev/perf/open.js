(async () => {
  const raf = () => new Promise((r) => requestAnimationFrame(r));
  const L = document.querySelector(".home .launcher");
  // Openness as drawn: the launcher rides up from translateY(100%) (shell.css) - --p no longer moves during a drag.
  const pOf = () => 1 - new DOMMatrix(getComputedStyle(L).transform).m42 / L.offsetHeight;
  if (pOf() > 0) return { error: "drawer already open" };
  // vsync from idle frames
  let last = await raf(), iv = [];
  for (let i = 0; i < 20; i++) { const t = await raf(); iv.push(t - last); last = t; }
  iv.sort((a, b) => a - b); const vs = iv[10];
  const W = innerWidth, H = innerHeight, x = W * 0.75;
  const fire = (type, y) => {
    const tgt = document.elementFromPoint(x, H * 0.6);
    const t = new Touch({ identifier: 7, target: tgt, clientX: x, clientY: y });
    tgt.dispatchEvent(new TouchEvent(type, { touches: type === "touchend" ? [] : [t], changedTouches: [t], bubbles: true, cancelable: true }));
  };
  const DY = +(window.__probeDY ?? 120), N = +(window.__probeN ?? 8);
  let y = H * 0.6; fire("touchstart", y);
  for (let i = 1; i <= N; i++) { await raf(); y -= DY / N; fire("touchmove", y); }
  const pAtUp = pOf();
  const t0 = performance.now(); fire("touchend", y);
  const frames = []; let settled = null;
  while (performance.now() - t0 < 1500) {
    const t = await raf(); const p = pOf(); frames.push([Math.round(t - t0), Math.round(p * 1000) / 1000]);
    if (p >= 0.999) { settled = t - t0; break; }
  }
  let dropped = 0; for (let i = 1; i < frames.length; i++) dropped += Math.max(0, Math.round((frames[i][0] - frames[i - 1][0]) / vs) - 1);
  const loading = document.querySelectorAll(".drawer .app-icon.loading").length;
  const out = { vsync: Math.round(vs * 100) / 100, pAtUp, settledMs: settled && Math.round(settled), frames: frames.length, dropped, loading, trace: frames.map((f) => f.join(":")).join(" ") };
  // close again
  await new Promise((r) => setTimeout(r, 400));
  const tgt = document.querySelector(".drawer-list") || document.querySelector(".launcher");
  const c = (type, yy) => { const t = new Touch({ identifier: 8, target: tgt, clientX: x, clientY: yy }); tgt.dispatchEvent(new TouchEvent(type, { touches: type === "touchend" ? [] : [t], changedTouches: [t], bubbles: true, cancelable: true })); };
  let yy = H * 0.3; c("touchstart", yy); for (let i = 0; i < 8; i++) { await raf(); yy += 40; c("touchmove", yy); } c("touchend", yy);
  await new Promise((r) => setTimeout(r, 600));
  out.closedAfter = pOf();
  return out;
})()
