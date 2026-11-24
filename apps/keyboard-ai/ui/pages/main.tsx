/**
 * "What the keyboard learned": the keyboard AI reply button's learning (docs/POWAI-ASSISTANT.md §3.9) - how often a draft
 * is picked and how much it's edited before sending, over time; per app its style profile, per-contact profiles and the
 * replies it learned from; learning switched off per app (which also forgets that app), clear per app, clear all.
 * Optimistic: a switch or a clear shows at once and rolls back if the module refuses.
 */
import { useState } from "preact/hooks";
import { useApp, type Props } from "../lib/app";
import { appName, apps, pct, totals, weeks, type AppView, type PrefRow, type ProfileRow, type ReplyRow, type StatRow, type Week } from "../lib/stats";

/** Learning switches and clears, optimistic: shown at once, rolled back with the module's error. */
function useControls(app: ReturnType<typeof useApp>) {
  const setLearn = app.useReducer<{ app: string; learn: boolean }>("set_learn");
  const forget = app.useReducer<{ app: string }>("forget");
  // Switched apps and cleared apps ("" = all) until the rows catch up or the call fails.
  const [switched, setSwitched] = useState<Record<string, boolean>>({});
  const [cleared, setCleared] = useState<Set<string>>(new Set());
  const [err, setErr] = useState("");
  const [confirm, setConfirm] = useState<string | null>(null);
  const run = async (what: () => Promise<unknown>, undo: () => void) => {
    setErr("");
    try {
      await what();
    } catch (e) {
      undo();
      setErr(String((e as Error)?.message ?? e));
    }
  };
  const toggle = (v: AppView) => {
    const learn = !v.learn;
    setSwitched((s) => ({ ...s, [v.app]: learn }));
    void run(() => setLearn({ app: v.app, learn }), () => setSwitched(({ [v.app]: _, ...s }) => s));
  };
  const uncleared = (a: string) => setCleared((c) => { const n = new Set(c); n.delete(a); return n; });
  const clear = (a: string) => {
    if (confirm !== a) return setConfirm(a);
    setConfirm(null);
    setCleared((c) => new Set(c).add(a));
    void run(() => forget({ app: a }), () => uncleared(a));
  };
  const gone = (a: string) => cleared.has("") || cleared.has(a);
  return { switched, gone, err, confirm, toggle, clear };
}

export default function Main({ host, close }: Props) {
  const app = useApp(host);
  const c = useControls(app);
  const replies = app.useTable<ReplyRow>("reply").filter((r) => !c.gone(r.app));
  const profiles = app.useTable<ProfileRow>("profile").filter((p) => !c.gone(p.app));
  const prefs = app.useTable<PrefRow>("app_pref");
  const stats = app.useTable<StatRow>("day_stat").filter((s) => !c.gone(s.app));
  const views = apps(replies, profiles, prefs, stats).map((v) => (v.app in c.switched ? { ...v, learn: c.switched[v.app] } : v));
  return (
    <div style={S.page}>
      <header style={S.head}>
        <button style={S.back} onClick={close} aria-label="back">‹</button>
        <h1 style={S.title}>What the keyboard learned</h1>
      </header>
      <div style={S.meta}>
        The ✨ reply button learns how you write from the drafts you pick and what you actually send. Text only, never
        screenshots; nothing from password or incognito fields.
      </div>
      {app.db.status !== "connected" && <div style={S.meta}>{app.db.status === "error" ? `Not available: ${app.db.error ?? ""}` : "Connecting…"}</div>}
      {c.err && <div style={S.err}>{c.err}</div>}
      <Summary stats={stats} />
      {!views.length && <div style={S.meta}>Nothing learned yet. Use the ✨ button in the keyboard and pick a draft.</div>}
      {views.map((v) => <AppCard key={v.app} v={v} confirm={c.confirm} toggle={c.toggle} clear={c.clear} />)}
      {!!views.length && (
        <button class="surface" style={S.button} onClick={() => c.clear("")}>
          {c.confirm === "" ? "Clear everything? Tap again" : "Clear everything"}
        </button>
      )}
    </div>
  );
}

/** Pick rate and edit distance, overall and per week: the measurement of the learning. */
function Summary({ stats }: { stats: StatRow[] }) {
  const all = totals(stats);
  const ws = weeks(stats, Date.now());
  return (
    <section class="tile" style={S.card}>
      <div style={S.row}>
        <span style={S.label}>Drafts picked</span>
        <span style={S.big}>{pct(all.pickRate)}</span>
      </div>
      <div style={S.row}>
        <span style={S.label}>Edited before sending</span>
        <span style={S.big}>{pct(all.edit)}</span>
      </div>
      <div style={S.meta}>{all.sessions} presses, {all.picks} picked. Getting better = more picked, less edited.</div>
      <Bars weeks={ws} value={(w) => w.pickRate} label="picked, per week" />
      <Bars weeks={ws} value={(w) => w.edit} label="edited, per week" />
    </section>
  );
}

interface CardProps { v: AppView; confirm: string | null; toggle: (v: AppView) => void; clear: (app: string) => void }

function AppCard({ v, confirm, toggle, clear }: CardProps) {
  return (
    <section class="tile" style={S.card}>
      <div style={S.row}>
        <span style={S.name}>{appName(v.app)} <small style={S.meta}>{v.app}</small></span>
        <button class="surface" style={S.button} onClick={() => toggle(v)} aria-pressed={v.learn}>
          {v.learn ? "Learning" : "Off"}
        </button>
      </div>
      {!v.learn && <div style={S.meta}>Nothing is learned or used here.</div>}
      {v.learn && <Learned v={v} />}
      {v.learn && (
        <button class="surface" style={S.button} onClick={() => clear(v.app)}>
          {confirm === v.app ? `Clear ${appName(v.app)}? Tap again` : "Clear this app"}
        </button>
      )}
    </section>
  );
}

function Learned({ v }: { v: AppView }) {
  return (
    <>
      <div style={S.meta}>{v.totals.sessions} presses · {pct(v.totals.pickRate)} picked · {pct(v.totals.edit)} edited</div>
      {v.profile && <Said who="Style here" text={v.profile.text} />}
      {v.contacts.map((p) => <Said key={p.id} who={`With ${p.contact}`} text={p.text} />)}
      {!!v.recent.length && (
        <div style={S.list}>
          <span style={S.label}>Learned from</span>
          {v.recent.map((r) => (
            <div key={r.id} style={S.example}>
              {r.contact && <span style={S.meta}>to {r.contact} · </span>}
              {r.finalText}
            </div>
          ))}
        </div>
      )}
    </>
  );
}

function Said({ who, text }: { who: string; text: string }) {
  return (
    <div style={S.list}>
      <span style={S.label}>{who}</span>
      <span style={S.profile}>{text}</span>
    </div>
  );
}

function Bars({ weeks, value, label }: { weeks: Week[]; value: (w: Week) => number | null; label: string }) {
  if (!weeks.some((w) => value(w) != null)) return null;
  return (
    <div style={S.list}>
      <div style={S.bars}>
        {weeks.map((w) => {
          const v = value(w);
          return (
            <div key={w.start} style={S.barCol} title={`${new Date(w.start).toLocaleDateString()}: ${pct(v)}`}>
              <span style={{ ...S.bar, height: v == null ? "0" : `${Math.max(4, v * 100)}%` }} />
            </div>
          );
        })}
      </div>
      <span style={S.meta}>{label}</span>
    </div>
  );
}

const S: Record<string, Record<string, string | number>> = {
  page: { display: "flex", flexDirection: "column", gap: "12px", height: "100%", padding: "8px 16px 16px", boxSizing: "border-box", overflowY: "auto" },
  head: { display: "flex", alignItems: "center", gap: "8px" },
  back: { font: "inherit", fontSize: "28px", lineHeight: 1, background: "none", border: 0, color: "var(--color-accent)", padding: "0 8px 0 0" },
  title: { flex: 1, margin: 0, fontSize: "1.3em", fontWeight: 600 },
  card: { display: "flex", flexDirection: "column", gap: "10px", padding: "12px 14px" },
  row: { display: "flex", alignItems: "center", justifyContent: "space-between", gap: "10px" },
  name: { fontWeight: 600, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis" },
  label: { color: "var(--color-muted)" },
  big: { fontSize: "1.4em", fontWeight: 600, fontVariantNumeric: "tabular-nums" },
  profile: { whiteSpace: "pre-line" },
  example: { padding: "6px 10px", borderRadius: "10px", background: "var(--fill-soft, rgba(127,127,127,0.12))", overflowWrap: "anywhere" },
  bars: { display: "flex", alignItems: "flex-end", gap: "6px", height: "40px" },
  barCol: { flex: 1, height: "100%", display: "flex", flexDirection: "column", justifyContent: "flex-end" },
  bar: { display: "block", width: "100%", borderRadius: "3px", background: "var(--color-accent)" },
  button: { font: "inherit", padding: "6px 14px", color: "inherit", alignSelf: "flex-start" },
  err: { color: "var(--color-red)" },
  list: { display: "flex", flexDirection: "column", gap: "6px" },
  meta: { fontSize: "var(--text-small)", color: "var(--color-muted)" },
};
