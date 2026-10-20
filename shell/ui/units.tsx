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
const units = signal<UnitRow[]>([]);
const open = stored("powai.units.open", "[]");
const opened = () => {
  try {
    return new Set<string>(JSON.parse(open.value));
  } catch {
    return new Set<string>();
  }
};
const HOSTS = ["phone", "phone-android", "mac", "colima", "powstation"];
const RANK: Record<string, number> = { running: 0, asleep: 1, stopped: 2, installed: 3, missing: 4 };
const mb = (kb: bigint | number) => (Number(kb) ? `${Math.round(Number(kb) / 1024)} MB` : "");

function Feed() {
  const db = useDb("powos-agents", AgentsDb);
  const rows = useRows<UnitRow>(db, "unit", "SELECT * FROM unit");
  useEffect(() => {
    if (db.status === "connected" && rows.length) units.value = rows;
  }, [rows, db.status]);
  return null;
}

function Line({ u, onTap, wide }: { u: UnitRow; onTap: () => void; wide: boolean }) {
  const cpu = u.cpuPermille ? ` · ${(u.cpuPermille / 10).toFixed(1)}%` : "";
  return (
    <button type="button" class={`ai-work ai-unit ${u.orphan ? "orphan" : ""}`} onClick={onTap}>
      <span class="ai-work-line">
        <span class={`ai-dot ${u.status === "running" ? "on" : ""} ${u.status}`} />
        <span class="ai-work-title">
          {u.orphan && <span class="ai-unit-flag">orphan · </span>}
          {u.name}
        </span>
        <span class="ai-work-meta muted">
          {u.status}
          {mb(u.memKb) && ` · ${mb(u.memKb)}`}
          {cpu}
        </span>
      </span>
      {wide && (
        <span class="ai-work-detail muted">
          {u.orphan && u.decide && <span class="ai-unit-decide">{u.decide}</span>}
          <span class="ai-work-note">{u.purpose}</span>
          <span>
            {u.owner} · {u.kind} · limits {u.limits || "-"}
            {u.autosleep && u.autosleep !== "-" ? ` · sleeps ${u.autosleep}` : ""} · {u.id}
          </span>
        </span>
      )}
    </button>
  );
}

/** Per host: a folding group (orphans and drift in its header), its units orphans-first, then by status. */
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
    <section class="ai-work-list">
      {shown && <Feed />}
      <h3 class="ai-heading ai-work-head tile">
        installed & running{orphans ? ` · ${orphans} to decide` : ""}
      </h3>
      <div class="ai-work-box tile">
        {hosts.map((h) => {
          const rows = all.filter((u) => u.host === h && u.id !== "_check");
          const check = all.find((u) => u.host === h && u.id === "_check");
          const orph = rows.filter((u) => u.orphan).length;
          const run = rows.filter((u) => u.status === "running").length;
          const asleep = rows.filter((u) => u.status === "asleep").length;
          const shut = !isOpen.has(h);
          rows.sort(
            (a, b) => Number(b.orphan) - Number(a.orphan) || (RANK[a.status] ?? 9) - (RANK[b.status] ?? 9) ||
              Number(b.memKb) - Number(a.memKb) || a.name.localeCompare(b.name),
          );
          return (
            <div key={h} class="ai-work-group">
              <button type="button" class="ai-work ai-work-project" onClick={() => toggle(h)}>
                <span class="ai-work-line">
                  <span class="ai-work-caret muted">{shut ? "▸" : "▾"}</span>
                  <span class="ai-work-title">{h}</span>
                  <span class="ai-work-meta muted">
                    {rows.length} units · {run} running{asleep ? ` · ${asleep} asleep` : ""}
                    {orph > 0 && <span class="ai-unit-flag"> · {orph} orphan{orph > 1 ? "s" : ""}</span>}
                    {check?.status === "drift" && <span class="ai-work-blocked"> · drift</span>}
                    {check && <span> · {ago(Number(check.updated) / 1000)}</span>}
                  </span>
                </span>
                {!shut && check?.status === "drift" && (
                  <span class="ai-work-detail muted">unregistered: {check.purpose} (powos units check)</span>
                )}
              </button>
              {!shut &&
                rows.map((u) => (
                  <Line key={u.key} u={u} wide={tapped === u.key} onTap={() => setTapped(tapped === u.key ? null : u.key)} />
                ))}
            </div>
          );
        })}
        {!hosts.length && <div class="ai-work-empty muted">no host has published yet (powos units publish)</div>}
      </div>
    </section>
  );
}
