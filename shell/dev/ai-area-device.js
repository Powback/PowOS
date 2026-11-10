/** Live-board drill-down; called one step at a time by the guarded phone queue job. No fixture writes. */
export async function aiAreaDevice(step) {
  const G = window.__gw;
  const S = await G.mod("./state.ts");
  const A = await G.mod("./ui/aiprogress.tsx");
  const P = await G.mod("./ui/powai.tsx");
  const q = (s) => document.querySelector(s);
  const visible = (s) => (q(s)?.getBoundingClientRect().height ?? 0) > 0;
  const row = (area) => `.ai-left .ais-area-row[data-area="${CSS.escape(area)}"]`;
  const detail = (area) => `.ai-left [data-area-detail="${CSS.escape(area)}"]`;
  const click = async (s) => { if (window.__aiAreaDevice?.touched) throw Error("STOP: user input"); if (!q(s)) throw Error(`missing ${s}`); q(s).click(); await G.sleep(700); };
  if (step === "setup") return aiAreaSetup({ S, A, P, q, visible, row, G });
  const t = window.__aiAreaDevice;
  if (!t) return ["SKIP: no live board snapshot"];
  if (t.touched) {
    window.removeEventListener("pointerdown", t.onTouch, true);
    return ["SKIP: user input; no further navigation or restoration"];
  }
  if (step === "restore") {
    const open = q('.ai-left .ais-area-row[aria-expanded="true"]');
    if (open) await click(row(open.dataset.area));
    if (t.expanded) await click(row(t.expanded));
    [S.page.value, S.aiScreen.value, S.aiAgent.value, A.progressFocus.value] = t.saved;
    window.removeEventListener("pointerdown", t.onTouch, true);
    delete window.__aiAreaDevice;
    return [];
  }
  const signature = JSON.stringify(A.areaStats().filter((a) => a.open.length).map((a) => [a.name, a.open.map((w) => [w.id, A.dotOf(w)])]));
  if (signature !== t.signature) return ["SKIP: live board membership/state changed during drill-down; retry on stable data"];
  const item = (area, id) => `${detail(area)} .ais-ck-item[data-task="${CSS.escape(id)}"]`;
  const taskShown = (id) => visible(`.aip-task[data-task="${CSS.escape(id)}"]`);
  const fail = (ok, why) => ok ? [] : [why];
  return aiAreaStep({ step, S, A, t, q, visible, row, detail, click, item, taskShown, fail, G });
}

async function aiAreaStep(c) {
  const run = aiAreaSteps[c.step];
  return run ? run(c) : [`unknown step ${c.step}`];
}
const aiAreaSteps = {
  mixed: async (c) => {
    const { S, A, t, q, visible, row, detail, click, item, taskShown, fail, G } = c;
    if (q(row(t.mixed.name)).getAttribute("aria-expanded") !== "true") await click(row(t.mixed.name));
    return fail(t.mixed.open.every((w) => visible(item(t.mixed.name, w.id))), "mixed area did not reveal every active/idle task");
  },
  area: async (c) => {
    const { S, A, t, q, visible, row, detail, click, item, taskShown, fail, G } = c;
    await click(`${detail(t.mixed.name)} .ais-ck-all`);
    return fail(S.aiScreen.value === "progress" && A.progressFocus.value?.area === t.mixed.name && A.progressFocus.value?.id === "" && t.mixed.open.every((w) => taskShown(w.id)), "All of area did not route to its open Progress card");
  },
  rest: async (c) => {
    const { S, A, t, q, visible, row, detail, click, item, taskShown, fail, G } = c;
    S.aiScreen.value = "chat"; await G.sleep(700);
    await click(row("rest"));
    return fail(q(row(t.mixed.name)).getAttribute("aria-expanded") === "false" && t.idle.open.every((w) => visible(item("rest", w.id))) && !t.mixed.open.some((w) => visible(item("rest", w.id))), "idle-only expansion is missing tasks or not exclusive");
  },
  task: async (c) => {
    const { S, A, t, q, visible, row, detail, click, item, taskShown, fail, G } = c;
    const id = t.idle.open[0].id;
    await click(`${item("rest", id)} .ais-ck-open`);
    return fail(S.aiScreen.value === "progress" && A.progressFocus.value?.area === t.idle.name && A.progressFocus.value?.id === id && taskShown(id) && !!q(`.aip-task.focus[data-task="${CSS.escape(id)}"]`), "Open task did not focus the live idle task");
  },
  all: async (c) => {
    const { S, A, t, q, visible, row, detail, click, item, taskShown, fail, G } = c;
    S.aiScreen.value = "chat"; await G.sleep(700); await click(`${detail("rest")} .ais-ck-all`);
    return fail(S.aiScreen.value === "progress" && A.progressFocus.value === null, "All areas did not clear progressFocus");
  },
  collapse: async (c) => {
    const { S, A, t, q, visible, row, detail, click, item, taskShown, fail, G } = c;
    S.aiScreen.value = "chat"; await G.sleep(700); await click(row("rest"));
    return fail(q(row("rest")).getAttribute("aria-expanded") === "false" && !visible(detail("rest")), "idle-only area did not collapse");
  },
};

async function aiAreaSetup({ S, A, P, q, visible, row, G }) {
    if (innerWidth < 700) return ["SKIP: unfolded AI layout required; fold state left untouched"];
    if (!P.boardSeen.value) return ["SKIP: live board has not loaded"];
    const areas = A.areaStats().filter((a) => a.open.length);
    const mixed = areas.find((a) => a.open.some((w) => A.dotOf(w) === "stalled") && a.open.some((w) => A.dotOf(w) !== "stalled"));
    const idle = areas.find((a) => a.open.every((w) => A.dotOf(w) === "stalled"));
    if (!mixed || !idle) return ["SKIP: live board needs both a mixed active/idle area and an idle-only area"];
    window.__aiAreaDevice = { mixed, idle, signature: JSON.stringify(areas.map((a) => [a.name, a.open.map((w) => [w.id, A.dotOf(w)])])), saved: [S.page.value, S.aiScreen.value, S.aiAgent.value, A.progressFocus.value], expanded: q('.ai-left .ais-area-row[aria-expanded="true"]')?.dataset.area };
    window.__aiAreaDevice.onTouch = (e) => { if (e.isTrusted) window.__aiAreaDevice.touched = true; };
    window.addEventListener("pointerdown", window.__aiAreaDevice.onTouch, true);
    S.page.value = -1; S.aiAgent.value = null; S.aiScreen.value = "chat";
    await G.sleep(700);
    return visible(row(mixed.name)) ? [] : ["By area not visible in live AI page"];
}
