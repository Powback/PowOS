/** Launcher providers return destinations, never execute capabilities while searching. */
import { computed, effect, signal } from "@preact/signals";
import { apps, chatting, closeDrawer, launch, query } from "./state.ts";
import { openScreen, type ScreenName } from "./screens.ts";
import { installedApps, openApp } from "./apps/pages.ts";
import { powos } from "./bridge.ts";
import { net } from "./apps/net.ts";

export interface SearchResult {
  id: string;
  label: string;
  source: string;
  icon?: string;
  keywords?: string;
  open(): void;
}
export interface SearchProvider {
  id: string;
  search(text: string, signal: AbortSignal): SearchResult[] | Promise<SearchResult[]>;
}
const providers = signal<SearchProvider[]>([]);
export function registerSearchProvider(provider: SearchProvider) {
  providers.value = [...providers.value.filter((p) => p.id !== provider.id), provider];
  return () => { providers.value = providers.value.filter((p) => p !== provider); };
}
export function searchRank(text: string, label: string, keywords = "") {
  const words = text.trim().toLocaleLowerCase().split(/\s+/);
  const name = label.toLocaleLowerCase();
  const haystack = `${name} ${keywords.toLocaleLowerCase()}`;
  if (!words.every((w) => haystack.includes(w))) return -1;
  return name.startsWith(text.trim().toLocaleLowerCase()) ? 0 : words.every((w) => name.includes(w)) ? 1 : 2;
}
export const settingDestinations: { screen: ScreenName; label: string; target?: string; keywords?: string }[] = [
  { screen: "settings", label: "Settings", keywords: "preferences system updates" },
  { screen: "settings", label: "Voice", target: "voice", keywords: "speech microphone dictation transcription whisper engine" },
  { screen: "settings", label: "Android settings", target: "android settings", keywords: "wifi bluetooth network phone system" },
  { screen: "settings", label: "System updates", target: "system updates", keywords: "upgrade download check version" },
  { screen: "store", label: "Widget store", keywords: "home widgets install" },
  { screen: "style", label: "Theme", target: "theme", keywords: "appearance style colors colours" },
  { screen: "style", label: "Wallpaper", target: "background", keywords: "background image" },
  ...["folded dock position", "unfolded dock position", "desktop dock position", "recent apps in the drawer", "separate notifications & controls", "control center", "pet", "icon colours", "font"].map((label) => ({ screen: "style" as const, label, target: label, keywords: "settings appearance launcher home docking bottom left right" })),
  { screen: "style", label: "Swipe up panels", target: "swipe up from the left: PowOS AI", keywords: "launcher gestures assistant" },
  ...["swipe up from a bottom corner over apps: apps, PowOS AI", "icon colors", "system colors", "glass", "glass edges", "text"].map((label) => ({ screen: "style" as const, label, target: label, keywords: "settings appearance terminal font size blur liquid gestures" })),
  ...["show handles", "sensitivity"].map((label) => ({ screen: "gestures" as const, label, target: label, keywords: "settings edge gestures swipe" })),
  ...["left", "right"].flatMap((side) => ["handle", "where", "width", "swipe in", "swipe in and up", "swipe in and down", "swipe in and hold", "in and up, hold", "in and down, hold"].map((control) => ({
    screen: "gestures" as const, label: `${side} edge ${control}`, target: `${side} edge/${control}`, keywords: "settings gestures quick tools swipe position size action",
  }))),
  { screen: "gestures", label: "Edge gestures", target: "edge gestures", keywords: "back swipe sensitivity handles" },
  { screen: "linux", label: "Linux", keywords: "install gpu driver" },
  { screen: "coding", label: "Coding agents", keywords: "assistant development" },
  { screen: "aur", label: "Packages", keywords: "install software aur pacman" },
  { screen: "themes", label: "Community themes", keywords: "download appearance" },
  { screen: "licenses", label: "Licenses", keywords: "about version open source" },
];
registerSearchProvider({ id: "settings", search: () => settingDestinations.map((s) => ({
  id: `settings:${s.screen}:${s.target ?? ""}`, label: s.label, source: "Settings", keywords: s.keywords,
  open: () => openScreen(s.screen, s.target),
})) });

// The host lists only pages this device can actually open. Old APKs and non-Android
// hosts can reject/omit discovery without delaying the other providers.
let nativeSettings: { id: string; label: string; keywords: string; breadcrumb?: string }[] = [];
let nativeSettingsFetched = 0;
const nativeSettingsRevision = signal(0);
powos.on("qs.destinations", () => { nativeSettingsFetched = 0; nativeSettingsRevision.value++; });
registerSearchProvider({ id: "android-settings", async search() {
  if (Date.now() - nativeSettingsFetched > 60_000) {
    nativeSettings = await powos.qs.destinations?.() ?? [];
    nativeSettingsFetched = Date.now();
  }
  // No catch-all search action: unmatched text belongs to the launcher chat flow.
  const entries = nativeSettings.filter((entry) => entry.id !== "settings-search");
  return entries.map((entry) => ({
    id: `android-settings:${entry.id}`, label: entry.label, source: entry.breadcrumb ? `Android settings · ${entry.breadcrumb.replaceAll(";", " › ")}` : "Android settings",
    keywords: `${entry.keywords} settings preferences android`,
    open: () => { void powos.qs.open(entry.id); },
  }));
} });

interface CatalogApp { app: string; name: string; enabled: boolean; error?: string; actions?: Record<string, { summary?: string; enabled?: boolean }> }
let catalog: CatalogApp[] = [];
let fetched = 0;
let loading: Promise<void> | null = null;
registerSearchProvider({ id: "app-api", async search(_text, signal) {
  if (!installedApps.value.some((a) => a.id === "local.app-api")) return [];
  if (Date.now() - fetched > 60_000) {
    loading ??= net.fetch("local.app-api", "http://127.0.0.1:3411/apps").then((r) => {
      if (r.status !== 200) throw new Error("App API unavailable");
      const data = r.json<{ apps: CatalogApp[] }>();
      catalog = Array.isArray(data.apps) ? data.apps : [];
      fetched = Date.now();
    }).finally(() => { loading = null; });
    await loading;
  }
  if (signal.aborted) return [];
  return catalog.filter((a) => a.enabled && !a.error).flatMap((a) => Object.entries(a.actions ?? {})
    .filter(([, action]) => action.enabled !== false)
    .map(([id, action]) => ({
      id: `app-api:${a.app}:${id}`, label: id.replace(/[_.-]/g, " "), source: a.name,
      keywords: a.name,
      open: () => openApp("local.app-api", null, { app: a.app, action: id }),
    })));
} });

const extra = signal<SearchResult[]>([]);
export const searchPending = signal(false);
/** What's searched: the pill's text - except in a chat, where it's the next message, never a search (the user, 2026-10-28:
 * "launcher chat refreshes every keypress" - each key ran every provider, and its results re-rendered the launcher). */
/** The shortest text that found nothing (lower case), or "". The user, 2026-10-29: "im typing in the launcherchat and it
 * triggers a search even after no search results" - a new chat message is typed before `chatting` is set, so every key
 * searched again and the launcher swapped between results and the chat. Text that still starts with this is the
 * message, not a search; deleting back to a shorter text (or clearing the pill) searches again. */
const noMatch = signal("");
const searched = computed(() => {
  const q = chatting.value ? "" : query.value.trim();
  return q && noMatch.value && q.toLocaleLowerCase().startsWith(noMatch.value) ? "" : q;
});
export const searchResults = computed(() => {
  const q = searched.value;
  if (!q) return [];
  const entries: SearchResult[] = apps.value.map((a) => ({ id: `app:${a.key}`, label: a.label, source: "Apps", icon: a.icon, open: () => { void launch(a.key); } }));
  // Apps and settings pages come first; App API capabilities (hundreds of "open <url>" actions) are a capped tail so they cannot bury them.
  const tier = (r: SearchResult) => r.id.startsWith("app-api:") ? 1 : 0;
  const ranked = [...entries, ...extra.value].map((r) => ({ r, rank: searchRank(q, r.label, r.keywords) }))
    .filter(({ rank }) => rank >= 0).sort((a, b) => tier(a.r) - tier(b.r) || a.rank - b.rank || a.r.label.localeCompare(b.r.label)).map(({ r }) => r);
  let capi = 0;
  return ranked.filter((r) => !r.id.startsWith("app-api:") || ++capi <= 8).slice(0, 60);
});
export function openSearchResult(result: SearchResult) {
  closeDrawer();
  result.open();
}
// State imports shell UI too; start after the module graph has initialized.
queueMicrotask(() => effect(() => {
  const m = noMatch.value;
  if (m && !query.value.trim().toLocaleLowerCase().startsWith(m)) noMatch.value = "";
}));
queueMicrotask(() => effect(() => {
  const q = searched.value;
  const sources = providers.value;
  nativeSettingsRevision.value;
  const controller = new AbortController();
  extra.value = [];
  searchPending.value = !!q;
  if (!q) return;
  const timer = setTimeout(() => {
    const found = new Map<string, SearchResult[]>();
    let remaining = sources.length;
    const finish = (id: string, results: SearchResult[]) => {
      if (controller.signal.aborted) return;
      found.set(id, results);
      extra.value = [...found.values()].flat();
      searchPending.value = --remaining > 0;
      if (!remaining && !searchResults.peek().length) noMatch.value = q.toLocaleLowerCase();
    };
    if (!remaining) { searchPending.value = false; if (!searchResults.peek().length) noMatch.value = q.toLocaleLowerCase(); }
    for (const provider of sources) {
      let timeout: ReturnType<typeof setTimeout> | undefined;
      try {
        const result = provider.search(q, controller.signal);
        if (Array.isArray(result)) { finish(provider.id, result); continue; }
        Promise.race([result, new Promise<SearchResult[]>((resolve) => { timeout = setTimeout(() => resolve([]), 1800); })])
          .then((results) => finish(provider.id, results), () => finish(provider.id, []))
          .finally(() => clearTimeout(timeout));
      } catch { finish(provider.id, []); }
    }
  }, 100);
  return () => { clearTimeout(timer); controller.abort(); };
}));
