/**
 * One app's page, in plain words: what it offers as cards. "Make a widget" first, then widgets it ships, live data
 * you can use (its reads), actions, privacy (collapsed), what used it lately, and one "Developer" fold with routes,
 * generated views and ids. Every old capability stays reachable: switches, dry runs, views, audit, trackers.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { optimistic } from "@powos/shared/pending";
import { ActionPanel, Widgets, type DetailProps } from "./action";
import { AppAudit, Privacy } from "./activity";
import { call, type Action, type AppSpec, type Host, type Views } from "./api";
import { useRuntime } from "./runtime";
import { offers } from "./app-list";
import { Block, Muted, S, Seg, Switch, title } from "./ui";

/** [spec] with an action's (or the app's own, key "_app") `enabled` optimistically overridden. */
function withOverride(spec: AppSpec, overrides: Record<string, boolean>): AppSpec {
  if (!Object.keys(overrides).length) return spec;
  const actions = { ...spec.actions };
  for (const [id, on] of Object.entries(overrides)) {
    if (id !== "_app" && actions[id]) actions[id] = { ...actions[id], enabled: on };
  }
  return { ...spec, enabled: overrides["_app"] ?? spec.enabled, actions };
}

/** One thing the app offers: its name and plain summary, a switch, and (opened) the try-it panel. */
function Offer({ p, id, note }: { p: DetailProps; id: string; note?: string }) {
  const [open, setOpen] = useState(p.selectedAction === id);
  const row = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (p.selectedAction === id) { setOpen(true); row.current?.scrollIntoView({ block: "start" }); }
  }, [p.selectedAction, id]);
  const a = p.spec.actions[id];
  return (
    <div ref={row} style={S.card}>
      <div style={{ ...S.row, cursor: "pointer" }} onClick={() => setOpen(!open)}>
        <div style={S.grow}>
          <div style={S.name}>{title(id)}</div>
          <Muted>{[a.summary, note].filter(Boolean).join(" · ")}</Muted>
        </div>
        {p.toggle && <Switch on={a.enabled} label={`${title(id)} allowed`} onFlip={(on) => p.toggle!(on, id)} />}
      </div>
      {open && <ActionPanel net={p.net} app={p.app} spec={p.spec.app} id={id} a={a} draft={p.draft} />}
    </div>
  );
}

function Section({ name, note, children }: { name: string; note?: string; children: preact.ComponentChildren }) {
  return (
    <section style={{ display: "flex", flexDirection: "column", gap: "8px" }}>
      <h2 style={S.group}>{name}</h2>
      {note && <Muted>{note}</Muted>}
      {children}
    </section>
  );
}

const WRITE_NOTE: Record<Action["safety"], string> = { read: "", "reversible-write": "changes something, you can undo it", spend: "costs money: always asks you in chat" };

function Offers({ p }: { p: DetailProps }) {
  const ids = Object.keys(p.spec.actions).sort((a, b) => Number(b === p.selectedAction) - Number(a === p.selectedAction) || a.localeCompare(b));
  const reads = ids.filter((id) => p.spec.actions[id].safety === "read" && !id.startsWith("widget_"));
  const acts = ids.filter((id) => p.spec.actions[id].safety !== "read");
  return (
    <>
      <Section name="Widgets you can put on home">
        {p.spec.widgets?.length ? <Widgets bare widgets={p.spec.widgets} addToHome={p.addToHome} /> : <Muted>This app has no ready-made widget. Tap "Make a widget" to build one from its live data.</Muted>}
      </Section>
      <Section name="Live data you can use" note="Things this app can tell you. Reading changes nothing.">
        {reads.length ? reads.map((id) => <Offer key={id} p={p} id={id} />) : <Muted>No live data yet.</Muted>}
      </Section>
      {acts.length > 0 && (
        <Section name="Actions" note="Things this app can do for you. Writes only rehearse (dry run) for now.">
          {acts.map((id) => <Offer key={id} p={p} id={id} note={WRITE_NOTE[p.spec.actions[id].safety]} />)}
        </Section>
      )}
    </>
  );
}

const VIEWS: [string, keyof Views][] = [["API", "api"], ["AI tools", "tools"], ["CLI", "cli"], ["Widgets", "widgets"]];

/** Routes, generated views, ids: everything a developer wants, behind one fold. */
function Developer({ p }: { p: DetailProps }) {
  const [view, setView] = useState("API");
  const [open, setOpen] = useState(false);
  const which = VIEWS.find(([v]) => v === view)![1];
  const [views, err] = useRuntime<Views>(p.net, p.app, open ? `/views?app=${encodeURIComponent(p.spec.app)}` : null, Number(p.spec.enabled));
  const s = p.spec;
  return (
    <details style={S.card} data-fold="developer" onToggle={(e) => setOpen((e.target as HTMLDetailsElement).open)}>
      <summary style={S.fold}><span style={S.foldRow}><span style={S.name}>Developer</span><span style={S.muted}>routes, views, ids</span></span></summary>
      <div style={{ display: "flex", flexDirection: "column", gap: "8px", marginTop: "10px" }}>
        <div style={S.idMuted}>{s.app} · {s.origin}{s.auth ? ` · auth ${s.auth}` : ""}</div>
        <Seg options={VIEWS.map(([v]) => v)} picked={view} onPick={setView} />
        <Block>{err ? `couldn't render: ${err}` : views ? views[which] : "…"}</Block>
        {Object.entries(s.actions).map(([id, a]) => <div key={id} style={S.idMuted}>{`${id} · ${a.safety} · ${a.endpoint}`}</div>)}
      </div>
    </details>
  );
}

/**
 * "Make a widget" on an app that ships its own home widget: the widget goes on home (the pixel tile, the fallback) and
 * a native-card composition of it (an android block, docs/COMPOSER.md) is made and installed - no chat in between.
 */
function makeNative(p: DetailProps & { host: Host }, w: { provider: string; label: string }): Promise<unknown> {
  return Promise.resolve(p.addToHome?.(w.provider)).then(() => call(p.net, p.app, "/compose/android", { provider: w.provider, label: w.label }));
}

/**
 * Apps with no widget of their own still go through PowOS AI, which builds one from the app's reads.
 * HACK: the composer (compose_widget) is reached through a chat prompt for these until it has its own call with live
 * progress (lib/pending); the real fix is a direct composer entry for appcap reads too.
 */
const MAKE = (spec: AppSpec) => `Make me a home widget from my ${spec.name} app (App API id ${spec.app}). Use its live data (reads) that App API already allows, pick a layout, and put it on home.`;

function MakeWidget({ p, spec }: { p: DetailProps & { host: Host; makeWidget: () => void }; spec: AppSpec }) {
  const [state, setState] = useState<"idle" | "busy" | "done" | string>("idle");
  const w = spec.widgets?.[0];
  const direct = !!(w && p.addToHome && p.net);
  const go = () => {
    if (!direct) return void (p.host.askAssistant ? p.host.askAssistant(MAKE(spec)) : p.makeWidget());
    setState("busy"); // Optimistic: shown at once; the tile lands on home as Android allows, the card is in the edit sheet.
    makeNative(p, w!).then(() => setState("done"), (e) => setState(`error:${e instanceof Error ? e.message : String(e)}`));
  };
  return (
    <>
      <button type="button" style={S.hero} disabled={state === "busy"} onClick={go} data-make-widget="">
        {state === "busy" ? "Making your widget… (approve Android's prompt if shown)" : state === "done" ? "Made: see home's edit sheet, PowOS apps ✓" : "Make a widget"}
      </button>
      {state.startsWith("error:") && <Muted><span style={S.bad}>{state.slice(6)}</span></Muted>}
    </>
  );
}

export function AppPage(p: DetailProps & { host: Host; back: () => void; makeWidget: () => void }) {
  const [overrides, setOverrides] = useState<Record<string, boolean>>({});
  const [toggleErr, setToggleErr] = useState<string | null>(null);
  const spec = withOverride(p.spec, overrides);
  // The switch flips now, /enable runs in the background, a failure rolls it back with why (optimistic()).
  const flip = (on: boolean, action?: string) => {
    const key = action ?? "_app";
    const prev = action ? p.spec.actions[action].enabled : p.spec.enabled;
    setToggleErr(null);
    optimistic(
      () => setOverrides((o) => ({ ...o, [key]: on })),
      () => Promise.resolve(p.toggle!(on, action)),
      (e) => {
        setOverrides((o) => ({ ...o, [key]: prev }));
        setToggleErr(`couldn't turn ${action ? title(action) : spec.name} ${on ? "on" : "off"}: ${(e as Error)?.message ?? String(e)}`);
      },
    );
  };
  const dp: DetailProps = { ...p, spec, toggle: flip };
  return (
    <>
      <header style={S.head}>
        <button style={S.back} onClick={p.back} aria-label="back">‹</button>
        <h1 style={S.title}>{spec.name}</h1>
        <Switch on={spec.enabled} label={`${spec.name} on`} onFlip={(on) => flip(on)} />
      </header>
      <Muted>{spec.description ? `${spec.description} · ${(offers(spec) || "nothing to use yet")}` : (offers(spec) || "nothing to use yet")}</Muted>
      {!spec.enabled && <Muted>This app is off: nothing can use its data until you switch it on.</Muted>}
      {toggleErr && <Muted><span style={S.bad}>{toggleErr}</span></Muted>}
      <MakeWidget p={p} spec={spec} />
      <Offers p={dp} />
      <Section name="Recent use"><AppAudit net={p.net} app={p.app} specApp={spec.app} /></Section>
      <Privacy net={p.net} app={p.app} specApp={spec.app} />
      <Developer p={dp} />
    </>
  );
}

