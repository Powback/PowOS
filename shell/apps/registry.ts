/**
 * The device's app registry (the powos-registry module, apps/registry): which PowOS apps are installed and the widgets
 * they offer, live. `powos app install` writes it; the launcher reads it here - the edit sheet's list of app widgets,
 * and each placed island's entry (ui/island.tsx). Bindings: vendor/powos-registry.js (generated, see vendor/VERSIONS).
 */
import { signal } from "@preact/signals";
import { DbConnection } from "../vendor/powos-registry.js";
import { installedApps } from "./pages.ts";
import { useDb, useRows, watchRows } from "./stdb.ts";

export const REGISTRY = "powos-registry";

export interface RegistryApp {
  id: string;
  name: string;
  version: string;
  database: string;
  tier: number;
  manifest: string;
}

export interface RegistryWidget {
  /** "<app id>/<widget id>" */
  key: string;
  appId: string;
  name: string;
  kind: "island" | "owl" | string;
  entry: string;
  size: string;
  minSize: string;
}

/**
 * An app or widget being built (ui/pending.tsx): written by the build pipeline (lib/apps/powos-compose for widgets)
 * as each step starts and ends, read live here - never written from the shell page itself.
 */
export interface RegistryCreation {
  /** "app:<id>" or "widget:<provisional id>". */
  id: string;
  kind: "app" | "widget" | string;
  title: string;
  status: "running" | "done" | "failed" | string;
  step: string;
  stepIndex: number;
  stepCount: number;
  error: string;
  /** The real app id (or "<app>/<widget>" key) once known; "" until then. */
  appId: string;
}

export interface RegistryCreationStep {
  id: string;
  creationId: string;
  idx: number;
  label: string;
  state: "pending" | "active" | "done" | "failed" | string;
}

export interface RegistryCreationLog {
  id: bigint;
  creationId: string;
  line: string;
}

/** Every creation in flight (or just finished/failed, until discarded), live while a component using it is shown. */
export function useCreations() {
  const db = useDb(REGISTRY, DbConnection);
  const creations = useRows<RegistryCreation>(db, "creation", "SELECT * FROM creation");
  const steps = useRows<RegistryCreationStep>(db, "creation_step", "SELECT * FROM creation_step");
  const logs = useRows<RegistryCreationLog>(db, "creation_log", "SELECT * FROM creation_log");
  return { status: db.status, error: db.error, creations, steps, logs };
}

/** "4x2" -> [4, 2] */
export const cells = (s: string): [number, number] => {
  const [w, h] = s.split("x").map((n) => parseInt(n, 10));
  return [w > 0 ? w : 4, h > 0 ? h : 2];
};

/** The registry, live while a component using it is shown. */
export function useRegistry() {
  const db = useDb(REGISTRY, DbConnection);
  const apps = useRows<RegistryApp>(db, "app", "SELECT * FROM app");
  const widgets = useRows<RegistryWidget>(db, "widget", "SELECT * FROM widget");
  return { status: db.status, error: db.error, apps, widgets };
}

/** The registry's apps into apps/pages.ts installedApps (the drawer, search, recents), live while home shows. */
let watching = false;
export function watchRegistry() {
  if (watching) return;
  watching = true;
  watchRows<RegistryApp>(REGISTRY, DbConnection, "app", "SELECT * FROM app", (rows) => (installedApps.value = rows));
}

/** Every creation row, kept live without a hook (ui/creationwidgets.tsx: home's widget placeholders are plain functions). */
export const creationRows = signal<{ creations: RegistryCreation[]; steps: RegistryCreationStep[]; logs: RegistryCreationLog[] }>({
  creations: [],
  steps: [],
  logs: [],
});
let watchingCreations = false;
export function watchCreations() {
  if (watchingCreations) return;
  watchingCreations = true;
  watchRows<RegistryCreation>(REGISTRY, DbConnection, "creation", "SELECT * FROM creation", (creations) => (creationRows.value = { ...creationRows.value, creations }));
  watchRows<RegistryCreationStep>(
    REGISTRY,
    DbConnection,
    "creation_step",
    "SELECT * FROM creation_step",
    (steps) => (creationRows.value = { ...creationRows.value, steps }),
  );
  watchRows<RegistryCreationLog>(REGISTRY, DbConnection, "creation_log", "SELECT * FROM creation_log", (logs) => (creationRows.value = { ...creationRows.value, logs }));
}
