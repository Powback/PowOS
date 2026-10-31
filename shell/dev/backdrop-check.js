/**
 * THE backdrop (theme.css --backdrop-tint, --backdrop-blur-native; 2026-10-31 "the launcher and the PoAi launcher is not
 * using the same dark background as everything else"): runs in the page, gate.mjs's backdrop-* cases. Each surface over
 * the wallpaper or an app reads as one material - its fill is the one tint and nothing over or under it (no veil, no
 * grey reference fill), its compositor radius (--glass-blur-native, what nativeglass.ts registers) the one blur:
 *
 * - "home": home's widgets (the reference), an open folder's sheet and the dim behind it, and the shade's scrim
 *   (.notif-scrim, its rule from shell.css on a probe) with its radius (--shade-blur-native, what shade.tsx sends);
 * - "apps" / "ai": the launcher's frame in the pull window (mode=pull) with the drawer, then with PowOS AI's panel, and
 *   the radius pull.tsx sends the host for the blur behind the window.
 *
 * Returns { fails, read } - read: what each surface resolved to, for the log.
 */

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const COLOR = /rgba?\([^)]*\)|color\(srgb[^)]*\)/g;
/** A colour as rgba numbers rounded to 0.01 (Chromium writes color-mix results as color(srgb ...)). */
function norm(c) {
  const n = (c.match(/[\d.]+/g) || []).map(Number);
  if (c.startsWith("color(")) return [n[0] * 255, n[1] * 255, n[2] * 255, n[3] ?? 1].map((v, i) => (i < 3 ? Math.round(v) : Math.round(v * 100) / 100)).join(",");
  return [n[0], n[1], n[2], n[3] ?? 1].map((v, i) => (i < 3 ? Math.round(v) : Math.round(v * 100) / 100)).join(",");
}
/** A surface's painted fill: the colours of its layers that aren't transparent (an image layer's own, or its colour). */
function fill(el) {
  const cs = getComputedStyle(el);
  const layers = [...(cs.backgroundImage === "none" ? "" : cs.backgroundImage).matchAll(COLOR)].map((m) => norm(m[0]));
  layers.push(norm(cs.backgroundColor));
  return [...new Set(layers.filter((c) => !c.endsWith(",0")))];
}
const radius = (el) => parseFloat(getComputedStyle(el).getPropertyValue("--glass-blur-native")) || 0;

/** Home's page: the widgets (the reference), the shade's scrim and radius, an open folder's sheet and its dim. */
async function home({ same, css, want, fails, read }) {
  const S = await window.__gw.mod("./state.ts");
  await window.__gw.settled(() => document.querySelector(".page .home-tile > .tile"));
  same("widget", document.querySelector(".page .home-tile > .tile"));
  const scrim = document.createElement("div");
  scrim.className = "notif-scrim";
  document.body.append(scrim);
  same("shade", scrim, false);
  scrim.remove();
  const shadeBlur = parseFloat(css.getPropertyValue("--shade-blur-native")) || 0;
  read.shadeBlur = shadeBlur;
  if (shadeBlur !== want.blur) fails.push(`shade: the blur behind it (--shade-blur-native) is ${shadeBlur}, not the backdrop's ${want.blur}`);
  S.page.value = S.pages.value.length;
  await window.__gw.settled(() => document.querySelector(".page.library .lib-card"));
  document.querySelector(".page.library .lib-card")?.click();
  await window.__gw.settled(() => document.querySelector(".folder-view.open .folder-bg.tile"));
  await sleep(400);
  same("folder", document.querySelector(".folder-view .folder-bg.tile"));
  same("folder dim", document.querySelector(".folder-view .folder-focus.tile"));
}

/** Whether rect [a] lies inside rect [b] (half a px of rounding). */
const inside = (a, b) => a.left >= b.left - 0.5 && a.top >= b.top - 0.5 && a.right <= b.right + 0.5 && a.bottom <= b.bottom + 0.5;
const box = (r) => [r.left, r.top, r.right, r.bottom].map(Math.round).join(",");

/** The pull window's backdrop is the whole screen, the search pill and the dock inside it (no seam above them). */
function cover(frame, fails, read) {
  if (!frame) return;
  const r = frame.getBoundingClientRect();
  read.frame = box(r);
  if (!inside(new DOMRect(0, 0, innerWidth, innerHeight), r)) fails.push(`launcher: its backdrop is ${box(r)}, not the whole ${innerWidth}x${innerHeight} screen`);
  for (const el of document.querySelectorAll(".pull-screen > :is(.bar, .dock)")) {
    const b = el.getBoundingClientRect();
    if (b.width && !inside(b, r)) fails.push(`launcher: the ${el.classList[0]} (${box(b)}) is outside its backdrop`);
  }
}

export async function backdrop(part) {
  const root = document.documentElement;
  const css = getComputedStyle(root);
  const want = { blur: parseFloat(css.getPropertyValue("--backdrop-blur-native")) || 0 };
  const probe = document.createElement("div");
  probe.style.background = "var(--backdrop-tint)";
  document.body.append(probe);
  want.tint = norm(getComputedStyle(probe).backgroundColor);
  probe.remove();
  const fails = [];
  const read = { want };
  if (!want.blur || want.tint.endsWith(",0")) fails.push(`no backdrop token (--backdrop-blur-native ${want.blur}, --backdrop-tint ${want.tint})`);
  const same = (name, el, blur = true) => {
    if (!el) return void fails.push(`${name}: not on the page`);
    const f = fill(el), r = radius(el);
    read[name] = { fill: f, blur: r };
    if (f.length !== 1 || f[0] !== want.tint) fails.push(`${name}: its fill is [${f.join(" | ")}], not the backdrop tint ${want.tint} alone`);
    if (blur && r !== want.blur) fails.push(`${name}: its compositor blur is ${r}, not the backdrop's ${want.blur}`);
  };
  if (part === "home") {
    await home({ same, css, want, fails, read });
    return { fails, read };
  }
  const B = (await window.__gw.mod("./bridge.ts")).powos;
  const sent = [];
  B.pull.blur = async (dp) => void sent.push(dp);
  const E = window.__mockEvents;
  E.emit("pull.begin", { kind: part });
  E.emit("pull.end", { open: true });
  await window.__gw.settled(() => document.querySelector(part === "ai" ? ".pull-screen .ai-panel" : ".pull-screen .drawer"));
  await sleep(300);
  same(part === "ai" ? "launcher (PowOS AI)" : "launcher", document.querySelector(".pull-screen .launcher-frame.tile"));
  read.sent = sent;
  cover(document.querySelector(".pull-screen .launcher-frame.tile"), fails, read);
  if (!sent.length || sent.some((dp) => dp !== want.blur)) fails.push(`the pull window's blur behind: sent [${sent.join(", ")}] to the host, not the backdrop's ${want.blur}`);
  return { fails, read };
}
