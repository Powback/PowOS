(async () => {
  const raf = () => new Promise((r) => requestAnimationFrame(r));
  const W = innerWidth, H = innerHeight, x = W * 0.75;
  const tgt = document.elementFromPoint(x, H * 0.7);
  const fire = (type, y) => { const t = new Touch({ identifier: 9, target: tgt, clientX: x, clientY: y });
    tgt.dispatchEvent(new TouchEvent(type, { touches: type === "touchend" ? [] : [t], changedTouches: [t], bubbles: true, cancelable: true })); };
  let y = H * 0.7; fire("touchstart", y); await raf();
  const iv = []; let last = await raf();
  for (let i = 0; i < 60; i++) { y -= 4; fire("touchmove", y); const t = await raf(); iv.push(t - last); last = t; }
  const L = document.querySelector(".home .launcher"); const a = L.getAnimations()[0]; const p = a ? +(Number(a.currentTime) / 1000).toFixed(3) : L.style.getPropertyValue("--p"); // the drag's WAAPI progress (gesture.ts follow)
  fire("touchend", y); await new Promise((r) => setTimeout(r, 500));
  return { frames: 60, p, over20: iv.filter((v) => v > 20).length };
})()
