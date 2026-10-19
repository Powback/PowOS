/**
 * The host (types.ts Bridge): window.powos when a host sets it, the phone's WebView (window.PowosHost), or - in a
 * desktop browser, for working on the shell - a mock with sample apps, a sample home and widget trees captured from
 * the phone, so the shell still runs.
 */
import type { AgentMail, App, AssistScreen, Bridge, Cell, Chat, Home, HomeItem, NotificationList, PhoneNotification, TermState, ThemeChoice, ThemeColors, WidgetScreen } from "./types.ts";

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
      arrange: (cols, rows) => call("home.arrange", cols, rows),
    },
    widgets: {
      watch: (key, screen) => call("widgets.watch", key, !!screen),
      unwatch: (key, screen) => call("widgets.unwatch", key, !!screen),
      fire: (key, screen, id, name, args) => call("widgets.fire", key, !!screen, id, name, args ?? []),
      size: (key, cols, rows, width, height) => call("widgets.size", key, cols, rows, width, height),
      canvas: (key, id, width, height) => call("widgets.canvas", key, id, width, height),
      page: (page) => call("widgets.page", page),
      tap: (key) => call("widgets.tap", key),
      screen: () => call<WidgetScreen>("widgets.screen"),
      closeScreen: () => call("widgets.closeScreen"),
    },
    store: {
      get: <T>(name: string) => call<T | null>("store.get", name),
      set: (name, value) => call("store.set", name, value),
    },
    ai: {
      chat: () => call<Chat>("ai.chat"),
      send: (text) => call("ai.send", text),
      open: () => call("ai.open"),
      mail: () => call<AgentMail[]>("ai.mail"),
      sessions: () => call("ai.sessions"),
      attach: (name) => call("ai.attach", name),
    },
    term: {
      open: (id, owner, command, cols, rows, restart) => call<TermState>("term.open", id, owner, command, cols, rows, !!restart),
      write: (id, data) => call("term.write", id, data),
      resize: (id, cols, rows) => call("term.resize", id, cols, rows),
      close: (id) => call("term.close", id),
      style: (points) => call("term.style", points),
    },
    clipboard: { read: () => call<string | null>("clipboard.read"), write: (text) => call("clipboard.write", text) },
    notifications: {
      list: () => call<NotificationList>("notifications.list"),
      open: (key) => call("notifications.open", key),
      dismiss: (key) => call("notifications.dismiss", key),
      clearAll: () => call("notifications.clearAll"),
      access: () => call("notifications.access"),
    },
    assist: {
      screen: () => call<AssistScreen | null>("assist.screen"),
      close: () => call("assist.close"),
      attach: (image) => call<string | null>("assist.attach", image),
    },
    theme: {
      get: () => call<ThemeColors>("theme.get"),
      list: () => call<ThemeChoice[]>("theme.list"),
      pick: (name) => call("theme.pick", name),
    },
    screens: { open: (name) => call("screens.open", name) },
    agents: {
      default: () => call<string | null>("agents.default"),
      newWidget: () => call("agents.newWidget"),
      newApp: () => call("agents.newApp"),
    },
    speech: {
      start: (hold) => call("speech.start", hold),
      stop: () => call("speech.stop"),
      cancel: () => call("speech.cancel"),
    },
    keyboard: { show: () => call("keyboard.show"), hide: () => call("keyboard.hide") },
    system: { insets: () => call("system.insets"), notifications: (open = true) => call("system.notifications", open), battery: () => call("system.battery") },
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
  let screen: WidgetScreen = { key: null };
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
      { key: "glance.owl", kind: "widget", page: 2, cell: { x: 4, y: 0, w: 2, h: 3 }, resizable: true, minSize: [2, 2], size: [2, 3], name: "Glance" },
      { key: "terminal.owl", kind: "widget", page: 2, cell: { x: 0, y: 3, w: 6, h: 4 }, resizable: true, minSize: [2, 2], size: [6, 4], name: "Terminal" },
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
      // As WidgetLayout.place: the first free spot at the item's size, on its page.
      arrange: async (cols, rows) => {
        let moved = false;
        for (const item of home.items.filter((i) => !i.cell)) {
          const [w, h] = item.size ?? [Math.floor(cols / 2), 3];
          const taken = home.items.filter((o) => o !== item && o.page === item.page && o.cell).map((o) => o.cell!);
          for (let y = 0; y + h <= rows && !item.cell; y++)
            for (let x = 0; x + w <= cols && !item.cell; x++)
              if (taken.every((c) => x >= c.x + c.w || c.x >= x + w || y >= c.y + c.h || c.y >= y + h)) item.cell = { x, y, w, h };
          moved ||= !!item.cell;
        }
        if (moved) changed();
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
        const id = screen ? `${key}#screen` : key;
        events.emit("widget.tree", { key, screen: !!screen, tree: (await samples)[id] ?? terminalTrees[id] ?? null });
      },
      unwatch: async () => {},
      // The mock's widgets with a screen open it on a tap, as their onTap: screen() does.
      tap: async (key) => {
        if (terminalTrees[`${key}#screen`]) events.emit("widget.screen", (screen = { key, terminal: true, title: key }));
      },
      screen: async () => screen,
      closeScreen: async () => void events.emit("widget.screen", (screen = { key: null })),
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
      mail: async () => {
        const now = Math.floor(Date.now() / 1000);
        return [
          { from: "coder", text: "Launcher refactor done - 3 commits pushed to master.", time: now - 600 },
          { from: "health", text: "Disk at 91% on /var - want me to prune old container images?", time: now - 5400 },
        ];
      },
      // Two agents: one working (a spinner in its title, as Claude Code shows), one waiting.
      sessions: async () => {
        const now = Math.floor(Date.now() / 1000);
        events.emit("ai.sessions", [
          { name: "launcher", activity: now - 4, attached: true, title: "⠂ Port the notification panel", path: "/home/powos/Projects/PowOS", command: "claude" },
          { name: "spec-llm", activity: now - 2400, attached: false, title: "✳ Benchmark the fusion backbone", path: "/home/powos/Projects/spec-llm", command: "claude" },
          { name: "main", activity: now - 9000, attached: false, title: "powos@localhost:~", path: "/home/powos", command: "bash" },
        ]);
      },
      attach: async (name) => console.log("[mock] attach", name),
    },
    term: mockTerm(events),
    clipboard: {
      read: async () => navigator.clipboard?.readText().catch(() => null) ?? null,
      write: async (text) => void (await navigator.clipboard?.writeText(text).catch(() => {})),
    },
    // A screen it was opened over: some text, no screenshot.
    assist: {
      screen: async () => ({ text: "Inbox\n  Mats - are we still on for tonight?\n  Your order has shipped", screenshot: null }),
      close: async () => console.log("[mock] assistant closed"),
      attach: async (image) => `/run/powos-app/powos-ai-shared/screen-mock.${image ? "png" : "jpg"}`,
    },
    // A few made-up notifications; dismissing and clearing work on them.
    notifications: (() => {
      const now = Math.floor(Date.now() / 1000);
      let items: PhoneNotification[] = [
        { key: "1", app: "Signal", icon: null, title: "Mats", text: "are we still on for tonight?", time: now - 120, clearable: true, profile: null },
        { key: "2", app: "Gmail", icon: null, title: "Your order has shipped", text: "Track your package: it arrives Thursday.", time: now - 3600, clearable: true, profile: null },
        { key: "3", app: "PowOS AI", icon: null, title: "coder", text: "Finished the launcher refactor - 3 commits pushed.", time: now - 7200, clearable: true, profile: null },
      ];
      const changed = () => events.emit("notifications.changed", { available: true, items });
      return {
        list: async () => ({ available: true, items }),
        open: async (key: string) => console.log("[mock] open notification", key),
        dismiss: async (key: string) => {
          items = items.filter((n) => n.key !== key);
          changed();
        },
        clearAll: async () => {
          items = items.filter((n) => !n.clearable);
          changed();
        },
        access: async () => console.log("[mock] notification access"),
      };
    })(),
    // Three of Omarchy's themes; picking one recolors the page as the phone's would.
    theme: (() => {
      const themes: ThemeChoice[] = [
        { name: "kanagawa", title: "Kanagawa", colors: { background: "#1f1f28", foreground: "#dcd7ba", accent: "#7e9cd8", red: "#e82424", yellow: "#e6c384", green: "#98bb6c", magenta: "#957fb8" } },
        { name: "tokyo-night", title: "Tokyo Night", colors: { background: "#1a1b26", foreground: "#a9b1d6", accent: "#7aa2f7", red: "#f7768e", yellow: "#e0af68", green: "#9ece6a", magenta: "#bb9af7" } },
        { name: "rose-pine", title: "Rosé Pine", colors: { background: "#faf4ed", foreground: "#575279", accent: "#56949f", red: "#b4637a", yellow: "#ea9d34", green: "#286983", magenta: "#907aa9" } },
      ];
      let picked = "kanagawa";
      const colors = (): ThemeColors => {
        const c = themes.find((t) => t.name === picked)!.colors;
        const light = picked === "rose-pine";
        const mix = (a: string, pct: number) => `color-mix(in srgb, ${a} ${pct}%, ${c.background})`;
        return { name: picked, light, css: { background: c.background, surface: mix(c.foreground, 8), foreground: c.foreground, muted: mix(c.foreground, 55), accent: c.accent, border: mix(c.foreground, 30), red: c.red }, colors: c };
      };
      return {
        get: async () => colors(),
        list: async () => themes,
        pick: async (name: string) => {
          picked = name;
          events.emit("theme.changed", colors());
        },
      };
    })(),
    screens: { open: async (name) => console.log("[mock] open screen", name) },
    agents: {
      default: async () => "Claude",
      newWidget: async () => (console.log("[mock] new widget with claude"), "started" as const),
      newApp: async () => (console.log("[mock] new app with claude"), "started" as const),
    },
    // Hears the same words every time, a word at a time; a tap ends at the "pause" after them.
    speech: (() => {
      const words = "how much battery is left".split(" ");
      let timer = 0;
      let heard = "";
      let held = false;
      const state = (listening: boolean) => events.emit("speech.state", { listening, text: heard, error: null });
      const done = () => {
        clearInterval(timer);
        state(false);
        events.emit("speech.done", { text: heard });
      };
      return {
        start: async (hold: boolean) => {
          clearInterval(timer);
          held = hold;
          heard = "";
          state(true);
          let i = 0;
          timer = window.setInterval(() => {
            if (i < words.length) heard = words.slice(0, ++i).join(" ");
            state(true);
            if (i >= words.length && !held) done();
          }, 150);
          return "started" as const;
        },
        stop: async () => done(),
        cancel: async () => {
          clearInterval(timer);
          state(false);
        },
      };
    })(),
    keyboard: { show: async () => {}, hide: async () => {} },
    system: { insets: async () => ({ top: 0, bottom: 0, left: 0, right: 0, keyboard: 0 }), notifications: async (open = true) => (console.log(`[mock] notification shade ${open ? "down" : "up"}`), true), battery: async () => ({ level: 76, charging: false }) },
    on: (event, handler) => events.on(event, handler),
  };
}

/** The mock's terminal widgets: a shell to type in, and one only shown (its taps are the widget's). */
const terminalTrees: Record<string, unknown> = {
  // As the bundled 45-terminal.owl: the tile only shows the shell; a tap opens it full size (its screen), typing there.
  "terminal.owl": { k: "Root", id: "r", padding: 0, tap: true, c: [{ k: "Terminal", id: "r.0", p: { session: "main", interactive: false } }] },
  "terminal.owl#screen": { k: "Root", id: "s", padding: 0, c: [{ k: "Terminal", id: "s.0", p: { session: "main", focus: true } }] },
  "glance.owl": {
    k: "Root",
    id: "r",
    padding: 0,
    c: [{ k: "Terminal", id: "r.0", p: { command: "seq 40", interactive: false, textSize: 9 }, h: ["onTap"] }],
  },
};

/**
 * Terminals for the mock: a tiny line-editing shell instead of a pty (echo, seq, size, colors, mouse, exit), with the host's
 * protocol - base64 both ways, output offsets, runs - so the page's terminal code runs as on the phone.
 */
function mockTerm(events: Events): Bridge["term"] {
  const utf8 = new TextEncoder();
  const b64 = (bytes: Uint8Array) => btoa(Array.from(bytes, (b) => String.fromCharCode(b)).join(""));
  const unb64 = (s: string) => new TextDecoder().decode(Uint8Array.from(atob(s), (c) => c.charCodeAt(0)));
  interface Shell { run: number; out: number[]; line: string; cols: number; rows: number; code: number | null; }
  const shells = new Map<string, Shell>();
  let runs = 0;
  const state = (sh: Shell): TermState => ({ running: sh.code == null, code: sh.code, run: sh.run, history: b64(Uint8Array.from(sh.out)), end: sh.out.length });
  const print = (id: string, sh: Shell, text: string) => {
    const bytes = utf8.encode(text);
    sh.out.push(...bytes);
    const end = sh.out.length;
    setTimeout(() => events.emit("term.data", { id, run: sh.run, data: b64(bytes), end }), 5);
  };
  const prompt = "\x1b[32mmock\x1b[0m:\x1b[34m~\x1b[0m$ ";
  const exec = (id: string, sh: Shell, line: string) => {
    const [cmd, ...args] = line.trim().split(/\s+/);
    if (cmd === "exit") {
      sh.code = Number(args[0] ?? 0) || 0;
      setTimeout(() => events.emit("term.exit", { id, run: sh.run, code: sh.code }), 10);
      return;
    }
    if (cmd === "echo") print(id, sh, args.join(" ") + "\r\n");
    else if (cmd === "seq") for (let i = 1; i <= Number(args[0] ?? 10); i++) print(id, sh, `${i}\r\n`);
    else if (cmd === "size") print(id, sh, `${sh.cols}x${sh.rows}\r\n`);
    else if (cmd === "colors") print(id, sh, Array.from({ length: 16 }, (_, i) => `\x1b[${i < 8 ? 40 + i : 92 + i}m ${i.toString(16)} `).join("") + "\x1b[0m\r\n");
    // tmux's mouse: reports in the SGR encoding; "mouse off" ends it.
    else if (cmd === "mouse") print(id, sh, args[0] === "off" ? "\x1b[?1000l\x1b[?1006l" : "\x1b[?1000h\x1b[?1006h");
    else if (cmd) print(id, sh, `${cmd}: not in the mock (echo, seq N, size, colors, mouse [off], exit N)\r\n`);
    print(id, sh, prompt);
  };
  return {
    open: async (id, _owner, command, cols, rows, restart) => {
      let sh = shells.get(id);
      if (!sh || (restart && sh.code != null)) {
        sh = { run: ++runs, out: [], line: "", cols, rows, code: null };
        shells.set(id, sh);
        print(id, sh, `mock terminal \x1b[2m(${command ?? "login shell"})\x1b[0m\r\n` + prompt);
      }
      return state(sh);
    },
    write: async (id, data) => {
      const sh = shells.get(id);
      if (!sh || sh.code != null) return;
      // Keys that are escape sequences (arrows, mouse reports) do nothing here.
      for (const ch of unb64(data).replace(/\x1b(\[[\d;?<]*[ -\/]*[@-~]|O.)?/g, "")) {
        if (ch === "\r") {
          print(id, sh, "\r\n");
          const line = sh.line;
          sh.line = "";
          exec(id, sh, line);
        } else if (ch === "\x7f") {
          if (sh.line) {
            sh.line = [...sh.line].slice(0, -1).join("");
            print(id, sh, "\b \b");
          }
        } else if (ch === "\x03") {
          sh.line = "";
          print(id, sh, "^C\r\n" + prompt);
        } else if (ch >= " ") {
          sh.line += ch;
          print(id, sh, ch);
        }
      }
    },
    resize: async (id, cols, rows) => {
      const sh = shells.get(id);
      if (sh) Object.assign(sh, { cols, rows });
    },
    close: async (id) => void shells.delete(id),
    style: async () => ({ size: 13, pad: 6, fontScale: 1, family: "JetBrainsMono Nerd Font", font: false }),
  };
}

export const powos: Bridge = window.powos ?? (window.PowosHost ? android(window.PowosHost) : mock());
