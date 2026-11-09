/**
 * The app library: home's last page, every installed app (Android, Linux, PowOS) in folders - the user's own folders as
 * they are, every other app in a folder of its category. Generated from the apps and home's layout (nothing of it is
 * stored), so it follows installs and removals as the app list does (apps.changed).
 *
 * - A category: Android's own (ApplicationInfo.category, `category`), a Linux app's .desktop Categories
 *   (`categories`), else guessed from its id and label (an APK before the categories came, or an app that says none).
 * - No search field of its own (the user, 2026-10-29): the launcher's pill finds apps.
 * - Tap an app to open it; hold one and drag it onto a home page to put it there (grid.tsx startCarry: the page turns
 *   at the screen's side). Tap a folder's free space for all of it, in the folder popover.
 */
import { computed } from "@preact/signals";
import { Fragment } from "preact";
import { apps, byKey, folder, home } from "../state.ts";
import { AppIcon } from "./apps.tsx";
import { folderName, morphing } from "./folders.tsx";
import type { App } from "../types.ts";
import { Icon } from "./icons.tsx";
import { PackBar, packAction, packCancellable, packDownload, packStatus, usePacks } from "./packs.tsx";

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

/** Helper entries packages add beside the real app (a terminal's client/server, avahi's browsers, v4l tools): System. */
const HELPERS = new Set(["l:footclient", "l:foot-server", "l:bssh", "l:bvnc", "l:avahi-discover", "l:qvidcap", "l:qv4l2"]);

/** The library's category of [a]. */
export function categoryOf(a: App) {
  if (HELPERS.has(a.key)) return "system";
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
  // One entry per name (the same app as an Android and a Linux one shows once).
  const seen = new Set<string>();
  for (const a of apps.value) {
    const name = a.label.trim().toLowerCase();
    if (inOwn.has(a.key) || seen.has(name)) continue;
    seen.add(name);
    const c = categoryOf(a);
    groups.set(c, [...(groups.get(c) ?? []), a]);
  }
  const cats = [...groups.entries()]
    .map(([c, list]) => ({ key: `lib:${c}`, name: NAMES[c] ?? c, apps: list.map(entry).sort(byLabel), own: false }))
    .sort((a, b) => (a.key === "lib:other" ? 1 : b.key === "lib:other" ? -1 : a.name.localeCompare(b.name)));
  return [...own.map((f) => ({ key: f.key, name: folderName(f.key), apps: f.apps!, own: true })), ...cats];
});

/** A card shows its apps in a 2x2 up to this many; more, and it is a full-width card of all of them. */
const SMALL_CARD = 4;

/**
 * A folder on the library: its name and count and EVERY app of it (board: "folder widget clips its apps, page leaves
 * empty space" - 'Other (14)' showed four) - up to four small in a 2x2, more
 * across the page's full width, as many rows as they take, so the page grows with them. A tap anywhere opens it.
 */
function Card({ f }: { f: LibraryFolder }) {
  const wide = f.apps.length > SMALL_CARD;
  return (
    <div class={`lib-card tile ${wide ? "wide" : ""} ${morphing.value === f.key ? "opened" : ""}`} data-key={f.key} onClick={() => (folder.value = f.key)}>
      <div class="lib-name">
        <span>{f.name}</span>
        <span class="lib-count">{f.apps.length}</span>
      </div>
      <div class="lib-icons">
        {f.apps.map((a) => {
          const app = byKey.value.get(a.app);
          return app ? <AppIcon key={a.key} src={app.icon} label={a.label} app={app.key} /> : <div key={a.key} class="app-icon initials">{a.label[0]}</div>;
        })}
      </div>
    </div>
  );
}

/**
 * "Add gaming", beside the Games folder, while a phone without root hasn't got the gaming pack (packs.tsx): a tap adds
 * it, and the card shows the download and unpack live until Steam and the games' runtimes are there; "cancel" stops it.
 */
function AddGamingCard() {
  const gaming = usePacks()?.find((p) => p.name === "gaming");
  if (!gaming || (gaming.installed && !gaming.job)) return null;
  const st = packStatus(gaming);
  return (
    <div class="lib-card tile lib-pack" data-key="pack:gaming" onClick={() => !st.busy && packAction("gaming", "add")}>
      <div class="lib-name">
        <span>{st.busy ? "adding gaming" : "add gaming"}</span>
      </div>
      <div class="lib-pack-body">
        <Icon name="gamepad" size={28} />
        <div class="lib-pack-text">{st.busy || st.failed ? st.text : `Steam, Proton, x86 apps · ${packDownload(gaming)}`}</div>
        {st.busy && <PackBar progress={st.progress} />}
        {packCancellable(gaming) && (
          <button
            type="button"
            class="lib-pack-cancel"
            onClick={(e) => {
              e.stopPropagation();
              packAction("gaming", "cancel");
            }}
          >
            cancel
          </button>
        )}
      </div>
    </div>
  );
}

/**
 * Home's last page: the folders. No search field of its own (the user, 2026-10-29: "We don't need that search apps bar
 * on top of the folder page") - the launcher's pill finds apps.
 */
export function LibraryPage({ here }: { here: boolean }) {
  return (
    <div class={here ? "page library" : "page library away"}>
      <div class="library-scroll">
        <div class="lib-grid">
          {library.value.map((f) => (
            <Fragment key={f.key}>
              <Card f={f} />
              {f.key === "lib:games" && <AddGamingCard />}
            </Fragment>
          ))}
          {!library.value.some((f) => f.key === "lib:games") && <AddGamingCard />}
        </div>
      </div>
    </div>
  );
}
