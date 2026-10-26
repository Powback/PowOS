// Read-only: the drawer's geometry when open, worked out from the page as it is (closed or open) - each piece's box
// on screen minus its current transform (shell.css: launcher-clip moves (p-1)*strip, the drawer in it
// (1-p)*(rise+strip), the bar p*strip). Nothing is set. Run: tools/phone/cdp.sh eval home "$(cat geometry.js)".
(() => {
  const q = (s) => document.querySelector(s);
  const L = q(".home > .stage > .launcher-clip > .launcher");
  if (!L) return { error: "not the windowed drawer (old page?)", frameInLauncher: !!q(".launcher > .launcher-frame") };
  const ty = (e) => new DOMMatrix(getComputedStyle(e).transform).m42;
  const strip = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--strip-height"));
  const rise = parseFloat(getComputedStyle(L).getPropertyValue("--rise"));
  const clip = q(".launcher-clip"), bar = q(".home > .bar"), pill = q(".home > .bar .bar-pill"), drawer = q(".home .drawer");
  // Each piece's place at rest open (p = 1): its box minus what moves it now, plus what moves it open.
  const clipBottom = clip.getBoundingClientRect().bottom - ty(clip);
  // The bar is at p*strip open (none under the dock: pill-below).
  const pillTop = pill.getBoundingClientRect().top - ty(bar) + (q(".home").classList.contains("pill-below") ? 0 : strip);
  const rowBottom = drawer.getBoundingClientRect().bottom - ty(clip) - ty(L);
  const az = q(".drawer .grid.az");
  return {
    open: q(".home").classList.contains("open"), H: innerHeight, strip, rise, riseVh: +((rise / innerHeight) * 100).toFixed(1),
    openWindowBottom: Math.round(clipBottom), openPillTop: Math.round(pillTop), windowToPill: Math.round(pillTop - clipBottom),
    openLastRowBottom: Math.round(rowBottom), lastRowClear: Math.round(clipBottom - rowBottom),
    grid: getComputedStyle(az).display, cols: getComputedStyle(az).gridTemplateColumns.split(" ").length, apps: az.children.length,
  };
})()
