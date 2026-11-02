/**
 * What runs and is installed where (lib/apps/powos-units, the powos-agents module's `unit` table): per host, every
 * unit with its status (running / asleep / stopped / installed), owner and resource use, and the host's drift - what
 * no unit claims. Orphans (found with no clear owner or purpose) come first and are marked: the user decides.
 * Rows come from `powos units publish` on each host (the phone, the Mac, the Colima VM); asleep is the sleepers' own
 * status (powos-autosleep), read by powos-units - nothing here decides it.
 */
import { useEffect, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { DbConnection as AgentsDb } from "../vendor/powos-agents.js";
import { useDb, useRows } from "../apps/stdb.ts";
import { stored } from "../state.ts";
import { ago } from "./time.ts";
import { HostSessions } from "./terms.tsx";
import { ThinBar } from "./aiprogress.tsx";

/** A `unit` row (u64s arrive as bigint). The `_check` row of a host carries its drift (status clean | drift). */
interface UnitRow {
  key: string;
  host: string;
  id: string;
  name: string;
  kind: string;
  owner: string;
  purpose: string;
  status: string;
  memKb: bigint | number;
  cpuPermille: number;
  limits: string;
  autosleep: string;
  orphan: boolean;
  decide: string;
  updated: bigint | number;
}

/** As last seen: shown at once when the page comes back. */
export const units = signal<UnitRow[]>([]);
const open = stored("powai.units.open", "[]");
const opened = () => {
  try {
    return new Set<string>(JSON.parse(open.value));
  } catch {
    return new Set<string>();
  }
};
export const HOSTS = ["phone", "phone-android", "mac", "colima", "powstation"];
const RANK: Record<string, number> = { running: 0, asleep: 1, stopped: 2, installed: 3, missing: 4 };
const mb = (kb: bigint | number) => (Number(kb) ? `${Math.round(Number(kb) / 1024)} MB` : "");

export function Feed() {
  const db = useDb("powos-agents", AgentsDb);
  const rows = useRows<UnitRow>(db, "unit", "SELECT * FROM unit");
  useEffect(() => {
    if (db.status === "connected" && rows.length) units.value = rows;
  }, [rows, db.status]);
  return null;
}

/** A unit's dot: running is the working colour, asleep the check colour, the rest grey (the Progress page's dots). */
const DOT: Record<string, string> = { running: "working", asleep: "check" };

/** One unit, one line: its dot, name, status · memory · cpu; a tap opens what it is, who owns it and its limits in place. */
function Line({ u, onTap, wide }: { u: UnitRow; onTap: () => void; wide: boolean }) {
  const cpu = u.cpuPermille ? ` · ${(u.cpuPermille / 10).toFixed(1)}%` : "";
  return (
    <li class={`ai-unit ${u.orphan ? "orphan" : ""}`}>
      <button type="button" class="ai-unit-line" aria-expanded={wide} onClick={onTap}>
        <span class={`aip-dot ${DOT[u.status] ?? ""}`} aria-hidden="true" />
        <span class="ai-unit-name">{u.name}</span>
        {u.orphan && <span class="aip-chip">orphan</span>}
        <span class="ai-unit-state">
          {u.status}
          {mb(u.memKb) && ` · ${mb(u.memKb)}`}
          {cpu}
        </span>
      </button>
      {wide && (
        <span class="ai-unit-detail">
          {u.orphan && u.decide && <span class="ai-unit-decide">{u.decide}</span>}
          <span>{u.purpose}</span>
          <span>
            {u.owner} · {u.kind} · limits {u.limits || "-"}
            {u.autosleep && u.autosleep !== "-" ? ` · sleeps ${u.autosleep}` : ""} · {u.id}
          </span>
        </span>
      )}
    </li>
  );
}

const STALE_MS = 3600_000;

/** A host's facts: [stale] (no publish for over an hour, or its publisher couldn't read it) and why, in plain words. */
function hostFacts(rows: UnitRow[], check?: UnitRow) {
  // Every host publishes on a timer (~15 min) and after each ship to it: over an hour without one is "stale", never a
  // silent age. A publisher that ran but couldn't read its host says why (status "stale", the reason as its purpose).
  const failed = check?.status === "stale";
  const old = !!check && Date.now() - Number(check.updated) > STALE_MS;
  const stale = failed || old || !check;
  const why = failed ? check?.purpose : check ? `no publish for ${ago(Number(check.updated) / 1000)} - its publish timer isn't running (powos units publish)` : "never published (powos units publish)";
  return {
    run: rows.filter((u) => u.status === "running").length,
    asleep: rows.filter((u) => u.status === "asleep").length,
    orph: rows.filter((u) => u.orphan).length,
    drift: check?.status === "drift",
    stale,
    why: stale ? why : "",
  };
}

/**
 * A host as the Progress page's area card (the user, 11-01 16:51: the device page doesn't "follow the same design"):
 * its name, an orphans / drift / stale chip, a bar of its units running and the count; a tap opens it in place - the
 * whole count line and its age, why it's stale, what drifted, then its units one line each; its terminals show under it open or not.
 */
function HostCard(props: { h: string; rows: UnitRow[]; check?: UnitRow; shut: boolean; onTap: () => void; children: preact.ComponentChildren }) {
  const { h, rows, check, shut, onTap, children } = props;
  const f = hostFacts(rows, check);
  return (
    <li class={`aip-area tile ai-unit-card ${shut ? "" : "open"}`} data-host={h}>
      <HostRow h={h} n={rows.length} f={f} shut={shut} onTap={onTap} />
      <HostSessions host={h} />
      {!shut && (
        <div class="ai-unit-open">
          <div class="ai-unit-facts">
            {rows.length} units · {f.run} running{f.asleep ? ` · ${f.asleep} asleep` : ""}
            {check && ` · ${ago(Number(check.updated) / 1000)}`}
          </div>
          {f.why && <div class="ai-unit-facts warn">{f.why}</div>}
          {f.drift && <div class="ai-unit-facts warn">unregistered: {check?.purpose} (powos units check)</div>}
          {children}
        </div>
      )}
    </li>
  );
}

/** A host card's row: its name, the chips, the bar of units running and the count. */
function HostRow({ h, n, f, shut, onTap }: { h: string; n: number; f: ReturnType<typeof hostFacts>; shut: boolean; onTap: () => void }) {
  return (
    <button type="button" class="aip-area-row ai-unit-host" aria-expanded={!shut} onClick={onTap}>
      <span class="aip-area-name">{h}</span>
      {f.orph > 0 && <span class="aip-chip">{f.orph} orphan{f.orph > 1 ? "s" : ""}</span>}
      {f.drift && <span class="aip-chip ai-unit-warn">drift</span>}
      {f.stale && <span class="aip-chip ai-unit-warn">stale</span>}
      <ThinBar done={f.run} total={n} />
      <span class="aip-count">
        {f.run}/{n}
      </span>
    </button>
  );
}

/** Per host a card (HostCard): its terminals always (one tap into each), open its units orphans-first, then by status. */
export function Units({ shown }: { shown: boolean }) {
  const [tapped, setTapped] = useState<string | null>(null);
  const all = units.value;
  const hosts = [...new Set(all.map((u) => u.host))].sort(
    (a, b) => (HOSTS.indexOf(a) + 1 || 99) - (HOSTS.indexOf(b) + 1 || 99) || a.localeCompare(b),
  );
  const isOpen = opened();
  const toggle = (h: string) => {
    const s = opened();
    s.has(h) ? s.delete(h) : s.add(h);
    open.value = JSON.stringify([...s]);
  };
  const orphans = all.filter((u) => u.orphan).length;
  return (
    <section class="aip ai-devices">
      {shown && <Feed />}
      <h3 class="ais-h">
        Installed & running<span class="ais-n">{hosts.length}</span>
        {orphans > 0 && <span class="aip-chip">{orphans} to decide</span>}
      </h3>
      <ul class="aip-areas">
        {hosts.map((h) => {
          const rows = all.filter((u) => u.host === h && u.id !== "_check");
          const check = all.find((u) => u.host === h && u.id === "_check");
          rows.sort(
            (a, b) => Number(b.orphan) - Number(a.orphan) || (RANK[a.status] ?? 9) - (RANK[b.status] ?? 9) ||
              Number(b.memKb) - Number(a.memKb) || a.name.localeCompare(b.name),
          );
          return (
            <HostCard key={h} h={h} rows={rows} check={check} shut={!isOpen.has(h)} onTap={() => toggle(h)}>
              <ul class="ai-unit-list">
                {rows.map((u) => (
                  <Line key={u.key} u={u} wide={tapped === u.key} onTap={() => setTapped(tapped === u.key ? null : u.key)} />
                ))}
              </ul>
            </HostCard>
          );
        })}
      </ul>
      {!hosts.length && <div class="aip-empty">No host has published yet (powos units publish)</div>}
    </section>
  );
}
