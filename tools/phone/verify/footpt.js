// A spot to start home's pull-up from that is always free (device px "x y", or "none"): the bottom bar's row or the
// dock's, where elementFromPoint is the row itself - a gap between icons, beside the pill - never an icon, the pill, a
// button, or a floating window (windows stop above the bar: desktops.ts barTop), 40 px clear of the screen's edge
// where it can be.
// The right half only: the left half is PowOS AI's pull-up corner. Dock row first (higher: more room for a long pull). Read-only.
(async () => {
  const D = await importShim("./ui/desktops.ts");
  const r = devicePixelRatio;
  const rows = [...document.querySelectorAll(".home > .dock, .home > .bar")].map((e) => e.getBoundingClientRect()).filter((b) => b.height > 0).sort((a, b) => a.top - b.top);
  // Clear of the screen's edge first; folded, the pill can fill its row to the edge margin - then that margin.
  for (const [hi, lo] of [[innerWidth - 40, innerWidth * 0.5], [innerWidth - 4, innerWidth - 40]])
    for (const b of rows) {
      const cy = b.top + b.height / 2;
      for (let x = hi; x >= lo; x -= 4) {
        // Under the drawer's frost at rest (.launcher-frame: hit on the device though pointer-events none): what's below.
        const e = document.elementsFromPoint(x, cy).find((n) => !n.closest(".launcher-frame"));
        if (!e || !e.closest(".home") || D.inWindow(x, cy)) continue;
        if (e.closest(".app, .app-icon, button, a, input, textarea, .bar-pill, .tile, [data-key], .mic, .letter-bar")) continue;
        return Math.round(x * r) + " " + Math.round(cy * r);
      }
    }
  return "none";
})()
