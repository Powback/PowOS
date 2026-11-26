// The AI page's Devices tab, signed-in devices (ui/aidevices.tsx; gate.mjs ai-devices-*; the user, 11-25: "The devices
// page should show the paired devices which are signed in"), against a mock realm (devices.realm, PowStation.kt's
// answers): this device first with its badge and a rename, another phone online, an offline desktop with apps missing,
// a removed one folded under Removed; Remove only for an approver, never on this device, with a confirm; rename and
// remove show at once and roll back with why when the realm refuses. Imported with importShim.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** The mock account (seconds), and a realm that answers it; [refuse]: rename/revoke reject. */
function mockRealm(approver) {
  const now = Math.floor(Date.now() / 1000);
  const list = [
    { id: "desk", name: "Desk", kind: "desktop", platform: "bazzite", last_seen: now - 2 * 86400, sync: { at: now - 2 * 86400, ok: true, missing_n: 3, missing: ["local.tally", "dev.powos.registry", "local.hello-web"] } },
    { id: "old", name: "OnePlus Open", kind: "phone", revoked: now - 5 * 86400, last_seen: now - 6 * 86400 },
    { id: "s25", name: "Galaxy S25", kind: "phone", model: "SM-S931B", last_seen: now - 40, sync: { at: now - 40, ok: true, missing_n: 0 } },
    { id: "fold", name: "Razr Fold", kind: "phone", model: "XT2651-1", self: true, last_seen: now - 5, sync: { at: now - 120, ok: true, missing_n: 0 } },
  ];
  const m = { refuse: false, calls: [] };
  m.realm = async (op, body) => {
    m.calls.push([op, body]);
    if (op === "state") return { enrolled: true, approver, id: "fold" };
    if (op === "devices") return { devices: list.map((d) => ({ ...d })) };
    await sleep(150);
    if (m.refuse) throw new Error("the hub (powstation.pow) isn't reachable");
    return op === "rename" ? { device: { ...list[3], name: body.name } } : { revoked: true };
  };
  return m;
}

const rows = () => [...document.querySelectorAll(".dv-account .dv-row[data-device]")];
const rowOf = (id) => document.querySelector(`.dv-account .dv-row[data-device="${id}"]`);
const text = (el) => (el?.textContent ?? "").replace(/\s+/g, " ").trim();

/** Open the Devices tab on [m]'s realm; the list read once. */
async function open(m) {
  const S = await importShim("./state.ts");
  const B = (await importShim("./bridge.ts")).powos;
  const D = await importShim("./ui/aidevices.tsx");
  B.devices = { ...(B.devices || {}), realm: m.realm };
  D.account.value = { state: "loading", list: [], approver: false, at: 0 };
  S.aiScreen.value = "chat";
  S.page.value = -1;
  await sleep(400);
  S.aiScreen.value = "devices";
  for (let i = 0; i < 30 && !rows().length; i++) await sleep(100);
  return S;
}

const presenceOf = (id) => text(rowOf(id)?.querySelector("[data-presence]"));
const syncOf = (id) => text(rowOf(id)?.querySelector("[data-sync]"));
const removedFold = () => text(document.querySelector("[data-removed-fold]"));
const errorShown = () => text(document.querySelector("[data-devices-error]"));

/** The list as an approver sees it: order, badge, presence, sync, Removed folded, Remove where it may be, the glance. */
function listFails() {
  const ids = rows().map((r) => r.dataset.device);
  const glance = text(document.querySelector(".ai-tab-head .fl-head"));
  const checks = [
    [JSON.stringify(ids) === JSON.stringify(["fold", "s25", "desk"]), `signed-in rows ${JSON.stringify(ids)}, want fold, s25, desk`],
    [rows().every((r) => r.getBoundingClientRect().height > 20), "a device row has no height"],
    [rows().filter((r) => r.querySelector(".dv-this")).map((r) => r.dataset.device).join() === "fold", "This device: not on exactly the self row"],
    [presenceOf("fold") === "online", `this device's presence "${presenceOf("fold")}"`],
    [presenceOf("s25") === "online", `the other phone (40 s ago): "${presenceOf("s25")}"`],
    [presenceOf("desk") === "seen 2 days ago", `the desktop's presence "${presenceOf("desk")}"`],
    [syncOf("desk") === "3 apps missing", `the desktop's sync "${syncOf("desk")}"`],
    [/^synced \d+ min ago$/.test(syncOf("fold")), `this device's sync "${syncOf("fold")}"`],
    [!rowOf("old") && /Removed · 1/.test(removedFold()), `the removed device: not alone under a folded Removed · 1 ("${removedFold()}")`],
    [!rowOf("fold")?.querySelector("[data-remove]") && !!rowOf("desk")?.querySelector("[data-remove]"), "Remove: on this device, or missing on another (approver)"],
    [glance === "3 signed in · 2 online", `the header's glance "${glance}"`],
  ];
  return checks.filter(([ok]) => !ok).map(([, why]) => why);
}

/** The desktop's "3 apps missing" opens into the three by name, each saying how it gets there (the user, 11-26). */
async function missingFails() {
  const toggle = rowOf("desk")?.querySelector("[data-missing-toggle]");
  if (!toggle) return ["the desktop's apps missing: no toggle to open which ones"];
  toggle.click();
  await sleep(500);
  const apps = [...rowOf("desk").querySelectorAll("[data-missing-app]")];
  const names = apps.map((a) => text(a.querySelector("[data-missing-name]"))).join("|");
  const list = rowOf("desk").querySelector("[data-missing-list]")?.getBoundingClientRect();
  const fails = [
    [names === "Hello web|Registry|Tally", `missing apps by name: "${names}"`],
    [!!list && list.height > 60 && list.right <= innerWidth, "the opened list has no height or runs off the page"],
    [apps.every((a) => text(a).length > a.querySelector("[data-missing-name]").textContent.length + 8), "a missing app doesn't say how it gets there"],
  ].filter(([ok]) => !ok).map(([, why]) => why);
  toggle.click();
  await sleep(400);
  return fails;
}

/** Rename this device to "Pocket": shown at once; [refuse]: the old name back with why, else kept. */
async function renameFails(m, refuse) {
  m.refuse = refuse;
  rowOf("fold").querySelector(".dv-edit").click();
  await sleep(100);
  const input = rowOf("fold")?.querySelector(".dv-rename input");
  if (!input) return ["rename: no field after the pencil"];
  input.value = "Pocket";
  input.dispatchEvent(new Event("input", { bubbles: true }));
  await sleep(30);
  input.form.requestSubmit();
  await sleep(40);
  const at = text(rowOf("fold")?.querySelector(".ag-row-title"));
  await sleep(400);
  const after = text(rowOf("fold")?.querySelector(".ag-row-title"));
  return [...(at === "Pocket" ? [] : [`rename: "${at}" right after, not the new name at once`]), ...renamed(refuse, after)];
}

/** After a rename settled: refused, the old name back with why; kept, the new one without. */
function renamed(refuse, after) {
  const ok = refuse ? after === "Razr Fold" && /Couldn't rename/.test(errorShown()) : after === "Pocket" && !errorShown();
  return ok ? [] : [`rename ${refuse ? "refused" : "kept"}: shows "${after}" ("${errorShown()}")`];
}

/** Remove the desktop: a confirm first, then under Removed at once; [refuse]: back with why, else revoked through the realm. */
async function removeFails(m, refuse) {
  m.refuse = refuse;
  const ask = rowOf("desk")?.querySelector("[data-remove]");
  if (!ask) return ["Remove: not offered on the desktop"];
  ask.click();
  await sleep(100);
  const sure = rowOf("desk")?.querySelector("[data-remove-sure]");
  if (!sure) return ["Remove: no confirm in the row (or it removed at once)"];
  sure.click();
  await sleep(40);
  const moved = !rowOf("desk") && /Removed · 2/.test(removedFold());
  await sleep(400);
  return [...(moved ? [] : [`remove: not under Removed at once ("${removedFold()}")`]), ...removed(m, refuse)];
}

/** After a remove settled: refused, back among the signed in with why; kept, revoked through the realm. */
function removed(m, refuse) {
  const revoked = m.calls.some(([op, b]) => op === "revoke" && b?.id === "desk");
  const ok = refuse ? !!rowOf("desk") && /Couldn't remove Desk/.test(errorShown()) : !rowOf("desk") && revoked;
  return ok ? [] : [`remove ${refuse ? "refused: not back with a reason" : "kept: not revoked through the realm"} ("${errorShown()}")`];
}

/** The list, then rename and remove (each once refused, once kept), then a non-approver's list (no Remove). */
export async function aiDevicesCheck() {
  const m = mockRealm(true);
  const S = await open(m);
  const fails = listFails();
  fails.push(...(await missingFails()));
  for (const refuse of [true, false]) fails.push(...(await renameFails(m, refuse)));
  for (const refuse of [true, false]) fails.push(...(await removeFails(m, refuse)));
  await open(mockRealm(false));
  if (rows().length !== 3 || document.querySelector(".dv-account [data-remove]")) fails.push("a non-approver is offered Remove (or sees no list)");
  S.aiScreen.value = "chat";
  return fails;
}
