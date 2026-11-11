// CDP diagnostic observer only; installed by ww-resize.sh outside timed gestures.
// Actual __ww.geometry() schema: dpr, count, then 24 words per entry; resizing is word 20 (1, or 2 = resizing and
// lifted over home - LH1; 3 = lifted only, the drag's end).
((token, id) => {
  if (!globalThis.__ww?.geometry || typeof globalThis.__glassDrag !== 'function') return 'ERR missing live schema';
  globalThis.__wwResizeProbe?.stop();
  let epoch = 0, previous = globalThis.__ww.lastResize, was = false;
  const timer = setInterval(() => {
    const words = globalThis.__ww.geometry().split(' ');
    let active = false;
    if (words.length !== 2 + Number(words[1]) * 24) return;
    for (let i = 2; i < words.length; i += 24) {
      if (Number(words[i]) === id) active = words[i + 20] === '1' || words[i + 20] === '2';
    }
    // lastResize changes even if a release/regrab happened between samples.
    if (previous !== globalThis.__ww.lastResize || active !== was) epoch++;
    previous = globalThis.__ww.lastResize;
    was = active;
    console.log(token + ' ' + JSON.stringify({at: Date.now(), active, epoch, off: globalThis.__glassDragOff}));
    // Quote-free marker for the device watcher; the JSON line stays the validator's evidence.
    if (active) console.log(token + '_ACTIVE');
  }, 16);
  globalThis.__wwResizeProbe = {stop() { clearInterval(timer); delete globalThis.__wwResizeProbe; }};
  return 'ok';
})(TOKEN, WINDOW_ID)
