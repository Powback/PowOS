/**
 * Devices' client: every PowOS device's own agent (lib/devices/powos-deviced, protocol v1 there), reached through
 * host.net - HTTPS on the LAN/VPN with the device's self-signed certificate pinned on first use (ShellNet), and this
 * device's token for it kept by host.net as the secret `dev-<id>` (captured from the pairing answer, put into each
 * call as `${secret:dev-<id>}`): the page never sees a token.
 *
 * Which devices: the ones paired from here (remembered in this app's storage: id, name, address, what it can do -
 * no secret), and the ones on this network that say they're PowOS (mDNS _powos._tcp with a dev=<port>) not yet
 * paired. docs/research/device-ecosystem.md D3: the paired list moves to the fleet's registry with enrollment.
 */
export interface Net {
  fetch(app: string, url: string, init?: { method?: string; headers?: Record<string, string>; body?: string | object; capture?: { secret: string; path: string } }): Promise<{
    status: number;
    json<T = any>(): T;
  }>;
  mdns?(app: string, type: string, ms?: number): Promise<{ name: string; host: string; port: number; txt: Record<string, string> }[]>;
  forget?(app: string, what: { host?: string; secret?: string }): Promise<void>;
}
/** This phone's lock from other devices without root (the shell's apps/thisdevice.ts); calls reject on an older APK. */
export interface LockAccess { available: boolean; rooted: boolean; allowed: boolean }
export interface ThisDevice {
  lock(): Promise<LockAccess>;
  allowLock(): Promise<LockAccess>;
  stopLock(): Promise<LockAccess>;
  onLock(on: (s: LockAccess) => void): () => void;
  /** Another device's home + dock (its "layout" answer) onto this one (the shell's homeimport.ts); missing on older shells. */
  importHome?(layout: unknown): Promise<{ dock: number; home: number; skipped: string[] }>;
}
export interface Host {
  net?: Net;
  thisDevice?: ThisDevice;
}

export const APP = "local.devices";
export type Cap = "status" | "lock" | "unlock" | "screen_off" | "screen_on" | "sleep" | "wake" | "ring" | "layout";

export interface Device {
  id: string;
  name: string;
  kind: string;
  url: string;
  caps: Cap[];
  /** The NIC another device can wake it on (from its last status: an armed Wake-on-LAN). */
  wakeMac?: string;
}
export interface Nic { if: string; mac: string; up: boolean; wol: boolean | null }
export interface Status {
  online: boolean;
  at?: number;
  power?: { source: "ac" | "battery"; battery: number | null; charging: boolean; accessories?: { name: string; battery: number | null }[] };
  screen: "on" | "off" | null;
  locked: boolean | null;
  busy?: string[];
  nics?: Nic[];
  /** This device's enrollment in the realm as its agent says it (no token): an approver, and whether this app runs on it. */
  realm?: Realm;
}
export interface Realm { enrolled: boolean; approver: boolean; here: boolean }
/** A device waiting to join the realm (its agent's /v1/enroll/pending): the code its own screen shows. */
export interface Waiting {
  user_code: string;
  device: { id: string; name: string; kind?: string; platform?: string };
  from?: string;
  expires_in: number;
  /** Already paired with the approving device: a paired-only device upgrading to enrolled. */
  paired?: boolean;
}
export interface Enrolled { id: string; name: string; revoked?: number | null }
export interface Found { name: string; url: string; id: string; kind: string }

const KEY = "powos.devices.v1";
const SELF = "powos.devices.self";

export function load(): Device[] {
  try {
    const v = JSON.parse(localStorage.getItem(KEY) ?? "[]");
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}
export function save(list: Device[]) {
  try {
    localStorage.setItem(KEY, JSON.stringify(list));
  } catch {
    /* not kept: paired again next time */
  }
}

/** This device as the others know it: a random id made once, and a name the user can read on the other screen. */
export function self(): { id: string; name: string; kind: string } {
  let id = "";
  try {
    id = localStorage.getItem(SELF) ?? "";
    if (!id) {
      id = Array.from(crypto.getRandomValues(new Uint8Array(8)), (b) => b.toString(16).padStart(2, "0")).join("");
      localStorage.setItem(SELF, id);
    }
  } catch {
    id ||= "anon" + Math.floor(Math.random() * 1e9);
  }
  const phone = matchMedia("(pointer: coarse)").matches;
  return { id, name: phone ? "PowOS phone" : "PowOS desktop", kind: phone ? "phone" : "desktop" };
}

export const secretOf = (id: string) => `dev-${id}`;
const auth = (id: string) => ({ Authorization: `Bearer \${secret:${secretOf(id)}}` });

/** An error with the device's own words ("busy: llama-swap.service would stop") and its code. */
export class DeviceError extends Error {
  constructor(message: string, readonly code: string, readonly status: number) {
    super(message);
  }
}

function parse(r: { json<T = any>(): T }): any {
  try {
    return r.json() ?? {};
  } catch {
    return {};
  }
}

/** A refusal in the device's own words; 401 = it no longer knows this device. */
function refusal(status: number, data: any): DeviceError {
  if (status === 401) return new DeviceError(data.error || "doesn't know this device any more - pair again", "auth", 401);
  return new DeviceError(data.error || `answered ${status}`, data.code || "failed", status);
}

async function call<T>(net: Net | undefined, url: string, init: Parameters<Net["fetch"]>[2] = {}): Promise<T> {
  if (!net) throw new DeviceError("this PowOS app is too old for Devices (no host.net)", "old", 0);
  const r = await net.fetch(APP, url, init);
  const data = parse(r);
  if (r.status !== 200) throw refusal(r.status, data);
  return data as T;
}

export const info = (net: Net | undefined, url: string) => call<{ id: string; name: string; kind: string; caps: Cap[] }>(net, `${url}/v1/info`);

export async function status(net: Net | undefined, d: Device): Promise<Status & { caps: Cap[] }> {
  const r = await call<{ caps: Cap[]; status: Status; realm?: Realm }>(net, `${d.url}/v1/status`, { headers: auth(d.id) });
  return { ...r.status, caps: r.caps, ...(r.realm && { realm: r.realm }) };
}

export function act(net: Net | undefined, d: Device, action: Cap, opts: { force?: boolean; args?: Record<string, string> } = {}) {
  return call<{ ok: boolean; result: unknown }>(net, `${d.url}/v1/action`, {
    method: "POST",
    headers: { ...auth(d.id), "content-type": "application/json" },
    body: JSON.stringify({ action, ...opts }),
  });
}

/** Pairing, step 1: the device shows a code on its own screen. */
export async function pairStart(net: Net | undefined, url: string) {
  return call<{ request: string; expires_s: number }>(net, `${url}/v1/pair`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(self()),
  });
}

/** Step 2: the code typed here; the token goes straight into host.net's secret for that device (blanked here). */
export async function pairConfirm(net: Net | undefined, p: { url: string; request: string; code: string; id: string }) {
  const { url, request, code, id } = p;
  return call<{ device: { id: string; name: string; kind: string; caps: Cap[] } }>(net, `${url}/v1/pair/confirm`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ request, code }),
    capture: { secret: secretOf(id), path: "token" },
  });
}

/** Forget a device: it revokes this device's token (if it can be reached), then the secret and the pin go here. */
export async function forget(net: Net | undefined, d: Device) {
  await call(net, `${d.url}/v1/peers/${self().id}`, { method: "DELETE", headers: auth(d.id) }).catch(() => {});
  await net?.forget?.(APP, { secret: secretOf(d.id) });
}

/** PowOS devices on this network that aren't paired yet (mDNS _powos._tcp, TXT dev=<port>). */
export async function discover(net: Net | undefined, paired: Device[]): Promise<Found[]> {
  if (!net?.mdns) return [];
  const known = new Set(paired.map((d) => d.id));
  const found = await net.mdns(APP, "_powos._tcp", 2500).catch(() => []);
  return found
    .filter((s) => s.txt?.dev && s.txt?.id && !known.has(s.txt.id))
    .map((s) => ({ name: s.name, id: s.txt.id, kind: s.txt.kind || "device", url: `https://${s.host}:${s.txt.dev}` }));
}

/** An address the user typed ("192.168.50.58", "desk.pow:3416") as the agent's URL. */
export function urlOf(text: string): string {
  const t = text.trim().replace(/^https?:\/\//, "").replace(/\/.*$/, "");
  return `https://${/:\d+$/.test(t) ? t : `${t}:3416`}`;
}

/** The status as it should look after [action] - what the page shows the moment it's tapped. */
export function expected(s: Status | undefined, action: Cap): Partial<Status> {
  if (action === "screen_off") return { screen: "off" };
  if (action === "screen_on") return { screen: "on" };
  if (action === "lock") return { locked: true };
  if (action === "unlock") return { locked: false };
  if (action === "sleep") return { online: false };
  return {};
}

/** A paired device that can wake [target] (on, has "wake", and the target's NIC is known), or null. */
export function waker(target: Device, list: Device[], live: Record<string, Status | undefined>): Device | null {
  if (!target.wakeMac) return null;
  return list.find((d) => d.id !== target.id && d.caps.includes("wake") && live[d.id]?.online) ?? null;
}

/**
 * The realm through the approver: the paired agent on THIS device whose enrollment may approve (lib/devices/powos-deviced
 * /v1/enroll/*, refused to callers on other devices). Approving uses that device's enrollment, never a token here.
 */
export const approverOf = (list: Device[], live: Record<string, Status | undefined>) =>
  list.find((d) => live[d.id]?.online && live[d.id]?.realm?.approver && live[d.id]?.realm?.here) ?? null;

export const waiting = (net: Net | undefined, by: Device) =>
  call<{ pending: Waiting[] }>(net, `${by.url}/v1/enroll/pending`, { headers: auth(by.id) }).then((r) => r.pending ?? []);

export const enrolledDevices = (net: Net | undefined, by: Device) =>
  call<{ devices: Enrolled[] }>(net, `${by.url}/v1/enroll/devices`, { headers: auth(by.id) }).then((r) => r.devices ?? []);

export function decide(net: Net | undefined, by: Device, code: string, decision: "approve" | "deny") {
  return call<{ state: string }>(net, `${by.url}/v1/enroll/approve`, {
    method: "POST",
    headers: { ...auth(by.id), "content-type": "application/json" },
    body: JSON.stringify({ code, decision }),
  });
}

export function revokeEnrolled(net: Net | undefined, by: Device, id: string) {
  return call<{ revoked: boolean }>(net, `${by.url}/v1/enroll/revoke`, {
    method: "POST",
    headers: { ...auth(by.id), "content-type": "application/json" },
    body: JSON.stringify({ id }),
  });
}
