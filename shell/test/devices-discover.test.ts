// The Devices app's discovery (apps/devices/ui/lib/devices.ts discover): mDNS on the LAN plus the realm's registry, which
// is what lists the owner's devices over the WireGuard VPN (mDNS is link-local). node --test shell/test/devices-discover.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { discover, realmAgentOf, type Device, type Enrolled, type Net, type Status } from "../../apps/devices/ui/lib/devices.ts";

const mdnsNet = (rows: { name: string; host: string; port: number; txt: Record<string, string> }[] | Error): Net => ({
  fetch: async () => ({ status: 500, json: () => ({}) as any }),
  mdns: async () => {
    if (rows instanceof Error) throw rows;
    return rows;
  },
});
const desk = { name: "desk", host: "192.168.50.58", port: 3416, txt: { id: "d58", dev: "3416", kind: "desktop" } };
const reg: Enrolled[] = [
  { id: "d58", name: "desk", kind: "desktop", agent: "https://192.168.50.58:3416" },
  { id: "razr", name: "razr", kind: "phone", agent: "https://192.168.50.18:3416" },
  { id: "gone", name: "old", agent: "https://192.168.50.9:3416", revoked: 1794000000 },
  { id: "noaddr", name: "no agent", agent: "" },
  { id: "evil", name: "path", agent: "https://x:1/../steal" },
  { id: "mine", name: "paired one", agent: "https://192.168.50.20:3416" },
];
const paired: Device[] = [{ id: "mine", name: "paired one", kind: "desktop", url: "https://192.168.50.20:3416", caps: [] }];

test("over the VPN (no mDNS answer) the realm's registry still lists the owner's devices", async () => {
  const f = await discover(mdnsNet([]), paired, async () => reg);
  assert.deepEqual(f.map((x) => [x.id, x.url, x.via]), [
    ["d58", "https://192.168.50.58:3416", "realm"],
    ["razr", "https://192.168.50.18:3416", "realm"],
  ]);
});

test("mDNS wins for the same device, and a failing source leaves the other", async () => {
  const both = await discover(mdnsNet([desk]), [], async () => reg);
  assert.equal(both.filter((x) => x.id === "d58").length, 1);
  assert.equal(both.find((x) => x.id === "d58")!.via, "mdns");
  const regDown = await discover(mdnsNet([desk]), [], async () => { throw new Error("realm unreachable"); });
  assert.deepEqual(regDown.map((x) => x.id), ["d58"]);
  const mdnsDown = await discover(mdnsNet(new Error("no multicast")), [], async () => reg);
  assert.deepEqual(mdnsDown.map((x) => x.id), ["d58", "razr", "mine"]);
});

test("no registry and no mdns: nothing, never a throw", async () => {
  assert.deepEqual(await discover(undefined, []), []);
  assert.deepEqual(await discover({ fetch: async () => ({ status: 200, json: () => ({}) as any }) }, []), []);
});

test("the registry is read through this device's own enrolled agent, approver or not", () => {
  const list: Device[] = [
    { id: "far", name: "far", kind: "desktop", url: "https://a:3416", caps: [] },
    { id: "here", name: "here", kind: "desktop", url: "https://b:3416", caps: [] },
  ];
  const live: Record<string, Status> = {
    far: { online: true, screen: "on", locked: false, realm: { enrolled: true, approver: true, here: false } },
    here: { online: true, screen: "on", locked: false, realm: { enrolled: true, approver: false, here: true } },
  };
  assert.equal(realmAgentOf(list, live)?.id, "here");
  assert.equal(realmAgentOf(list, { ...live, here: { ...live.here, realm: { enrolled: false, approver: false, here: true } } }), null);
});
