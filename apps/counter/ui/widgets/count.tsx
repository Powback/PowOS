// The counter app's home widget: an island in the shell's one shared page (shell/ui/island.tsx). Live through a
// direct subscription to its database on the device's SpacetimeDB; a tap is a reducer call, and the row comes back
// through the subscription (the latency shown is that round trip). The module version shows which module wrote the
// count: republish the module (powos app publish) and the next tap says so, the connection never dropping.
import { useState } from "preact/hooks";
import { DbConnection } from "../bindings";

type Host = import("../../../../shell/apps/stdb.ts").IslandHost;

const DB = "powos-counter";

export default function Count({ host, cells }: { host: Host; cells: [number, number] }) {
  const db = host.useDb(DB, DbConnection);
  const counter = host.useRows<any>(db, "counter", "SELECT * FROM counter")[0];
  const taps = host.useRows<any>(db, "tap", "SELECT * FROM tap");
  const [rtt, setRtt] = useState<number | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const add = async (by: number, e: Event) => {
    e.stopPropagation();
    if (!db.conn) return;
    const t0 = performance.now();
    try {
      await db.conn.reducers.add({ by: BigInt(by) });
      setRtt(Math.round(performance.now() - t0));
      setErr(null);
    } catch (x) {
      setErr(String((x as Error)?.message ?? x));
    }
  };
  const small = cells[1] < 2;
  const dot = db.status === "connected" ? "var(--color-green, #4c4)" : db.status === "error" ? "var(--color-red, #c44)" : "var(--color-yellow, #cc4)";
  const btn = {
    font: "inherit", fontSize: "1.3em", minWidth: "2.4em", padding: "0.2em 0.6em", borderRadius: "999px",
    border: "1px solid var(--color-foreground, #fff)", background: "transparent", color: "inherit",
  };
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%", padding: "10px 14px", boxSizing: "border-box", gap: "4px" }}>
      <div style={{ display: "flex", alignItems: "center", gap: "6px", opacity: 0.75, fontSize: "0.8em" }}>
        <span style={{ width: "8px", height: "8px", borderRadius: "50%", background: dot }} />
        <span style={{ flex: 1 }}>counter · {db.status}</span>
        {rtt != null && <span>{rtt} ms</span>}
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: "10px", flex: 1 }}>
        <button style={btn} onClick={(e) => add(-1, e)} onPointerDown={(e) => e.stopPropagation()}>−</button>
        <div style={{ flex: 1, textAlign: "center", fontSize: small ? "1.8em" : "2.8em", fontWeight: 600, fontVariantNumeric: "tabular-nums" }}>
          {counter ? String(counter.value) : "…"}
        </div>
        <button style={btn} onClick={(e) => add(1, e)} onPointerDown={(e) => e.stopPropagation()}>+</button>
      </div>
      {!small && (
        <div style={{ opacity: 0.6, fontSize: "0.75em", display: "flex", gap: "8px" }}>
          <span style={{ flex: 1 }}>{err ?? `${taps.length} recent taps`}</span>
          {counter && <span>module {counter.module}</span>}
        </div>
      )}
    </div>
  );
}
