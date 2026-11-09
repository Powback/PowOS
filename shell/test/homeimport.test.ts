// Home + dock import from another device (shell/homeimport.ts): node --test shell/test/homeimport.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { importLayout, mapKey, plan, type LayoutExport } from "../homeimport.ts";
import type { App, Cell, Home, HomeItem } from "../types.ts";

const app = (key: string, extra: Partial<App> = {}): App => ({ key, label: key, icon: "", kind: key.startsWith("a:") ? "android" : "powos", ...extra }) as App;
const cell = (x: number, y: number): Cell => ({ x, y, w: 1, h: 1 });
const item = (o: Partial<HomeItem>): HomeItem => ({ key: "k", kind: "app", page: 1, cell: null, resizable: false, minSize: [1, 1], size: null, ...o }) as HomeItem;

// The razr's apps: the same Android apps under other activities, a work copy, no Slack.
const here = [
  app("a:org.mozilla.firefox/.App"),
  app("a:com.spotify.music/.Main@10", { work: true }),
  app("a:com.spotify.music/.Main"),
  app("a:com.whatsapp/.Home"),
  app("p:local.devices"),
];
const src: LayoutExport = {
  v: 1,
  at: 1,
  dock: ["a:org.mozilla.firefox/.Browser", "a:com.slack/.Main", "p:local.devices", "a:com.spotify.music/.Main"],
  home: {
    pages: [1, 2],
    items: [
      item({ key: "app:1", app: "a:com.whatsapp/.Main", label: "WhatsApp", page: 1, cell: cell(0, 3) }),
      item({ key: "app:2", app: "a:com.slack/.Main", label: "Slack", page: 2, cell: cell(1, 1) }),
      item({
        key: "folder:1",
        kind: "folder",
        page: 2,
        cell: cell(2, 2),
        apps: [
          { key: "x", label: "Firefox", app: "a:org.mozilla.firefox/.Browser" },
          { key: "y", label: "Spotify", app: "a:com.spotify.music/.Main" },
          { key: "z", label: "Slack", app: "a:com.slack/.Main" },
        ],
      }),
      item({ key: "panel:search", kind: "panel", name: "search", page: 1, cell: { x: 0, y: 5, w: 4, h: 1 } }),
      item({ key: "w:1", kind: "widget", name: "clock", page: 1, cell: cell(0, 0) }),
    ],
  },
};

test("maps by package, the main profile first", () => {
  assert.equal(mapKey("a:org.mozilla.firefox/.Browser", here), "a:org.mozilla.firefox/.App");
  assert.equal(mapKey("a:com.spotify.music/.Other", here), "a:com.spotify.music/.Main");
  assert.equal(mapKey("p:local.devices", here), "p:local.devices");
  assert.equal(mapKey("a:com.slack/.Main", here), null);
  assert.equal(mapKey("p:local.gone", here), null);
});

test("the plan: the other's dock first, this one's own pins kept, missing apps skipped", () => {
  const p = plan(src, here, { dock: ["a:com.whatsapp/.Home", "a:org.mozilla.firefox/.App"], home: { items: [] } });
  assert.deepEqual(p.dock, ["a:org.mozilla.firefox/.App", "p:local.devices", "a:com.spotify.music/.Main", "a:com.whatsapp/.Home"]);
  assert.deepEqual(p.apps, [{ app: "a:com.whatsapp/.Home", page: 1, cell: cell(0, 3) }]);
  assert.deepEqual(p.folders, [{ apps: ["a:org.mozilla.firefox/.App", "a:com.spotify.music/.Main"], page: 2, cell: cell(2, 2) }]);
  assert.deepEqual(p.panels, [{ name: "search", page: 1, cell: { x: 0, y: 5, w: 4, h: 1 } }]);
  assert.ok(p.skipped.includes("Slack"));
});

test("nothing already on this home is pinned twice", () => {
  const items = [item({ app: "a:com.whatsapp/.Home" }), item({ kind: "panel", name: "search" })];
  const p = plan(src, here, { dock: [], home: { items } });
  assert.deepEqual(p.apps, []);
  assert.deepEqual(p.panels, []);
});

test("importLayout applies the plan through the host, a failed item doesn't stop the rest", async () => {
  const calls: string[] = [];
  let n = 0;
  const res = await importLayout(src, {
    apps: async () => here,
    dock: async () => [],
    home: async () => ({ columns: 6, pages: [1], items: [] }) as Home,
    setDock: async (k) => void calls.push(`dock ${k.join(",")}`),
    add: async (a, page) => {
      calls.push(`add ${a} ${page}`);
      if (a.includes("whatsapp")) throw new Error("boom");
      return `app:${++n}`;
    },
    group: async (k, t) => (calls.push(`group ${k} ${t}`), "folder:9"),
    addPanel: async (name) => (calls.push(`panel ${name}`), `panel:${name}`),
  });
  assert.equal(res.dock, 3);
  assert.equal(res.home, 1);
  assert.ok(calls.includes("group app:2 app:1"));
  assert.ok(calls.includes("panel search"));
  await assert.rejects(importLayout({ v: 2 } as unknown as LayoutExport, {} as never));
});
