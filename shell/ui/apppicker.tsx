/**
 * The edit sheet's PowOS apps: the widgets installed apps offer (the registry, apps/registry.ts), live - an install
 * from anywhere (`powos app install`, an agent) shows up here at once. Picking one puts it on home as an island
 * (ui/island.tsx), a "panel" item named "app:<app id>/<widget id>" in the first free spot at its size.
 */
import { powos } from "../bridge.ts";
import { cells, useRegistry, type RegistryWidget } from "../apps/registry.ts";
import { placeNewCells } from "./grid.tsx";

export async function addIsland(w: RegistryWidget) {
  const [cw, ch] = cells(w.size);
  const spot = placeNewCells(cw, ch);
  await powos.home.addPanel(`app:${w.key}`, spot.page, spot.cell);
}

export function AppWidgetList({ onAdded }: { onAdded?: () => void }) {
  const reg = useRegistry();
  const islands = reg.widgets.filter((w) => w.kind === "island");
  if (reg.status === "error") return <div class="muted">PowOS apps: SpacetimeDB unreachable ({reg.error})</div>;
  if (!islands.length) return null;
  return (
    <div class="aw-app">
      <div class="aw-app-head">
        <span class="aw-app-blank" />
        <span>PowOS apps</span>
      </div>
      <div class="aw-row">
        {islands.map((w) => {
          const app = reg.apps.find((a) => a.id === w.appId);
          return (
            <button
              type="button"
              class="aw-provider"
              key={w.key}
              onClick={async () => {
                await addIsland(w);
                onAdded?.();
              }}
            >
              <span class="aw-label">{w.name}</span>
              <span class="aw-desc muted">
                {app?.name ?? w.appId} {app?.version} · {w.size}
              </span>
            </button>
          );
        })}
      </div>
    </div>
  );
}
