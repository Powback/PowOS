/**
 * "+ add app" (tools/app-api/appcap_add.py): three ways to a draft, and the drafts waiting for review.
 *   1. Describe it: PowOS AI gets a ready prompt in its field (host.askAssistant) and writes the draft itself with
 *      appcap_add.py - the user sends it; the model never runs in App API's runtime.
 *   2. An installed app: one searchable list (PowOS apps from the registry's "/installed", Android apps from the
 *      shell bridge's apps.list via host.androidApps). Tapping one adds a placeholder card to Drafts at once, with
 *      live progress (lib/pending.tsx), while the runtime builds the draft (host.appLinks for an Android app's deep
 *      links, or the PowOS app's own database); the card turns into the real draft in place, no navigation.
 *   3. Import its API: an OpenAPI document or a capability spec, from a URL (the runtime fetches it; no credentials)
 *      or a file, or the bundled Open-Meteo sample.
 * A draft is never one of your apps: its review is dry runs only; "Add to my apps" moves it in with the app off.
 */
import { useEffect, useState } from "preact/hooks";
import { Actions } from "./action";
import { call, type AppSpec, type DraftInfo, type Host, type InstalledPowos, type Net } from "./api";
import { optimistic, ProgressRing, StepList, stepsProgress, type PendingState, type PendingStep } from "./pending";
import { useRuntime } from "./runtime";
import { Muted, S } from "./ui";

interface Ctx {
  host: Host;
  app: string;
  /** A draft was made: review it. */
  review: (draft: string) => void;
  /** An installed app was picked: a placeholder in Drafts at once, [run] (the real draft) in the background. */
  startInstalled: (label: string, steps: PendingStep[], run: () => Promise<DraftInfo>) => void;
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

interface InstalledEntry {
  kind: "powos" | "android";
  key: string;
  label: string;
}

/**
 * One searchable list, PowOS apps (the registry's "/installed") and Android apps (host.androidApps, the shell
 * bridge's apps.list) together. Tapping one starts building its draft at once (Ctx.startInstalled): a placeholder
 * card appears in Drafts immediately, with live progress, while this runs in the background - no navigation, no
 * wait before something shows.
 */
function InstalledApps({ host, app, startInstalled }: Ctx) {
  const [q, setQ] = useState("");
  const [d, err] = useRuntime<{ powos: InstalledPowos[] }>(host.net, app, "/installed");
  const [android, setAndroid] = useState<{ pkg: string; label: string }[] | null>(null);
  useEffect(() => {
    if (host.androidApps) host.androidApps().then(setAndroid, () => setAndroid([]));
    else setAndroid([]);
    // host.androidApps is read once at mount (the bridge's own list doesn't change while this is open).
  }, []);
  const entries: InstalledEntry[] = [
    ...(d?.powos ?? []).map((a): InstalledEntry => ({ kind: "powos", key: a.id, label: a.name })),
    ...(android ?? []).map((a): InstalledEntry => ({ kind: "android", key: a.pkg, label: a.label })),
  ];
  const shown = (q ? entries.filter((e) => e.label.toLowerCase().includes(q.toLowerCase())) : entries).slice(0, 40);
  const pick = (e: InstalledEntry) => {
    if (e.kind === "powos") {
      startInstalled(e.label, [{ label: "Building the draft", state: "active" }],
        () => call<DraftInfo>(host.net, app, "/draft/installed", { id: e.key }));
      return;
    }
    startInstalled(e.label, [{ label: "Reading its links", state: "active" }, { label: "Building the draft", state: "pending" }],
      async () => {
        if (!host.appLinks) throw new Error("reading an app's links needs the newer PowOS app");
        const l = await host.appLinks(e.key);
        return call<DraftInfo>(host.net, app, "/draft/installed", { kind: "android", ...l });
      });
  };
  if (err) return <Muted>{err}</Muted>;
  if (!d && android === null) return <Muted>…</Muted>;
  return (
    <>
      <input style={S.field} placeholder="find an installed app" value={q} onInput={(e) => setQ((e.target as HTMLInputElement).value)} />
      {!entries.length && <Muted>No installed apps found.</Muted>}
      <div style={{ display: "flex", flexWrap: "wrap", gap: "6px" }}>
        {shown.map((e) => <Pick key={`${e.kind}:${e.key}`} label={e.label} busy={false} onPick={() => pick(e)} />)}
      </div>
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

/** A placeholder card: the install still building (ProgressRing + StepList), or stopped with a reason to discard. */
function PendingDraftCard({ state, onDiscard }: { state: PendingState; onDiscard: () => void }) {
  const progress = state.status === "failed" ? 1 : stepsProgress(state.steps);
  return (
    <div style={S.card} data-pending-draft={state.title}>
      <div style={S.row}>
        <ProgressRing progress={progress} />
        <div style={S.grow}>
          <div style={S.name}>{state.title}</div>
          <StepList steps={state.steps} />
        </div>
      </div>
      {state.status === "failed" && (
        <div style={S.row}>
          <Muted>{state.error || "couldn't build the draft"}</Muted>
          <button type="button" style={S.btn} onClick={onDiscard}>
            Discard
          </button>
        </div>
      )}
    </div>
  );
}

function Drafts({ host, app, review, pending, justAdded, discardPending }: Ctx & {
  pending: PendingState[];
  justAdded: Record<string, DraftInfo>;
  discardPending: (id: string) => void;
}) {
  const [d, err] = useRuntime<{ drafts: DraftInfo[] }>(host.net, app, "/drafts");
  if (err) return <Muted>{err}</Muted>;
  const known = new Set((d?.drafts ?? []).map((x) => x.app));
  // justAdded: a draft the runtime just finished, shown here at once - the real list catches up to it on its own
  // next poll (useRuntime's visibilitychange reload); no flash either way, since this dedupes by app id.
  const list = [...Object.values(justAdded).filter((x) => !known.has(x.app)), ...(d?.drafts ?? [])];
  if (!pending.length && !list.length) return <Muted>No drafts waiting.</Muted>;
  return (
    <>
      {pending.map((s) => <PendingDraftCard key={s.id} state={s} onDiscard={() => discardPending(s.id)} />)}
      {list.map((x) => (
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

/**
 * Add to my apps / Discard - refused (and said why) when an app of the draft's id is in your apps already.
 * "Added" shows at once (optimistic: the user already decided, the write is what's still catching up) - a failure
 * reverts it in place with the reason, button and all back to normal, instead of leaving "Added" up over an error.
 */
function Decide({ net, app, draft, back, added, ready }: ReviewProps & { ready: boolean }) {
  const [busy, err, run] = useAct();
  const [addedNow, setAddedNow] = useState(false);
  const [list] = useRuntime<{ drafts: DraftInfo[] }>(net, app, "/drafts");
  const exists = !!list?.drafts.find((x) => x.app === draft)?.exists;
  const add = () => {
    setAddedNow(true);
    run(() =>
      call(net, app, "/draft/add", { app: draft })
        .then(() => added(draft))
        .catch((e) => {
          setAddedNow(false);
          throw e;
        }),
    );
  };
  const discard = () => run(() => call(net, app, "/draft/discard", { app: draft }).then(back));
  return (
    <>
      <div style={S.row}>
        <button type="button" style={{ ...S.btn, ...S.btnOn }} disabled={busy || exists || !ready || addedNow} onClick={add}>
          {addedNow ? "Added" : "Add to my apps"}
        </button>
        <button type="button" style={S.btn} disabled={busy || addedNow} onClick={discard}>
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
  const [pending, setPending] = useState<Record<string, PendingState>>({});
  const [justAdded, setJustAdded] = useState<Record<string, DraftInfo>>({});

  const discardPending = (id: string) => setPending((p) => { const { [id]: _drop, ...rest } = p; return rest; });

  /** Optimistic: a placeholder in Drafts the instant [label] is tapped, [run]'s real draft swapped in in place -
   * a failure leaves the card up with its reason and a Discard, instead of nothing having shown at all. */
  const startInstalled = (label: string, steps: PendingStep[], run: () => Promise<DraftInfo>) => {
    const id = `pending:${Date.now()}:${Math.random().toString(36).slice(2)}`;
    void optimistic<DraftInfo>(
      () => setPending((p) => ({ ...p, [id]: { id, title: label, status: "running", steps } })),
      run,
      (err) =>
        setPending((p) => ({
          ...p,
          [id]: {
            ...p[id],
            status: "failed",
            error: String((err as { message?: string } | undefined)?.message ?? err),
            steps: p[id].steps.map((s) => (s.state === "active" ? { ...s, state: "failed" } : s)),
          },
        })),
    ).then(
      (info) => {
        discardPending(id);
        setJustAdded((j) => ({ ...j, [info.app]: info }));
      },
      () => {}, // already reflected in `pending` (status "failed", Discard there) - nothing else to do
    );
  };

  if (draft) return <Review net={host.net} app={app} draft={draft} back={() => setDraft(null)} added={added} />;
  const ctx: Ctx = { host, app, review: setDraft, startInstalled };
  return (
    <>
      <header style={S.head}>
        <button style={S.back} onClick={back} aria-label="back">‹</button>
        <h1 style={S.title}>Add an app</h1>
      </header>
      <Path title="Describe it" note="PowOS AI reads the app's docs and writes the draft.">
        <Describe {...ctx} />
      </Path>
      <Path title="From an installed app" note="Search what's installed. Tap one: it starts building at once, live, below in Drafts.">
        <InstalledApps {...ctx} />
      </Path>
      <Path title="Import its API" note="An OpenAPI document or a capability spec, from a link or a file. Never a password or a token.">
        <Import {...ctx} />
      </Path>
      <h2 style={S.group}>Drafts</h2>
      <Drafts {...ctx} pending={Object.values(pending)} justAdded={justAdded} discardPending={discardPending} />
    </>
  );
}
