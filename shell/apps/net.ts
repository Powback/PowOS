/**
 * host.net - PowOS apps' network capability, from the app itself (ShellNet.kt over the native port, apps/native.ts):
 * an app's islands and pages reach the devices and services its powos-app.json declares in "net" - exact hosts, or
 * "lan" for any private address - without a process of their own, CORS, or a browser's refusal of self-signed
 * certificates (a LAN device's is pinned on first use, per app and host). Secrets (a bridge's key) stay in the app:
 * `capture` takes one out of a response, `${secret:name}` in a header puts it in.
 *
 *   const r = await host.net.fetch(app, "https://192.168.1.2/clip/v2/resource/room", { headers: { "hue-application-key": "${secret:hue}" } });
 *   const status = host.net.useEvents(app, url, headers, (data) => ...);   // SSE: one connection per app + url for
 *                                                                          // the whole shell, only while it's shown
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { fromNative, native, send } from "./native.ts";

export interface NetResponse {
  status: number;
  body: string;
  json<T = any>(): T;
}
export interface NetInit {
  method?: string;
  headers?: Record<string, string>;
  body?: string | object;
  /** Keep the string at [path] ("0.success.username") of the JSON response as the app's secret [secret]. */
  capture?: { secret: string; path: string };
}
export type StreamState = "off" | "open" | "retry" | "closed" | "unavailable";

export interface Net {
  fetch(app: string, url: string, init?: NetInit): Promise<NetResponse>;
  /** DNS-SD on the local network ("_hue._tcp"); needs "lan". */
  mdns(app: string, type: string, ms?: number): Promise<{ name: string; host: string; port: number; txt: Record<string, string> }[]>;
  hasSecret(app: string, name: string): Promise<boolean>;
  /** Drops a host's pinned certificate and/or a secret. */
  forget(app: string, what: { host?: string; secret?: string }): Promise<void>;
  /** Server-sent events while the page is shown (closed 5 s after it's hidden or the last user goes). null: off. */
  useEvents(app: string, url: string | null, headers: Record<string, string>, onEvent: (data: string, event: string) => void): StreamState;
}

const NO_NATIVE = "this PowOS app has no host.net yet (update the PowOS app)";
const TIMEOUT_MS = 40_000;
const GRACE_MS = 5000;

let nextId = 1;
const waiting = new Map<string, { ok: (v: any) => void; fail: (e: Error) => void; timer: number }>();

interface Stream {
  key: string;
  app: string;
  sub: string;
  url: string;
  headers: Record<string, string>;
  state: StreamState;
  users: Set<{ onEvent: (d: string, e: string) => void; onState: (s: StreamState) => void }>;
  running: boolean;
  drop?: number;
}
const streams = new Map<string, Stream>();
const bySub = new Map<string, Stream>();

fromNative.add((text) => {
  const sp = text.indexOf(" ");
  const verb = text.slice(0, sp);
  if (!verb.startsWith("n.")) return;
  let m: any;
  try {
    m = JSON.parse(text.slice(sp + 1));
  } catch {
    return;
  }
  if (verb === "n.res") {
    const w = waiting.get(m.id);
    if (!w) return;
    waiting.delete(m.id);
    clearTimeout(w.timer);
    m.error ? w.fail(new Error(m.error)) : w.ok(m);
  } else if (verb === "n.ev" || verb === "n.st") {
    const s = bySub.get(`${m.app}/${m.sub}`);
    if (!s) return;
    if (verb === "n.ev") for (const u of s.users) u.onEvent(m.data, m.event);
    else {
      s.state = m.state;
      for (const u of s.users) u.onState(s.state);
    }
  }
});

function request(op: string, app: string, args: Record<string, unknown>): Promise<any> {
  if (!native.value) return Promise.reject(new Error(NO_NATIVE));
  const id = String(nextId++);
  return new Promise((ok, fail) => {
    const timer = window.setTimeout(() => {
      waiting.delete(id);
      fail(new Error(`${op}: no answer`));
    }, TIMEOUT_MS);
    waiting.set(id, { ok, fail, timer });
    send(`n.req ${JSON.stringify({ ...args, id, op, app })}`);
  });
}

function start(s: Stream) {
  if (s.running || !native.value) return;
  s.running = true;
  send(`n.req ${JSON.stringify({ id: String(nextId++), op: "events", app: s.app, sub: s.sub, url: s.url, headers: s.headers })}`);
}
function stop(s: Stream) {
  if (!s.running) return;
  s.running = false;
  s.state = "off";
  send(`n.req ${JSON.stringify({ id: String(nextId++), op: "close", app: s.app, sub: s.sub })}`);
  for (const u of s.users) u.onState("off");
}
// Shown again: every stream someone holds opens again (the app closed them all 5 s after hiding).
document.addEventListener("visibilitychange", () => {
  for (const s of streams.values()) {
    clearTimeout(s.drop);
    if (document.hidden) s.drop = window.setTimeout(() => stop(s), GRACE_MS);
    else if (s.users.size) start(s);
  }
});
// A new port (the page reloaded the app side): the app forgot every stream.
native.subscribe(() => {
  for (const s of streams.values()) {
    s.running = false;
    if (s.users.size && !document.hidden) start(s);
  }
});

function useEvents(app: string, url: string | null, headers: Record<string, string>, onEvent: (data: string, event: string) => void): StreamState {
  const [state, setState] = useState<StreamState>(native.value ? "off" : "unavailable");
  const cb = useRef(onEvent);
  cb.current = onEvent;
  const hkey = JSON.stringify(headers);
  useEffect(() => {
    if (!url) return;
    if (!native.value) {
      setState("unavailable");
      return;
    }
    const key = `${app} ${url} ${hkey}`;
    let s = streams.get(key);
    if (!s) {
      s = { key, app, sub: `s${nextId++}`, url, headers, state: "off", users: new Set(), running: false };
      streams.set(key, s);
      bySub.set(`${app}/${s.sub}`, s);
    }
    const user = { onEvent: (d: string, e: string) => cb.current(d, e), onState: setState };
    s.users.add(user);
    clearTimeout(s.drop);
    setState(s.state);
    if (!document.hidden) start(s);
    const held = s;
    return () => {
      held.users.delete(user);
      if (held.users.size) return;
      clearTimeout(held.drop);
      held.drop = window.setTimeout(() => {
        if (held.users.size) return;
        stop(held);
        streams.delete(held.key);
        bySub.delete(`${held.app}/${held.sub}`);
      }, GRACE_MS);
    };
  }, [app, url, hkey]);
  return url ? state : "off";
}

export const net: Net = {
  async fetch(app, url, init = {}) {
    const body = init.body === undefined ? undefined : typeof init.body === "string" ? init.body : JSON.stringify(init.body);
    const r = await request("fetch", app, { url, method: init.method ?? "GET", headers: init.headers ?? {}, ...(body !== undefined ? { body } : {}), ...(init.capture ? { capture: init.capture } : {}) });
    return { status: r.status, body: r.body, json: () => JSON.parse(r.body) };
  },
  async mdns(app, type, ms = 3000) {
    return (await request("mdns", app, { type, ms })).services ?? [];
  },
  async hasSecret(app, name) {
    return !!(await request("secret", app, { name })).has;
  },
  async forget(app, what) {
    await request("forget", app, what);
  },
  useEvents,
};
