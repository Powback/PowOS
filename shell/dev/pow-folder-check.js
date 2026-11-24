/**
 * PF1 (the user, 11-23: "the pow apps should be in a pow folder or something idk custom apps or Your apps or Pow or
 * whatever"; board pow-apps-live-in-one-pow-folder-in-the-launcher): every .pow web app ("w:<host>", WebApps.kt's
 * catalog sync) sits in one "Pow" folder in the launcher (ui/launcherview.ts launcherApps/powGroups, drawer.tsx).
 *
 * powFolder(): with four .pow apps in the mock's list -
 * - the launcher's All view has ONE Pow folder cell (under P) and no loose "w:" cell; the letter P shows the folder;
 * - tapping it shows its apps under the "Pow" chip, user-facing categories first, infrastructure last, each with its
 *   kind mark (.app-web-mark);
 * - search ("scan") finds the .pow app itself;
 * - the catalog sync adding and removing an app updates the folder live (its open view and its count);
 * - the folder pins to the dock and its icon there opens the folder (state.ts launch -> folder "lib:pow");
 * - an app pinned on the dock before (a placement of 11-23's build) is still pinned and drawn.
 * powEmpty(): no .pow apps - no folder anywhere (launcher, library), and a dock pin of the folder isn't drawn.
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const svg = (fill) => "data:image/svg+xml," + encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="192" height="192"><rect width="192" height="192" rx="40" fill="${fill}"/></svg>`);
const web = (host, label, [kind, category, fill]) => ({ key: `w:${host}`, label, kind: "web", url: `http://${host}/`, web: kind, webCategory: category, icon: svg(fill) });

/** The .pow apps the mock lists now (the catalog sync's result), before its own apps. */
export const WEB = [
  web("powscan.pow", "PowScan", ["pwa", "productivity", "#2f7d6d"]),
  web("ararat.pow", "Ararat", ["sleeps", "games", "#8a5a2b"]),
  web("pihole.pow", "Pi-hole", ["page", "infrastructure", "#9b2d3a"]),
  web("cdn.pow", "CDN", ["page", null, "#5a6aa8"]),
];

/** Sets the mock's .pow apps to [list] and tells the page (as the host's apps.changed after a sync). */
export async function setWeb(list) {
  const B = (await importShim("./bridge.ts")).powos;
  if (!window.__powBase) window.__powBase = B.apps.list.bind(B.apps);
  window.__powWeb = list;
  B.apps.list = async () => [...window.__powWeb, ...(await window.__powBase())];
  window.__mockEvents.emit("apps.changed", {});
  await sleep(600);
}

const cells = (sel) => [...document.querySelectorAll(`${sel} .app[data-key]`)].map((el) => el.dataset.key);

/** Opens the launcher on [letter] (null: its sections). */
async function launcher(S, D, letter) {
  S.closeDrawer(true);
  await sleep(200);
  S.drawer.value = 1;
  await sleep(400);
  D.launcherLetter.value = letter;
  await sleep(300);
}

/** The launcher's A-Z: one folder, no loose .pow app; the letter P has it. */
async function inList(S, D) {
  const fails = [];
  await launcher(S, D, "All");
  const all = cells(".drawer-page [data-view=all]");
  if (all.filter((k) => k === "lib:pow").length !== 1) fails.push(`PF1 All: ${all.filter((k) => k === "lib:pow").length} Pow folder cells, want 1`);
  const loose = all.filter((k) => k.startsWith("w:"));
  if (loose.length) fails.push(`PF1 All: .pow apps loose in the A-Z list: ${loose.join(", ")}`);
  if (!document.querySelector(".drawer-page [data-view=all] .app[data-key='lib:pow'] .pow-face")) fails.push("PF1 All: the Pow folder's cell has no folder icon (.pow-face)");
  await launcher(S, D, "P");
  const p = cells(".drawer-page [data-view=letter]");
  if (!p.includes("lib:pow")) fails.push(`PF1 letter P: no Pow folder (${p.join(", ")})`);
  if (p.some((k) => k.startsWith("w:"))) fails.push(`PF1 letter P: .pow apps loose: ${p.join(", ")}`);
  return fails;
}

/** Tapping the folder: its apps in their order, each marked, under the "Pow" chip. */
async function opens(S, D, want) {
  await launcher(S, D, "P");
  const cell = document.querySelector(".drawer-page [data-view=letter] .app[data-key='lib:pow']");
  if (!cell) return ["PF1 open: no Pow folder cell to tap"];
  cell.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, pointerId: 3, clientX: 1, clientY: 1 }));
  cell.dispatchEvent(new PointerEvent("pointerup", { bubbles: true, pointerId: 3, clientX: 1, clientY: 1 }));
  cell.click();
  await sleep(400);
  const view = document.querySelector(".drawer-page [data-view=folder]");
  if (!view) return [`PF1 open: tapping the folder didn't open it (letter ${D.launcherLetter.value})`];
  const fails = [];
  const got = cells(".drawer-page [data-view=folder]");
  if (JSON.stringify(got) !== JSON.stringify(want)) fails.push(`PF1 open: the folder shows ${got.join(", ")}, want ${want.join(", ")}`);
  if (view.querySelector(".launcher-chip-letter")?.textContent !== "Pow") fails.push("PF1 open: no \"Pow\" chip over the folder's apps");
  const marked = view.querySelectorAll(".app[data-key^='w:'] .app-web-mark").length;
  if (marked !== got.length) fails.push(`PF1 open: ${marked} of ${got.length} apps carry their kind mark`);
  return fails;
}

/** Search finds a .pow app itself. */
async function searched(S) {
  S.query.value = "scan";
  await sleep(900);
  const found = [...document.querySelectorAll(".drawer .scr-row[data-key]")].map((el) => el.dataset.key);
  S.query.value = "";
  await sleep(200);
  return found.includes("w:powscan.pow") ? [] : [`PF1 search "scan": PowScan not found (${found.join(", ") || "nothing"})`];
}

const ORDER = ["w:ararat.pow", "w:powscan.pow", "w:cdn.pow", "w:pihole.pow"];

/** The sync adds one and drops one: the open folder follows, with no reopening. */
async function live(S, D) {
  const fails = [];
  await setWeb([...WEB, web("traefik.pow", "Traefik", ["page", "infrastructure", "#444"])]);
  let got = cells(".drawer-page [data-view=folder]");
  if (!got.includes("w:traefik.pow")) fails.push(`PF1 sync add: the open folder didn't get Traefik (${got.join(", ")})`);
  else if (got[got.length - 1] !== "w:traefik.pow") fails.push(`PF1 sync add: Traefik (infrastructure) isn't last: ${got.join(", ")}`);
  await setWeb(WEB.filter((a) => a.key !== "w:cdn.pow"));
  got = cells(".drawer-page [data-view=folder]");
  if (got.includes("w:cdn.pow") || got.includes("w:traefik.pow")) fails.push(`PF1 sync remove: the folder still shows removed apps (${got.join(", ")})`);
  // All gone: powEmpty (the page keeps a kind it had for its first 20 s, state.ts withKept, so not here).
  await setWeb(WEB);
  return fails;
}

/** The dock: an old pin of a .pow app survives; the folder pins there, and its icon opens it. */
async function docked(S) {
  const fails = [];
  S.closeDrawer(true);
  await sleep(300);
  S.dock.value = ["w:pihole.pow", "lib:pow", ...S.dock.value.filter((k) => !k.startsWith("w:") && k !== "lib:pow").slice(0, 3)];
  await sleep(500);
  const dock = cells(".home .dock");
  if (!dock.includes("w:pihole.pow")) fails.push(`PF1 dock: the .pow app pinned before isn't drawn (${dock.join(", ")})`);
  if (!dock.includes("lib:pow")) fails.push(`PF1 dock: the Pow folder pinned isn't drawn (${dock.join(", ")})`);
  await S.launch("lib:pow");
  await sleep(700);
  if (S.folder.value !== "lib:pow") fails.push(`PF1 dock: the folder's icon opens ${S.folder.value}, not the Pow folder`);
  const shown = [...document.querySelectorAll(".folder-view.open .folder-grid .app[data-key]")].map((el) => el.dataset.key);
  if (JSON.stringify(shown) !== JSON.stringify(ORDER)) fails.push(`PF1 dock: the open folder shows ${shown.join(", ")}, want ${ORDER.join(", ")}`);
  S.folder.value = null;
  await sleep(500);
  return fails;
}

/** Pins the folder and a .pow app on home, each in a free cell; an error's words, or null. */
async function pin(P, G) {
  try {
    for (const key of ["lib:pow", "w:ararat.pow"]) {
      const spot = G.placeNewCells(1, 1);
      await P.addToHome(key, spot.page, spot.cell);
    }
    return null;
  } catch (e) {
    return `PF1 home: pinning failed: ${e.message}`;
  }
}

/** Home: the folder and a single .pow app pinned (powtiles.ts shell tiles) draw as app cells; the folder's opens it. */
async function homed(S) {
  const P = await importShim("./ui/powtiles.ts").catch(() => null);
  if (!P) return ["PF1 home: no shell tiles for the Pow folder and .pow apps (ui/powtiles.ts)"];
  const G = await importShim("./ui/grid.tsx");
  const fails = [];
  S.page.value = 0;
  await sleep(200);
  const pinned = await pin(P, G);
  if (pinned) return [pinned];
  await sleep(700);
  const folder = document.querySelector(".home-tile[data-key='panel:pow']");
  const app = document.querySelector(".home-tile[data-key='panel:w:ararat.pow']");
  if (!folder?.querySelector(".pow-face")) fails.push("PF1 home: the Pow folder pinned on home isn't drawn as its folder icon");
  if (!app?.querySelector(".app-web-mark")) fails.push("PF1 home: the .pow app pinned on home isn't drawn as its app cell");
  if (folder && folder.getBoundingClientRect().width > 200) fails.push(`PF1 home: the folder's tile is ${Math.round(folder.getBoundingClientRect().width)} px wide, not one cell`);
  for (const key of ["panel:pow", "panel:w:ararat.pow"]) await (await importShim("./bridge.ts")).powos.home.remove(key);
  await sleep(400);
  return fails;
}

/** Each check, for a dock [side] ("": the mode's own; "right"/"left": side-docked). */
export async function powFolder(side = "") {
  const S = await importShim("./state.ts");
  const D = await importShim("./ui/drawer.tsx");
  if (side) S.dockTry.value = side;
  await sleep(300);
  await setWeb(WEB);
  const fails = [...(await inList(S, D)), ...(await opens(S, D, ORDER)), ...(await live(S, D))];
  S.closeDrawer(true);
  await sleep(200);
  S.drawer.value = 1;
  await sleep(300);
  fails.push(...(await searched(S)), ...(await docked(S)), ...(await homed(S)));
  S.closeDrawer(true);
  return fails;
}

/**
 * The sync's last .pow app gone (and a device with none): the folder comes with the first and goes with the last - no
 * folder in the launcher or the library, a dock pin of it not drawn.
 */
export async function powEmpty() {
  const S = await importShim("./state.ts");
  const D = await importShim("./ui/drawer.tsx");
  const L = await importShim("./ui/library.tsx");
  const fails = [];
  await setWeb(WEB);
  await launcher(S, D, "All");
  if (!document.querySelector(".drawer-page .app[data-key='lib:pow']")) fails.push("PF1 empty: no Pow folder with .pow apps listed");
  // The page keeps a kind of app it had for its first 20 s (state.ts withKept: a host list still loading); a real sync
  // that drops the last .pow app comes later than that.
  localStorage.removeItem("powos.apps");
  await setWeb([]);
  S.dock.value = ["lib:pow", ...S.dock.value.filter((k) => k !== "lib:pow")];
  await launcher(S, D, "All");
  if (document.querySelector(".drawer .app[data-key='lib:pow']")) fails.push("PF1 empty: a Pow folder shows with no .pow apps");
  if (L.library.value.some((f) => f.key === "lib:pow")) fails.push("PF1 empty: the app library has an empty Pow folder");
  S.closeDrawer(true);
  await sleep(300);
  if (document.querySelector(".home .dock .app[data-key='lib:pow']")) fails.push("PF1 empty: the dock draws the Pow folder with no .pow apps");
  return fails;
}
