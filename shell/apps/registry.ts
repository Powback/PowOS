/**
 * The device's app registry (the powos-registry module, apps/registry): which PowOS apps are installed and the widgets
 * they offer, live. `powos app install` writes it; the launcher reads it here - the edit sheet's list of app widgets,
 * and each placed island's entry (ui/island.tsx). Bindings: vendor/powos-registry.js (generated, see vendor/VERSIONS).
 */
import { DbConnection } from "../vendor/powos-registry.js";
import { useDb, useRows } from "./stdb.ts";

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
