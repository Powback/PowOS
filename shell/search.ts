/** Launcher providers return destinations, never execute capabilities while searching. */
import { computed, effect, signal } from "@preact/signals";
import { apps, chatting, closeDrawer, launch, query } from "./state.ts";
import { openScreen, type ScreenName } from "./screens.ts";
import { installedApps, openApp } from "./apps/pages.ts";
import { powos } from "./bridge.ts";
import type { NativeSetting } from "./types.ts";
import { net } from "./apps/net.ts";

export interface SearchResult {
  id: string;
  label: string;
  source: string;
  icon?: string;
  keywords?: string;
  /** A setting or an action: the app it belongs to. Shown in the launcher as a list under that app's icon and name
   * (the user, 2026-10-30: "show which app the settings came from"); none for an app itself, which is a grid tile. */
  group?: SearchGroup;
  /** Where it is in its app, for a setting ("Apps › Default apps"). */
  detail?: string;
  open(): void;
}
export interface SearchGroup { id: string; label: string; icon?: string }
/** The launcher app that is [pkg] (an Android app's key is "a:<package>/<activity>[@profile]"), its own profile first. */
function androidApp(pkg: string) {
  const mine = apps.value.filter((a) => a.kind === "android" && a.key.slice(2).split(/[/@]/)[0] === pkg);
  return mine.find((a) => !a.work && !a.clone) ?? mine[0];
}
const POWOS_SETTINGS: SearchGroup = { id: "powos", label: "PowOS settings", icon: "./icons/powos.svg" };
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
  id: `settings:${s.screen}:${s.target ?? ""}`, label: s.label, source: "Settings", keywords: s.keywords, group: POWOS_SETTINGS,
  open: () => openScreen(s.screen, s.target),
})) });

// The host lists only pages this device can actually open. Old APKs and non-Android
// hosts can reject/omit discovery without delaying the other providers.
let nativeSettings: NativeSetting[] = [];
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
  const groups = new Map<string, SearchGroup>();
  return entries.map((entry) => {
    const detail = entry.breadcrumb ? entry.breadcrumb.replaceAll(";", " › ") : undefined;
    const group = settingGroup(entry, groups);
    return {
      id: `android-settings:${entry.id}`, label: entry.label, source: detail ? `${group.label} · ${detail}` : group.label, group, detail,
      keywords: `${entry.keywords} settings preferences android`,
      open: () => { void powos.qs.open(entry.id); },
    };
  });
} });

/** The app [entry] opens in (SettingsSearch.kt: package, its name and picture): the launcher's own icon for it where it's
 * a launcher app, as in the grid. An older host sends none: one "Android settings" group. One per package, in [cache]. */
function settingGroup(entry: NativeSetting, cache: Map<string, SearchGroup>): SearchGroup {
  const pkg = entry.package;
  if (!pkg) return { id: "android", label: "Android settings" };
  let group = cache.get(pkg);
  if (!group) {
    const app = androidApp(pkg);
    cache.set(pkg, group = { id: `android:${pkg}`, label: entry.app || app?.label || pkg, icon: app?.icon ?? entry.appIcon });
  }
  return group;
}

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
  return catalog.filter((a) => a.enabled && !a.error).flatMap((a) => {
    const installed = androidApp(a.app) ?? apps.value.find((x) => x.label.toLocaleLowerCase() === a.name.toLocaleLowerCase());
    const group = { id: `app-api:${a.app}`, label: a.name, icon: installed?.icon };
    return Object.entries(a.actions ?? {})
    .filter(([, action]) => action.enabled !== false)
    .map(([id, action]) => ({
      id: `app-api:${a.app}:${id}`, label: id.replace(/[_.-]/g, " ").trim(), source: a.name, group, detail: action.summary,
      keywords: a.name,
      open: () => openApp("local.app-api", null, { app: a.app, action: id }),
    }));
  });
} });

const extra = signal<SearchResult[]>([]);
export const searchPending = signal(false);
/** What's searched: the pill's text - except in a chat, where it's the next message, never a search (the user, 2026-10-28:
 * "launcher chat refreshes every keypress" - each key ran every provider, and its results re-rendered the launcher). */
/** The pill's text switched to chat because it found nothing. The user, 2026-10-29: "im typing in the launcherchat and it
 * triggers a search even after no search results" - a new chat message is typed before `chatting` is set, so every key
 * searched again and the launcher swapped between results and the chat. Once switched, that input stays chat while it
 * types on from the text that found nothing. Deleting back past it searches again (the user, 2026-10-29: "if I delete
 * so that it should have results it still shows the chat"), as do an empty pill and a different text. Holds that
 * text, "" none. */
const noMatch = signal("");
const related = (q: string, nm: string) => !!nm && !!q && q.startsWith(nm);
/** Searches run after the switch to chat (should stay 0), logged when the input ends for the device check. */
let searchesAfterChat = 0;
const searched = computed(() => {
  const q = query.value.trim();
  return chatting.value || related(q, noMatch.value) ? "" : q;
});
export const searchResults = computed(() => {
  const q = searched.value;
  if (!q) return [];
  const entries: SearchResult[] = apps.value.map((a) => ({ id: `app:${a.key}`, label: a.label, source: "Apps", icon: a.icon, open: () => { void launch(a.key); } }));
  // Apps and settings pages come first; App API capabilities (hundreds of "open <url>" actions) are a capped tail so they cannot bury them.
  // The apps themselves before everything else: they're the grid at the top (the user, 2026-10-30).
  const tier = (r: SearchResult) => r.id.startsWith("app-api:") ? 2 : r.group ? 1 : 0;
  const ranked = [...entries, ...extra.value].map((r) => ({ r, rank: searchRank(q, r.label, r.keywords) }))
    .filter(({ rank }) => rank >= 0).sort((a, b) => tier(a.r) - tier(b.r) || a.rank - b.rank || a.r.label.localeCompare(b.r.label)).map(({ r }) => r);
  // The same thing twice - one setting indexed from two Android sources, an action under two ids - shows once: same
  // app, same name, same place in it.
  const seen = new Set<string>();
  const norm = (s = "") => s.trim().replace(/\s+/g, " ").toLocaleLowerCase();
  let capi = 0;
  return ranked.filter((r) => {
    const key = `${r.group?.id ?? r.id}\u0000${norm(r.label)}\u0000${norm(r.detail)}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return !r.id.startsWith("app-api:") || ++capi <= 8;
  }).slice(0, 60);
});
/** [searchResults] as the launcher shows them: the apps (a grid), then each app's settings and actions under it, the
 * groups in the order of their best match. */
export const searchSections = computed(() => {
  const appsFound: SearchResult[] = [];
  const groups = new Map<string, SearchGroup & { items: SearchResult[] }>();
  for (const r of searchResults.value) {
    if (!r.group) { appsFound.push(r); continue; }
    let g = groups.get(r.group.id);
    if (!g) groups.set(r.group.id, g = { ...r.group, items: [] });
    g.items.push(r);
  }
  return { apps: appsFound, groups: [...groups.values()] };
});
export function openSearchResult(result: SearchResult) {
  closeDrawer();
  result.open();
}
// State imports shell UI too; start after the module graph has initialized.
queueMicrotask(() => effect(() => {
  // query read first, always: a run that returned before reading it would leave the effect with nothing to follow.
  const q = query.value.trim();
  const nm = noMatch.peek();
  if (!nm || related(q, nm)) return;
  console.info(`search-after-chat n=${searchesAfterChat}`);
  noMatch.value = "";
  searchesAfterChat = 0;
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
    if (related(q, noMatch.peek()) || chatting.peek()) searchesAfterChat++;
    const found = new Map<string, SearchResult[]>();
    let remaining = sources.length;
    const finish = (id: string, results: SearchResult[]) => {
      if (controller.signal.aborted) return;
      found.set(id, results);
      extra.value = [...found.values()].flat();
      searchPending.value = --remaining > 0;
      if (!remaining && !searchResults.peek().length) noMatch.value = q;
    };
    if (!remaining) { searchPending.value = false; if (!searchResults.peek().length) noMatch.value = q; }
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
