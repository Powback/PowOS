/**
 * HP4 (11-06 23:46, ship bbe9e53c: "RENDER STALL ... no geometry for 4s"): the host's render watch (RenderWatch.kt)
 * probes still windows every second ("webwindows.resend") - the page's frame tick is off while nothing moves, so each
 * probe must be answered by one "w.f" at once. 11 probes ~1 s apart: every one answered, the tick a frame or two each.
 */
export async function probedStillWindows() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const ticks0 = window.__ww.ticks;
  for (let i = 0; i < 11; i++) {
    const before = window.__ww.sent.at(-1);
    window.__mockEvents.emit("webwindows.resend", 0);
    const answered = window.__ww.sent.at(-1) !== before;
    await window.__gw.frames(10);
    const after = window.__ww.sent.slice(window.__ww.sent.lastIndexOf(before) + 1);
    if (!answered || after.length !== 1) return [`WT-IDLE: probe ${i + 1}: ${after.length} w.f in 10 frames after a webwindows.resend${answered ? "" : ", none at once"} (want exactly 1, sent at once)`];
    await sleep(1000);
  }
  const ticks = window.__ww.ticks - ticks0;
  return ticks > 11 * 3 ? [`WT-IDLE: the window tick ran ${ticks}x over 11 probes of still windows (want a frame or two per probe, no loop)`] : [];
}
