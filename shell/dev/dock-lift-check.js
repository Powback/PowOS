/**
 * DL1 (the user, 10-31 15:12: "If I hold it I enter edit mode where I can edit the position, so I shouldn't have to hold
 * it, I should just be able to drag it out"): a dock app pressed and moved away from the dock lifts out at once
 * (gesture.ts chromeWay "out", home.tsx liftOut). In the page, for gate.mjs's dock-lift-* scenes, which drive a real
 * finger (CDP touch): [setup] spies on the host and pins known apps, [cell] says where one sits, [state] what happened.
 */
const mod = (p) => window.__gw.mod(p);

/** Spies on split / float / launch / the haptic tick, pins four mock apps; [right]: the dock on the right (unfolded). */
export async function setup(right) {
  const [S, B, W] = await Promise.all([mod("./state.ts"), mod("./bridge.ts"), mod("./ui/webwindows.tsx")]);
  const powos = B.powos;
  const calls = { split: [], float: [], launch: [], ticks: 0 };
  window.__dl = calls;
  powos.tasks.split = async (a, b) => (calls.split.push([a, b]), true);
  powos.tasks.float = async (id) => (calls.float.push(id), true);
  powos.apps.launch = async (key, opts) => void calls.launch.push([key, !!opts?.fullScreen]);
  const tick = powos.haptics?.tick?.bind(powos.haptics);
  powos.haptics = { ...(powos.haptics ?? {}), tick: async () => (calls.ticks++, tick?.()) };
  powos.webwindows = { enabled: async () => true, open: async () => 77, close: async () => true, input: async () => true, minimise: async () => true, restore: async () => true };
  W.webWins.value = [];
  if (right) S.dockTry.value = "right";
  S.setDock(["a:signal", "a:spotify", "a:maps", "a:chrome"]);
  S.page.value = 0;
  await window.__gw.settled();
  await window.__gw.frames(2);
  return S.dockPosition.value;
}

/**
 * The centre of dock app [key]'s cell once it's ready for a finger, or null: no carry, no menu, the cell still for two
 * frames (home.tsx useGlide, a scrim fading) and the topmost thing at its centre. Waits for that (up to 5 s), never a
 * fixed sleep: under the ship gate's load the dock's glide back after a drop takes longer.
 */
export async function cell(key) {
  const S = await mod("./state.ts");
  const at = () => {
    const r = document.querySelector(`.dock .dock-page .app[data-key="${key}"]`)?.getBoundingClientRect();
    return r?.width ? [r.left + r.width / 2, r.top + r.height / 2] : null;
  };
  const ready = (p) => !S.carry.value && !S.menu.value && document.elementFromPoint(p[0], p[1])?.closest(".app")?.dataset.key === key;
  let was = null;
  for (const t0 = performance.now(); performance.now() - t0 < 5000; await window.__gw.frames(2)) {
    const p = at();
    if (p && was && p[0] === was[0] && p[1] === was[1] && ready(p)) return p;
    was = p;
  }
  return null;
}

/** What the finger did: the host calls, the carry, the ghost's zone, the menu, home's page, the dock strip's scroll. */
export async function state() {
  const S = await mod("./state.ts");
  const ghost = document.querySelector(".ww-drop.dock-out");
  return {
    ...window.__dl,
    carry: S.carry.value ? { app: S.carry.value.app, lifted: !!S.carry.value.lifted } : null,
    zone: ghost?.dataset.zone ?? null,
    menu: S.menu.value?.app?.key ?? null,
    page: S.page.value,
    strip: document.querySelector(".dock .dock-pages")?.scrollLeft ?? 0,
    windows: document.querySelectorAll(".webwindow").length,
  };
}

/** Clears the calls, the menu, the page and the strip between steps. */
export async function reset() {
  const S = await mod("./state.ts");
  Object.assign(window.__dl, { split: [], float: [], launch: [], ticks: 0 });
  S.menu.value = null;
  S.page.value = 0;
  const strip = document.querySelector(".dock .dock-pages");
  if (strip) strip.scrollLeft = 0;
  await window.__gw.settled();
}
