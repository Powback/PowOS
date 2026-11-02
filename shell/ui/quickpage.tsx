// Quick pages (the user: "we don't need to open the whole Settings... I'd love to use the side launcher to launch e.g.
// Wi-Fi settings this way"): ONE settings page of any app as a compact glass card springing out of what opened it - a
// search row, a side-launcher item, a control center tile's long press. The host (QuickPages.kt / QuickPageRoute.kt)
// starts the page on its own trusted display; the card is a web window (ui/webwindows.tsx renders it with [QuickBar]).
// Not in recents or the dock; Back inside the page navigates, at its root it closes; a tap outside or a swipe down on
// its bar closes; the pop-out (↗) reopens the same page in its app's normal window. Native panels (internet, NFC,
// volume) stay Android's own sheets (docs/DESIGN-LANGUAGE.md).
import { signal } from "@preact/signals";
import { useRef } from "preact/hooks";
import { powos } from "../bridge.ts";
import { Icon, type IconName } from "./icons.tsx";

export interface QuickRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

/** A web window that is a quick page: the host's token (its launch), its page's app, what it springs out of. */
export interface QuickInfo {
  token: string;
  pkg: string;
  anchor?: QuickRect;
  /** Folded: a full-width sheet rising from the bottom (else a ~440 dp card at the anchor). */
  sheet?: boolean;
  /** Where it springs out of: a transform-origin inside the card ([quickPlace]). */
  origin?: string;
}

/** What a quick page opens: a search result's id, a settings ACTION, an exported component or a Settings fragment. */
export interface QuickSpec {
  id?: string;
  action?: string;
  component?: string;
  fragment?: string;
  label?: string;
}

/** The packages that own Settings' pages (OxygenOS moves Wi-Fi, Bluetooth and hotspot into its own): Settings' icon. */
const SETTINGS_PKGS = new Set(["com.android.settings", "com.oplus.wirelesssettings"]);

/**
 * The app keys whose icon a quick page's bar shows, best first: a Settings page's the Settings app's launcher icon, else
 * its own package's (an Android key is "a:<package>/<activity>": webwindows' iconOf matches the package's prefix too).
 */
export function quickIconKeys(pkg: string | undefined): string[] {
  if (!pkg) return [];
  return SETTINGS_PKGS.has(pkg) && pkg !== "com.android.settings" ? ["a:com.android.settings", `a:${pkg}`] : [`a:${pkg}`];
}

/** The card's sizes (CSS px ~ dp): ~440 wide unfolded, at most 70% of the screen high, 16 from every edge. */
export const QUICK = { width: 440, share: 0.7, margin: 16, folded: 600 };

/**
 * The control center tiles whose long press is a quick page, by tile id: a stable settings ACTION (or component),
 * never a search index id (those expire). Side-launcher items store the same.
 */
export const TILE_PAGES: Record<string, QuickSpec> = {
  wifi: { action: "android.settings.WIFI_SETTINGS", label: "Wi-Fi" },
  bt: { action: "android.settings.BLUETOOTH_SETTINGS", label: "Bluetooth" },
  bluetooth: { action: "android.settings.BLUETOOTH_SETTINGS", label: "Bluetooth" },
  hotspot: { component: "com.android.settings/.TetherSettings", label: "Hotspot & tethering" },
  nfc: { action: "android.settings.NFC_SETTINGS", label: "NFC" },
};

/**
 * The settings pages a quick-page item can hold, as an older host (no quickpage.pages) or the dev page has them: each a
 * stable settings ACTION (an Intent action QuickPages.open resolves; never a search index id, those expire). On the phone
 * the list is the device's own ([quickPages], QuickPageCatalog.kt): only the pages it really has, their own names and
 * pictures.
 */
export const QUICK_PAGES: QuickPageInfo[] = [
  { action: "android.settings.WIFI_SETTINGS", label: "Wi-Fi" },
  { action: "android.settings.BLUETOOTH_SETTINGS", label: "Bluetooth" },
  { action: "android.settings.NFC_SETTINGS", label: "NFC" },
  { action: "android.settings.DISPLAY_SETTINGS", label: "Display" },
  { action: "android.settings.SOUND_SETTINGS", label: "Sound" },
  { action: "android.intent.action.POWER_USAGE_SUMMARY", label: "Battery" },
  { action: "android.settings.LOCATION_SOURCE_SETTINGS", label: "Location" },
  { action: "android.settings.APPLICATION_SETTINGS", label: "Apps" },
  { action: "android.settings.INTERNAL_STORAGE_SETTINGS", label: "Storage" },
  { action: "android.settings.ACCESSIBILITY_SETTINGS", label: "Accessibility" },
  { action: "android.settings.DATE_SETTINGS", label: "Date & time" },
  { action: "android.settings.APPLICATION_DEVELOPMENT_SETTINGS", label: "Developer options" },
];

/** A settings page for a quick-page item: its ACTION, its name, the page's own picture (a PNG; [mono]: one colour, tinted). */
export interface QuickPageInfo {
  action: string;
  label: string;
  icon?: string;
  mono?: boolean;
}

/** The pages to offer: the host's (quickpage.pages, this device's own), else [QUICK_PAGES]. */
export const quickPages = signal<QuickPageInfo[]>(QUICK_PAGES);
let pagesRead = false;
/** Reads the device's pages once (the control center's edit mode asks); an older host keeps [QUICK_PAGES]. */
export function loadQuickPages() {
  const read = powos.quickpage?.pages;
  if (pagesRead || !read) return;
  pagesRead = true;
  read().then((l) => Array.isArray(l) && l.length && (quickPages.value = l), () => (pagesRead = false));
}

/**
 * Each page's own glyph (MDI, in the theme's colour) when it has no picture of its own: never the Settings app's gear
 * for every page (the user, 11-02: "real settings icons, not all the gear").
 */
const QUICK_GLYPH: Record<string, IconName> = {
  "android.settings.WIFI_SETTINGS": "wifi",
  "android.settings.BLUETOOTH_SETTINGS": "bluetooth",
  "android.settings.WIRELESS_SETTINGS": "web",
  "android.settings.DATA_USAGE_SETTINGS": "chartDonut",
  "android.settings.VPN_SETTINGS": "vpn",
  "android.settings.NFC_SETTINGS": "nfcVariant",
  "android.settings.DISPLAY_SETTINGS": "brightnessAuto",
  "android.settings.SOUND_SETTINGS": "volumeHigh",
  "android.settings.ZEN_MODE_SETTINGS": "bellOffOutline",
  "android.intent.action.POWER_USAGE_SUMMARY": "battery",
  "android.settings.BATTERY_SAVER_SETTINGS": "leaf",
  "android.settings.LOCATION_SOURCE_SETTINGS": "mapMarker",
  "android.settings.APPLICATION_SETTINGS": "apps",
  "android.settings.ALL_APPS_NOTIFICATION_SETTINGS": "bellOutline",
  "android.settings.INTERNAL_STORAGE_SETTINGS": "harddisk",
  "android.settings.SECURITY_SETTINGS": "shieldLockOutline",
  "android.settings.PRIVACY_SETTINGS": "eyeOffOutline",
  "android.settings.ACCESSIBILITY_SETTINGS": "human",
  "android.settings.INPUT_METHOD_SETTINGS": "keyboardOutline",
  "android.settings.LOCALE_SETTINGS": "translate",
  "android.settings.DATE_SETTINGS": "clockOutline",
  "android.settings.SYNC_SETTINGS": "accountCircleOutline",
  "android.settings.DEVICE_INFO_SETTINGS": "informationOutline",
  "android.settings.APPLICATION_DEVELOPMENT_SETTINGS": "codeBraces",
};

/** A quick-page item's picture: the page's own (as drawn, or one colour tinted with the theme), else its glyph. */
export function QuickFace({ action }: { action: string }) {
  const q = quickPages.value.find((x) => x.action === action);
  if (q?.icon && !q.mono) return <img src={q.icon} alt="" draggable={false} />;
  if (q?.icon) return <span class="qp-mono" style={{ "--qp-mask": `url("${q.icon}")` }} />;
  return <Icon name={QUICK_GLYPH[action] ?? "tuneVariant"} />;
}

/** A quick-page item's stored id ("qp:<ACTION>"), and back: its action, or null (not a quick-page item). */
export const QUICK_ID = "qp:";
export const quickAction = (id: string): string | null => (id.startsWith(QUICK_ID) ? id.slice(QUICK_ID.length) : null);

/** An element's rect as a quick page's anchor (viewport CSS px): it springs out of that item. */
export function rectOf(el: Element): QuickRect {
  const r = el.getBoundingClientRect();
  return { left: r.left, top: r.top, width: r.width, height: r.height };
}

/** The last pressed element's rect (viewport CSS px): a quick page opened by that press springs out of it. */
let pressed: QuickRect | undefined;
if (typeof addEventListener === "function") {
  addEventListener(
    "pointerdown",
    (e) => {
      const t = e.target as Element | null;
      const el = t?.closest?.("button, [role=button], .search-group-row, .scr-row, .tile") ?? t;
      const r = el?.getBoundingClientRect?.();
      if (r && r.width) pressed = { left: r.left, top: r.top, width: r.width, height: r.height };
    },
    { capture: true, passive: true },
  );
}

/**
 * [spec] as a quick page from [anchor] (default: the element just pressed). False: this host has no quick pages (an
 * older APK, the browser) - the caller opens it its old way.
 */
export function openQuickPage(spec: QuickSpec, anchor: QuickRect | undefined = pressed): boolean {
  const q = powos.quickpage;
  if (!q) return false;
  q.open({ ...spec, anchorRect: anchor ?? null }).catch((e: unknown) => console.warn("quickpage: couldn't open", spec, e));
  return true;
}

/**
 * Where the user returns when a quick page's card closes (the user, 11-01: "it's closing when returning back" - Back out
 * of a search result's card landed on bare home): the search it was opened from, as Android's and iOS's settings search
 * do. [opened] arms it for the next card shown (bound to its token by [quickShown]); its close ([quickGone] "closed": its
 * page's own back at its root, Back, the bar's swipe down, a tap outside) runs [restore]; the pop-out (↗), home or a
 * card that never came drop it.
 */
let returnTo: { token?: string; at: number; restore: () => void } | null = null;
/** An armed return no card took within this (a refused card, the host's full-screen net) is stale. */
const RETURN_MS = 5000;

export function returnAfterQuick(restore: () => void) {
  returnTo = { at: Date.now(), restore };
}

/** Quick page [token]'s card is up: an armed return is its. */
export function quickShown(token: string) {
  if (returnTo && returnTo.token == null) {
    if (Date.now() - returnTo.at <= RETURN_MS) returnTo.token = token;
    else returnTo = null;
  }
}

/** Quick page [token]'s card went: [how] "closed" goes back to where it was opened from; "popout" (its app's window) doesn't. */
export function quickGone(token: string, how: "closed" | "popout") {
  const r = returnTo;
  if (!r || r.token !== token) return;
  returnTo = null;
  if (how === "closed") r.restore();
}

/** Home pressed, a card refused: nothing to return to. */
export function forgetQuickReturn() {
  returnTo = null;
}

type Area = { left: number; top: number; right: number; bottom: number };

/**
 * The card's frame (viewport CSS px) in work area [a]: folded ([sheet]) full width minus 16 rising from the bottom (above
 * the bar); unfolded ~440 wide, centred on [anchor] and below it (above it when there's no room), up to 70% of [screenH]
 * high. [origin]: where it springs out of, as a transform-origin inside the card.
 */
export function quickPlace(anchor: QuickRect | undefined, a: Area, sheet: boolean, screenH: number): { x: number; y: number; w: number; h: number; origin: string } {
  const m = QUICK.margin;
  const aw = a.right - a.left - 2 * m;
  const h = Math.max(160, Math.round(Math.min(screenH * QUICK.share, a.bottom - a.top - 2 * m)));
  if (sheet) return { x: a.left + m, y: a.bottom - m - h, w: aw, h, origin: "50% 100%" };
  const w = Math.min(QUICK.width, aw);
  const cx = anchor ? anchor.left + anchor.width / 2 : (a.left + a.right) / 2;
  const x = Math.round(Math.min(Math.max(cx - w / 2, a.left + m), a.right - m - w));
  const y = quickTop(anchor, a, h);
  const ox = anchor ? Math.min(Math.max(cx - x, 0), w) : w / 2;
  const oy = anchor ? (y >= anchor.top ? 0 : h) : 0;
  return { x, y, w, h, origin: `${Math.round(ox)}px ${oy}px` };
}

/** The card's top: below [anchor] when it fits, else above it, else as high as the area lets it be. */
function quickTop(anchor: QuickRect | undefined, a: Area, h: number): number {
  const m = QUICK.margin;
  if (!anchor) return a.top + m;
  const below = anchor.top + anchor.height + 8;
  if (below + h <= a.bottom - m) return Math.round(below);
  const above = anchor.top - 8 - h;
  return Math.round(above >= a.top + m ? above : Math.max(a.top + m, a.bottom - m - h));
}

/** The card's small title bar: its app's icon, the page's name, pop-out and close. A swipe down on it closes. */
export function QuickBar({ label, icon, height, onPopOut, onClose }: { label: string; icon?: string; height: number; onPopOut: () => void; onClose: () => void }) {
  const from = useRef<number | null>(null);
  return (
    <div
      class="webwindow-title quickpage-bar tile"
      style={{ height: `${height}px`, flex: `0 0 ${height}px`, touchAction: "none" }}
      onPointerDown={(e) => ((from.current = e.clientY), e.stopPropagation())}
      onPointerUp={(e) => {
        const y0 = from.current;
        from.current = null;
        if (y0 != null && e.clientY - y0 > 48) onClose();
      }}
      onPointerCancel={() => (from.current = null)}
    >
      <div class="ww-title-label">
        {icon && <img class="ww-icon" src={icon} alt="" draggable={false} />}
        <span>{label}</span>
      </div>
      <div class="ww-spacer" />
      <button type="button" class="quickpage-btn" aria-label="Open in its app" onPointerDown={(e) => e.stopPropagation()} onClick={onPopOut}>
        ↗
      </button>
      <button type="button" class="quickpage-btn" aria-label="Close" onPointerDown={(e) => e.stopPropagation()} onClick={onClose}>
        ✕
      </button>
    </div>
  );
}
