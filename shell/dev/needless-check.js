/**
 * needless-renders (the user, 11-07: "reactscan catches it fine" - the rs overlay's outlines): what the render scan
 * flags as needless on home - props/state/hooks equal, no signal - while the usual updates arrive: a notification
 * list, PowOS AI's board, the bar's text, a page change to the AI page and back. The offenders of the user's traces
 * (perf-1793970543446 / -527979, 11-06: Icon 208 of 212 needless, Send 94 of 95, LiveBar, PowOS AI's status
 * sections rebuilt equal) must render only when their content changes. Before the fix (gate, 821x883): 406 renders,
 * 164 needless; after: ~242, ~22 (PillSend 10).
 */
const FIXED = ["Icon", "Send", "LiveBar", "ThinBar", "WorkRowLive", "WorkingNow", "NeedsAttention", "RecentlyDone", "NeedStack", "UpNext", "SevChip"];

const list = () => ({ available: true, items: [1, 2, 3].map((i) => ({ key: `n${i}`, app: "gate", title: `T${i}`, text: `x${i}`, when: 1, icon: null, actions: [] })) });

/** Five rounds of the updates home gets anyway; the scan's report over them. */
async function rounds() {
  const R = await importShim("./ui/renderscan.ts"), S = await importShim("./state.ts"), B = await importShim("./ui/aiboard.tsx");
  R.startScan("needless");
  try {
    for (let i = 0; i < 5; i++) {
      window.__mockEvents.emit("notifications.changed", list());
      B.board.value = B.board.value.map((w) => ({ ...w }));
      S.query.value = "ab".slice(0, i % 3);
      await window.__gw.frames(3);
      S.page.value = i % 2 ? 0 : -1;
      await window.__gw.sleep(400);
    }
    return R.renderReport();
  } finally {
    R.stopScan("needless");
    S.query.value = "";
    S.page.value = 0;
  }
}

export async function needlessRenders() {
  await window.__gw.settled();
  const r = await rounds();
  const row = (x) => `${x.name} ${x.renders}r ${x.needless}n (${x.changed})`;
  window.__needless = `renders ${r.renders}, needless ${r.needlessRenders}: ${r.needless.map(row).join("; ") || "none"}`;
  const bad = r.needless.filter((x) => FIXED.includes(x.name) && x.needless > 1);
  const fails = bad.length ? [`needless renders again in ${bad.map(row).join("; ")}`] : [];
  if (r.needlessRenders > 40) fails.push(`home's needless renders ${r.needlessRenders} (want <= 40; 164 before the fix): ${r.needless.slice(0, 6).map(row).join("; ")}`);
  return fails;
}
