/**
 * "+ add app" (tools/app-api/appcap_add.py): three ways to a draft, and the drafts waiting for review.
 *   1. Describe it: PowOS AI gets a ready prompt in its field (host.askAssistant) and writes the draft itself with
 *      appcap_add.py - the user sends it; the model never runs in App API's runtime.
 *   2. An installed app: a PowOS app (its page + its own database's API) or an Android app (the screens its links open,
 *      host.appLinks - read from its manifest, nothing fired).
 *   3. Import its API: an OpenAPI document or a capability spec, from a URL (the runtime fetches it; no credentials)
 *      or a file, or the bundled Open-Meteo sample.
 * A draft is never one of your apps: its review is dry runs only; "Add to my apps" moves it in with the app off.
 */
import { useState } from "preact/hooks";
import { Actions } from "./action";
import { call, type AppSpec, type DraftInfo, type Host, type InstalledPowos, type Net } from "./api";
import { useRuntime } from "./runtime";
import { Muted, S } from "./ui";

interface Ctx {
  host: Host;
  app: string;
  /** A draft was made: review it. */
  review: (draft: string) => void;
}

const PROMPT = (what: string) =>
  `Add an app to App API: ${what.trim()}\n\n` +
  "Read its public API docs - never sign in, never ask me for a password or a token. Write a capability spec " +
  "(powos.appcap/v1, like /usr/lib/powos/app-api/examples/hue.appcap.json) to a file: what only looks is safety " +
  '"read", what changes something "reversible-write", what costs money or contacts people "spend"; auth only as the ' +
  "handle store:<app>:session. Then run: python3 /usr/lib/powos/app-api/appcap_add.py put --source describe FILE\n" +
  "It becomes a draft in App API (+ add app, Drafts) for me to review - nothing is switched on.";

/** Runs [fn] once at a time: [busy, error, run]. */
function useAct(): [boolean, string | null, (fn: () => Promise<unknown>) => void] {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const run = (fn: () => Promise<unknown>) => {
    setBusy(true);
    setErr(null);
    fn().catch((e) => setErr(String(e?.message ?? e))).finally(() => setBusy(false));
  };
  return [busy, err, run];
}

function Path({ title, note, children }: { title: string; note: string; children: preact.ComponentChildren }) {
  return (
    <section style={S.card} data-add-path={title}>
      <div style={S.name}>{title}</div>
      <Muted>{note}</Muted>
      {children}
    </section>
  );
}

function Describe({ host }: Ctx) {
  const [what, setWhat] = useState("");
  if (!host.askAssistant) return <Muted>This PowOS is too old to hand a description to PowOS AI.</Muted>;
  const ask = host.askAssistant;
  return (
    <>
      <textarea style={{ ...S.field, minHeight: "64px" }} placeholder="Which app, and what should it be able to do?" value={what} onInput={(e) => setWhat((e.target as HTMLTextAreaElement).value)} />
      <div style={S.row}>
        <button type="button" style={{ ...S.btn, ...S.btnOn }} disabled={!what.trim()} onClick={() => ask(PROMPT(what))}>
          Ask PowOS AI
        </button>
        <Muted>Opens PowOS AI with the request ready - you send it.</Muted>
      </div>
    </>
  );
}

function Pick({ label, busy, onPick }: { label: string; busy: boolean; onPick: () => void }) {
  return (
    <button type="button" style={{ ...S.btn, textAlign: "left" }} disabled={busy} onClick={onPick}>
      {label}
    </button>
  );
}

function PowosApps({ host, app, review }: Ctx) {
  const [d, err] = useRuntime<{ powos: InstalledPowos[] }>(host.net, app, "/installed");
  const [busy, perr, run] = useAct();
  const pick = (id: string) => run(() => call<DraftInfo>(host.net, app, "/draft/installed", { id }).then((r) => review(r.app)));
  if (err) return <Muted>{err}</Muted>;
  return (
    <>
      <div style={S.group}>PowOS apps</div>
      {d?.powos.length === 0 && <Muted>No PowOS apps installed.</Muted>}
      <div style={{ display: "flex", flexWrap: "wrap", gap: "6px" }}>
        {d?.powos.map((a) => <Pick key={a.id} label={a.name} busy={busy} onPick={() => pick(a.id)} />)}
      </div>
      {perr && <Muted>{perr}</Muted>}
    </>
  );
}

function AndroidApps({ host, app, review }: Ctx) {
  const [list, setList] = useState<{ pkg: string; label: string }[] | null>(null);
  const [q, setQ] = useState("");
  const [busy, err, run] = useAct();
  const { androidApps, appLinks } = host;
  if (!androidApps || !appLinks) return null;
  const pick = (pkg: string) =>
    run(async () => {
      const l = await appLinks(pkg).catch(() => Promise.reject(new Error("reading an app's links needs the newer PowOS app")));
      review((await call<DraftInfo>(host.net, app, "/draft/installed", { kind: "android", ...l })).app);
    });
  if (!list) return <Pick label="Android apps…" busy={busy} onPick={() => run(() => androidApps().then(setList))} />;
  const shown = list.filter((a) => a.label.toLowerCase().includes(q.toLowerCase())).slice(0, 24);
  return (
    <>
      <div style={S.group}>Android apps</div>
      <input style={S.field} placeholder="find an app" value={q} onInput={(e) => setQ((e.target as HTMLInputElement).value)} />
      <div style={{ display: "flex", flexWrap: "wrap", gap: "6px" }}>
        {shown.map((a) => <Pick key={a.pkg} label={a.label} busy={busy} onPick={() => pick(a.pkg)} />)}
      </div>
      {err && <Muted>{err}</Muted>}
    </>
  );
}

function Import({ host, app, review }: Ctx) {
  const [url, setUrl] = useState("");
  const [busy, err, run] = useAct();
  const send = (body: object) => run(() => call<DraftInfo>(host.net, app, "/draft/import", body).then((r) => review(r.app)));
  const file = (e: Event) => {
    const f = (e.target as HTMLInputElement).files?.[0];
    if (f) run(() => f.text().then((doc) => call<DraftInfo>(host.net, app, "/draft/import", { doc })).then((r) => review(r.app)));
  };
  return (
    <>
      <div style={S.row}>
        <input style={S.field} inputMode="url" placeholder="https://… openapi.json" value={url} onInput={(e) => setUrl((e.target as HTMLInputElement).value)} />
        <button type="button" style={{ ...S.btn, ...S.btnOn }} disabled={busy || !/^https?:\/\//.test(url)} onClick={() => send({ url })}>
          Import
        </button>
      </div>
      <div style={S.row}>
        <input type="file" accept=".json,application/json" disabled={busy} onChange={file} />
      </div>
      <button type="button" style={S.btn} disabled={busy} onClick={() => send({ sample: "open-meteo" })}>
        Try the Open-Meteo sample
      </button>
      {err && <Muted>{err}</Muted>}
    </>
  );
}

function Drafts({ host, app, review }: Ctx) {
  const [d, err] = useRuntime<{ drafts: DraftInfo[] }>(host.net, app, "/drafts");
  if (err) return <Muted>{err}</Muted>;
  if (!d?.drafts.length) return <Muted>No drafts waiting.</Muted>;
  return (
    <>
      {d.drafts.map((x) => (
        <div key={x.app} style={{ ...S.card, cursor: "pointer" }} onClick={() => review(x.app)} data-draft={x.app}>
          <div style={S.name}>{x.name}</div>
          <Muted>{`${x.reads} read${x.reads === 1 ? "" : "s"} · ${x.writes} write${x.writes === 1 ? "" : "s"} · ${x.app}`}</Muted>
        </div>
      ))}
    </>
  );
}

interface ReviewProps {
  net?: Net;
  app: string;
  draft: string;
  back: () => void;
  added: (id: string) => void;
}

/** Add to my apps / Discard - refused (and said why) when an app of the draft's id is in your apps already. */
function Decide({ net, app, draft, back, added, ready }: ReviewProps & { ready: boolean }) {
  const [busy, err, run] = useAct();
  const [list] = useRuntime<{ drafts: DraftInfo[] }>(net, app, "/drafts");
  const exists = !!list?.drafts.find((x) => x.app === draft)?.exists;
  const add = () => run(() => call(net, app, "/draft/add", { app: draft }).then(() => added(draft)));
  const discard = () => run(() => call(net, app, "/draft/discard", { app: draft }).then(back));
  return (
    <>
      <div style={S.row}>
        <button type="button" style={{ ...S.btn, ...S.btnOn }} disabled={busy || exists || !ready} onClick={add}>
          Add to my apps
        </button>
        <button type="button" style={S.btn} disabled={busy} onClick={discard}>
          Discard
        </button>
      </div>
      {exists && <Muted>{`"${draft}" is in your apps already: discard this draft, or import it under another name.`}</Muted>}
      {err && <Muted>{err}</Muted>}
    </>
  );
}

/** A draft's review: its actions as in an app's detail, without switches, dry runs only (Actions draft). */
function Review(p: ReviewProps) {
  const [spec, err] = useRuntime<AppSpec>(p.net, p.app, `/draft?app=${encodeURIComponent(p.draft)}`);
  return (
    <>
      <header style={S.head}>
        <button style={S.back} onClick={p.back} aria-label="back">‹</button>
        <h1 style={S.title}>{spec?.name ?? p.draft}</h1>
      </header>
      <Muted>A draft: dry runs only, nothing is sent. Reads are on once you add it; writes stay off until you switch one on.</Muted>
      {spec?.description && <Muted>{spec.description}</Muted>}
      {err ? <Muted>{err}</Muted> : spec ? <Actions net={p.net} app={p.app} spec={spec} draft /> : <Muted>…</Muted>}
      <Decide {...p} ready={!!spec} />
    </>
  );
}

export function AddApp({ host, app, back, added }: { host: Host; app: string; back: () => void; added: (id: string) => void }) {
  const [draft, setDraft] = useState<string | null>(null);
  if (draft) return <Review net={host.net} app={app} draft={draft} back={() => setDraft(null)} added={added} />;
  const ctx: Ctx = { host, app, review: setDraft };
  return (
    <>
      <header style={S.head}>
        <button style={S.back} onClick={back} aria-label="back">‹</button>
        <h1 style={S.title}>Add an app</h1>
      </header>
      <Path title="Describe it" note="PowOS AI reads the app's docs and writes the draft.">
        <Describe {...ctx} />
      </Path>
      <Path title="From an installed app" note="What it already opens or offers - its screens, or a PowOS app's own data.">
        <PowosApps {...ctx} />
        <AndroidApps {...ctx} />
      </Path>
      <Path title="Import its API" note="An OpenAPI document or a capability spec, from a link or a file. Never a password or a token.">
        <Import {...ctx} />
      </Path>
      <h2 style={S.group}>Drafts</h2>
      <Drafts {...ctx} />
    </>
  );
}
