/** The mock host's status bar icons (bridge.ts mock system.status): a typical phone; `?status=all` lights every icon. */
import type { SystemStatus } from "./types.ts";

const cell = { roaming: false, activity: null, carrier: "Telia", service: "in", sim: "ready" } as const;

/** One SIM on 5G, Wi-Fi, nothing else on: what most of the gate's shots show. */
export const typicalStatus: SystemStatus = {
  cells: [{ ...cell, slot: 0, bars: 3, type: "5G", data: true }],
  airplane: false, wifi: 4, wifiInternet: true, hotspot: false, bluetooth: "off", bluetoothBattery: null, nfc: false,
  location: false, dnd: false, ringer: "normal", alarm: null, dataSaver: false, batterySaver: false, cast: false,
  limited: false, notifications: [],
};

const glyph = (letter: string) =>
  "data:image/svg+xml," + encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M4 4h16v16H4z" fill="none" stroke="black" stroke-width="2"/><text x="12" y="17" font-family="sans-serif" font-size="12" font-weight="700" fill="black" text-anchor="middle">${letter}</text></svg>`);

/** (A notification's small icon is an alpha mask: the mock's are outlined letters, never a solid disc.) */
/** Every icon the stock bar can show at once: two SIMs (one roaming), every toggle, a headset's battery, 5 apps' icons. */
export const allStatus: SystemStatus = {
  cells: [
    { ...cell, slot: 0, bars: 4, type: "5G", data: true, activity: "inout" },
    { ...cell, slot: 1, bars: 2, type: null, data: false, roaming: true, carrier: "Roam" },
  ],
  airplane: false, wifi: 3, wifiInternet: true, hotspot: true, bluetooth: "connected", bluetoothBattery: 70, nfc: true,
  location: true, dnd: true, ringer: "vibrate", alarm: Date.now() + 8 * 3600_000, dataSaver: true, batterySaver: true,
  cast: true, limited: false,
  notifications: ["M", "S", "W", "G", "T"].map((l, i) => ({ key: `k${i}`, pkg: `app.${l}`, url: glyph(l) })),
};

export function mockStatus(): SystemStatus {
  return new URLSearchParams(location.search).get("status") === "all" ? allStatus : typicalStatus;
}
