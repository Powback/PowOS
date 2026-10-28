/** Step 1: pick an app. Search, recently used first, everything else below. */
import { useState } from "preact/hooks";
import type { AppSpec } from "./api";
import { Muted, S, Switch } from "./ui";

const KEY = "app-api:recent";

function recents(): string[] {
  try { return JSON.parse(localStorage.getItem(KEY) ?? "[]"); } catch { return []; }
}

/** Remember [id] as the most recently opened app (best effort: storage can be unavailable). */
export function remember(id: string) {
  try { localStorage.setItem(KEY, JSON.stringify([id, ...recents().filter((x) => x !== id)].slice(0, 8))); } catch { /* not kept */ }
}

function summary(a: AppSpec): string {
  if (a.error) return "can't be read, tap for why";
  const acts = Object.values(a.actions ?? {});
  const reads = acts.filter((x) => x.safety === "read").length;
  const w = a.widgets?.length ?? 0;
  const parts = [w && `${w} widget${w === 1 ? "" : "s"}`, reads && `${reads} live data`, acts.length - reads && `${acts.length - reads} action${acts.length - reads === 1 ? "" : "s"}`];
  return parts.filter(Boolean).join(" · ") || "nothing to use yet";
}

function Row({ a, open, flip }: { a: AppSpec; open: () => void; flip: (on: boolean) => void }) {
  return (
    <div style={{ ...S.card, cursor: "pointer" }} onClick={open} data-app-row={a.app}>
      <div style={S.row}>
        <div style={S.grow}>
          <div style={S.name}>{a.name}</div>
          <Muted>{summary(a)}</Muted>
        </div>
        {!a.error && <Switch on={a.enabled} label={`${a.name} on`} onFlip={flip} />}
      </div>
    </div>
  );
}

function Group({ name, apps, open, flip }: { name: string; apps: AppSpec[]; open: (id: string) => void; flip: (id: string) => (on: boolean) => void }) {
  if (!apps.length) return null;
  return (
    <section style={{ display: "flex", flexDirection: "column", gap: "8px" }}>
      <h2 style={S.group}>{name}</h2>
      {apps.map((a) => <Row key={a.app} a={a} open={() => open(a.app)} flip={flip(a.app)} />)}
    </section>
  );
}

export function AppList({ apps, open, add, flip }: { apps: AppSpec[]; open: (id: string) => void; add: () => void; flip: (id: string) => (on: boolean) => void }) {
  const [q, setQ] = useState("");
  const needle = q.trim().toLowerCase();
  const shown = apps.filter((a) => !needle || a.name.toLowerCase().includes(needle) || a.app.toLowerCase().includes(needle));
  const recent = needle ? [] : recents().map((id) => shown.find((a) => a.app === id)).filter((a): a is AppSpec => !!a).slice(0, 3);
  const rest = shown.filter((a) => !recent.includes(a));
  return (
    <>
      <input style={S.field} type="search" placeholder="Search your apps" value={q} onInput={(e) => setQ((e.target as HTMLInputElement).value)} aria-label="search apps" />
      <Group name="Recently used" apps={recent} open={open} flip={flip} />
      <Group name={recent.length ? "All apps" : "Your apps"} apps={rest} open={open} flip={flip} />
      {needle && !shown.length && <Muted>{`No app called "${q.trim()}" yet.`}</Muted>}
      <div style={{ ...S.card, cursor: "pointer" }} onClick={add} data-add-app="">
        <div style={S.name}>+ Add an app</div>
        <Muted>{needle && !shown.length ? `Find "${q.trim()}" among your installed apps.` : "Pick one that's installed, describe it, or import its API."}</Muted>
      </div>
    </>
  );
}
