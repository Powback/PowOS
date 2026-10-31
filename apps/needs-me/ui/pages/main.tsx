/**
 * What needs me's page: the same rows as the widget, all of them, with a filter per app and "Mark all read" - one tap
 * that presses each shown notification's own mark-as-read (or dismisses one that has none), one after another.
 */
import { useState } from "preact/hooks";
import { markAll, type Props } from "../lib/act";
import { sourceOf, type Group } from "../lib/model";
import { Row, S as R, useGroups } from "../lib/rows";

const APPS = ["Discord", "WhatsApp", "Gmail"];
const has = (g: Group, app: string) => g.entries.some((e) => sourceOf(e.n) === app);

function Filters({ groups, filter, set }: { groups: Group[]; filter: string | null; set(f: string | null): void }) {
  const chip = (label: string, value: string | null, n: number) => (
    <button key={label} aria-pressed={filter === value} onClick={() => set(value)} style={{ ...R.pillButton, ...(filter === value ? S.on : null) }}>
      {label} {n > 0 && <span style={{ opacity: 0.7 }}>{n}</span>}
    </button>
  );
  return (
    <div style={{ display: "flex", gap: "0.5em", flexWrap: "wrap" }}>
      {chip("All", null, groups.length)}
      {APPS.map((a) => chip(a, a, groups.filter((g) => has(g, a)).length))}
    </div>
  );
}

export default function Main({ host, app, close }: Props) {
  const { phase, groups } = useGroups(host, app);
  const [filter, setFilter] = useState<string | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const shown = filter ? groups.filter((g) => has(g, filter)) : groups;
  const all = async () => {
    setBusy(true);
    await markAll(host, app, shown);
    setBusy(false);
  };
  return (
    <div style={S.page}>
      <header style={S.head}>
        <button style={S.back} onClick={close} aria-label="back">
          ‹
        </button>
        <h1 style={{ flex: 1, fontSize: "1.3em", margin: 0 }}>What needs me</h1>
        <button style={R.pillButton} disabled={!shown.length || busy} onClick={all}>
          {busy ? "Marking…" : "Mark all read"}
        </button>
      </header>
      <Filters groups={groups} filter={filter} set={setFilter} />
      {phase === "no-access" && (
        <button style={R.pillButton} onClick={() => void host.notifications?.access()}>
          Allow PowOS notification access
        </button>
      )}
      {phase === "old" && <p style={R.line}>This PowOS can't read notifications for apps yet: update PowOS.</p>}
      <div style={S.list}>
        {shown.map((g) => (
          <Row key={g.id} g={g} host={host} app={app} open={open === g.id} onToggle={() => setOpen(open === g.id ? null : g.id)} />
        ))}
        {phase === "ok" && !shown.length && <p style={{ ...R.line, textAlign: "center" }}>Nothing needs you</p>}
      </div>
      <p style={{ ...R.line, fontSize: "0.75em", whiteSpace: "normal" }}>
        Read from the notifications these apps post on this phone; replies and mark-as-read are their own buttons.
      </p>
    </div>
  );
}

const S = {
  page: { height: "100%", boxSizing: "border-box", padding: "1em var(--edge, 16px)", display: "flex", flexDirection: "column", gap: "0.9em", color: "var(--color-foreground)" },
  head: { display: "flex", alignItems: "center", gap: "0.6em" },
  back: { font: "inherit", fontSize: "1.6em", lineHeight: 1, padding: "0 0.3em", border: 0, background: "none", color: "inherit" },
  list: { flex: 1, minHeight: 0, overflowY: "auto", display: "flex", flexDirection: "column", gap: "0.9em" },
  on: { background: "var(--color-accent)", color: "var(--color-background)" },
} as const;
