/**
 * The screens' host (ShellScreens.kt) for a desktop browser (bridge.ts's mock): sample settings, themes, widgets and
 * packages, so screens.tsx runs without the phone. Taps change the samples where it's simple (a theme picked, a flag
 * flipped) and are logged otherwise.
 */
import type { Bridge } from "./types.ts";

type Emitter = { emit(event: string, data: unknown): void };

const svg = (bg: string, fg: string, text: string) =>
  `data:image/svg+xml,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200"><rect width="320" height="200" fill="${bg}"/><text x="20" y="110" font-family="monospace" font-size="28" fill="${fg}">${text}</text></svg>`)}`;

const THEMES = [
  { name: "kanagawa", title: "Kanagawa", colors: { background: "#1f1f28", foreground: "#dcd7ba", accent: "#7e9cd8", red: "#e82424", green: "#76946a", yellow: "#c0a36e" } },
  { name: "tokyo-night", title: "Tokyo Night", colors: { background: "#1a1b26", foreground: "#a9b1d6", accent: "#7aa2f7", red: "#f7768e", green: "#9ece6a", yellow: "#e0af68" } },
  { name: "gruvbox", title: "Gruvbox", colors: { background: "#282828", foreground: "#ebdbb2", accent: "#d79921", red: "#cc241d", green: "#98971a", yellow: "#d79921" } },
  { name: "catppuccin-latte", title: "Catppuccin Latte", colors: { background: "#eff1f5", foreground: "#4c4f69", accent: "#1e66f5", red: "#d20f39", green: "#40a02b", yellow: "#df8e1d" } },
].map((t) => ({ ...t, preview: svg(t.colors.background, t.colors.accent, t.title) }));

const AGENTS = [
  { bin: "claude", name: "Claude Code", description: "Anthropic's coding agent", installed: true, job: null },
  { bin: "opencode", name: "OpenCode", description: "an open source coding agent", installed: false, job: null },
  { bin: "codex", name: "Codex", description: "OpenAI's coding agent", installed: false, job: null },
];

export function mockScreens(events: Emitter): Bridge["screens"] {
  const linux = { state: "installed" as const };
  const state: Record<string, any> = {
    settings: {
      theme: "Kanagawa",
      linux,
      powos: true,
      agent: "Claude Code",
      updates: { checking: false, checked: Date.now() - 3 * 3600_000, error: null, packages: ["mesa", "firefox"], tools: [], job: null },
      setup: null,
      version: "0.1.0-dev",
    },
    style: {
      current: "kanagawa",
      themes: THEMES,
      complete: true,
      download: { state: "idle", partial: true },
      installing: null,
      source: null,
      own: false,
      builtIn: false,
      background: "1-kanagawa.jpg",
      backgrounds: ["1-kanagawa.jpg", "2-wave.jpg"].map((n, i) => ({ name: n, image: svg(i ? "#223249" : "#16161d", "#dcd7ba", n) })),
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
        image: svg(["#faf4ed", "#2d353b", "#2e3440", "#121212"][i], "#888", title),
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
        preview: svg("#1f1f28", "#7e9cd8", name),
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
    licenses: {
      version: "0.1.0-dev",
      components: [{ name: "Nerd Fonts", use: "symbol font", license: "mit", notice: "Copyright (c) 2014 Ryan L McIntyre", url: "https://www.nerdfonts.com", source: null }],
    },
  };
  const changed = (name: string) => events.emit("screens.state", { name, state: state[name] });
  return {
    watch: async (name) => state[name],
    unwatch: async () => {},
    act: async (name, action, arg) => {
      console.log("[mock] screens", name, action, arg);
      if (name === "style" && action === "apply") {
        state.style.current = arg;
        state.settings.theme = THEMES.find((t) => t.name === arg)?.title ?? null;
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
      } else if (name === "licenses" && action === "text") {
        return "MIT License\n\nPermission is hereby granted, free of charge, …";
      }
      return null;
    },
  };
}
