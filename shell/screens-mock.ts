/**
 * The screens' host (ShellScreens.kt) for a desktop browser (bridge.ts's mock): sample settings, themes, widgets and
 * packages, so screens.tsx runs without the phone. Taps change the samples where it's simple (a theme picked, a flag
 * flipped) and are logged otherwise.
 */
import type { Bridge } from "./types.ts";

type Emitter = { emit(event: string, data: unknown): void };

const svg = (bg: string, fg: string, text: string) =>
  `data:image/svg+xml,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200"><rect width="320" height="200" fill="${bg}"/><text x="20" y="110" font-family="monospace" font-size="28" fill="${fg}">${text}</text></svg>`)}`;

/** Sample theme data (dev/sample-themes.json): theme palettes and preview colours, data rather than UI colour. */
type Palette = Record<"background" | "foreground" | "accent" | "red" | "green" | "yellow", string>;
interface Fixture {
  themes: { name: string; title: string; colors: Palette }[];
  backgrounds: string[];
  backgroundInk: string;
  catalog: string[];
  catalogInk: string;
  widgetPreview: [string, string];
}
/** Without the file (a host serving no dev/), the samples draw unpainted. */
const NO_FIXTURE: Fixture = { themes: [], backgrounds: ["", ""], backgroundInk: "", catalog: ["", "", "", ""], catalogInk: "", widgetPreview: ["", ""] };
const fixture = (): Promise<Fixture> =>
  fetch("./dev/sample-themes.json")
    .then((r) => r.json() as Promise<Fixture>)
    .catch(() => NO_FIXTURE);

const AGENTS = [
  { bin: "claude", name: "Claude Code", description: "Anthropic's coding agent", installed: true, job: null },
  { bin: "opencode", name: "OpenCode", description: "an open source coding agent", installed: false, job: null },
  { bin: "codex", name: "Codex", description: "OpenAI's coding agent", installed: false, job: null },
];

/**
 * A pack's add: a few seconds of download, then unpack, as the host reports them; a removal at once; a cancel stops it.
 * [get] / [put]: the mock's storage state.
 */
function packJobs(get: () => any, put: (storage: unknown) => void) {
  const ticks: Record<string, ReturnType<typeof setInterval>> = {};
  return (name: string, action: string) => {
    const packs = get().packs as { name: string; download: number; installed: boolean; job: unknown }[];
    const set = (job: unknown, installed?: boolean) => put({ packs: packs.map((p) => (p.name === name ? { ...p, job, installed: installed ?? p.installed } : p)) });
    const total = packs.find((p) => p.name === name)?.download ?? 0;
    if (action === "remove") return setTimeout(() => set(null, false), 600);
    if (action === "cancel") {
      clearInterval(ticks[name]);
      return setTimeout(() => set(null), 300);
    }
    let step = 0;
    const tick = (ticks[name] = setInterval(() => {
      step++;
      if (step <= 8) set({ phase: "downloading", done: (total * step) / 8, total });
      else if (step <= 10) set({ phase: "installing", done: (total * (step - 8)) / 2, total });
      else {
        clearInterval(tick);
        set(null, true);
      }
    }, 400));
  };
}

/** "Join your PowStation" (PowStation.kt) on the mock host; returns the join screen's act. */
function joinMock(st: () => Record<string, any>, changed: (name: string) => void) {
  // "Join your PowStation" (PowStation.kt): the hub found after 300 ms, the code after 300 ms more, approved when the
  // page's window.__joinApprove() runs (the gate's join scene stands in for the approver), Leave after 300 ms.
  const join = (next: Record<string, unknown>, after = 0) =>
    setTimeout(() => {
      const s = st();
      s.join = { ...s.join, ...next };
      s.settings = { ...s.settings, join: s.join };
      changed("join");
      changed("settings");
    }, after);
  const w = window as unknown as { __joinApprove?: () => void; __joinAsked?: string[] };
  w.__joinApprove = () => st().join?.phase === "code" && join({ phase: "joined", owner: "Mats", tenant: "default", code: "", linux: "PowOS Linux joined too" });
  const steps: Record<string, (arg: unknown) => [Record<string, unknown>, Record<string, unknown>?]> = {
    standalone: () => [{ phase: "standalone", error: "" }],
    start: () => [{ phase: "finding" }, { phase: "ready", found: true, address: "powstation.pow", owner: "Mats" }],
    ask: (arg) =>
      String(arg).trim() === "nowhere.pow"
        ? [{ phase: "asking", error: "" }, { phase: "ready", error: "couldn't reach nowhere.pow" }]
        : [{ phase: "asking", address: String(arg), error: "" }, { phase: "code", code: "BCDF-GHJK" }],
    cancel: () => [{ phase: "choose", error: "" }],
    leave: () => [{ phase: "leaving" }, { phase: "standalone", owner: "", tenant: "", linux: "" }],
  };
  const joinAct = (action: string, arg: unknown) => {
    (w.__joinAsked ??= []).push(action);
    const [now, later] = (steps[action === "find" ? "start" : action] ?? (() => [{}]))(arg);
    join(now);
    if (later) join(later, 300);
  };
  return joinAct;
}

export function mockScreens(events: Emitter): Bridge["screens"] {
  let state: Record<string, any> = {};
  const ready = fixture().then((f) => (state = sampleState(f)));

  const changed = (name: string) => events.emit("screens.state", { name, state: state[name] });
  const packJob = packJobs(() => state.storage, (storage) => {
    state.storage = storage;
    changed("storage");
  });
  const joinAct = joinMock(() => state, changed);
  return {
    watch: async (name) => {
      await ready;
      return state[name];
    },
    unwatch: async () => {},
    act: async (name, action, arg) => {
      await ready;
      console.log("[mock] screens", name, action, arg);
      if (name === "style" && action === "apply") {
        state.style.current = arg;
        state.settings.theme = (state.style.themes as { name: string; title: string }[]).find((t) => t.name === arg)?.title ?? null;
        changed("style");
      } else if (name === "style" && action === "flag") {
        const [key, on] = arg as [string, boolean];
        state.style.flags = state.style.flags.map((f: { key: string }) => (f.key === key ? { ...f, value: on } : f));
        changed("style");
      } else if (name === "style" && action === "background") {
        state.style.background = arg;
        changed("style");
      } else if (name === "coding" && action === "choose") {
        state.coding.default = arg;
        changed("coding");
      } else if (name === "aur" && action === "query") {
        state.aur.query = arg;
        changed("aur");
      } else if (name === "storage" && (action === "add" || action === "remove" || action === "cancel")) {
        packJob(arg as string, action);
      } else if (name === "settings" && (action === "check" || action === "update")) {
        // PowosUpdates.maybeRun(force): checking, then the run's result (the gate's updates check, dev/updates-check.js).
        const w = window as unknown as { __updatesAsked?: string[] };
        (w.__updatesAsked ??= []).push(action);
        // A new object each time, as the host's JSON is (the page keeps a state it was already handed).
        const put = (updates: Record<string, unknown>) => ((state.settings = { ...state.settings, updates: { ...state.settings.updates, ...updates } }), changed("settings"));
        setTimeout(() => put({ checking: true }), 300);
        setTimeout(() => put({ checking: false, checked: Date.now(), powos: { ...state.settings.updates.powos, summary: "Updated: the home screen" } }), 900);
      } else if (name === "join") {
        joinAct(action, arg);
      } else if (name === "licenses" && action === "text") {
        return "MIT License\n\nPermission is hereby granted, free of charge, …";
      }
      return null;
    },
  };
}

/** PowosUpdates.kt's snapshot on the mock host: a phone without root, or (?updates=rooted) one the ship service updates. */
function powosUpdates() {
  const rooted = new URLSearchParams(location.search).get("updates") === "rooted";
  return { app: "0.1.0-dev", shell: "0123abcde", summary: "PowOS is up to date", rooted, via: rooted ? "ship" : "app", waiting: [] as string[] };
}

/** The screens' sample states, painted from the fixture. */
function sampleState(f: Fixture): Record<string, any> {
  // ?join=choose: a first run that hasn't picked yet (the gate's join scene); otherwise a device already on its own.
  const phase = new URLSearchParams(location.search).get("join") === "choose" ? "choose" : "standalone";
  const join = { phase, address: "powstation.pow", found: false, hub: "Your PowStation", owner: "", code: "", name: "PowOS phone", tenant: "", error: "", linux: "" };
  const linux = { state: "installed" as const };
  const themes = f.themes.map((t) => ({ ...t, preview: svg(t.colors.background, t.colors.accent, t.title) }));
  return {
    join,
    settings: {
      join,
      theme: "Kanagawa",
      linux,
      powos: true,
      agent: "Claude Code",
      // A PowOS phone's card (ShellScreens.powosUpdates): the app's run; ?updates=rooted a rooted phone's (ship service).
      updates: { checking: false, checked: Date.now() - 3 * 3600_000, error: null, packages: [], tools: [], job: null, powos: powosUpdates() },
      setup: null,
      version: "0.1.0-dev",
    },
    style: {
      current: "kanagawa",
      themes,
      complete: true,
      download: { state: "idle", partial: true },
      installing: null,
      source: null,
      own: false,
      builtIn: false,
      background: "1-kanagawa.jpg",
      backgrounds: ["1-kanagawa.jpg", "2-wave.jpg"].map((n, i) => ({ name: n, image: svg(f.backgrounds[i], f.backgroundInk, n) })),
      liveWallpaper: false,
      flags: [
        { key: "icons.monochrome", label: "icons", on: "monochrome", off: "colored", value: false },
        { key: "icons.themed", label: "icon colors", on: "theme", off: "original", value: true },
        { key: "system.theme", label: "system colors", on: "theme", off: "own", value: true },
      ],
      terminal: {
        families: ["JetBrains Mono", "Cascadia Code"],
        family: "JetBrains Mono",
        text: 12,
        presets: [
          { label: "smaller", value: 10 },
          { label: "default", value: 12 },
          { label: "larger", value: 14 },
        ],
        size: "9",
        columns: 55,
      },
      styleFile: "~/.config/omalauncher/style/style.toml",
    },
    themes: {
      loading: false,
      error: null,
      installing: null,
      entries: ["Rose Pine Dawn", "Everforest", "Nord", "Matte Black"].map((title, i) => ({
        title,
        repo: `github.com/someone/omarchy-${title.toLowerCase().replace(/ /g, "-")}-theme`,
        url: `https://github.com/someone/omarchy-${title.toLowerCase().replace(/ /g, "-")}-theme`,
        image: svg(f.catalog[i], f.catalogInk, title),
        installedAs: i === 2 ? "nord" : null,
        inUse: false,
        running: false,
        replaces: null,
      })),
    },
    store: {
      page: 1,
      linux: true,
      repo: "SimonSchubert/omarchy-widgets",
      loading: false,
      error: null,
      categories: ["news", "dev", "productivity", "time", "world", "fun", "home", "system"],
      message: null,
      builtIn: [{ bin: "claude", name: "Claude Code", description: "Anthropic's coding agent", added: false }],
      entries: [
        ["hacker-news", "Hacker News", "news", "4x4"],
        ["github-prs", "GitHub PRs", "dev", "4x2"],
        ["world-clock", "World clock", "time", "4x2"],
        ["btop", "btop", "system", "6x4"],
      ].map(([id, name, category, size], i) => ({
        id: `someone/${id}`,
        name,
        author: "someone",
        version: "1.0.0",
        license: "MIT",
        description: `${name}, on the home screen.`,
        category,
        size,
        owl: 1,
        supported: true,
        needsLinux: i === 3,
        installed: i === 2 ? "1.0.0" : null,
        update: false,
        changed: false,
        busy: null,
        requires: i === 3 ? "pacman: btop" : "",
        commands: i === 3 ? ["btop --utf-force"] : ["http GET https://example.com/feed.json"],
        preview: svg(f.widgetPreview[0], f.widgetPreview[1], name),
      })),
    },
    linux: {
      linux,
      powos: true,
      stages: ["download arch linux", "unpack the system", "configure pacman", "install omarchy's apps"],
      agentsStage: 4,
      size: 3.2 * 2 ** 30,
      agents: AGENTS,
      gpu: { wanted: false, active: false, device: null, job: null },
    },
    coding: { linux, default: "claude", agents: AGENTS },
    aur: {
      linux,
      query: "",
      searching: false,
      packages: [
        { name: "btop", version: "1.4.0-1", description: "A monitor of resources", repo: null, installed: true, core: false, job: null },
        { name: "bash", version: "5.2-1", description: "The GNU Bourne Again shell", repo: null, installed: true, core: true, job: null },
      ],
    },
    // A base install (no root): what rootfs-packs.conf leaves out, sized as the 11-03 split measured.
    storage: {
      packs: [
        { name: "gaming", download: 2.75e9, unpacked: 5.0 * 2 ** 30, installed: false, job: null },
        { name: "apps", download: 2.2e9, unpacked: 5.2 * 2 ** 30, installed: false, job: null },
        { name: "dev", download: 0.23e9, unpacked: 0.8 * 2 ** 30, installed: false, job: null },
        { name: "languages", download: 0.59e9, unpacked: 1.55 * 2 ** 30, installed: true, job: null },
      ],
    },
    licenses: {
      version: "0.1.0-dev",
      components: [{ name: "Nerd Fonts", use: "symbol font", license: "mit", notice: "Copyright (c) 2014 Ryan L McIntyre", url: "https://www.nerdfonts.com", source: null }],
    },
  };}
