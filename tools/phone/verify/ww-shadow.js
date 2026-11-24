// tools/phone/verify/ww-shadow.js: ww-shadow.sh's sampler, evaluated in home's page. SH1 (the user, 11-23: "The
// shadow is not positioned correctly when I'm resizing a window"): every display frame (rAF) while it runs, window ID's
// drop shadow against its frame - the whole shadow's caster box, or each RS6 9-slice piece's box and the caster edges
// it shows - in CSS px, 1 px slack. The same reading as the gate's ww-shadow-track (shell/dev/gate.mjs shadowAt).
// __wwShadow.start(id) / .stop() -> "frames F sliced S bad B; <first bad frames>".
(() => {
  const near = (a, b) => Math.abs(a - b) <= 1;
  const R = (r) => `${Math.round(r.left)},${Math.round(r.top)} ${Math.round(r.width)}x${Math.round(r.height)}`;
  const IJ = [[0, 0], [1, 0], [2, 0], [0, 1], [2, 1], [0, 2], [1, 2], [2, 2]];
  const NAMES = "nw n ne w e sw s se".split(" ");
  function piece(p, n, F, P, S) {
    const [i, j] = IJ[n];
    const col = [[F.left - P, S], [F.left - P + S, F.width + 2 * P - 2 * S], [F.right + P - S, S]][i];
    const row = [[F.top - P, S], [F.top - P + S, F.height + 2 * P - 2 * S], [F.bottom + P - S, S]][j];
    const b = p.getBoundingClientRect(), c = p.firstElementChild.getBoundingClientRect();
    const out = [];
    if (!(near(b.left, col[0]) && near(b.width, col[1]) && near(b.top, row[0]) && near(b.height, row[1]))) out.push(`${NAMES[n]} at ${R(b)}`);
    for (const [e, got, want] of [i === 0 && ["l", c.left, F.left], i === 2 && ["r", c.right, F.right], j === 0 && ["t", c.top, F.top], j === 2 && ["b", c.bottom, F.bottom]].filter(Boolean))
      if (!near(got, want)) out.push(`${NAMES[n]} ${e} edge ${Math.round(got - want)} px off`);
    return out;
  }
  function look(id) {
    const frame = document.querySelector(`.webwindow[data-wwid="${id}"]`);
    const sh = frame?.parentElement?.querySelector(`.ww-shadow[data-wwid="${id}"]`);
    if (!frame || !sh) return { sliced: false, bad: frame ? ["no shadow"] : ["no frame"] };
    const F = frame.getBoundingClientRect();
    const k = F.width / parseFloat(frame.style.width) || 1;
    const first = sh.firstElementChild, pieces = [...sh.querySelectorAll(":scope > .ww-s9")];
    const hidden = getComputedStyle(first).visibility === "hidden";
    if (!sh.classList.contains("sliced")) {
      const c = first.getBoundingClientRect();
      const bad = [];
      if (pieces.length) bad.push(`${pieces.length} pieces left`);
      if (!(near(c.left, F.left) && near(c.top, F.top) && near(c.width, F.width) && near(c.height, F.height))) bad.push(`whole at ${R(c)}, frame ${R(F)}`);
      if (hidden) bad.push("whole hidden");
      return { sliced: false, bad };
    }
    if (pieces.length !== 8) return { sliced: true, bad: [`${pieces.length} pieces`] };
    const P = (first.getBoundingClientRect().left - sh.getBoundingClientRect().left);
    const S = pieces[0].getBoundingClientRect().width;
    const bad = pieces.flatMap((p, n) => piece(p, n, F, P, S));
    if (!hidden) bad.push("whole shows beside the pieces");
    if (bad.length) bad.push(`frame ${R(F)} k ${k.toFixed(2)}`);
    return { sliced: true, bad };
  }
  let run = null;
  globalThis.__wwShadow = {
    start(id) {
      if (run) cancelAnimationFrame(run.raf);
      run = { id, frames: 0, sliced: 0, bad: 0, first: [], raf: 0 };
      const tick = () => {
        const r = look(run.id);
        run.frames++;
        if (r.sliced) run.sliced++;
        if (r.bad.length) (run.bad++, run.first.length < 3 && run.first.push(`frame ${run.frames}: ${r.bad.slice(0, 4).join("; ")}`));
        run.raf = requestAnimationFrame(tick);
      };
      run.raf = requestAnimationFrame(tick);
      return "ok";
    },
    stop() {
      if (!run) return "not running";
      cancelAnimationFrame(run.raf);
      const r = run;
      run = null;
      return `frames ${r.frames} sliced ${r.sliced} bad ${r.bad}${r.first.length ? "; " + r.first.join(" | ") : ""}`;
    },
  };
  return "ok";
})();
