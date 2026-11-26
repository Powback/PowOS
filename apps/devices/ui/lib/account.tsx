/**
 * The owner's devices signed in to the Pow account, the same list the AI page's Devices tab shows (the user, 11-26:
 * the tab said "3 signed in" while this app said "No devices yet"): the realm's GET /v1/devices through this device's
 * own enrollment (host.thisDevice.realm "devices" - PowStation.kt on a phone; the token never reaches the page), read
 * when the page opens and every 30 s while it shows. A paired device (lib/devices.ts, its controls) draws its own card;
 * every other signed-in device gets a card here with its presence, its account sync and which apps it misses
 * (@powos/shared/missingapps). The pure parts are @powos/shared/devicesview, the tab's own.
 */
import { useEffect, useState } from "preact/hooks";
import { devicesView, presence, syncLine, whatIs, type AccountDevice } from "@powos/shared/devicesview";
import { MissingApps } from "@powos/shared/missingapps";
import type { ThisDevice } from "./devices";
import { S } from "./ui";

const READ_MS = 30_000;

/** The signed-in devices (revoked ones left out), [] while unknown or on a device that can't ask. */
export function useAccount(td?: ThisDevice): AccountDevice[] {
  const [list, setList] = useState<AccountDevice[]>([]);
  useEffect(() => {
    if (!td?.realm) return;
    let on = true;
    const read = async () => {
      try {
        const st = await td.realm!("state");
        if (!st?.enrolled) return on && setList([]);
        const r = await td.realm!("devices");
        if (on && Array.isArray(r?.devices)) setList(devicesView(r.devices, Date.now() / 1000).signedIn);
      } catch {
        // The hub not reachable: the last list stays.
      }
    };
    void read();
    const t = setInterval(() => !document.hidden && void read(), READ_MS);
    return () => ((on = false), clearInterval(t));
  }, [td]);
  return list;
}

/** A signed-in device this app hasn't paired: who it is, online or when seen, its sync and the apps it misses. */
export function AccountCard({ d, td }: { d: AccountDevice; td?: ThisDevice }) {
  const now = Math.floor(Date.now() / 1000);
  const on = presence(d, now) === "online";
  const sync = syncLine(d, now);
  const missing = /missing/.test(sync);
  const line = [whatIs(d), presence(d, now), !missing && sync].filter(Boolean).join(" · ");
  return (
    <div style={S.card} data-account-device={d.id}>
      <div style={S.row}>
        <span style={{ ...S.dot, background: on ? "var(--status-working)" : "var(--color-muted)" }} aria-hidden="true" />
        <div style={S.grow}>
          <div style={S.name}>
            {d.name || d.id}
            {d.self ? " · This device" : ""}
          </div>
          <div style={S.muted} data-device-line>
            {line}
          </div>
          {missing && <MissingApps d={d} known={td?.known?.() ?? {}} label={sync} />}
        </div>
      </div>
    </div>
  );
}
