/**
 * The app library: home's last page, every installed app (Android, Linux, PowOS) in folders - the user's own folders as
 * they are, every other app in a folder of its category. Generated from the apps and home's layout (nothing of it is
 * stored), so it follows installs and removals as the app list does (apps.changed).
 *
 * - A category: Android's own (ApplicationInfo.category, `category`), a Linux app's .desktop Categories
 *   (`categories`), else guessed from its id and label (an APK before the categories came, or an app that says none).
 * - A search field at the top: typed in, the matching apps instead of the folders.
 * - Tap an app to open it; hold one and drag it onto a home page to put it there (grid.tsx startCarry: the page turns
 *   at the screen's side). Tap a folder's free space for all of it, in the folder popover.
 */
import { computed, signal } from "@preact/signals";
import { apps, folder, home } from "../state.ts";
import { AppPress, folderName, type DragOut } from "./folders.tsx";
import type { App } from "../types.ts";

/** ApplicationInfo.CATEGORY_* (0..8) -> the library's category. */
const ANDROID = ["games", "music", "video", "photos", "social", "news", "travel", "productivity", "utilities"];
/** A .desktop file's main categories -> the library's, first match wins. */
const LINUX: [string, string][] = [
  ["Game", "games"],
  ["Audio", "music"],
  ["Video", "video"],
  ["AudioVideo", "video"],
  ["Graphics", "photos"],
  ["Office", "productivity"],
  ["Development", "development"],
  ["Education", "education"],
  ["Science", "education"],
  ["Network", "internet"],
  ["Settings", "system"],
  ["System", "system"],
  ["Utility", "utilities"],
];
/** No category said: a guess from the app's id and label. */
const GUESS: [RegExp, string][] = [
  [/game|steam|nintendo|minecraft|chess|puzzle|broforce/i, "games"],
  [/music|spotify|audio|podcast|radio|sound|tidal|deezer/i, "music"],
  [/video|youtube|netflix|\btv\b|vlc|twitch|plex|jellyfin/i, "video"],
  [/camera|photo|gallery|image|lens/i, "photos"],
  [/signal|whatsapp|telegram|messag|chat|discord|social|facebook|instagram|twitter|reddit|mastodon|mail|contacts|dialer|\bphone\b|sms/i, "social"],
  [/news|feed|rss/i, "news"],
  [/maps|navigation|transit|travel|uber|airbnb|booking/i, "travel"],
  [/docs|sheets|office|calendar|notes|keep|drive|todo|task|pdf/i, "productivity"],
  [/chrome|firefox|browser|brave|vivaldi|opera/i, "internet"],
  [/term|code|\bdev\b|git|shell|ssh|foot/i, "development"],
  [/settings|clock|calculator|files|launcher|system|update|store|vending|weather|powos/i, "utilities"],
];
const NAMES: Record<string, string> = {
  games: "Games",
  music: "Music",
  video: "Video",
  photos: "Photos",
  social: "Social",
  news: "News",
  travel: "Travel",
  productivity: "Productivity",
  internet: "Internet",
  development: "Development",
  education: "Education",
  system: "System",
  utilities: "Utilities",
  other: "Other",
};

/** The library's category of [a]. */
export function categoryOf(a: App) {
  if (a.category != null && ANDROID[a.category]) return ANDROID[a.category];
  const said = new Set((a.categories ?? "").split(";").filter(Boolean));
  const linux = LINUX.find(([c]) => said.has(c));
  if (linux) return linux[1];
  const text = `${a.key} ${a.label}`;
  return GUESS.find(([re]) => re.test(text))?.[1] ?? "other";
}

export type LibraryFolder = { key: string; name: string; apps: { key: string; label: string; app: string }[]; own: boolean };

const entry = (a: App) => ({ key: a.key, label: a.label, app: a.key });
const byLabel = (a: { label: string }, b: { label: string }) => a.label.localeCompare(b.label);

/** The library's folders: the user's own first (as they are), then a category's for every other app, "Other" last. */
export const library = computed<LibraryFolder[]>(() => {
  const own = home.value.items.filter((i) => i.kind === "folder");
  const inOwn = new Set(own.flatMap((f) => f.apps!.map((a) => a.app)));
  const groups = new Map<string, App[]>();
  for (const a of apps.value) {
    if (inOwn.has(a.key)) continue;
    const c = categoryOf(a);
    groups.set(c, [...(groups.get(c) ?? []), a]);
  }
  const cats = [...groups.entries()]
    .map(([c, list]) => ({ key: `lib:${c}`, name: NAMES[c] ?? c, apps: list.map(entry).sort(byLabel), own: false }))
    .sort((a, b) => (a.key === "lib:other" ? 1 : b.key === "lib:other" ? -1 : a.name.localeCompare(b.name)));
  return [...own.map((f) => ({ key: f.key, name: folderName(f.key), apps: f.apps!, own: true })), ...cats];
});

/** The search field's text. */
export const libraryQuery = signal("");
/** A category folder open in the popover (the user's own open as home's folder: state.ts folder). */
export const libraryOpen = signal<string | null>(null);

const matches = computed(() => {
  const q = libraryQuery.value.trim().toLowerCase();
  return q ? apps.value.filter((a) => a.label.toLowerCase().includes(q)).map(entry).sort(byLabel) : null;
});

/** A folder on the library: its name, its first apps to tap at once, the rest a tap on its free space away. */
function Card({ f, onHold }: { f: LibraryFolder; onHold: DragOut }) {
  const open = () => (f.own ? (folder.value = f.key) : (libraryOpen.value = f.key));
  const shown = f.apps.length > 4 ? f.apps.slice(0, 3) : f.apps;
  return (
    <div class="lib-card tile" data-key={f.key} onClick={open}>
      <div class="lib-name">{f.name}</div>
      <div class="lib-icons">
        {shown.map((a) => (
          <AppPress key={a.key} a={a} from={f.own ? f.key : undefined} onHold={onHold} small />
        ))}
        {f.apps.length > 4 && <div class="lib-more">+{f.apps.length - 3}</div>}
      </div>
    </div>
  );
}

/** A category folder open: all of its apps (not renamed: its name is its category's). */
function LibraryPanel({ onHold }: { onHold: DragOut }) {
  const f = library.value.find((x) => x.key === libraryOpen.value && !x.own);
  if (!f) return null;
  const close = () => (libraryOpen.value = null);
  return (
    <div class="folder-scrim" onClick={close}>
      <div class="folder-panel tile sheet pop" data-key={f.key} onClick={(e) => e.stopPropagation()}>
        <div class="folder-name">{f.name}</div>
        <div class="folder-apps">
          {f.apps.map((a) => (
            <AppPress key={a.key} a={a} onHold={onHold} onLeave={close} onLift={close} />
          ))}
        </div>
      </div>
    </div>
  );
}

/** Home's last page: the search field, then the folders (or what the search finds). */
export function LibraryPage({ onHold, here }: { onHold: DragOut; here: boolean }) {
  const found = matches.value;
  return (
    <div class={here ? "page library" : "page library away"}>
      <div class="library-scroll">
        <input
          class="lib-search tile pill"
          type="search"
          placeholder="Search apps"
          aria-label="Search apps"
          value={libraryQuery.value}
          onInput={(e) => (libraryQuery.value = (e.currentTarget as HTMLInputElement).value)}
        />
        {found ? (
          <div class="lib-results">
            {found.map((a) => (
              <AppPress key={a.key} a={a} onHold={onHold} onLeave={() => (libraryQuery.value = "")} />
            ))}
            {!found.length && <div class="lib-none">No app called that</div>}
          </div>
        ) : (
          <div class="lib-grid">
            {library.value.map((f) => (
              <Card key={f.key} f={f} onHold={onHold} />
            ))}
          </div>
        )}
      </div>
      <LibraryPanel onHold={onHold} />
    </div>
  );
}
