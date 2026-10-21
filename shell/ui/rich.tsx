/**
 * The conversation's rich parts (after SpaceTimeAI's console): what PowOS AI's chat (chat.tsx) and its page (powai.tsx)
 * draw beyond plain lines.
 *   Thread    the items, consecutive tool calls folded into one ToolRun
 *   ToolRun   a run of tool calls on one line - the newest (or the running one) and how many; a tap lists them all, a
 *             tap on one shows what it returned
 */
import { Fragment } from "preact";
import { useState } from "preact/hooks";
import type { ChatItem } from "../types.ts";
import { Icon, type IconName } from "./icons.tsx";

export type ToolItem = Extract<ChatItem, { kind: "tool" }>;

/** The tool's own name: an MCP tool's last part ("mcp__comms__send_message" -> "send_message"). */
const bare = (name: string) => name.split("__").at(-1) ?? name;

/** Calls the chat draws as something else (a choice card, a presentation): not listed as steps. */
export const shownElsewhere = (t: ToolItem) => /^(present|present_choices)$/.test(bare(t.name));

const ICON: Record<string, IconName> = {
  Bash: "console",
  Read: "eyeOutline",
  Edit: "pencilOutline",
  Write: "pencilOutline",
  NotebookEdit: "pencilOutline",
  Grep: "magnify",
  Glob: "magnify",
  WebFetch: "web",
  WebSearch: "web",
  Task: "robotOutline",
  Agent: "robotOutline",
};
const VERB: Record<string, string> = {
  Bash: "ran",
  Read: "read",
  Edit: "edited",
  Write: "wrote",
  NotebookEdit: "edited",
  Grep: "searched",
  Glob: "listed",
  WebFetch: "fetched",
  WebSearch: "searched the web",
  Task: "asked an agent",
  Agent: "asked an agent",
  TodoWrite: "planned",
};
const iconOf = (t: ToolItem): IconName => ICON[t.name] ?? (t.name.startsWith("mcp__") ? "chip" : "cogOutline");
/** Paths read as their file's name; a command as it is. */
const argOf = (t: ToolItem) => (/^(Read|Edit|Write|NotebookEdit)$/.test(t.name) ? (t.hint.split("/").at(-1) ?? t.hint) : t.hint);

/** What a step line says before its argument: "ran", "read", "send message". */
export const toolLabel = (t: ToolItem) => VERB[t.name] ?? bare(t.name).replace(/_/g, " ");

function Status({ t }: { t: ToolItem }) {
  if (t.ok === null) return <span class="tl-spin" aria-label="running" />;
  if (!t.ok) return <Icon name="alertCircleOutline" class="tl-fail" />;
  return <Icon name={iconOf(t)} class="tl-icon" />;
}

function Step({ t }: { t: ToolItem }) {
  const [open, setOpen] = useState(false);
  const out = t.out?.trim();
  return (
    <>
      <button type="button" class={`tl-row ${out ? "has-out" : ""}`} onClick={() => out && setOpen(!open)} aria-expanded={out ? open : undefined}>
        <Status t={t} />
        <span class="tl-verb">{toolLabel(t)}</span>
        <span class={`tl-arg ${t.name === "Bash" ? "code" : ""}`}>{argOf(t)}</span>
      </button>
      {open && out && <pre class="tl-out">{out}</pre>}
    </>
  );
}

/** A run of consecutive tool calls: one line (the running one, else the newest) and a count; a tap lists them all. */
export function ToolRun({ tools }: { tools: ToolItem[] }) {
  const [open, setOpen] = useState(false);
  const shown = tools.filter((t) => !shownElsewhere(t));
  if (!shown.length) return null;
  if (shown.length === 1 || open)
    return (
      <div class="tl">
        {shown.map((t, i) => (
          <Step key={i} t={t} />
        ))}
        {open && (
          <button type="button" class="tl-more" onClick={() => setOpen(false)}>
            fewer
          </button>
        )}
      </div>
    );
  const head = shown.find((t) => t.ok === null) ?? shown.at(-1)!;
  const failed = shown.filter((t) => t.ok === false).length;
  return (
    <div class="tl">
      <button type="button" class="tl-row" onClick={() => setOpen(true)} aria-expanded={false}>
        <Status t={head} />
        <span class="tl-verb">{toolLabel(head)}</span>
        <span class={`tl-arg ${head.name === "Bash" ? "code" : ""}`}>{argOf(head)}</span>
        <span class="tl-count">
          {failed ? `${failed} failed · ` : null}
          {shown.length} steps
        </span>
      </button>
    </div>
  );
}

type Entry = { tools: ToolItem[] } | { item: Exclude<ChatItem, ToolItem> };

/** The items with each run of consecutive tool calls as one entry. */
export function entries(items: ChatItem[]): Entry[] {
  const out: Entry[] = [];
  for (const item of items) {
    const last = out.at(-1);
    if (item.kind !== "tool") out.push({ item });
    else if (last && "tools" in last) last.tools.push(item);
    else out.push({ tools: [item] });
  }
  return out;
}

/** The conversation: each item as [render] draws it, tool runs folded. */
export function Thread({ items, render }: { items: ChatItem[]; render: (item: Exclude<ChatItem, ToolItem>) => preact.ComponentChild }) {
  return (
    <>
      {entries(items).map((e, i) => ("tools" in e ? <ToolRun key={i} tools={e.tools} /> : <Fragment key={i}>{render(e.item)}</Fragment>))}
    </>
  );
}
