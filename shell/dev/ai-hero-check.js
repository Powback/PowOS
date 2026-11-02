// Perf P1 (trace perf-1793551432355, 11-01 17:43, the AI page at rest): the status page's hero re-rendered on every
// chat change (it read chat.value for its "manager working" word) and each render re-scanned the whole board twice
// (needsYou + areaStats, one 4.7 ms commit on the phone). In the page, on the status page (aiStatusSetup): a board the
// live one's size, then a reply streaming in 20 chunks and 5 board updates - the hero renders only for the busy flip and
// the board's changes, and the ring's figure is worked out once per board change, not per render.
export async function aiHeroRenders() {
  const G = window.__gw;
  const [S, P, scan] = await Promise.all([G.mod("./state.ts"), G.mod("./ui/powai.tsx"), G.mod("./ui/renderscan.ts")]);
  const raf = () => new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(() => ok())));
  const now = Date.now();
  const projects = ["Windows", "Home & launcher", "Shade & lock", "AI page", "Apps", "Games", "Performance", "Kernel & system", "Agents & tooling"];
  const row = (i, extra = {}) => ({ id: `hero-${i}`, title: i ? `Task ${i}` : "Daily driver: everything the phone needs every day", owner: "coder", status: i % 3 ? "done" : i % 5 ? "working" : "waiting", note: i % 5 ? "" : "Which one? (a / b)", project: projects[i % projects.length], created: now - 9e6, updated: now - 6e4 - i, done: i % 3 ? now - 36e5 : 0, progressDone: i ? 0 : 13, progressTotal: i ? 0 : 20, step: "", steps: "", commits: "", images: "", activity: now - 6e4, tryLine: "", ...extra });
  P.board.value = Array.from({ length: 160 }, (_, i) => row(i));
  await raf();
  scan.startScan("gate-ai-hero");
  scan.reset();
  const items = [{ kind: "user", text: "how is it going" }];
  const reply = "Three agents are on it: the dock size, the window raise and the page dots. Two of them land tonight and the third waits on you.".split(" ");
  for (let i = 1; i <= 20; i++) (S.chat.value = { busy: i < 20, items: [...items, { kind: "assistant", text: reply.slice(0, i).join(" ") }] }), await raf();
  const chatRenders = scan.scanStats().filter((x) => x.name === "Hero").reduce((n, x) => n + x.renders, 0);
  const top = scan.scanStats().sort((a, b) => b.renders - a.renders).slice(0, 6).map((x) => `${x.name} ${x.renders}`);
  for (let i = 0; i < 5; i++) (P.board.value = P.board.value.map((r, j) => (j === i + 1 ? { ...r, updated: Date.now() } : r))), await raf();
  const hero = scan.scanStats().filter((x) => x.name === "Hero");
  const counts = { chat: chatRenders, board: hero.reduce((n, x) => n + x.renders, 0) - chatRenders, heroMs: +hero.reduce((n, x) => n + x.selfMs, 0).toFixed(1), top };
  scan.stopScan("gate-ai-hero");
  const fails = [];
  // The busy word turns on with the first chunk and off with the last: two renders at most (the setup's chat is idle).
  if (counts.chat > 2) fails.push(`the hero rendered ${counts.chat}x over a 20-chunk reply, expected <= 2 (busy on, off)`);
  if (counts.board > 5) fails.push(`the hero rendered ${counts.board}x over 5 board updates, expected <= 5`);
  if (!document.querySelector(".ai-screen.status .ais-top .ais-title")?.textContent?.includes("%")) fails.push("the hero shows no ring figure");
  return { fails, counts };
}
