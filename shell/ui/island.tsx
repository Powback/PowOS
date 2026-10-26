/**
 * A PowOS app's widget on home, as an island in this one shared page (docs/POWOS-APPS-FEASIBILITY.md section 6.2):
 * the app's widget module (its registry entry, served from the app's own dir at ./_app/<id>/) imported into the page
 * and rendered here - one renderer, one Preact, one SpacetimeDB SDK and one socket per database for every island,
 * ~1 MB each instead of a WebView's ~20. The module's default export is a Preact component; it gets the host
 * (apps/stdb.ts: its database's connection and live rows) and its size in cells. Home items of kind "panel" named
 * "app:<app id>/<widget id>" (ShellPanels.kt keeps their place).
 *
 * Trusted, as the shell is: an island runs with the page's bridge. Third-party apps get the iframe-isolated kind
 * (their own origin, a scoped bridge) - section 3.
 */
import { Component, type ComponentType } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { host } from "../apps/stdb.ts";
import { useOnScreen } from "../apps/onscreen.ts";
import { useSleepReport } from "../apps/sleepreport.ts";
import { useRegistry } from "../apps/registry.ts";
import { moduleUrl, retryDelay, retryUrl } from "../apps/pages.ts";
import type { HomeItem } from "../types.ts";

declare function importShim(url: string): Promise<{ default: ComponentType<any> }>;

class Boundary extends Component<{ name: string; children?: any }, { error: string | null }> {
  state = { error: null as string | null };
  componentDidCatch(e: unknown) {
    this.setState({ error: String((e as Error)?.message ?? e) });
  }
  render() {
    return this.state.error ? <Fault name={this.props.name} error={this.state.error} /> : this.props.children;
  }
}

function Fault({ name, error }: { name: string; error: string }) {
  return (
    <div class="tile widget-face">
      <div class="widget-name">{name}</div>
      <div class="widget-error">{error}</div>
    </div>
  );
}

/** "app:<app id>/<widget id>" -> [app id, widget key] */
export const islandOf = (name: string) => {
  const key = name.slice("app:".length);
  return [key.split("/")[0], key] as const;
};

/** The loaded island's tile; reported to `powos sleep status` as on screen (working) or paused off screen - the same
 * signal the island itself pauses on. */
function Face({ id, name, children }: { id: string; name: string; children?: any }) {
  const ref = useRef<HTMLDivElement>(null);
  useSleepReport(id, name, useOnScreen(ref));
  return (
    <div class="tile island-face" ref={ref}>
      {children}
    </div>
  );
}

export function Island({ item }: { item: HomeItem }) {
  const [appId, key] = islandOf(item.name ?? "");
  const reg = useRegistry();
  const widget = reg.widgets.find((w) => w.key === key);
  const app = reg.apps.find((a) => a.id === appId);
  const [mod, setMod] = useState<{ c: ComponentType<any> } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tries, setTries] = useState(0);
  // A new URL for each version and each change of its installed UI (hot reload): imported anew, swapped in once in.
  const base = widget && app ? moduleUrl(appId, widget.entry, app.version) : null;
  // The app changed: a fresh start (no retry count, its error goes once the new module is in).
  useEffect(() => setTries(0), [base]);
  const url = base ? retryUrl(base, tries) : null;
  useEffect(() => {
    if (!url) return;
    let live = true;
    let timer = 0;
    importShim(url).then(
      (m) => {
        if (!live) return;
        setMod({ c: m.default });
        setError(null);
      },
      (e) => {
        // Reported (the shell's error capture reads console.error) as well as shown on the tile - and tried again.
        console.error(`[powos-app] ${appId}: widget ${url} didn't load: ${e?.message ?? e}`, e);
        if (!live) return;
        setError(String(e?.message ?? e));
        timer = window.setTimeout(() => live && setTries((n) => n + 1), retryDelay(tries));
      },
    );
    return () => {
      live = false;
      clearTimeout(timer);
    };
  }, [url]);
  const name = widget?.name ?? key;
  if (error && !mod) return <Fault name={name} error={`${error} - trying again`} />;
  if (!mod) {
    const why = reg.status === "error" ? `SpacetimeDB: ${reg.error}` : reg.status === "connected" && !widget ? "not installed" : "…";
    return <Fault name={name} error={why} />;
  }
  const C = mod.c;
  return (
    <Boundary key={base ?? ""} name={name}>
      <Face id={key} name={`${app?.name ?? appId}: ${name}`}>
        <C host={host} app={appId} cells={item.cell ? [item.cell.w, item.cell.h] : [4, 2]} base={`./_app/${appId}/`} />
      </Face>
    </Boundary>
  );
}
