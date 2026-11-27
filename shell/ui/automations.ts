/**
 * Automations (board task automations-triggers-and-actions, docs/research/stock-parity-gaps.md): the user's own "when X,
 * do Y". This is the page's side - the list as Settings > automations edits it (screens.tsx AutomationsScreen) and the
 * words for each trigger and action. The phone's app runs them (Automations.kt: alarms, proximity alerts, receivers),
 * with or without a page, and after a reboot; the page only saves the list and shows each one's last run.
 *
 * A focus mode is the page's state (focus.ts), so an automation's "focus" action reaches it here: told at once
 * ("automations.focus"), or taken on the next start when no page was open.
 */
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { endFocus, modeOf, startFocus } from "./focus.ts";
import type { Automation, AutomationAction, AutomationTrigger } from "../types.ts";

export const automations = signal<Automation[]>([]);
/** This host runs automations (the phone's app; not the desktop's, nor an older APK). */
export const automationsHere = !!powos.automations;

export async function loadAutomations() {
  if (!powos.automations) return;
  try {
    automations.value = (await powos.automations.list()) ?? [];
  } catch (e) {
    console.warn("[automations] list", e);
  }
}

/** The list saved (optimistic: shown at once, the app's answer - with its last-run lines - after). */
export async function saveAutomations(list: Automation[]) {
  const was = automations.value;
  automations.value = list;
  try {
    automations.value = (await powos.automations!.save(list)) ?? list;
  } catch (e) {
    automations.value = was;
    throw e;
  }
}

export const newId = () => `a${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;

export function blankAutomation(): Automation {
  return { id: newId(), name: "", on: true, trigger: { kind: "time", at: "08:00", days: [] }, actions: [{ kind: "notify", title: "Automation", text: "" }] };
}

export const DAYS = ["S", "M", "T", "W", "T", "F", "S"];

function dayWords(days?: number[]): string {
  if (!days?.length || days.length === 7) return "every day";
  const k = [...days].sort().join("");
  if (k === "12345") return "weekdays";
  if (k === "06") return "weekends";
  return days.map((d) => ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d]).join(", ");
}

const placeWords = (t: Extract<AutomationTrigger, { kind: "place" }>) => `${t.when === "leave" ? "leaving" : "arriving at"} ${t.label || "a place"}`;

export function triggerWords(t: AutomationTrigger, appName: (pkg: string) => string = (p) => p): string {
  switch (t.kind) {
    case "time":
      return `at ${t.at}, ${dayWords(t.days)}`;
    case "place":
      return placeWords(t);
    case "app":
      return `${appName(t.pkg) || "an app"} opened`;
    case "charger":
      return `charger ${t.when}`;
    case "bluetooth":
      return `${t.device || "a Bluetooth device"} ${t.when}`;
  }
}

/** Settings' tile line: how many are on. */
export const automationsLine = () => (automations.value.length ? `${automations.value.filter((a) => a.on).length} on` : "when this happens, do that");

export function actionWords(a: AutomationAction, appName: (pkg: string) => string = (p) => p): string {
  switch (a.kind) {
    case "notify":
      return `notify "${a.title}"`;
    case "open":
      return `open ${a.target.includes("://") ? a.target : appName(a.target)}`;
    case "toggle":
      return `${{ wifi: "Wi-Fi", bt: "Bluetooth", dnd: "Do not disturb" }[a.what]} ${a.on ? "on" : "off"}`;
    case "focus":
      return a.mode ? `focus: ${modeOf(a.mode).label}` : "focus off";
    case "appapi":
      return `${a.app}: ${a.action}`;
  }
}

/** "ran 5 min ago: notified" / "never ran". */
export function lastRanLine(a: Automation, now = Date.now()): string {
  if (!a.lastRan) return "never ran";
  const m = Math.round((now - a.lastRan) / 60000);
  const ago = m < 1 ? "just now" : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : new Date(a.lastRan).toLocaleDateString();
  return `ran ${ago}${a.lastResult ? `: ${a.lastResult}` : ""}`;
}

function takeFocus(mode: string | null) {
  if (!mode) return;
  if (mode === "off") endFocus();
  else startFocus(mode);
}

if (powos.automations) {
  powos.on("automations.focus", (mode: string) => {
    takeFocus(mode);
    // Told: the stored one is taken too, so the next page start doesn't apply it again.
    powos.automations?.takeFocus().catch(() => {});
  });
  powos.on("automations.ran", (r: { id: string; result: string }) => {
    automations.value = automations.value.map((a) => (a.id === r.id ? { ...a, lastRan: Date.now(), lastResult: r.result } : a));
  });
  powos.automations.takeFocus().then(takeFocus, () => {});
}
