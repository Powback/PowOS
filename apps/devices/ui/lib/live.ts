/**
 * Devices' live side: every paired device's status, polled while the page is shown (5 s), and its actions - the
 * expected result shown the moment one is tapped (Pending.expect laid over the last status), kept when the device
 * did it, rolled back with the device's own words when it refused.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { act, DeviceError, expected, status as fetchStatus, waker, type Cap, type Device, type Net, type Status } from "./devices";

export type Live = { s?: Status; err?: string; auth?: boolean; at: number };
export type Pending = { action: Cap; expect: Partial<Status>; error?: string; busy?: string[] };

const POLL_MS = 5000;
const OFF: Status = { online: false, screen: null, locked: null };

const statuses = (live: Record<string, Live>) => Object.fromEntries(Object.entries(live).map(([k, v]) => [k, v.s]));
export const canWake = (d: Device, list: Device[], live: Record<string, Live>) => !!waker(d, list, statuses(live));

/** One device's status, or the reason it has none (offline, or it no longer knows this device). */
async function poll1(net: Net | undefined, d: Device, prev?: Live): Promise<Live> {
  try {
    return { s: await fetchStatus(net, d), at: Date.now() };
  } catch (e) {
    const auth = e instanceof DeviceError && e.code === "auth";
    return { s: { ...(prev?.s ?? OFF), online: false }, err: (e as Error).message, auth, at: Date.now() };
  }
}

/** The NIC another device can wake [d] on, from its status (Wake-on-LAN armed and up), if it changed. */
function wakeMacOf(d: Device, l: Live): string | null {
  const nic = l.s?.nics?.find((n) => n.wol && n.up);
  return nic && nic.mac !== d.wakeMac ? nic.mac : null;
}

/**
 * The device's caps from its last status, when they differ from the ones kept: what it can do changes while it's paired
 * (a phone's owner allows or turns off its lock), and the buttons follow the device's own word.
 */
function capsChanged(d: Device, l: Live): Cap[] | null {
  const caps = (l.s as { caps?: Cap[] } | undefined)?.caps;
  if (!Array.isArray(caps) || !l.s?.online) return null;
  return caps.length === d.caps.length && caps.every((c) => d.caps.includes(c)) ? null : caps;
}

export function useLive(net: Net | undefined, list: Device[], update: (next: Device[]) => void) {
  const [live, setLive] = useState<Record<string, Live>>({});
  const ref = useRef({ list, live });
  ref.current = { list, live };
  useEffect(() => {
    let stop = false;
    const poll = () =>
      ref.current.list.forEach(async (d) => {
        const l = await poll1(net, d, ref.current.live[d.id]);
        if (stop) return;
        setLive((all) => ({ ...all, [d.id]: l }));
        const mac = wakeMacOf(d, l);
        const caps = capsChanged(d, l);
        if (mac || caps) update(ref.current.list.map((x) => (x.id === d.id ? { ...x, ...(mac && { wakeMac: mac }), ...(caps && { caps }) } : x)));
      });
    poll();
    const t = setInterval(() => !document.hidden && poll(), POLL_MS);
    return () => {
      stop = true;
      clearInterval(t);
    };
  }, [net, list.length]);
  // A finished action's result is the truth until the next poll says otherwise.
  const settle = (id: string, expect: Partial<Status>) =>
    setLive((all) => (all[id]?.s ? { ...all, [id]: { ...all[id], s: { ...all[id].s!, ...expect } } } : all));
  return { live, settle };
}

/** "busy: a, b would stop - sleep refused" -> ["a", "b"]. */
const busyOf = (e: DeviceError) => (e.code === "busy" ? e.message.replace(/^busy: /, "").replace(/ would stop.*$/, "").split(", ") : undefined);

export function useActions(net: Net | undefined, list: Device[], { live, settle }: ReturnType<typeof useLive>) {
  const [pending, setPending] = useState<Record<string, Pending>>({});
  const dismiss = (id: string) => setPending(({ [id]: _, ...rest }) => rest);
  const send = (d: Device, action: Cap, force: boolean) => {
    if (action !== "wake") return act(net, d, action, { force });
    const by = waker(d, list, statuses(live));
    if (!by) throw new DeviceError("no device that's on can wake it", "unsupported", 0);
    return act(net, by, "wake", { args: { mac: d.wakeMac! } });
  };
  const run = async (d: Device, action: Cap, force = false) => {
    const expect = expected(live[d.id]?.s, action);
    setPending((p) => ({ ...p, [d.id]: { action, expect } }));
    try {
      await send(d, action, force);
      settle(d.id, expect);
      dismiss(d.id);
    } catch (e) {
      const err = e as DeviceError;
      setPending((p) => ({ ...p, [d.id]: { action, expect, error: err.message, busy: busyOf(err) } }));
    }
  };
  return { pending, run, dismiss };
}
