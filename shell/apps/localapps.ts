/**
 * PowOS apps on a phone without root (docs/research/nonroot-parity.md #2): the apps the launcher has itself - the ones
 * whose built UI ships inside the APK (apps/bundled.list, built and versioned with it) and any installed in the app's
 * files - read from the host (apps.local, shell/LocalApps.kt), not from the powos-registry database. Without root
 * there is no `powos app install` and SpacetimeDB only runs once the PowOS Linux image is installed and up, so the
 * registry alone left every island "…" forever. Also where SpacetimeDB stands ("stdb"), so an island whose app keeps
 * its data there says what it waits for instead of drawing nothing.
 *
 * Rooted phones: the host answers rooted: true and nothing here changes what the registry says (the rooted path is
 * as before). Hosts without the call (the desktop, the mock, an older APK): null, the same.
 */
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { RegistryApp, RegistryWidget } from "./registry.ts";

/** "up": SpacetimeDB answers on 127.0.0.1:3410; "starting": the image is installed, it's on its way; "image": the
 * PowOS Linux image isn't on the phone (the download, [mb]); "missing": the image has no SpacetimeDB (an older one). */
export type StdbState = "up" | "starting" | "image" | "missing";

export interface LocalApps {
  rooted: boolean;
  stdb: StdbState;
  /** The image's download size, MB, when known (stdb "image"). */
  mb: number | null;
  apps: RegistryApp[];
}

export const localApps = signal<LocalApps | null>(null);

let watching = false;
/** Asks the host once, then again every few seconds while SpacetimeDB isn't up (it comes up on its own). */
export function watchLocalApps() {
  if (watching || !powos.apps.local) return;
  watching = true;
  const ask = () =>
    powos.apps.local!().then(
      (l) => {
        localApps.value = l;
        if (!l.rooted && l.stdb !== "up") setTimeout(ask, 3000);
      },
      // An older APK: no such call - the registry only, as before.
      () => {},
    );
  ask();
}

/** The local apps' widgets, as the registry lists them ("<app id>/<widget id>"). */
export function localWidgets(apps: RegistryApp[]): RegistryWidget[] {
  return apps.flatMap((a) => {
    let m: { widgets?: { id: string; name?: string; kind?: string; entry: string; size?: string; minSize?: string }[] };
    try {
      m = JSON.parse(a.manifest);
    } catch {
      return [];
    }
    return (m.widgets ?? []).map((w) => ({
      key: `${a.id}/${w.id}`,
      appId: a.id,
      name: w.name ?? w.id,
      kind: w.kind ?? "island",
      entry: w.entry,
      size: w.size ?? "4x2",
      minSize: w.minSize ?? "2x1",
    }));
  });
}

/** [rows] with the local apps added (no root only): a registry row wins over a local one of the same id. */
export function withLocal<T>(rows: T[], local: T[], id: (t: T) => string): T[] {
  const l = localApps.value;
  if (!l || l.rooted || !local.length) return rows;
  const have = new Set(rows.map(id));
  const extra = local.filter((t) => !have.has(id(t)));
  return extra.length ? [...rows, ...extra] : rows;
}

/**
 * What an island of [app] waits for, no root: its data is a SpacetimeDB database and SpacetimeDB isn't up. Null when
 * it can run (rooted, no database, or SpacetimeDB up).
 */
export function islandWait(app: RegistryApp | undefined): StdbState | null {
  const l = localApps.value;
  if (!l || l.rooted || !app?.database || l.stdb === "up") return null;
  return l.stdb;
}
