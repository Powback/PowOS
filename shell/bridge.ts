/**
 * The host (types.ts Bridge): window.powos when a host sets it, a native host's window.PowosHost (the phone's WebView,
 * or the desktop's powos-shell over QWebChannel - one contract, sources/powos-shell/src/bridge.cpp), or - in a
 * desktop browser, for working on the shell - a mock with sample apps, a sample home and widget trees captured from
 * the phone, so the shell still runs.
 */
import type {
  BarInput,
  Agent,
  AgentEvent,
  AgentMail,
  AgentsDelta,
  NativePerf,
  FrontPresents,
  App,
  AppWidgetProvider,
  AssistScreen,
  Bridge,
  HealthRecord,
  HealthStatus,
  ChromeState,
  Cell,
  Chat,
  DesktopWindow,
  VirtualDesktop,
  Home,
  HomeItem,
  NotificationList,
  PhoneNotification,
  RecentTask,
  RunState,
  AppLinks,
  AppWindow,
  QuickState,
  TermState,
  ThemeChoice,
  GlassSource,
  ThemeColors,
  WidgetScreen,
  MediaState,
  NativeSetting,
  GlassesState,
} from "./types.ts";
import { mockScreens } from "./screens-mock.ts";
import { homeLayout } from "./hosts/layout.ts";
import { desktop } from "./hosts/desktop.ts";
import { wide } from "./hosts/wide.ts";

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
 * A native host - the phone's WebView (ShellBridge.kt) or the desktop's powos-shell (bridge.cpp): one native entry,
 * PowosHost.call(id, method, argsJson) on the desktop, PowosHost.postMessage(JSON [id, method, argsJson]) on the phone
 * (a web message listener the app gives only to this page's top frame at its origin: ShellOrigin.kt), answered through
 * window.__powosHost.resolve / reject; events arrive through window.__powosHost.emit. An area a host doesn't have
 * rejects ("no such call" / "unsupported").
 */
function native(host: NonNullable<Window["PowosHost"]>): Bridge {
  const send = host.call
    ? (id: number, method: string, args: string) => host.call!(id, method, args)
    : (id: number, method: string, args: string) => host.postMessage!(JSON.stringify([id, method, args]));
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
      send(id, method, JSON.stringify(args));
    });
  return {
    host: host.name ?? "android",
    chrome: {
      state: () => call<ChromeState>("chrome.state"),
      ready: () => call("chrome.ready"),
      action: (action) => call("chrome.action", action),
      regions: (regions) => call("chrome.regions", regions),
    },
    apps: {
      list: () => call<App[]>("apps.list"),
      launch: (key, opts) => (opts?.fullScreen ? call("apps.launch", key, { fullScreen: true }) : call("apps.launch", key)),
      info: (key) => call("apps.info", key),
      uninstall: (key) => call("apps.uninstall", key),
      running: () => call<Record<string, RunState>>("apps.running"),
      links: (pkg) => call<AppLinks>("apps.links", pkg),
      close: (key) => call<boolean>("apps.close", key),
    },
    usage: { recent: (limit) => call<string[]>("usage.recent", limit) },
    home: {
      get: () => call<Home>("home.get"),
      place: (key, cell, page) => call("home.place", key, cell, page),
      add: (app, page, cell) => call<string>("home.add", app, page, cell ?? null),
      remove: (key) => call("home.remove", key),
      group: (key, target) => call<string | null>("home.group", key, target),
      arrange: (cols, rows) => call("home.arrange", cols, rows),
      addPanel: (name, page, cell) => call<string>("home.addPanel", name, page, cell),
    },
    appWidgets: {
      providers: () => call<AppWidgetProvider[]>("appwidgets.providers"),
      add: (provider, page, cell, width, height) =>
        call<"added" | "pending" | "failed">("appwidgets.add", provider, page, cell, width, height),
      watch: (id, width, height) =>
        call<{ url: string | null; scrolls: boolean } | null>("appwidgets.watch", id, width, height),
      unwatch: (id) => call("appwidgets.unwatch", id),
      watchData: (id, on) => call("appwidgets.watchData", id, on),
      image: (ref) => call<string | null>("appwidgets.image", ref),
      touch: (id, action, x, y, width, height) => call("appwidgets.touch", id, action, x, y, width, height),
      configure: (id) => call("appwidgets.configure", id),
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
    bar: { publish: (v) => call<BarInput | null>("bar.publish", v), get: () => call<BarInput | null>("bar.get") },
    perf: { save: (json) => call<string | null>("perf.save", json), publish: (json) => call("perf.publish", json), native: (on) => call<NativePerf | true | null>("perf.native", on), front: () => call<FrontPresents | null>("perf.front") },
    ai: {
      chat: () => call<Chat>("ai.chat"),
      send: (text, recents = true) => call("ai.send", text, recents),
      unqueue: (id) => call("ai.unqueue", id),
      verifyGo: (task) => call("verify.go", task),
      verdict: (task, works, line) => call("ai.verdict", task, works, line ?? ""),
      verifyState: () => call("verify.state"),
      verifyStop: (dry = false) => call("verify.stop", dry),
      open: () => call("ai.open"),
      newApp: (description) => call<boolean>("ai.newApp", description),
      closeThread: () => call<boolean>("ai.closeThread"),
      mail: () => call<AgentMail[]>("ai.mail"),
      mailRead: (id) => call("ai.mailRead", id),
      mailClear: () => call("ai.mailClear"),
      sessions: () => call("ai.sessions"),
      attach: (name) => call("ai.attach", name),
    },
    term: {
      open: (id, owner, command, cols, rows, restart) =>
        call<TermState>("term.open", id, owner, command, cols, rows, !!restart),
      write: (id, data) => call("term.write", id, data),
      resize: (id, cols, rows) => call("term.resize", id, cols, rows),
      close: (id) => call("term.close", id),
      style: (points) => call("term.style", points),
    },
    clipboard: {
      read: () => call<string | null>("clipboard.read"),
      write: (text) => call("clipboard.write", text),
    },
    remote: {
      state: () => call<RemoteState>("remote.state"),
      target: (t) => call<RemoteState>("remote.target", t),
      off: (side) => call<RemoteState>("remote.off", side),
      discoverable: () => call("remote.discoverable"),
      connect: (address) => call("remote.connect", address),
      disconnect: () => call("remote.disconnect"),
      keys: (reports) => call("remote.keys", reports),
      mouse: (buttons, dx, dy, wheel, pan) => call("remote.mouse", buttons, dx, dy, wheel ?? 0, pan ?? 0),
    },
    glasses: {
      state: () => call<GlassesState>("glasses.state"),
      pair: () => call<"started" | "unavailable">("glasses.pair"),
      forget: () => call<GlassesState>("glasses.forget"),
      connect: () => call<boolean>("glasses.connect"),
      disconnect: () => call<GlassesState>("glasses.disconnect"),
      showText: (text) => call<boolean>("glasses.showText", text),
      showImage: (image, dither) => call<boolean>("glasses.showImage", image, dither ?? true),
      clear: () => call<boolean>("glasses.clear"),
      mic: (on) => call<boolean>("glasses.mic", on),
      audio: (on) => call<boolean>("glasses.audio", on),
      surface: (on) => call<boolean>("glasses.surface", on),
      reload: () => call("glasses.reload"),
      option: (name, value) => call<boolean>("glasses.option", name, value ?? null),
    },
    health: {
      status: () => call<HealthStatus>("health.status"), // detect
      grant: () => call<HealthStatus>("health.grant"), // detect
      read: (types, sinceMs, untilMs) => call<HealthRecord[]>("health.read", types, sinceMs, untilMs ?? null), // detect
      token: (types) => call<{ token: string }>("health.token", types), // detect
      changes: (types, token) =>
        call<{ token: string; records: HealthRecord[]; deleted: string[]; expired: boolean }>("health.changes", types, token), // detect
    },
    notifications: {
      list: () => call<NotificationList>("notifications.list"),
      open: (key) => call("notifications.open", key),
      dismiss: (key) => call("notifications.dismiss", key),
      clearAll: () => call("notifications.clearAll"),
      access: () => call("notifications.access"),
      action: (key, index, text) => call("notifications.action", key, index, text ?? null),
    },
    lock: { unlock: () => call("lock.unlock"), mark: (step) => call("lock.mark", step).catch(() => {}) }, // detect: lock.mark - timing only, an older APK lacks it
    pad: {
      state: () => call<boolean>("pad.state"),
      overlay: (on) => call<boolean>("pad.overlay", on),
      edit: () => call<boolean>("pad.edit"),
    },
    media: {
      state: () => call<MediaState>("media.state"),
      control: (command, pkg) => call("media.control", command, pkg ?? ""),
      seek: (pkg, seconds) => call("media.seek", pkg ?? "", seconds),
      output: (pkg) => call("media.output", pkg ?? ""),
    },
    qs: {
      destinations: () => call<NativeSetting[]>("qs.destinations").catch(() => []), // detect: older APKs have no native settings catalog
      state: () => call<QuickState>("qs.state"),
      toggle: (name) => call<QuickState>("qs.toggle", name),
      open: (name) => call("qs.open", name),
      set: (name, value) => call<QuickState>("qs.set", name, value),
      listening: (on) => call("qs.listening", on),
    },
    panels: { open: (kind) => call("panels.open", kind), closed: () => call("panels.closed") },
    shade: {
      closed: () => call("shade.closed"),
      expand: () => call("shade.expand"),
      peekHeight: (px) => call("shade.peekHeight", px),
      blur: (dp) => call("shade.blur", dp),
      behind: (q) => call("shade.behind", q),
      homePull: (on, exclude, mainPage, regions) =>
        call<boolean>("shade.homePull", on, exclude ?? null, mainPage ?? false, regions ?? null),
      open: () => call("shade.open"),
    },
    overlay: {
      closed: () => call("overlay.closed"),
    },
    pull: {
      closed: () => call("pull.closed"),
      launched: () => call("pull.launched"),
      open: (kind, how) => call<boolean>("pull.open", kind, how ?? {}),
      drive: (phase, arg) => call<boolean>("pull.drive", phase, arg ?? null),
      homePull: (on, exclude, split, regions) =>
        call<boolean>("pull.homePull", on, exclude ?? null, split ?? false, regions ?? null),
    },
    windows: {
      list: () => call<DesktopWindow[]>("windows.list"),
      activate: (id) => call<boolean>("windows.activate", id), // host: panel (the Qt desktop host serves it; never the Android app)
      minimize: (id) => call<boolean>("windows.minimize", id), // host: panel (the Qt desktop host serves it; never the Android app)
      close: (id) => call<boolean>("windows.close", id), // host: panel (the Qt desktop host serves it; never the Android app)
    },
    desktops: {
      list: () => call<VirtualDesktop[]>("desktops.list"), // host: panel (the Qt desktop host serves it; never the Android app)
      setCurrent: (index) => call<boolean>("desktops.setCurrent", index), // host: panel (the Qt desktop host serves it; never the Android app)
      ensure: (count) => call<VirtualDesktop[]>("desktops.ensure", count), // host: panel (the Qt desktop host serves it; never the Android app)
    },
    panel: { height: (px) => call("panel.height", px) }, // host: panel (the Qt desktop host serves it; never the Android app)
    // The phone's floating windows; on the desktop host "windows.list" is the taskbar's (DesktopWindow[]).
    floating: host.name === "powos" ? undefined : {
      list: () => call<AppWindow[]>("windows.list"),
      restore: (id: number) => call<boolean>("windows.restore", id),
      desktop: (hide: number[]) => call<boolean>("windows.desktop", hide),
      minimise: (id: number) => call<boolean>("windows.minimise", id),
      maximise: (id: number) => call<boolean>("windows.maximise", id),
      area: (barTop: number) => call<boolean>("windows.area", barTop),
      slide: (op: string, data?: unknown) => call<boolean>("windows.slide", op, data ?? null),
    },
    // Web windows (ui/webwindows.tsx): the phone's only.
    webwindows: host.name === "powos" ? undefined : {
      enabled: () => call<boolean>("webwindows.enabled"),
      open: (key, rect, task, kwin) => call<number>("webwindows.open", key, rect, task ?? -1, kwin ?? -1),
      input: (id, action, at) => call<boolean>("webwindows.input", id, action, at.x, at.y, at.finger ?? 0),
      close: (id) => call<boolean>("webwindows.close", id),
      fullScreen: (id) => call<boolean>("webwindows.fullScreen", id),
      toWindow: (id) => call<boolean>("webwindows.toWindow", id),
      minimise: (id) => call<boolean>("webwindows.minimise", id),
      restore: (id) => call<boolean>("webwindows.restore", id),
    },
    tasks: {
      list: () => call<RecentTask[]>("tasks.list"),
      open: (id, from) => call<boolean>("tasks.open", id, from ?? null),
      remove: (id) => call<boolean>("tasks.remove", id),
      split: (first, second) => call<boolean>("tasks.split", first, second),
      openSplit: (first, second) => call<boolean>("tasks.openSplit", first, second),
      float: (id) => call<boolean>("tasks.float", id),
      desktopWindow: (id, on = true) => call<boolean>("tasks.desktopWindow", id, on),
      info: (id) => call<boolean>("tasks.info", id),
      screenshot: (id) => call<string | null>("tasks.screenshot", id),
      toWindow: (id) => call<boolean>("tasks.toWindow", id),
    },
    recents: {
      slot: (rect) => call("recents.slot", rect),
      ready: () => call("recents.ready"),
      closed: () => call("recents.closed"),
      state: () => call("recents.state"),
    },
    assist: {
      screen: () => call<AssistScreen | null>("assist.screen"),
      close: () => call("assist.close"),
      attach: (image) => call<string | null>("assist.attach", image),
      live: (on) => call("assist.live", on),
      liveState: () => call("assist.liveState"),
      filmstrip: () => call<string | null>("assist.filmstrip"),
      touchable: (rect) => call("assist.touchable", rect),
    },
    theme: {
      get: () => call<ThemeColors>("theme.get"),
      list: () => call<ThemeChoice[]>("theme.list"),
      pick: (name) => call("theme.pick", name),
    },
    screens: {
      watch: (name) => call("screens.watch", name),
      unwatch: (name) => call("screens.unwatch", name),
      act: (name, action, arg) => call("screens.act", name, action, arg ?? null),
    },
    agents: {
      default: () => call<string | null>("agents.default"),
      newWidget: () => call("agents.newWidget"),
      newApp: () => call("agents.newApp"),
      snapshot: () => call<AgentsDelta>("agents.snapshot"),
      unsubscribe: () => call("agents.unsubscribe"),
      events: (agent) => call("agents.events", agent),
      takeOpen: () => call<boolean>("agents.takeOpen"),
      answer: (ask, behavior, reason) => call("agents.answer", ask, behavior, reason ?? null),
      message: (role, text) => call("agents.message", role, text),
      interrupt: (agent) => call("agents.interrupt", agent),
    },
    speech: {
      start: (hold) => call("speech.start", hold),
      stop: () => call("speech.stop"),
      cancel: () => call("speech.cancel"),
      hold: () => call("speech.hold"),
      warm: () => call("speech.warm"),
      quiet: (ms) => call("speech.quiet", ms),
    },
    keyboard: {
      // Logged like hide: the pull-up panel's search never reached an IME request (2026-10-28).
      show: () => (console.info("keyboard.show from", new Error().stack?.split("\n").slice(2, 4).join(" <- ")), call("keyboard.show")),
      // Who took the keyboard down, in logcat (chromium console): desktop-mode search kept closing it (2026-10-28).
      hide: () => (console.info("keyboard.hide from", new Error().stack?.split("\n").slice(2, 5).join(" <- ")), call("keyboard.hide")),
    },
    haptics: {
      tick: () => call("haptics.tick"),
      confirm: () => call("haptics.confirm"),
    },
    pet: {
      overlay: (on) => call<boolean>("pet.overlay", on ?? null),
    },
    system: {
      insets: () => call("system.insets"),
      display: () => call("system.display"),
      notifications: (open = true) => call("system.notifications", open),
      battery: () => call("system.battery"),
      glass: () => call<GlassSource>("system.glass"),
    },
    on: (event, handler) => events.on(event, handler),
  };
}

function mock(): Bridge {
  const events = new Events();
  // Dev tools (dev/shots.mjs, a desktop browser's console): host events emitted by hand - __mockEvents.emit(name, e).
  (window as unknown as { __mockEvents: Events }).__mockEvents = events;
  const names = [
    "Brave",
    "Calculator",
    "Calendar",
    "Camera",
    "Chrome",
    "Clock",
    "Contacts",
    "Discord",
    "Dolphin",
    "Drive",
    "Files",
    "Firefox",
    "Gmail",
    "Kate",
    "Konsole",
    "Maps",
    "Messages",
    "Netflix",
    "Phone",
    "Photos",
    "Play Store",
    "Settings",
    "Signal",
    "Spotify",
    "Steam",
    "System Settings",
    "Telegram",
    "Terminal",
    "WhatsApp",
    "YouTube",
    "Zoom",
    "Ölwerk",
    "7-Zip",
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
  let chat: Chat = { busy: false, items: [], queued: [] };
  let screen: WidgetScreen = { key: null };
  // The phone-check runner's word (VerifyRun.kt state): checks waiting for a free phone until stopped.
  let mockRunner = "waiting";
  let liveMock = { on: false, frames: 0 };
  const pin = (name: string, x: number, y: number): HomeItem => {
    const a = apps.find((app) => app.label === name)!;
    return {
      key: "app:" + a.key.slice(2),
      kind: "app",
      page: 1,
      cell: { x, y, w: 1, h: 1 },
      resizable: false,
      minSize: [1, 1],
      size: [1, 1],
      label: a.label,
      app: a.key,
    };
  };
  const home: Home = {
    columns: 6,
    pages: [1, 2],
    items: [
      {
        key: "clock.owl",
        kind: "widget",
        page: 1,
        cell: { x: 0, y: 0, w: 6, h: 2 },
        resizable: true,
        minSize: [2, 1],
        size: [6, 2],
        name: "Clock",
      },
      {
        key: "weather.owl",
        kind: "widget",
        page: 1,
        cell: { x: 0, y: 2, w: 3, h: 2 },
        resizable: true,
        minSize: [2, 2],
        size: [3, 2],
        name: "Weather",
      },
      pin("Chrome", 3, 2),
      pin("Signal", 4, 2),
      pin("Spotify", 5, 2),
      {
        key: "monitor.owl",
        kind: "widget",
        page: 2,
        cell: { x: 0, y: 0, w: 4, h: 3 },
        resizable: true,
        minSize: [2, 2],
        size: [4, 3],
        name: "Monitor",
      },
      {
        key: "glance.owl",
        kind: "widget",
        page: 2,
        cell: { x: 4, y: 0, w: 2, h: 3 },
        resizable: true,
        minSize: [2, 2],
        size: [2, 3],
        name: "Glance",
      },
      {
        key: "terminal.owl",
        kind: "widget",
        page: 2,
        cell: { x: 0, y: 3, w: 6, h: 4 },
        resizable: true,
        minSize: [2, 2],
        size: [6, 4],
        name: "Terminal",
      },
    ],
  };
  // The mock's layout lives in the page only; a check that reloads (dev/gate.mjs "add-app") sets "mock.keepHome" in
  // localStorage to keep it there too, as the phone keeps its own.
  const keepHome = (() => {
    try {
      const kept = localStorage.getItem(data("mock.keepHome")) === "1" && localStorage.getItem(data("mock.home"));
      if (kept) Object.assign(home, JSON.parse(kept));
      return localStorage.getItem(data("mock.keepHome")) === "1";
    } catch {
      return false;
    }
  })();
  const homeChanged = () => {
    if (keepHome) localStorage.setItem(data("mock.home"), JSON.stringify(home));
    events.emit("home.changed", null);
  };
  const changed = () => {
    home.pages = [...new Set(home.items.map((i) => i.page))].sort((a, b) => a - b);
    events.emit("home.changed", null);
  };
  return {
    host: "mock",
    chrome: {
      state: async () => ({ kind: new URLSearchParams(location.search).get("mode") === "statusbar" ? "status" : new URLSearchParams(location.search).get("mode") === "windowgrip" ? "grip" : "window", title: "Calculator", maximised: false }),
      ready: async () => {},
      action: async (action) => { console.log("[mock] chrome", action); },
      regions: async () => {},
    },
    apps: {
      list: async () => apps,
      launch: async (key) => {
        console.log("[mock] launch", key);
        if (recent.includes(key)) recent.splice(recent.indexOf(key), 1);
        recent.unshift(key);
      },
      info: async (key) => console.log("[mock] info", key),
      uninstall: async (key) => console.log("[mock] uninstall", key),
      // A few running, Steam frozen (a game asleep with it) and Dolphin frozen (powos-sleep-gui).
      running: async () => ({ "a:chrome": "running", "l:konsole": "running", "a:spotify": "running", "a:signal": "running", "l:dolphin": "frozen", "l:steam": "frozen" }),
      links: async (pkg) => ({ pkg, label: pkg, links: [{ uri: `https://${pkg}.example/item/.*`, activity: ".ItemActivity" }] }),
    },
    usage: { recent: async (limit) => recent.slice(0, limit) },
    home: homeLayout(home, homeChanged, () => apps),
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
    // Android widgets: two made-up providers, drawn as SVG; a tap on one flips it, as a light switch would.
    appWidgets: mockAppWidgets(home, changed, events),
    // Trees captured from real widgets on the phone (dev/sample-trees.json), keyed by the mock home's widgets.
    widgets: {
      watch: async (key, screen) => {
        samples ??= fetch("./dev/sample-trees.json")
          .then((r) => r.json())
          .catch(() => ({}));
        const id = screen ? `${key}#screen` : key;
        events.emit("widget.tree", {
          key,
          screen: !!screen,
          tree: (await samples)[id] ?? terminalTrees[id] ?? null,
        });
      },
      unwatch: async () => {},
      // The mock's widgets with a screen open it on a tap, as their onTap: screen() does.
      tap: async (key) => {
        if (terminalTrees[`${key}#screen`])
          events.emit("widget.screen", (screen = { key, terminal: true, title: key }));
      },
      screen: async () => screen,
      closeScreen: async () => void events.emit("widget.screen", (screen = { key: null })),
      fire: async (key, _screen, id, name, args) => console.log("[mock] fire", key, id, name, args),
      size: async () => {},
      canvas: async () => {},
      page: async () => {},
    },
    // A stand-in that answers after a tool call, as a streamed turn does.
    bar: mockBar(),
    perf: { publish: async () => {}, front: async () => null, native: async (on) => (on ? true : { thresholdMs: 50, blocks: [], frameGaps: [] }), save: async (json) => (console.log("[mock] perf.save", json.length), "/run/powos-app/powos-ai-shared/perf-mock.json") },
    ai: {
      chat: async () => chat,
      send: async function send(text: string): Promise<void> {
        const step = (next: Partial<Chat>) => events.emit("ai.changed", (chat = { ...chat, ...next }));
        // Mid-turn: queued, as PowosAiChat does; the next turn when this one ends.
        if (chat.busy) return void step({ queued: [...(chat.queued ?? []), { id: Date.now(), text }] });
        step({ busy: true, items: [...chat.items, { kind: "user", text }] });
        await new Promise((r) => setTimeout(r, 400));
        step({
          items: [...chat.items, { kind: "tool", name: "Bash", hint: "powos status", ok: null }],
        });
        await new Promise((r) => setTimeout(r, 600));
        const items = chat.items.slice(0, -1);
        step({
          busy: false,
          items: [
            ...items,
            { kind: "tool", name: "Bash", hint: "powos status", ok: true },
            { kind: "assistant", text: `(mock) You asked: ${text}` },
          ],
        });
        const next = chat.queued?.[0];
        if (next) {
          step({ queued: chat.queued!.slice(1) });
          await send(next.text);
        }
      },
      unqueue: async (id) => void events.emit("ai.changed", (chat = { ...chat, queued: (chat.queued ?? []).filter((q) => q.id !== id) })),
      verdict: async (task, works, line) => console.log(`[mock] verdict: ${task} ${works ? "works" : "still broken"}${line ? ` (${line})` : ""}`),
      verifyGo: async (task) => {
        console.log(`[mock] test now: ${task}`);
        if (mockRunner === "paused") mockRunner = "waiting";
      },
      verifyState: async () => events.emit("verify.state", { state: mockRunner, age: 2 }),
      verifyStop: async (dry = false) => {
        if (!dry) mockRunner = "paused";
      },
      open: async () => console.log("[mock] open PowOS AI"),
      newApp: async (description) => {
        const step = (next: Partial<Chat>) => events.emit("ai.changed", (chat = { ...chat, ...next }));
        const thread = { dir: "Projects/new-app-mock", title: "New app", kind: "app" };
        step({ busy: true, thread, items: [{ kind: "user", text: description }] });
        const tool = (hint: string, name = "Bash") => ({ kind: "tool" as const, name, hint, ok: true });
        for (const it of [tool("powos app new notes --name Notes --dir ."), tool("module/src/lib.rs", "Write"), tool("ui/pages/main.tsx", "Write"), tool("powos app install .")]) {
          await new Promise((r) => setTimeout(r, 300));
          step({ items: [...chat.items, it] });
        }
        step({ busy: false, items: [...chat.items, { kind: "assistant", text: "(mock) Notes: a list of notes, in your drawer." }] });
        return true;
      },
      closeThread: async () => (events.emit("ai.changed", (chat = { busy: false, items: [], thread: null })), true),
      mailRead: async (id) => console.log("[mock] mail read", id),
      mailClear: async () => console.log("[mock] all mail read"),
      mail: async () => {
        const now = Math.floor(Date.now() / 1000);
        return [
          {
            id: "m1",
            from: "coder",
            text: "Launcher refactor done - 3 commits pushed to master.",
            time: now - 600,
          },
          {
            id: "m2",
            from: "health",
            text: "Disk at 91% on /var - want me to prune old container images?",
            time: now - 5400,
          },
        ];
      },
      // Two agents: one working (a spinner in its title, as Claude Code shows), one waiting.
      sessions: async () => {
        const now = Math.floor(Date.now() / 1000);
        events.emit("ai.sessions", [
          {
            name: "launcher",
            activity: now - 4,
            attached: true,
            title: "⠂ Port the notification panel",
            path: "/home/powos/Projects/PowOS",
            command: "claude",
          },
          {
            name: "spec-llm",
            activity: now - 2400,
            attached: false,
            title: "✳ Benchmark the fusion backbone",
            path: "/home/powos/Projects/spec-llm",
            command: "claude",
          },
          {
            name: "main",
            activity: now - 9000,
            attached: false,
            title: "powos@localhost:~",
            path: "/home/powos",
            command: "bash",
          },
        ]);
      },
      attach: async (name) => console.log("[mock] attach", name),
    },
    term: mockTerm(events),
    clipboard: {
      read: async () => navigator.clipboard?.readText().catch(() => null) ?? null,
      write: async (text) => void (await navigator.clipboard?.writeText(text).catch(() => {})),
    },
    remote: mockRemote(events),
    glasses: mockGlasses(events),
    lock: { unlock: async () => console.log("[mock] unlock"), mark: async () => {} },
    pad: (() => {
      let on = false;
      return {
        state: async () => on,
        overlay: async (v: boolean) => (on = v),
        edit: async () => (console.log("[mock] controller layout editor"), true),
      };
    })(),
    media: (() => {
      // One session by default; dev/shots.mjs's media scenes emit "media.changed" with none or two.
      const one: MediaState = {
        available: true,
        playing: true,
        title: "Teardrop",
        artist: "Massive Attack",
        app: "Spotify",
        package: "spotify", // the mock's app key is "a:spotify" (its card finds the icon by it)
        position: 42,
        duration: 330,
        art: null,
        seekable: true,
      };
      let st: MediaState = { ...one, sessions: [one] };
      return {
        state: async () => st,
        control: async (command: string, pkg?: string) => {
          const of = (s: MediaState) => (command === "toggle" && (!pkg || s.package === pkg) ? { ...s, playing: !s.playing } : s);
          st = { ...of(st), sessions: st.sessions?.map(of) };
          events.emit("media.changed", st);
        },
        seek: async (pkg: string | undefined, seconds: number) => {
          st = { ...st, sessions: st.sessions?.map((s) => (s.package === pkg ? { ...s, position: seconds } : s)) };
          events.emit("media.changed", st);
        },
        output: async () => console.log("[mock] media output picker"),
      };
    })(),
    qs: (() => {
      const tile = (id: string, label: string, on: boolean | null, detail: string | null = null) => ({
        id,
        label,
        on,
        detail,
      });
      let st: QuickState = {
        torch: false,
        dnd: false,
        tiles: [
          tile("wifi", "Wi-Fi", true),
          tile("bt", "Bluetooth", true),
          tile("cell", "Mobile data", true, "Telenor"),
          tile("flashlight", "Torch", false),
          tile("location", "Location", true),
          tile("airplane", "Airplane mode", false),
          tile("controls", "Device controls", null),
          tile("wallet", "Wallet", null),
          tile("rotation", "Auto-rotate", false),
          tile("dnd", "Do not disturb", false),
          tile("darkmode", "Dark mode", true),
          tile("screenshot", "Screenshot", null),
          tile("screenrecord", "Screen record", null),
          tile("hotspot", "Hotspot", false),
          tile("calculator", "Calculator", null),
          tile("nfc", "NFC", true),
          tile("battery", "Battery saver", false),
          tile("lockscreen", "Lock", null),
          tile("qr_code_scanner", "Scan QR code", null),
          { ...tile("custom(com.coloros.alarmclock/.timer.TimerTileService)", "Timer", null), app: "com.coloros.alarmclock" },
          {
            ...tile("custom(com.oplus.eyeprotect/.services.EyeProtectTileService)", "Eye comfort", null),
            app: "com.oplus.eyeprotect",
          },
          // The phone's other third-party tiles (its sysui_qs_tiles, 2026-10-21).
          { ...tile("custom(com.oneplus.oshare/com.oplus.oshare.OshareTileService)", "OnePlus Share", false), app: "com.oneplus.oshare" },
          { ...tile("custom(com.google.android.gms/.nearby.sharing.SharingTileService)", "Quick Share", null), app: "com.google.android.gms" },
          { ...tile("custom(com.oplus.linker/.synergy.service.TVTileService)", "Screencast", null), app: "com.oplus.linker" },
          { ...tile("custom(com.microsoft.appmanager/.quicksettings.WindowsLinkTileService)", "Link to Windows", null), app: "com.microsoft.appmanager" },
        ],
        brightness: { value: 0.6, auto: true },
        volume: { value: 0.4, ringer: 2 },
      };
      const changed = () => (events.emit("qs.changed", st), st);
      return {
        state: async () => st,
        toggle: async (name: string) => {
          const t = st.tiles.find((t) => t.id === name);
          if (t && t.on != null)
            st = {
              ...st,
              tiles: st.tiles.map((x) => (x === t ? { ...x, on: !x.on } : x)),
            };
          else console.log("[mock] quick action", name);
          if (name === "flashlight" || name === "torch") st = { ...st, torch: !st.torch };
          if (name === "dnd") st = { ...st, dnd: !st.dnd };
          return changed();
        },
        destinations: async () => [
          { id: "settings-search", label: "Search Android settings", keywords: "" }, // Old hosts must not steal unmatched chat text.
          { id: "indexed:settings:display:refresh_rate", label: "Screen refresh rate", keywords: "display brightness motion", breadcrumb: "Display & brightness", package: "settings", app: "Settings" },
          { id: "settings:VPN_SETTINGS", label: "VPN", keywords: "virtual private network tunnel", package: "settings", app: "Settings" },
          { id: "settings:WIFI_SETTINGS", label: "Wi-Fi", keywords: "wifi wireless internet", package: "settings", app: "Settings" },
          { id: "settings:BLUETOOTH_SETTINGS", label: "Bluetooth", keywords: "pairing devices", package: "settings", app: "Settings" },
          { id: "settings:ACCESSIBILITY_SETTINGS", label: "Accessibility", keywords: "talkback screen reader", package: "settings", app: "Settings" },
        ],
        open: async (name: string) => console.log("[mock] open quick setting", name),
        listening: async (on: boolean) => console.log("[mock] tiles listening", on),
        set: async (name, value) => {
          if (name === "brightness") st = { ...st, brightness: { value, auto: false } };
          if (name === "auto-brightness") st = { ...st, brightness: { ...st.brightness, auto: value > 0 } };
          if (name === "volume") st = { ...st, volume: { ...st.volume, value } };
          if (name === "ringer")
            st = {
              ...st,
              volume: { ...st.volume, ringer: Math.round(value * 2) },
            };
          return changed();
        },
      };
    })(),
    panels: { open: async () => {}, closed: async () => {} },
    shade: {
      closed: async () => console.log("[mock] shade closed"),
      expand: async () => console.log("[mock] shade expanded"),
      peekHeight: async (px) => console.log("[mock] banner height", px),
      blur: async (dp) => console.log("[mock] shade blur", dp),
      behind: async () => {},
      // The gate reads the last regions home excluded from the host's pulls (W-IN1: they follow the windows).
      homePull: async (...args: unknown[]) => (((globalThis as { __homePullRegions?: unknown }).__homePullRegions = args[3] ?? null), true),
      open: async () => console.log("[mock] shade open"),
    },
    overlay: { closed: async () => console.log("[mock] overlay closed") },
    pull: {
      closed: async () => console.log("[mock] pull closed"),
      launched: async () => console.log("[mock] pull launched"),
    },
    windows: mockWindows(events, icon),
    // The browser has no KWin: one desktop, nothing to switch.
    desktops: {
      list: async () => [{ id: "mock", name: "Page 1", index: 0, current: true }],
      setCurrent: async (index) => index === 0,
      ensure: async () => [{ id: "mock", name: "Page 1", index: 0, current: true }],
    },
    panel: { height: async (px) => console.log("[mock] panel height", px) },
    tasks: mockTasks(icon, hue),
    recents: {
      slot: async () => {},
      ready: async () => {},
      closed: async () => {},
      state: async () => ({ open: false, from: null, tasks: [] }),
    },
    // A screen it was opened over: some text, no screenshot.
    assist: {
      screen: async () => ({
        text: "Inbox\n  Mats - are we still on for tonight?\n  Your order has shipped",
        screenshot: null,
      }),
      close: async () => console.log("[mock] assistant closed"),
      attach: async (image) => `/run/powos-app/powos-ai-shared/screen-mock.${image ? "png" : "jpg"}`,
      live: async (on) => void events.emit("assist.live", (liveMock = { on, frames: on ? 5 : 0 })),
      liveState: async () => liveMock,
      filmstrip: async () => "/run/powos-app/powos-ai-shared/live-mock.jpg",
      touchable: async (rect) => console.log("[mock] touchable", rect),
    },
    // A few made-up notifications; dismissing and clearing work on them.
    notifications: (() => {
      const now = Math.floor(Date.now() / 1000);
      let items: PhoneNotification[] = [
        {
          key: "1",
          app: "Signal",
          icon: null,
          title: "Mats",
          text: "are we still on for tonight?",
          time: now - 120,
          clearable: true,
          profile: null,
          conversation: true,
        },
        {
          key: "2",
          app: "Gmail",
          icon: "data:image/svg+xml," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18"><rect width="18" height="18" rx="5" fill="#d44"/><text x="9" y="13" font-size="11" text-anchor="middle" fill="#fff" font-family="sans-serif">M</text></svg>'),
          title: "Your order has shipped",
          text: "Track your package: it arrives Thursday.",
          time: now - 3600,
          clearable: true,
          profile: null,
        },
        {
          key: "3",
          app: "PowOS AI",
          icon: null,
          title: "coder",
          text: "Finished the launcher refactor - 3 commits pushed.",
          time: now - 7200,
          clearable: true,
          profile: null,
          actions: [
            { title: "Reply", input: true },
            { title: "Mark read", input: false },
          ],
        },
        { key: "4", app: "Gmail", icon: null, title: "Weekly digest", text: "12 new posts in your groups.", time: now - 5400, clearable: true, profile: null },
        { key: "5", app: "Gmail", icon: null, title: "Invoice #4411", text: "Your invoice is ready.", time: now - 9000, clearable: true, profile: null },
        { key: "6", app: "PowOS AI", icon: null, title: "deploy", text: "Search can sit below the dock.", time: now - 300, clearable: true, profile: null },
        { key: "7", app: "PowOS AI", icon: null, title: "deploy", text: "Chat in the drawer is easier to read.", time: now - 900, clearable: true, profile: null },
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
        action: async (key: string, index: number, text?: string) => console.log("[mock] notification action", key, index, text),
      };
    })(),
    // Three of Omarchy's themes; picking one recolors the page as the phone's would.
    theme: (() => {
      const themes: ThemeChoice[] = [
        {
          name: "kanagawa",
          title: "Kanagawa",
          colors: {
            background: "#1f1f28",
            foreground: "#dcd7ba",
            accent: "#7e9cd8",
            red: "#e82424",
            yellow: "#e6c384",
            green: "#98bb6c",
            magenta: "#957fb8",
          },
        },
        {
          name: "tokyo-night",
          title: "Tokyo Night",
          colors: {
            background: "#1a1b26",
            foreground: "#a9b1d6",
            accent: "#7aa2f7",
            red: "#f7768e",
            yellow: "#e0af68",
            green: "#9ece6a",
            magenta: "#bb9af7",
          },
        },
        {
          name: "rose-pine",
          title: "Rosé Pine",
          colors: {
            background: "#faf4ed",
            foreground: "#575279",
            accent: "#56949f",
            red: "#b4637a",
            yellow: "#ea9d34",
            green: "#286983",
            magenta: "#907aa9",
          },
        },
      ];
      let picked = "kanagawa";
      const colors = (): ThemeColors => {
        const c = themes.find((t) => t.name === picked)!.colors;
        const light = picked === "rose-pine";
        const mix = (a: string, pct: number) => `color-mix(in srgb, ${a} ${pct}%, ${c.background})`;
        return {
          name: picked,
          light,
          css: {
            background: c.background,
            surface: mix(c.foreground, 8),
            foreground: c.foreground,
            muted: mix(c.foreground, 55),
            accent: c.accent,
            border: mix(c.foreground, 30),
            red: c.red,
          },
          colors: c,
        };
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
    screens: mockScreens(events),
    agents: {
      default: async () => "Claude",
      newWidget: async () => (console.log("[mock] new widget with claude"), "started" as const),
      newApp: async () => (console.log("[mock] new app with claude"), "started" as const),
      ...mockAgents(events),
    },
    // Hears the same words every time, a word at a time; a tap ends at the "pause" after them.
    // As the native side (SpeechEngines' SessionSlot): one session at a time, a start ends the one before it.
    // window.__speechMock counts them (dev/mic-one-check.js): open must never pass 1.
    speech: (() => {
      const words = "how much battery is left".split(" ");
      let timer = 0;
      let heard = "";
      let held = false;
      const counts = { starts: 0, stops: 0, cancels: 0, superseded: 0, open: 0, maxOpen: 0 };
      (window as unknown as { __speechMock: typeof counts }).__speechMock = counts;
      const state = (listening: boolean) => events.emit("speech.state", { listening, text: heard, error: null });
      const close = () => {
        clearInterval(timer);
        counts.open = 0;
      };
      const done = () => {
        if (!counts.open) return;
        close();
        state(false);
        events.emit("speech.done", { text: heard });
      };
      return {
        start: async (hold: boolean) => {
          counts.starts++;
          if (counts.open) counts.superseded++;
          close();
          counts.open = 1;
          counts.maxOpen = Math.max(counts.maxOpen, counts.open);
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
        stop: async () => (counts.stops++, done()),
        cancel: async () => {
          counts.cancels++;
          close();
          state(false);
        },
        hold: async () => void (held = true),
        warm: async () => {},
        quiet: async () => {},
      };
    })(),
    keyboard: { show: async () => {}, hide: async () => {} },
    // The dev/mock host's touch feedback: a short buzz where the browser has one; window.__hapticsMock counts the calls
    // (dev/gate.mjs launcher-haptics: once per threshold crossing).
    haptics: (() => {
      const counts = { tick: 0, confirm: 0 };
      (window as unknown as { __hapticsMock: typeof counts }).__hapticsMock = counts;
      return {
        tick: async () => void (counts.tick++, navigator.vibrate?.(8)),
        confirm: async () => void (counts.confirm++, navigator.vibrate?.(8)),
      };
    })(),
    pet: {
      overlay: async () => true,
    },
    system: {
      insets: async () => ({
        top: 0,
        bottom: 0,
        left: 0,
        right: 0,
        keyboard: 0,
      }),
      notifications: async (open = true) => (console.log(`[mock] notification shade ${open ? "down" : "up"}`), true),
      battery: async () => ({ level: 76, charging: false }),
      // No wallpaper to frost in a browser: the plain fills (ui/glass.ts's __glass.use() tries one by hand).
      glass: async () => ({ wallpaper: null, blurBehind: false }),
    },
    on: (event, handler) => events.on(event, handler),
  };
}

/** The mock's Android widgets: a light switch and a note card, their frames SVG data URLs. */
const dataTimers = new Map<number, ReturnType<typeof setInterval>>();

/**
 * The bar's host, as ShellBridge keeps it (an older generation refused, every kept write numbered). The browser preview
 * has one page; the gate (dev/bar-sync-check.js) joins two through window.__barHost - one host in node for both, which
 * sends each page's kept writes to the other as "bar.input".
 */
function mockBar(): Bridge["bar"] {
  let v: BarInput | null = null;
  const host = () => (window as unknown as { __barHost?: (op: string, v?: BarInput) => Promise<BarInput | null> }).__barHost;
  return {
    publish: async (next) => {
      const shared = host();
      if (shared) return shared("publish", next);
      if (v && next.gen < v.gen) return v;
      return (v = { ...next, seq: (v?.seq ?? 0) + 1 });
    },
    get: async () => (host() ? host()!("get") : v),
  };
}

function mockAppWidgets(home: Home, changed: () => void, events: Events): Bridge["appWidgets"] {
  const providers: AppWidgetProvider[] = [
    ["com.example.lights/.Switch#0", "Light switch", "Lights", [57, 57], [40, 40], true],
    ["com.example.notes/.Card#0", "Note", "Notes", [250, 110], [110, 57], false],
  ].map(([provider, label, app, sizeDp, minDp, configure]) => ({
    provider: provider as string,
    label: label as string,
    app: app as string,
    package: (provider as string).split("/")[0],
    work: false,
    description: null,
    sizeDp: sizeDp as [number, number],
    minDp: minDp as [number, number],
    configure: configure as boolean,
    preview: frame(label as string, true),
  }));
  const on = new Map<number, boolean>();
  let next = 100;
  function frame(label: string, lit: boolean) {
    const fill = lit ? "#f5c542" : "#444";
    return (
      "data:image/svg+xml," +
      encodeURIComponent(
        `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" rx="22" fill="${fill}"/>` +
          `<text x="50" y="58" font-family="sans-serif" font-size="14" text-anchor="middle">${label}</text></svg>`,
      )
    );
  }
  const url = (id: number) => {
    const item = home.items.find((i) => i.appWidget?.id === id);
    return frame(item?.name ?? "?", on.get(id) ?? false);
  };
  return {
    providers: async () => providers,
    add: async (provider, page, cell) => {
      const p = providers.find((x) => x.provider === provider)!;
      const id = next++;
      home.items.push({
        key: `aw:${id}`,
        kind: "appwidget",
        page,
        cell,
        resizable: true,
        minSize: [1, 1],
        size: null,
        name: p.label,
        appWidget: { id, provider, package: p.package, reconfigurable: false, minDp: p.minDp, resize: "both" },
      });
      changed();
      return "added";
    },
    watch: async (id) => ({ url: url(id), scrolls: false }),
    unwatch: async () => {},
    // A fake step counter: the same tree a real widget's view tree slims to; the count ticks while watched.
    watchData: async (id, on) => {
      clearInterval(dataTimers.get(id));
      dataTimers.delete(id);
      if (!on) return;
      let steps = 4210;
      const push = () => {
        const item = home.items.find((i) => i.appWidget?.id === id);
        events.emit("appwidgets.data", {
          id,
          provider: item?.appWidget?.provider ?? "com.example.steps/.Counter#0",
          at: Date.now(),
          tree: {
            w: 250,
            h: 110,
            texts: [
              { t: "Steps", role: "title", size: 12, b: [12, 8, 60, 16] },
              { t: steps.toLocaleString("en"), role: "value", size: 34, b: [12, 28, 120, 44] },
              { t: "of 8,000", role: "label", size: 12, b: [12, 74, 70, 16] },
            ],
            images: [],
            progress: [{ v: steps, max: 8000, indeterminate: false, b: [12, 94, 226, 6] }],
            lists: [],
            targets: [{ b: [0, 0, 250, 110], label: "Steps" }],
          },
        });
        steps += 17;
      };
      push();
      dataTimers.set(id, setInterval(push, 1000));
    },
    image: async () => null,
    touch: async (id, action) => {
      if (action !== "up") return;
      on.set(id, !(on.get(id) ?? false));
      events.emit("appwidgets.frame", { id, url: url(id), scrolls: false });
    },
    configure: async (id) => console.log("[mock] configure", id),
  };
}

/** The mock's terminal widgets: a shell to type in, and one only shown (its taps are the widget's). */
const terminalTrees: Record<string, unknown> = {
  // As the bundled 45-terminal.owl: the tile only shows the shell; a tap opens it full size (its screen), typing there.
  "terminal.owl": {
    k: "Root",
    id: "r",
    padding: 0,
    tap: true,
    c: [{ k: "Terminal", id: "r.0", p: { session: "main", interactive: false } }],
  },
  "terminal.owl#screen": {
    k: "Root",
    id: "s",
    padding: 0,
    c: [{ k: "Terminal", id: "s.0", p: { session: "main", focus: true } }],
  },
  "glance.owl": {
    k: "Root",
    id: "r",
    padding: 0,
    c: [
      {
        k: "Terminal",
        id: "r.0",
        p: { command: "seq 40", interactive: false, textSize: 9 },
        h: ["onTap"],
      },
    ],
  },
};

/**
 * Recent tasks for the mock: a few apps, each "snapshot" a drawing of a screen in its color; removing one removes it.
 */
/** The desktop's windows in a browser: a few, one active; activating / minimizing them as KWin would. */
function mockWindows(events: Events, icon: (name: string) => string): Bridge["windows"] {
  const w = (id: string, title: string, app: string, appName: string, active = false, minimized = false): DesktopWindow => ({
    id,
    title,
    app,
    appName,
    icon: icon(appName),
    active,
    minimized,
  });
  const list = [
    w("w1", "~/Projects/PowOS : bash - Konsole", "org.kde.konsole", "Konsole", true),
    w("w2", "PowOS - Dolphin", "org.kde.dolphin", "Dolphin"),
    w("w3", "DESKTOP-WEB-SHELL.md - Kate", "org.kde.kate", "Kate"),
    w("w4", "Steam", "steam", "Steam", false, true),
    { ...w("w5", "Chrome", "android-com.android.chrome", "Chrome"), android: true },
    { ...w("w6", "Termux", "android-com.termux", "Termux", false, true), android: true, onPhone: true },
  ];
  const changed = () => events.emit("windows.changed", structuredClone(list));
  const find = (id: string) => list.find((x) => x.id === id);
  return {
    list: async () => structuredClone(list),
    activate: async (id) => {
      const target = find(id);
      if (!target) return false;
      for (const x of list) x.active = x === target;
      target.minimized = false;
      changed();
      return true;
    },
    minimize: async (id) => {
      const target = find(id);
      if (!target) return false;
      target.minimized = !target.minimized;
      target.active = !target.minimized;
      if (target.minimized) for (const x of list) if (x !== target) x.active = false;
      changed();
      return true;
    },
    close: async (id) => {
      const i = list.findIndex((x) => x.id === id);
      if (i < 0) return false;
      list.splice(i, 1);
      changed();
      return true;
    },
  };
}

function mockTasks(icon: (name: string) => string, hue: (name: string) => number): Bridge["tasks"] {
  const shot = (name: string) =>
    "data:image/svg+xml," +
    encodeURIComponent(
      // A stand-in for the app's last frame, as an app looks: a light page, a thin app bar in its colour, grey rows.
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 780"><rect width="360" height="780" fill="#f4f4f5"/>` +
        `<rect y="0" width="360" height="96" fill="hsl(${hue(name)} 35% 45%)"/>` +
        `<text x="24" y="66" font-family="sans-serif" font-size="30" fill="white">${name}</text>` +
        Array.from(
          { length: 7 },
          (_, i) =>
            `<rect x="24" y="${130 + i * 86}" width="${312 - (i % 3) * 60}" height="54" rx="10" fill="#e1e1e4"/>`,
        ).join("") +
        `</svg>`,
    );
  let tasks: RecentTask[] = ["Chrome", "Signal", "Spotify", "Maps", "Terminal", "Gmail"].map((name, i) => ({
    id: 100 + i,
    label: name,
    key: `a:${name.toLowerCase()}`,
    icon: icon(name),
    snapshot: shot(name),
  }));
  return {
    list: async () => tasks.slice(),
    open: async (id) => (console.log("[mock] switch to task", id), tasks.some((t) => t.id === id)),
    remove: async (id) => {
      tasks = tasks.filter((t) => t.id !== id);
      return true;
    },
    split: async (a, b) => (console.log("[mock] split", a, b), true),
    openSplit: async (a, b) => (console.log("[mock] openSplit", a, b), true),
    float: async (id) => (console.log("[mock] float", id), true),
    desktopWindow: async (id, on = true) => (console.log("[mock] desktop window", id, on), true),
    info: async (id) => (console.log("[mock] info", id), true),
    screenshot: async (id) => (console.log("[mock] screenshot", id), "Screenshot_mock.jpg"),
  };
}

/**
 * Terminals for the mock: a tiny line-editing shell instead of a pty (echo, seq, size, colors, mouse, exit), with the host's
 * protocol - base64 both ways, output offsets, runs - so the page's terminal code runs as on the phone.
 */
/**
 * A shell as it's used, for the widget preview (dev/preview/data/45-terminal*.json "term"): "full" - ls, a git status
 * with changes, a log, a line long enough to wrap and a journal that runs past any tile's height; "short" - one command
 * and the prompt. Lines end CR LF, colours as a shell prints them.
 */
function mockTranscript(kind: string) {
  const p = (dir: string) => `\x1b[32mmats@phone\x1b[0m:\x1b[34m${dir}\x1b[0m$ `;
  if (kind === "short") return `${p("~")}uptime\r\n 23:41:07 up 16:36,  2 users,  load average: 0.42, 0.51, 0.47\r\n${p("~")}`;
  const lines = [
    `${p("~")}ls`,
    "\x1b[34mDocuments\x1b[0m  \x1b[34mDownloads\x1b[0m  \x1b[34mProjects\x1b[0m  notes.md  todo.txt",
    `${p("~")}cd Projects/powos && git status`,
    "On branch worktree-powos-multiplatform",
    "Your branch is up to date with 'origin/worktree-powos-multiplatform'.",
    "",
    "Changes not staged for commit:",
    '  (use "git add <file>..." to update what will be committed)',
    "\t\x1b[31mmodified:   shell/ui/owl.tsx\x1b[0m",
    "\t\x1b[31mmodified:   shell/dev/preview/baseline.json\x1b[0m",
    "",
    'no changes added to commit (use "git add" and/or "git commit -a")',
    `${p("~/Projects/powos")}git log --oneline -6`,
    "\x1b[33mc5d21b8\x1b[0m Example widgets fit with real data at every size they allow",
    "\x1b[33m696a0d1\x1b[0m OWL widget text follows the theme",
    "\x1b[33m8409d27\x1b[0m Agents widget fills its tile at every size, empty included",
    "\x1b[33m64893c3\x1b[0m home: a widget's slider or drag control wins over the page swipe",
    "\x1b[33m5e597b3\x1b[0m powos app preview <dir|file.owl|widget-id>",
    "\x1b[33m36116ff\x1b[0m Pet physics: left/top pinned to 0 while it's on",
    `${p("~/Projects/powos")}head -c 300 README.md`,
    "PowOS is a layered Linux that runs from RAM, keeps what you install and configure in a layer of its own and rolls each layer back on its own when an update or a package breaks something - the OS stays yours, the changes stay undoable.",
    `${p("~/Projects/powos")}journalctl --user -n 40 --no-pager`,
    ...Array.from({ length: 40 }, (_, i) => {
      const t = `Oct 21 23:${String(10 + Math.floor(i / 2)).padStart(2, "0")}:${String((i * 17) % 60).padStart(2, "0")}`;
      const what = [
        "powos-agentsd[812]: spool: 3 agents, 1 working",
        "pipewire[1204]: client 51 connected",
        "kwin_wayland[901]: output DSI-1 mode 2440x2268@120, scale 2.75, adaptive sync on, the cover display DSI-0 asleep",
        "powos-shell[1330]: home: 0 frames at rest",
        "systemd[1]: Started powos-apps-cargo.service - the app builder's cache volume, mounted for 2 builds of local.lights and local.shopping",
      ][i % 5];
      return `${t} cph2551 ${what}`;
    }),
    p("~/Projects/powos"),
  ];
  return lines.join("\r\n");
}

function mockTerm(events: Events): Bridge["term"] {
  const utf8 = new TextEncoder();
  const b64 = (bytes: Uint8Array) => btoa(Array.from(bytes, (b) => String.fromCharCode(b)).join(""));
  const unb64 = (s: string) => new TextDecoder().decode(Uint8Array.from(atob(s), (c) => c.charCodeAt(0)));
  interface Shell {
    run: number;
    out: number[];
    line: string;
    cols: number;
    rows: number;
    code: number | null;
  }
  const shells = new Map<string, Shell>();
  let runs = 0;
  const state = (sh: Shell): TermState => ({
    running: sh.code == null,
    code: sh.code,
    run: sh.run,
    history: b64(Uint8Array.from(sh.out)),
    end: sh.out.length,
  });
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
    else if (cmd === "colors")
      print(
        id,
        sh,
        Array.from({ length: 16 }, (_, i) => `\x1b[${i < 8 ? 40 + i : 92 + i}m ${i.toString(16)} `).join("") +
          "\x1b[0m\r\n",
      );
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
        // The widget preview's transcripts (dev/preview: a terminal widget's data "term"): a shell as it's used.
        const t = (window as unknown as { __powosMockTerm?: string }).__powosMockTerm;
        if (t) print(id, sh, mockTranscript(t));
        else print(id, sh, `mock terminal \x1b[2m(${command ?? "login shell"})\x1b[0m\r\n` + prompt);
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
    style: async () => ({
      size: 13,
      pad: 6,
      fontScale: 1,
      family: "JetBrainsMono Nerd Font",
      font: false,
    }),
  };
}

export const powos: Bridge =
  window.powos ??
  // The desktop's host (powos-shell) has fewer areas natively; hosts/desktop.ts adds the ones kept in the page (its
  // own desktop-wide grid). The phone's (and the mock): two of home's pages side by side when unfolded (hosts/wide.ts).
  (window.PowosHost ? (window.PowosHost.name === "powos" ? desktop(native(window.PowosHost)) : wide(native(window.PowosHost))) : wide(mock()));

/**
 * The mock's agents (as the design's §1.3 sketch): the manager on the phone, a coder on the Mac with two subagents,
 * devops idle; the coder's step moves every few seconds while a page is subscribed, as "agents.delta" brings it.
 */
function mockAgents(
  events: Events,
): Pick<Bridge["agents"], "snapshot" | "unsubscribe" | "events" | "takeOpen" | "answer" | "message" | "interrupt"> {
  const now = Date.now();
  const row = (
    id: string,
    role: string,
    state: Agent["state"],
    title: string,
    step: string,
    ago: number,
    parent: string | null = null,
    subs = 0,
  ): Agent => ({
    id,
    host: id.split(":")[0],
    role,
    parent,
    state,
    title,
    step,
    cwd: "PowOS",
    pid: 0,
    subs,
    unread: 0,
    report: state === "idle" ? "design drafted, waiting on the survey" : "",
    started: now - 3_600_000,
    last: now - ago,
    rev: 1,
  });
  const agents: Agent[] = [
    row("phone:m1", "manager", "idle", "ship widgets", "", 120_000),
    row("mac:c1", "coder", "working", "hosted widgets", "Edit ShellBridge.kt", 12_000, "@manager", 2),
    row("mac:c1/a1", "Explore", "working", "find FileObserver users", "Grep", 4_000, "mac:c1"),
    row("mac:c1/a2", "general-purpose", "working", "survey SpaceTimeAI", "Read console-views.ts", 9_000, "mac:c1"),
    { ...row("mac:c1/a3", "general-purpose", "gone", "fix hook labels", "", 600_000, "mac:c1"), sha: "abc1234", started: Date.now() - 1_200_000 },
    row("phone:d1", "devops", "idle", "prune old images", "", 3_600_000, "@manager"),
  ];
  const steps = ["Edit grid.tsx", "compiling", "Read types.ts", "Edit ShellBridge.kt"];
  let timer = 0;
  let n = 0;
  const ring = (agent: string): AgentEvent[] =>
    ["Read", "Bash", "Edit", "Grep"].map((name, i) => ({
      id: i + 1,
      agent,
      ts: now - (4 - i) * 30_000,
      kind: "tool",
      name,
      hint: steps[i].split(" ").slice(1).join(" "),
      ok: i !== 1,
      n: i ? 1 : 6,
      ms: 200 * i,
    }));
  return {
    snapshot: async () => {
      clearInterval(timer);
      timer = window.setInterval(() => {
        // The gate's idle check (dev/gate.mjs): the mock's own news would be a change, not idle drawing.
        if ((window as { __powosMockQuiet?: boolean }).__powosMockQuiet) return;
        const c = { ...agents[1], step: steps[n++ % steps.length], last: Date.now(), rev: agents[1].rev + 1 };
        agents[1] = c;
        events.emit("agents.delta", { agents: [c] });
      }, 4000);
      return {
        full: true,
        agents,
        tasks: [
          { id: "mac:c1#1", agent: "mac:c1", subject: "read context", status: "done", order: 0, updated: now },
          {
            id: "mac:c1#2",
            agent: "mac:c1",
            subject: "write the widget",
            status: "in_progress",
            order: 1,
            updated: now,
          },
          { id: "mac:c1#3", agent: "mac:c1", subject: "commit", status: "open", order: 2, updated: now },
        ],
        messages: [
          {
            id: "1",
            from: "manager",
            to: "coder",
            kind: "message",
            priority: "normal",
            ts: now - 2_400_000,
            body: "task: agents view",
            read: true,
          },
          {
            id: "2",
            from: "coder",
            to: "manager",
            kind: "message",
            priority: "normal",
            ts: now - 60_000,
            body: "report: design + goodies",
            read: false,
          },
        ],
        asks: [],
      };
    },
    unsubscribe: async () => clearInterval(timer),
    events: async (agent) => {
      if (agent) setTimeout(() => events.emit("agents.delta", { eventsOf: agent, events: ring(agent) }));
    },
    takeOpen: async () => false,
    answer: async (ask, behavior, reason) => console.log("[mock] answer", ask, behavior, reason),
    message: async (role, text) => console.log("[mock] message", role, text),
    interrupt: async (agent) => console.log("[mock] interrupt", agent),
  };
}

type RemoteState = import("./types.ts").RemoteState;

/**
 * Glasses in a desktop browser: a pretend G2 pair, connected; what's shown goes to the console (the glasses page,
 * index.html?mode=glasses, shows its own frame on screen, and keys stand in for the touch bars: surface.tsx).
 */
function mockGlasses(events: Events): Bridge["glasses"] {
  const arm = (side: string, phase: string) => ({ address: `AA:BB:CC:DD:EE:0${side === "L" ? 1 : 2}`, name: `Even G2_84_${side}_8AF0B1`, phase });
  const state: GlassesState = {
    available: true,
    enabled: true,
    paired: { model: "G2", pairId: "G2_84" },
    wanted: true,
    phase: "ready",
    left: arm("L", "ready"),
    right: arm("R", "ready"),
    worn: null,
    shown: true,
    battery: {},
    mic: false,
    error: null,
    canvas: { width: 576, height: 288, bits: 4 },
    image: { verified: false, usable: false },
    options: { g2Raster: false },
  };
  const changed = () => {
    events.emit("glasses.state", structuredClone(state));
    return structuredClone(state);
  };
  const ready = () => state.phase === "ready";
  return {
    state: async () => structuredClone(state),
    pair: async () => (console.log("[mock] glasses pairing dialog"), "started" as const),
    forget: async () => {
      Object.assign(state, { paired: null, left: null, right: null, wanted: false, phase: "off", canvas: null });
      return changed();
    },
    connect: async () => {
      if (!state.paired) return false;
      Object.assign(state, { wanted: true, phase: "ready", left: arm("L", "ready"), right: arm("R", "ready") });
      changed();
      return true;
    },
    disconnect: async () => {
      Object.assign(state, { wanted: false, phase: "off", left: arm("L", "off"), right: arm("R", "off"), mic: false });
      return changed();
    },
    showText: async (text) => (ready() && console.log("[mock] glasses text\n" + text), ready()),
    showImage: async (image) => (ready() && console.log("[mock] glasses image", image.length, "chars"), ready() && state.image.usable),
    clear: async () => (console.log("[mock] glasses cleared"), ready()),
    mic: async (on) => {
      state.mic = on && ready();
      changed();
      return state.mic === on;
    },
    audio: async (on) => on,
    surface: async (on) => on,
    reload: async () => events.emit("glasses.reload", null),
    option: async (name, value) => {
      if (value != null) {
        state.options[name] = value;
        if (name === "g2Raster") state.image.usable = value;
        changed();
      }
      return !!state.options[name];
    },
  };
}

/** Remote input in a desktop browser: a pretend USB cable and a paired laptop; reports go to the console. */
function mockRemote(events: Events): Bridge["remote"] {
  const state: RemoteState = {
    target: null,
    usb: { on: false, busy: false, state: "off", error: null },
    bluetooth: {
      available: true,
      enabled: true,
      registered: false,
      discoverable: false,
      name: "OnePlus Open",
      host: null,
      connecting: null,
      hosts: [{ address: "AA:BB:CC:DD:EE:01", name: "powstation", last: true }],
      error: null,
    },
  };
  const changed = () => {
    events.emit("remote.state", structuredClone(state));
    return structuredClone(state);
  };
  return {
    state: async () => structuredClone(state),
    target: async (t) => {
      state.target = t;
      if (t === "usb") Object.assign(state.usb, { on: true, state: "configured" });
      if (t === "bluetooth") {
        state.bluetooth.registered = true;
        state.bluetooth.host = state.bluetooth.hosts[0];
      }
      return changed();
    },
    off: async (side) => {
      if (side === "usb") Object.assign(state.usb, { on: false, state: "off" });
      else Object.assign(state.bluetooth, { registered: false, host: null });
      if (state.target === side) state.target = null;
      return changed();
    },
    discoverable: async () => {
      state.bluetooth.discoverable = true;
      changed();
    },
    connect: async (address) => {
      state.bluetooth.host = state.bluetooth.hosts.find((h) => h.address === address) ?? null;
      changed();
    },
    disconnect: async () => {
      state.bluetooth.host = null;
      changed();
    },
    keys: async (reports) => console.log("[mock] keys", JSON.stringify(reports)),
    mouse: async (buttons, dx, dy, wheel, pan) => console.log("[mock] mouse", buttons, dx, dy, wheel ?? 0, pan ?? 0),
  };
}
