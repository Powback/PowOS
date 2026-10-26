// Node 22.18+ (native TypeScript stripping); no compositor or Android device needed.
import assert from "node:assert/strict";
import { test } from "node:test";
import { desktop } from "../hosts/desktop.ts";

function fixture() {
  const events = new Map();
  const writes = [];
  const launches = [];
  const pending = new Map();
  globalThis.innerWidth = 1280;
  globalThis.addEventListener = (name, handler) => events.set(name, handler);
  const host = desktop({
    store: {
      get: (name) => new Promise((resolve) => pending.set(name, resolve)),
      set: async (name, value) => writes.push([name, structuredClone(value)]),
    },
    apps: { list: async () => [], launch: async (key) => launches.push(key) },
    widgets: {},
    on: () => () => {},
  });
  const saved = {
    columns: 13, pages: [1],
    items: [{ key: "panel:agents", kind: "panel", name: "agents", page: 1,
      cell: { x: 9, y: 0, w: 3, h: 2 }, size: [3, 2], minSize: [2, 1], resizable: true }],
  };
  return {
    host, writes, launches,
    resize: (width) => { globalThis.innerWidth = width; return events.get("resize")(); },
    load: () => {
      pending.get("desktop-home")(structuredClone(saved));
      pending.get("desktop-recent")(["l:org.kde.dolphin"]);
    },
  };
}

test("resize during startup cannot replace the saved desktop with an empty one", async () => {
  const f = fixture();
  const resizing = f.resize(800);
  assert.deepEqual(f.writes, []);
  f.load();
  await resizing;
  const home = await f.host.home.get();
  assert.equal(home.columns, 8);
  assert.equal(home.items[0].key, "panel:agents");
  assert.equal(home.items[0].cell, null);
  await f.resize(600);
  assert.equal(f.writes.at(-1)[1].items[0].key, "panel:agents");
  assert.equal(f.writes.at(-1)[1].columns, 6);
});

test("launch during startup preserves existing recent apps", async () => {
  const f = fixture();
  const launching = f.host.apps.launch("l:org.kde.kate");
  await Promise.resolve();
  assert.deepEqual(f.writes, []);
  f.load();
  await launching;
  assert.deepEqual(f.launches, ["l:org.kde.kate"]);
  const expected = ["l:org.kde.kate", "l:org.kde.dolphin"];
  assert.deepEqual(await f.host.usage.recent(10), expected);
  assert.deepEqual(f.writes.at(-1), ["desktop-recent", expected]);
});
