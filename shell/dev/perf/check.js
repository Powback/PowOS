(async () => {
  const L = document.querySelector(".home .launcher");
  const st = () => { const c = getComputedStyle(L); return { p: L.style.getPropertyValue("--p"), op: c.opacity, tf: c.transform, anims: L.getAnimations().length }; };
  const raf = () => new Promise((r) => requestAnimationFrame(r));
  const W = innerWidth, H = innerHeight, x = W * 0.75;
  const fire = (tgt, type, y) => { const t = new Touch({ identifier: 9, target: tgt, clientX: x, clientY: y }); tgt.dispatchEvent(new TouchEvent(type, { touches: type === "touchend" ? [] : [t], changedTouches: [t], bubbles: true, cancelable: true })); };
  const out = {};
  let tgt = document.elementFromPoint(x, H * 0.7); let y = H * 0.7; fire(tgt, "touchstart", y); await raf();
  for (let i = 0; i < 30; i++) { y -= 6; fire(tgt, "touchmove", y); await raf(); }
  out.mid = st();
  fire(tgt, "touchend", y); await raf(); out.settling = st(); await new Promise((r) => setTimeout(r, 400)); out.opened = st();
  tgt = document.querySelector(".drawer-list"); y = H * 0.3; fire(tgt, "touchstart", y); await raf();
  for (let i = 0; i < 20; i++) { y += 20; fire(tgt, "touchmove", y); await raf(); }
  out.closingMid = st(); fire(tgt, "touchend", y); await new Promise((r) => setTimeout(r, 400)); out.closed = st();
  return out;
})()
