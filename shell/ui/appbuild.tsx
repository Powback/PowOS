/**
 * "Create app" in PowOS AI: what the app should do is asked here, then PowOS AI builds it in a thread of its own
 * (PowosAiChat.newApp: a fresh directory, a fresh manager session - not the main conversation's busy one). Its work
 * shows as a few friendly steps (set up, the logic, the page, the widget, build and install), not tool lines, and the
 * finished app as a card that opens it.
 */
import { signal } from "@preact/signals";
import { useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import { chat, editing, page } from "../state.ts";
import { installedApps, manifestOf, moduleUrl, openApp } from "../apps/pages.ts";
import type { ChatItem } from "../types.ts";

/** The "what should it do?" card is up on PowOS AI's page. */
export const newAppAsk = signal(false);

/** From the edit sheet: to PowOS AI's page, asking what to build. */
export function startNewApp() {
  editing.value = false;
  page.value = -1;
  newAppAsk.value = true;
}

type Tool = Extract<ChatItem, { kind: "tool" }>;

/** A tool use as a step a person would name. */
function stepOf(t: Tool): string {
  const h = t.hint;
  if (/powos app new\b/.test(h)) return "Setting up the project";
  if (/powos app (install|build)\b/.test(h)) return t.ok === false ? "Build failed - fixing it" : "Building and installing";
  if (/powos app publish\b/.test(h)) return "Updating the app's logic";
  if (/module\//.test(h)) return "Writing the app's logic";
  if (/ui\/widgets\//.test(h)) return "Making the home widget";
  if (/ui\/pages\/|ui\/lib\//.test(h)) return "Designing the page";
  if (/powos-app\.json/.test(h)) return "Describing the app";
  if (/^(Read|Grep|Glob|LS)$/.test(t.name)) return "Looking around";
  return "Working";
}

/** The app's id, from its `powos app new <name>` (a name without a dot is local.<name>). */
function appIdOf(items: ChatItem[]) {
  for (const i of items) {
    const m = i.kind === "tool" ? /powos app new\s+([a-z0-9][a-z0-9.-]*)/.exec(i.hint) : null;
    if (m) return m[1].includes(".") ? m[1] : `local.${m[1]}`;
  }
  return null;
}

export function NewAppAsk() {
  const [text, setText] = useState("");
  const [why, setWhy] = useState<string | null>(null);
  const go = async (e: Event) => {
    e.preventDefault();
    if (!text.trim()) return;
    const ok = await powos.ai.newApp(text.trim());
    if (ok) newAppAsk.value = false;
    else setWhy("PowOS AI is busy with something else - try again in a moment.");
  };
  return (
    <section class="ai-card tile">
      <div class="ai-asked">New app</div>
      <form onSubmit={go} style={{ display: "flex", flexDirection: "column", gap: "10px" }}>
        <input
          value={text}
          onInput={(e) => setText((e.currentTarget as HTMLInputElement).value)}
          onFocus={() => powos.keyboard.show()}
          placeholder="What should it do? e.g. a shared shopping list"
          enterKeyHint="go"
          autocomplete="off"
          style={{ font: "inherit", padding: "10px 12px", borderRadius: "12px", border: 0, outline: 0, background: "var(--soft-fill)", color: "inherit" }}
        />
        <div style={{ display: "flex", gap: "10px", justifyContent: "flex-end" }}>
          <button type="button" class="sheet-item" onClick={() => (newAppAsk.value = false)}>
            cancel
          </button>
          <button type="submit" class="sheet-item">
            create
          </button>
        </div>
      </form>
      {why && <div class="ai-note muted">{why}</div>}
    </section>
  );
}

/** The app-building thread: steps, the finished app's card, PowOS AI's last words; back to the main conversation. */
export function AppBuild() {
  const { busy, items } = chat.value;
  const asked = (items.find((i) => i.kind === "user") as { text: string } | undefined)?.text ?? "";
  // Consecutive tool uses with the same step are one step; its state the last of them.
  const steps: { label: string; ok: boolean | null }[] = [];
  for (const i of items) {
    if (i.kind !== "tool") continue;
    const label = stepOf(i);
    const last = steps.at(-1);
    if (last && last.label === label) last.ok = i.ok;
    else steps.push({ label, ok: i.ok });
  }
  const id = appIdOf(items);
  const installed = items.some((i) => i.kind === "tool" && /powos app install\b/.test(i.hint) && i.ok === true);
  const app = id ? installedApps.value.find((a) => a.id === id) : undefined;
  const answer = (items.filter((i) => i.kind === "assistant").at(-1) as { text: string } | undefined)?.text;
  const notes = items.filter((i) => i.kind === "note") as Extract<ChatItem, { kind: "note" }>[];
  const icon = app && manifestOf(app).icon ? moduleUrl(app.id, manifestOf(app).icon!, app.version) : null;
  return (
    <section class="ai-card tile">
      <div style={{ display: "flex", alignItems: "center", gap: "8px" }}>
        <span class="ai-asked" style={{ flex: 1 }}>
          New app: {asked}
        </span>
        <button type="button" class="ai-open" disabled={busy} onClick={() => powos.ai.closeThread()} title={busy ? "when it's done" : ""}>
          PowOS AI ›
        </button>
      </div>
      <div class="ai-steps">
        {steps.map((s, i) => (
          <div key={i} class="ai-step">
            <span class={s.ok == null ? "run" : s.ok ? "ok" : "fail"}>{s.ok == null ? "…" : s.ok ? "✓" : "✗"}</span> {s.label}
          </div>
        ))}
        {busy && !steps.length && <div class="ai-step muted">Getting started…</div>}
      </div>
      {installed && app && (
        <button
          type="button"
          class="ai-session tile"
          onClick={() => openApp(app.id)}
          style={{ display: "flex", alignItems: "center", gap: "12px", width: "100%", textAlign: "left" }}
        >
          {icon && <img src={icon} alt="" style={{ width: "40px", height: "40px", borderRadius: "10px" }} />}
          <span class="ai-session-main">
            <span class="ai-session-task">{app.name}</span>
            <span class="ai-session-meta muted">ready - tap to open (it's in your drawer too)</span>
          </span>
        </button>
      )}
      {answer && <div class="ai-answer">{answer}</div>}
      {notes.map((n, i) => (
        <div key={i} class={`ai-note ${n.error ? "error" : "muted"}`}>
          {n.text}
        </div>
      ))}
      {busy && <div class="ai-thinking muted">building…</div>}
    </section>
  );
}
