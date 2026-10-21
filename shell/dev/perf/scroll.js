(async () => {
  const S = await importShim("./state.ts"); const NG = await importShim("./ui/nativeglass.ts");
  document.documentElement.classList.add("glass-native");
  S.drawer.value = 1; await new Promise((r) => setTimeout(r, 600));
  const raf = () => new Promise((r) => requestAnimationFrame(r));
  const list = document.querySelector(".drawer-list");
  const muts = []; const mo = new MutationObserver((rs) => rs.forEach((r) => muts.push(`${r.type}:${r.attributeName ?? ""}:${(r.target.className || r.target.nodeName || "").toString().slice(0, 40)}`)));
  mo.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
  const regions = new Set(); const sl = []; let rafCount = 0;
  for (let i = 0; i < 40; i++) {
    list.scrollTop += i < 20 ? 25 : -25;
    const a = performance.now(); void document.body.offsetHeight; sl.push(performance.now() - a);
    regions.add(NG.debug.measure());
    await raf(); rafCount++;
  }
  mo.disconnect();
  const pill = document.querySelector(".bar-pill"); const cs = getComputedStyle(pill);
  return { scrollRange: list.scrollHeight - list.clientHeight, distinctRegionSets: regions.size, mutations: muts.length, sampleMut: [...new Set(muts)].slice(0, 8),
    styleLayoutMed: +[...sl].sort((m, n) => m - n)[20].toFixed(2), styleLayoutMax: +Math.max(...sl).toFixed(2), pill: { opacity: cs.opacity, filter: cs.filter, backdrop: cs.backdropFilter, willChange: cs.willChange, transform: cs.transform } };
})()
