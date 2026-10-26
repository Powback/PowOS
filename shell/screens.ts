/**
 * Settings and the screens it opens (ui/screens.tsx): which are open, and each one's state from the host
 * (ShellScreens.kt). They stack - settings, then style over it, then the community themes over that - and Back closes
 * the top one (state.ts back). The host opens one too ("screens.open": Linux when something needs it, coding agents
 * when there's none to run a task).
 */
import { signal } from "@preact/signals";
import { useEffect, useState } from "preact/hooks";
import { powos } from "./bridge.ts";

export type ScreenName = "settings" | "style" | "themes" | "store" | "linux" | "coding" | "aur" | "licenses" | "gestures";

/** The open screens, bottom first; the last one shows. */
export const screens = signal<ScreenName[]>([]);

/** Opens [name] on top (one already open comes up from under the others). */
export function openScreen(name: ScreenName) {
  screens.value = [...screens.value.filter((s) => s !== name), name];
}

/** Closes the top screen (or [name]). False when none was open. */
export function closeScreen(name?: ScreenName): boolean {
  const open = screens.value;
  if (!open.length) return false;
  screens.value = name ? open.filter((s) => s !== name) : open.slice(0, -1);
  return true;
}

export const closeScreens = () => (screens.value = []);

/**
 * What Back does inside the top screen first (a widget's page in the store closes back to the grid): set by that
 * screen while it has something of its own to close.
 */
let inner: (() => void) | null = null;
export function setInnerBack(close: (() => void) | null) {
  inner = close;
}

/** Back (state.ts): the top screen's own first, then the screen. False when no screen was open. */
export function backScreen(): boolean {
  if (!screens.value.length) return false;
  if (inner) {
    const close = inner;
    inner = null;
    close();
    return true;
  }
  return closeScreen();
}

powos.on("screens.open", (e: { name: ScreenName }) => openScreen(e.name));
// A widget from the store went on home: the store goes, as the Compose store did, so it shows.
powos.on("screens.done", (e: { name: ScreenName }) => closeScreen(e.name));

/** [name]'s state while the component using it shows: watched from mount, updated as the host sends it. */
export function useScreen<T>(name: ScreenName): T | null {
  const [state, setState] = useState<T | null>(null);
  useEffect(() => {
    let live = true;
    const off = powos.on("screens.state", (e: { name: string; state: T }) => e.name === name && setState(e.state));
    powos.screens.watch(name).then(
      (s) => live && setState(s as T),
      () => {},
    );
    return () => {
      live = false;
      off();
      powos.screens.unwatch(name);
    };
  }, [name]);
  return state;
}

/** Something tapped on [name]: the host does it (the state that follows comes as "screens.state"). */
export const act = (name: ScreenName, action: string, arg?: unknown) => powos.screens.act(name, action, arg);

// --- what the host sends (ShellScreens.kt)

/** A job's progress (installing an agent, a package, the GPU driver): its last log lines. Null while idle. */
export type Job = { state: "working"; action: string; log: string[] } | { state: "failed"; log: string[] } | null;

export interface LinuxStatus {
  state: "checking" | "none" | "installing" | "failed" | "installed" | "removing";
  stage?: number;
  step?: string;
  progress?: number | null;
  log?: string[];
}

export interface SettingsState {
  theme: string | null;
  linux: LinuxStatus;
  /** PowOS's own Linux session runs (rooted): its apps and agents, not this app's optional Arch. */
  powos: boolean;
  agent: string | null;
  updates: {
    checking: boolean;
    checked: number | null;
    error: string | null;
    packages: string[];
    tools: string[];
    job: Job;
  } | null;
  setup: Job;
  version: string;
}

export interface CodingAgent {
  bin: string;
  name: string;
  description: string;
  installed: boolean;
  job: Job;
}

export interface LinuxScreenState {
  linux: LinuxStatus;
  powos: boolean;
  stages: string[];
  agentsStage: number;
  size: number | null;
  agents: CodingAgent[];
  gpu: { wanted: boolean; active: boolean; device: string | null; job: Job } | null;
}

export interface CodingState {
  linux: LinuxStatus;
  default: string | null;
  agents: CodingAgent[];
}

export interface PackagesState {
  linux: LinuxStatus;
  query: string;
  searching: boolean;
  packages: { name: string; version: string; description: string; repo: string | null; installed: boolean; core: boolean; job: Job }[];
}

export interface StyleState {
  current: string | null;
  themes: { name: string; title: string; colors: Record<string, string>; preview: string }[];
  complete: boolean;
  download: { state: "idle" | "running" | "failed"; megabytes?: number; message?: string; partial: boolean };
  installing: { state: "running"; name: string; megabytes: number } | { state: "failed"; message: string } | null;
  /** Where the current theme came from (github.com/owner/repo), when it's one installed from a repo. */
  source: string | null;
  own: boolean;
  builtIn: boolean;
  background: string | null;
  backgrounds: { name: string; image: string }[];
  liveWallpaper: boolean;
  flags: { key: string; label: string; on: string; off: string; value: boolean }[];
  terminal: {
    families: string[];
    family: string;
    text: number;
    presets: { label: string; value: number }[];
    size: string;
    columns: number;
  } | null;
  styleFile: string;
}

export interface ThemesState {
  loading: boolean;
  error: string | null;
  installing: StyleState["installing"];
  entries: {
    title: string;
    repo: string;
    url: string;
    image: string;
    installedAs: string | null;
    inUse: boolean;
    running: boolean;
    /** What installing it replaces: "own:<title>" (the user's), "omarchy:<title>" (Omarchy's, which comes back). */
    replaces: string | null;
  }[];
}

export interface StoreWidget {
  id: string;
  name: string;
  author: string;
  version: string;
  license: string;
  description: string;
  category: string | null;
  size: string | null;
  owl: number;
  supported: boolean;
  needsLinux: boolean;
  installed: string | null;
  update: boolean;
  changed: boolean;
  busy: string | null;
  requires: string;
  commands: string[];
  preview: string | null;
}

export interface StoreState {
  page: number;
  linux: boolean;
  repo: string;
  loading: boolean;
  error: string | null;
  categories: string[];
  message: { id: string; text: string } | null;
  builtIn: { bin: string; name: string; description: string; added: boolean }[];
  entries: StoreWidget[];
}

export interface LicensesState {
  version: string;
  components: { name: string; use: string; license: string; notice: string; url: string; source: string | null }[];
}
