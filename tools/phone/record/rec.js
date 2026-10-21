// rec.js: injected into home's page over CDP (run.sh) - logs into window.__hg every recents.*/system.* event (not
// system.glass/insets), every animation frame where .screens' opacity/transform or the switcher layer's classes
// change, rAF gaps > 40 ms, visibility changes and long tasks. __hg[0].off = Date.now() - performance.now() (to line
// entries up with the phone's clock). Read back: JSON.stringify(window.__hg).
(() => {
  const w = window; w.__hg = [{ off: Date.now() - performance.now() }]; const L = (o) => { w.__hg.push(Object.assign({ t: Math.round(performance.now()) }, o)); if (w.__hg.length > 5000) w.__hg.shift(); };
  const h = w.__powosHost;
  if (!w.__hgOrig) w.__hgOrig = h.emit.bind(h);
  h.emit = (e, p) => { if (/^(recents|system|switcher)/.test(e) && e !== "system.glass" && e !== "system.insets") L({ ev: e, p: e === "recents.drag" ? [p.progress, p.home].map(x=>+(+x).toFixed(2)).join("/") : /begin|update|tasks/.test(e) ? (p && p.from) : JSON.stringify(p).slice(0, 80) }); return w.__hgOrig(e, p); };
  if (!w.__hgVis) { w.__hgVis = 1; document.addEventListener("visibilitychange", () => w.__hgL({ vis: document.visibilityState })); }
  w.__hgL = L;
  try { if (!w.__hgPO) { w.__hgPO = new PerformanceObserver((l) => l.getEntries().forEach((e) => w.__hgL({ long: Math.round(e.duration), at: Math.round(e.startTime) }))); w.__hgPO.observe({ type: "longtask" }); } } catch (e) {}
  let last = "", lt = 0;
  const loop = () => { const now = performance.now(); if (lt && now - lt > 40) L({ gap: Math.round(now - lt) }); lt = now;
    const s = document.querySelector(".screens"); const r = document.querySelector(".recents"); const cs = s && getComputedStyle(s);
    const k = `${s && s.style.opacity}|${cs && cs.opacity}|${s && s.style.transform}|${r && r.className}|${document.documentElement.className}`;
    if (k !== last) { last = k; L({ f: k }); } w.__hgRaf = requestAnimationFrame(loop); };
  cancelAnimationFrame(w.__hgRaf); loop();
  return "ok";
})()
