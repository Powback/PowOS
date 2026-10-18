/**
 * The host (bridge.d.ts): window.powos, set by the phone's WebView or PowOS's desktop host before the page loads.
 * Without one - a desktop browser, for working on the shell - a mock with sample apps, so the shell still runs.
 */

/** @returns {import('./bridge').Bridge} */
function mock() {
  const listeners = new Map();
  const names = [
    "Brave", "Calculator", "Calendar", "Camera", "Chrome", "Clock", "Contacts", "Discord", "Dolphin", "Drive",
    "Files", "Firefox", "Gmail", "Kate", "Konsole", "Maps", "Messages", "Netflix", "Phone", "Photos", "Play Store",
    "Settings", "Signal", "Spotify", "Steam", "System Settings", "Telegram", "Terminal", "WhatsApp", "YouTube",
    "Zoom", "Ölwerk", "7-Zip",
  ];
  const linux = new Set(["Dolphin", "Kate", "Konsole", "Steam", "System Settings", "Terminal", "Firefox"]);
  const hue = (s) => [...s].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 360, 7);
  const icon = (name) =>
    "data:image/svg+xml," +
    encodeURIComponent(
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="hsl(${hue(name)} 55% 45%)"/>` +
        `<text x="24" y="31" font-family="sans-serif" font-size="20" fill="white" text-anchor="middle">${name[0]}</text></svg>`,
    );
  const apps = names.map((name) => ({
    key: (linux.has(name) ? "l:" : "a:") + name.toLowerCase().replace(/\W+/g, "."),
    label: name,
    icon: icon(name),
    kind: linux.has(name) ? "linux" : "android",
  }));
  const recent = ["a:chrome", "l:konsole", "a:spotify", "a:signal", "l:dolphin", "a:youtube"];
  const data = (name) => `powos-shell:${name}`;
  return {
    host: "mock",
    apps: {
      list: async () => apps,
      launch: async (key) => {
        console.log("[mock] launch", key);
        recent.splice(recent.indexOf(key) >>> 0, recent.includes(key) ? 1 : 0);
        recent.unshift(key);
      },
      info: async (key) => console.log("[mock] info", key),
      uninstall: async (key) => console.log("[mock] uninstall", key),
    },
    usage: { recent: async (limit) => recent.slice(0, limit) },
    store: {
      get: async (name) => {
        try {
          return JSON.parse(localStorage.getItem(data(name)) ?? "null");
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
    keyboard: { show: async () => {}, hide: async () => {} },
    system: { insets: async () => ({ top: 0, bottom: 0, left: 0, right: 0, keyboard: 0 }) },
    on(event, handler) {
      if (!listeners.has(event)) listeners.set(event, new Set());
      listeners.get(event).add(handler);
      return () => listeners.get(event).delete(handler);
    },
  };
}

/**
 * The phone's WebView (ShellBridge.kt): one native entry, PowosHost.call(id, method, argsJson), answered through
 * window.__powosHost.resolve / reject; events arrive through window.__powosHost.emit.
 * @returns {import('./bridge').Bridge}
 */
function android(host) {
  const pending = new Map();
  const listeners = new Map();
  let next = 1;
  window.__powosHost = {
    resolve: (id, value) => (pending.get(id)?.[0](value), pending.delete(id)),
    reject: (id, message) => (pending.get(id)?.[1](new Error(message)), pending.delete(id)),
    emit: (event, data) => listeners.get(event)?.forEach((handler) => handler(data)),
  };
  const call = (method, ...args) =>
    new Promise((resolve, reject) => {
      const id = next++;
      pending.set(id, [resolve, reject]);
      host.call(id, method, JSON.stringify(args));
    });
  return {
    host: "android",
    apps: {
      list: () => call("apps.list"),
      launch: (key) => call("apps.launch", key),
      info: (key) => call("apps.info", key),
      uninstall: (key) => call("apps.uninstall", key),
    },
    usage: { recent: (limit) => call("usage.recent", limit) },
    store: { get: (name) => call("store.get", name), set: (name, value) => call("store.set", name, value) },
    keyboard: { show: () => call("keyboard.show"), hide: () => call("keyboard.hide") },
    system: { insets: () => call("system.insets") },
    on(event, handler) {
      if (!listeners.has(event)) listeners.set(event, new Set());
      listeners.get(event).add(handler);
      return () => listeners.get(event).delete(handler);
    },
  };
}

export const powos = window.powos ?? (window.PowosHost ? android(window.PowosHost) : mock());
