// F8: scroll the page 12 px per animation frame for 10 s (a steady fling), F9: stop. The textarea keeps focus.
(function () {
  let until = 0;
  function step() { if (performance.now() < until) { window.scrollBy(0, 12); requestAnimationFrame(step); } }
  addEventListener('keydown', e => {
    if (e.key === 'F8') { e.preventDefault(); until = performance.now() + 10000; requestAnimationFrame(step); }
    if (e.key === 'F9') { e.preventDefault(); until = 0; window.scrollTo(0, 0); }
  }, true);
  addEventListener('load', () => document.getElementById('ta').focus());
})();
