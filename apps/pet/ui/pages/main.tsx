/**
 * Pet's page: who it is (name, level, energy) and what's been said through it. The pet itself lives on home (the
 * shell's ui/pet.tsx): this is where you rename it, feed it and read back its lines.
 */
import { useState } from "preact/hooks";
import { useApp, type Props } from "../lib/app";

interface PetRow {
  name: string;
  mood: string;
  moodUntil: bigint;
  energy: number;
  fed: bigint;
  xp: number;
  level: number;
}
interface Said {
  id: bigint;
  text: string;
  from: string;
  at: bigint;
}

/** Energy runs down 3 points an hour from what it was when fed. */
const energyNow = (p: PetRow) => Math.max(0, p.energy - Math.floor(((Date.now() - Number(p.fed)) / 3_600_000) * 3));
const time = (ms: bigint) => new Date(Number(ms)).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

export default function Main({ host, close }: Props) {
  const app = useApp(host);
  const pet = app.useTable<PetRow>("pet")[0];
  const said = app.useTable<Said>("said").sort((a, b) => Number(b.id - a.id));
  const feed = app.useReducer("feed");
  const rename = app.useReducer<{ name: string }>("rename");
  const hush = app.useReducer("hush");
  const [name, setName] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const run = (p: Promise<unknown>) => p.then(() => setErr(null), (e) => setErr(String(e?.message ?? e)));
  const xpNext = pet ? 5 * pet.level * pet.level : 5;
  return (
    <div style={S.page}>
      <header style={S.head}>
        <button style={S.back} onClick={close} aria-label="back">‹</button>
        <h1 style={S.title}>{pet?.name ?? "Pet"}</h1>
      </header>
      {pet && (
        <section class="tile" style={S.card}>
          <div style={S.row}>
            <span style={S.label}>level</span>
            <span>{pet.level} · {pet.xp}/{xpNext} xp</span>
          </div>
          <div style={S.row}>
            <span style={S.label}>energy</span>
            <span style={S.bar}><span style={{ ...S.fill, width: `${energyNow(pet)}%` }} /></span>
            <button class="surface" style={S.button} onClick={() => run(feed())}>Feed</button>
          </div>
          <form
            style={S.row}
            onSubmit={(e) => {
              e.preventDefault();
              if (name?.trim()) run(rename({ name }).then(() => setName(null)));
            }}
          >
            <span style={S.label}>name</span>
            <input style={S.input} value={name ?? pet.name} onInput={(e) => setName((e.target as HTMLInputElement).value)} />
            {name != null && name !== pet.name && <button class="surface" style={S.button} type="submit">Save</button>}
          </form>
          {err && <div style={S.err}>{err}</div>}
        </section>
      )}
      <h3 style={S.heading}>
        <span style={{ flex: 1 }}>said lately</span>
        {said.length > 0 && <button style={S.link} onClick={() => run(hush())}>clear</button>}
      </h3>
      <div style={S.list}>
        {said.map((s) => (
          <div key={String(s.id)} style={S.line}>
            <span style={S.meta}>{time(s.at)} · {s.from}</span>
            <span>{s.text}</span>
          </div>
        ))}
        {!said.length && <div style={S.meta}>Nothing yet. Agents speak through it with `powos pet say`.</div>}
      </div>
    </div>
  );
}

const S: Record<string, Record<string, string | number>> = {
  page: { display: "flex", flexDirection: "column", gap: "12px", height: "100%", padding: "8px 16px 16px", boxSizing: "border-box", overflowY: "auto" },
  head: { display: "flex", alignItems: "center", gap: "8px" },
  back: { font: "inherit", fontSize: "28px", lineHeight: 1, background: "none", border: 0, color: "var(--color-accent)", padding: "0 8px 0 0" },
  title: { flex: 1, margin: 0, fontSize: "1.4em", fontWeight: 600 },
  card: { display: "flex", flexDirection: "column", gap: "10px", padding: "12px 14px" },
  row: { display: "flex", alignItems: "center", gap: "10px" },
  label: { width: "64px", color: "var(--color-muted)" },
  bar: { flex: 1, height: "8px", borderRadius: "4px", background: "var(--soft-fill)", overflow: "hidden" },
  fill: { display: "block", height: "100%", background: "var(--color-accent)" },
  input: { flex: 1, minWidth: 0, font: "inherit", padding: "6px 10px", borderRadius: "10px", border: 0, background: "var(--soft-fill)", color: "inherit" },
  button: { font: "inherit", padding: "6px 14px", color: "inherit" },
  err: { color: "var(--color-red)" },
  heading: { display: "flex", margin: "4px 0 0", fontSize: "var(--text-small)", fontWeight: 500, color: "var(--color-muted)" },
  link: { font: "inherit", background: "none", border: 0, color: "var(--color-accent)", padding: 0 },
  list: { display: "flex", flexDirection: "column", gap: "8px" },
  line: { display: "flex", flexDirection: "column", gap: "2px", paddingBottom: "8px", borderBottom: "1px solid var(--divider)" },
  meta: { fontSize: "var(--text-small)", color: "var(--color-muted)" },
};
