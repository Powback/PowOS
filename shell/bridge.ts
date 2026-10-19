/**
 * The host (types.ts Bridge): window.powos when a host sets it, the phone's WebView (window.PowosHost), or - in a
 * desktop browser, for working on the shell - a mock with sample apps, a sample home and widget trees captured from
 * the phone, so the shell still runs.
 */
import type { App, Bridge, Cell, Chat, Home, HomeItem } from "./types.ts";

type Handler = (data: any) => void;

/** Events by name, for either host. */
class Events {
  private listeners = new Map<string, Set<Handler>>();

  on(event: string, handler: Handler): () => void {
    if (!this.listeners.has(event)) this.listeners.set(event, new Set());
    this.listeners.get(event)!.add(handler);
    return () => this.listeners.get(event)?.delete(handler);
  }

  emit(event: string, data: unknown) {
    this.listeners.get(event)?.forEach((h) => h(data));
  }
}

/**
 * The phone's WebView (ShellBridge.kt): one native entry, PowosHost.call(id, method, argsJson), answered through
 * window.__powosHost.resolve / reject; events arrive through window.__powosHost.emit.
 */
function android(host: NonNullable<Window["PowosHost"]>): Bridge {
  const pending = new Map<number, [(v: any) => void, (e: Error) => void]>();
  const events = new Events();
  let next = 1;
  window.__powosHost = {
    resolve: (id, value) => {
      pending.get(id)?.[0](value);
      pending.delete(id);
    },
    reject: (id, message) => {
      pending.get(id)?.[1](new Error(message));
      pending.delete(id);
    },
    emit: (event, data) => events.emit(event, data),
  };
  const call = <T = void>(method: string, ...args: unknown[]) =>
    new Promise<T>((resolve, reject) => {
      const id = next++;
      pending.set(id, [resolve, reject]);
      host.call(id, method, JSON.stringify(args));
    });
  return {
    host: "android",
    apps: {
      list: () => call<App[]>("apps.list"),
      launch: (key) => call("apps.launch", key),
      info: (key) => call("apps.info", key),
      uninstall: (key) => call("apps.uninstall", key),
    },
    usage: { recent: (limit) => call<string[]>("usage.recent", limit) },
    home: {
      get: () => call<Home>("home.get"),
      place: (key, cell, page) => call("home.place", key, cell, page),
      add: (app, page, cell) => call<string>("home.add", app, page, cell ?? null),
      remove: (key) => call("home.remove", key),
      group: (key, target) => call<string | null>("home.group", key, target),
    },
    widgets: {
      watch: (key, screen) => call("widgets.watch", key, !!screen),
      unwatch: (key, screen) => call("widgets.unwatch", key, !!screen),
      fire: (key, screen, id, name, args) => call("widgets.fire", key, !!screen, id, name, args ?? []),
      size: (key, cols, rows, width, height) => call("widgets.size", key, cols, rows, width, height),
      canvas: (key, id, width, height) => call("widgets.canvas", key, id, width, height),
      page: (page) => call("widgets.page", page),
    },
    store: {
      get: <T>(name: string) => call<T | null>("store.get", name),
      set: (name, value) => call("store.set", name, value),
    },
    ai: {
      chat: () => call<Chat>("ai.chat"),
      send: (text) => call("ai.send", text),
      open: () => call("ai.open"),
    },
    keyboard: { show: () => call("keyboard.show"), hide: () => call("keyboard.hide") },
    system: { insets: () => call("system.insets") },
    on: (event, handler) => events.on(event, handler),
  };
}

function mock(): Bridge {
  const events = new Events();
  const names = [
    "Brave", "Calculator", "Calendar", "Camera", "Chrome", "Clock", "Contacts", "Discord", "Dolphin", "Drive",
    "Files", "Firefox", "Gmail", "Kate", "Konsole", "Maps", "Messages", "Netflix", "Phone", "Photos", "Play Store",
    "Settings", "Signal", "Spotify", "Steam", "System Settings", "Telegram", "Terminal", "WhatsApp", "YouTube",
    "Zoom", "Ölwerk", "7-Zip",
  ];
  const linux = new Set(["Dolphin", "Kate", "Konsole", "Steam", "System Settings", "Terminal", "Firefox"]);
  const hue = (s: string) => [...s].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 360, 7);
  const icon = (name: string) =>
    "data:image/svg+xml," +
    encodeURIComponent(
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="hsl(${hue(name)} 55% 45%)"/>` +
        `<text x="24" y="31" font-family="sans-serif" font-size="20" fill="white" text-anchor="middle">${name[0]}</text></svg>`,
    );
  const apps: App[] = names.map((name) => ({
    key: (linux.has(name) ? "l:" : "a:") + name.toLowerCase().replace(/\W+/g, "."),
    label: name,
    icon: icon(name),
    kind: linux.has(name) ? "linux" : "android",
  }));
  const recent = ["a:chrome", "l:konsole", "a:spotify", "a:signal", "l:dolphin", "a:youtube"];
  const data = (name: string) => `powos-shell:${name}`;
  let samples: Promise<Record<string, unknown>> | null = null;
  let chat: Chat = { busy: false, items: [] };
  const pin = (name: string, x: number, y: number): HomeItem => {
    const a = apps.find((app) => app.label === name)!;
    return { key: "app:" + a.key.slice(2), kind: "app", page: 1, cell: { x, y, w: 1, h: 1 }, resizable: false, minSize: [1, 1], size: [1, 1], label: a.label, app: a.key };
  };
  const home: Home = {
    columns: 6,
    pages: [1, 2],
    items: [
      { key: "clock.owl", kind: "widget", page: 1, cell: { x: 0, y: 0, w: 6, h: 2 }, resizable: true, minSize: [2, 1], size: [6, 2], name: "Clock" },
      { key: "weather.owl", kind: "widget", page: 1, cell: { x: 0, y: 2, w: 3, h: 2 }, resizable: true, minSize: [2, 2], size: [3, 2], name: "Weather" },
      pin("Chrome", 3, 2),
      pin("Signal", 4, 2),
      pin("Spotify", 5, 2),
      { key: "monitor.owl", kind: "widget", page: 2, cell: { x: 0, y: 0, w: 4, h: 3 }, resizable: true, minSize: [2, 2], size: [4, 3], name: "Monitor" },
    ],
  };
  const changed = () => {
    home.pages = [...new Set(home.items.map((i) => i.page))].sort((a, b) => a - b);
    events.emit("home.changed", null);
  };
  return {
    host: "mock",
    apps: {
      list: async () => apps,
      launch: async (key) => {
        console.log("[mock] launch", key);
        if (recent.includes(key)) recent.splice(recent.indexOf(key), 1);
        recent.unshift(key);
      },
      info: async (key) => console.log("[mock] info", key),
      uninstall: async (key) => console.log("[mock] uninstall", key),
    },
    usage: { recent: async (limit) => recent.slice(0, limit) },
    home: {
      get: async () => structuredClone(home),
      place: async (key: string, cell: Cell, page: number) => {
        Object.assign(home.items.find((i) => i.key === key)!, { cell, page });
        changed();
      },
      add: async (app, page, cell) => {
        const a = apps.find((x) => x.key === app)!;
        const key = (a.kind === "linux" ? "linux:" : "app:") + a.key.slice(2);
        home.items = home.items.filter((i) => i.key !== key);
        home.items.push({ key, kind: "app", page, cell: cell ?? null, resizable: false, minSize: [1, 1], size: [1, 1], label: a.label, app });
        changed();
        return key;
      },
      remove: async (key) => {
        home.items = home.items.filter((i) => i.key !== key);
        changed();
      },
      group: async (key, target) => {
        const item = home.items.find((i) => i.key === key);
        const into = home.items.find((i) => i.key === target);
        if (!item || !into || item.kind !== "app") return null;
        home.items = home.items.filter((i) => i.key !== key);
        const entry = { key: item.key, label: item.label!, app: item.app! };
        if (into.kind === "folder") into.apps!.push(entry);
        else {
          home.items = home.items.filter((i) => i.key !== target);
          home.items.push({ ...into, key: "folder:" + Date.now(), kind: "folder", apps: [{ key: into.key, label: into.label!, app: into.app! }, entry] });
        }
        changed();
        return null;
      },
    },
    store: {
      get: async <T>(name: string) => {
        try {
          return JSON.parse(localStorage.getItem(data(name)) ?? "null") as T | null;
        } catch {
          return null;
        }
      },
      set: async (name, value) => {
        try {
          localStorage.setItem(data(name), JSON.stringify(value));
        } catch {
          // a private window: kept for this page only
        }
      },
    },
    // Trees captured from real widgets on the phone (dev/sample-trees.json), keyed by the mock home's widgets.
    widgets: {
      watch: async (key, screen) => {
        samples ??= fetch("./dev/sample-trees.json").then((r) => r.json()).catch(() => ({}));
        events.emit("widget.tree", { key, screen: !!screen, tree: (await samples)[key] ?? null });
      },
      unwatch: async () => {},
      fire: async (key, _screen, id, name, args) => console.log("[mock] fire", key, id, name, args),
      size: async () => {},
      canvas: async () => {},
      page: async () => {},
    },
    // A stand-in that answers after a tool call, as a streamed turn does.
    ai: {
      chat: async () => chat,
      send: async (text) => {
        const step = (next: Partial<Chat>) => events.emit("ai.changed", (chat = { ...chat, ...next }));
        step({ busy: true, items: [...chat.items, { kind: "user", text }] });
        await new Promise((r) => setTimeout(r, 400));
        step({ items: [...chat.items, { kind: "tool", name: "Bash", hint: "powos status", ok: null }] });
        await new Promise((r) => setTimeout(r, 600));
        const items = chat.items.slice(0, -1);
        step({ busy: false, items: [...items, { kind: "tool", name: "Bash", hint: "powos status", ok: true }, { kind: "assistant", text: `(mock) You asked: ${text}` }] });
      },
      open: async () => console.log("[mock] open PowOS AI"),
    },
    keyboard: { show: async () => {}, hide: async () => {} },
    system: { insets: async () => ({ top: 0, bottom: 0, left: 0, right: 0, keyboard: 0 }) },
    on: (event, handler) => events.on(event, handler),
  };
}

export const powos: Bridge = window.powos ?? (window.PowosHost ? android(window.PowosHost) : mock());
