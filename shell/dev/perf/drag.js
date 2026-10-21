(async () => {
  const raf = () => new Promise((r) => requestAnimationFrame(r));
  const W = innerWidth, H = innerHeight, x = W * 0.75;
  const tgt = document.elementFromPoint(x, H * 0.7);
  const fire = (type, y) => { const t = new Touch({ identifier: 9, target: tgt, clientX: x, clientY: y });
    tgt.dispatchEvent(new TouchEvent(type, { touches: type === "touchend" ? [] : [t], changedTouches: [t], bubbles: true, cancelable: true })); };
  const runs = [];
  for (let run = 0; run < 3; run++) {
    let y = H * 0.7; fire("touchstart", y); await raf();
    const js = [], sl = [], iv = []; let last = await raf();
    for (let i = 0; i < 40; i++) {
      const a = performance.now(); y -= 4; fire("touchmove", y);
      const b = performance.now(); void document.body.offsetHeight; getComputedStyle(document.querySelector(".home .launcher")).transform;
      const c = performance.now(); js.push(b - a); sl.push(c - b);
      const t = await raf(); iv.push(t - last); last = t;
    }
    const L = document.querySelector(".home .launcher"); const p = 1 - new DOMMatrix(getComputedStyle(L).transform).m42 / L.offsetHeight;
    fire("touchmove", H * 0.95); fire("touchend", H * 0.95);
    await new Promise((r) => setTimeout(r, 900));
    const med = (a) => { const s = [...a].sort((m, n) => m - n); return +s[Math.floor(s.length / 2)].toFixed(2); };
    const max = (a) => +Math.max(...a).toFixed(2);
    runs.push({ pEnd: +p.toFixed(3), jsMed: med(js), jsMax: max(js), styleLayoutMed: med(sl), styleLayoutMax: max(sl), frameMed: med(iv), frameMax: max(iv), over20ms: iv.filter((v) => v > 20).length });
  }
  return runs;
})()
