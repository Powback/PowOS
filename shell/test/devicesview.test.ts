// The AI page's Devices tab, pure (shell/ui/devicesview.ts): node --test shell/test/devicesview.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { appName, devicesView, howOf, kindIcon, missingApps, missingNote, presence, syncLine, whatIs, withDevice, type AccountDevice } from "../ui/devicesview.ts";

const now = 2_000_000_000;
const list: AccountDevice[] = [
  { id: "desk", name: "Desk", kind: "desktop", last_seen: now - 3 * 86400, sync: { at: now - 3 * 86400, ok: true, missing_n: 3, missing: ["a", "b", "c"] } },
  { id: "old", name: "Old phone", kind: "phone", revoked: now - 86400, last_seen: now - 9 * 86400 },
  { id: "s25", name: "S25", kind: "phone", model: "SM-S931B", last_seen: now - 20, sync: { at: now - 130, ok: true } },
  { id: "fold", name: "Razr Fold", kind: "phone", self: true, last_seen: now - 400, sync: { at: now - 30, ok: true } },
  { id: "tv", name: "TV", kind: "tv" },
];

test("this device first, then online, then most recently seen; removed apart", () => {
  const v = devicesView(list, now);
  assert.deepEqual(v.signedIn.map((d) => d.id), ["fold", "s25", "desk", "tv"]);
  assert.deepEqual(v.removed.map((d) => d.id), ["old"]);
  assert.equal(v.online, 2);
});

test("presence and sync in plain words", () => {
  const [fold, s25, desk, tv] = devicesView(list, now).signedIn;
  assert.equal(presence(fold, now), "online"); // this device is asking: online whatever its row says
  assert.equal(presence(s25, now), "online");
  assert.equal(presence(desk, now), "seen 3 days ago");
  assert.equal(presence(tv, now), "not seen yet");
  assert.equal(syncLine(s25, now), "synced 2 min ago");
  assert.equal(syncLine(desk, now), "3 apps missing");
  assert.equal(syncLine(tv, now), "");
  assert.equal(syncLine({ id: "x", sync: { offline: true, why: "away" } }, now), "sync waits for home");
});

test("kind icons, what it is, an edit leaves the rest", () => {
  assert.deepEqual(["phone", "desktop", "server", "tv", ""].map(kindIcon), ["cellphone", "monitor", "server", "television", "monitor"]);
  assert.equal(whatIs(list[2]), "SM-S931B");
  assert.equal(whatIs(list[0]), "desktop");
  const out = withDevice(list, "s25", (d) => ({ ...d, name: "Mine" }));
  assert.equal(out[2].name, "Mine");
  assert.equal(list[2].name, "S25");
  assert.equal(out[0], list[0]);
});

test("missing apps: named from this device's apps, else from the id; sorted; how each gets there", () => {
  const d: AccountDevice = { id: "s", name: "S25", sync: { missing: ["local.oslo-temp", "dev.powos.agents", "w:cdn.pow", "local.shop"], missing_n: 70 } };
  const { apps, more } = missingApps(d, { "local.shop": { name: "Shopping", icon: "x.svg" } });
  assert.deepEqual(apps.map((a) => [a.name, a.how, a.icon]), [
    ["Agents", "powos", ""],
    ["Cdn pow", "web", ""],
    ["Oslo temp", "folder", ""],
    ["Shopping", "folder", "x.svg"],
  ]);
  assert.equal(more, 66);
  assert.equal(appName("local.hue-rooms-on"), "Hue rooms on");
  assert.equal(howOf("dev.powos.registry"), "powos");
  assert.match(missingNote(apps[3], "S25"), /powos app install .* on S25/);
  assert.deepEqual(missingApps({ id: "x" }, {}), { apps: [], more: 0 });
});
