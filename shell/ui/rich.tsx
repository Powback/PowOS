/**
 * The conversation's rich parts (after SpaceTimeAI's console): what PowOS AI's chat (chat.tsx) and its page (powai.tsx)
 * draw beyond plain lines.
 *   Thread    the items, consecutive tool calls folded into one ToolRun
 *   ToolRun   a run of tool calls on one line - the newest (or the running one) and how many; a tap lists them all, a
 *             tap on one shows what it returned
 *   Said      an assistant message: its prose, and the blocks the manager's comms tools put in it (manager.py
 *             _rich_block: a fence named for the block, one JSON line) - ```choices: the question with tappable options
 *             (a tap answers it: the next turn, in the user's words); ```present: a document (Markdown, or an HTML page)
 *             as a card with its beginning, a tap opens it full screen
 */
import { Fragment, render } from "preact";
import { useState } from "preact/hooks";
import type { ChatItem } from "../types.ts";
import { Icon, type IconName } from "./icons.tsx";
import { askQueued, openAssistant } from "./assistant.ts";
import { powos } from "../bridge.ts";
import { topBack } from "../state.ts";
import { openLink } from "../apps/native.ts";
import { md } from "./md.ts";

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

/** What the user said next after entry [i] (a question's answer), null while nothing yet. */
const replyAfter = (list: Entry[], i: number) => {
  const next = list.slice(i + 1).find((e) => "item" in e && e.item.kind === "user") as { item: { text: string } } | undefined;
  return next ? next.item.text : null;
};

/** The conversation: each item as [render] draws it (with what the user said next), tool runs folded. */
export function Thread({
  items,
  render,
}: {
  items: ChatItem[];
  render: (item: Exclude<ChatItem, ToolItem>, reply: string | null) => preact.ComponentChild;
}) {
  const list = entries(items);
  return (
    <>
      {list.map((e, i) =>
        "tools" in e ? <ToolRun key={i} tools={e.tools} /> : <Fragment key={i}>{render(e.item, replyAfter(list, i))}</Fragment>,
      )}
    </>
  );
}

type Part = { text: string } | { block: string; body: string };

/** Prose and fenced blocks, in order. A fence left open (a reply cut off) runs to the end. */
export function parts(text: string): Part[] {
  const out: Part[] = [];
  const lines = text.split("\n");
  let prose: string[] = [];
  const flush = () => {
    const t = prose.join("\n").trim();
    if (t) out.push({ text: t });
    prose = [];
  };
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^\s*```\s*([\w-]*)/);
    if (!m) {
      prose.push(lines[i]);
      continue;
    }
    flush();
    const end = lines.findIndex((l, j) => j > i && /^\s*```\s*$/.test(l));
    const stop = end < 0 ? lines.length : end;
    out.push({ block: m[1], body: lines.slice(i + 1, stop).join("\n") });
    i = stop;
  }
  flush();
  return out;
}

const json = <T,>(body: string): T | null => {
  try {
    return JSON.parse(body) as T;
  } catch {
    return null;
  }
};

interface Choices {
  question: string;
  options: string[];
  multi?: boolean;
  other?: boolean;
}

/** "other…": the one compose field - the chat surface's pill - with the keyboard up. */
function answerOwnWords() {
  openAssistant();
  window.setTimeout(() => {
    document.querySelector<HTMLTextAreaElement>(".bar textarea")?.focus();
    powos.keyboard.show();
  }, 60);
}

/** A question with options: a tap on one answers it (multi: tap several, then send). Once answered (the user's reply
 *  shows right under it) only the question stays. */
export function ChoiceCard({ c, reply }: { c: Choices; reply: string | null }) {
  const [picked, setPicked] = useState<string[]>([]);
  const tap = (o: string) => {
    if (!c.multi) return askQueued(o);
    setPicked(picked.includes(o) ? picked.filter((p) => p !== o) : c.options.filter((x) => x === o || picked.includes(x)));
  };
  return (
    <div class="choice">
      {c.question && <div class="msg assistant">{c.question}</div>}
      {reply === null && (
        <div class="choice-opts" role="group">
          {c.options.map((o) => (
            <button type="button" key={o} class={`choice-opt ${picked.includes(o) ? "on" : ""}`} aria-pressed={picked.includes(o)} onClick={() => tap(o)}>
              {o}
            </button>
          ))}
          {c.other !== false && (
            <button type="button" class="choice-opt other" onClick={answerOwnWords}>
              other…
            </button>
          )}
          {c.multi && picked.length > 0 && (
            <button type="button" class="choice-opt on" onClick={() => askQueued(picked.join(", "))}>
              send
            </button>
          )}
        </div>
      )}
    </div>
  );
}

interface Presented {
  title: string;
  format: "md" | "html";
  body: string;
}

/** A tap on a Markdown link: opened outside (the page itself never navigates). */
export function onLink(e: MouseEvent) {
  const a = (e.target as Element).closest?.("a[data-link]") as HTMLAnchorElement | null;
  if (!a) return;
  e.preventDefault();
  e.stopPropagation();
  openLink(a.href);
}

/** The theme's colours as values (a sandboxed page can't read the shell's tokens). */
function themeCss() {
  const css = getComputedStyle(document.documentElement);
  const fg = css.getPropertyValue("--color-foreground").trim();
  const accent = css.getPropertyValue("--color-accent").trim();
  // No color-scheme: one unlike the page's makes the frame paint an opaque canvas instead of showing the glass.
  return `html{background:transparent;color:${fg};font:14px/1.45 system-ui,sans-serif}body{margin:12px}a{color:${accent}}img{max-width:100%}`;
}

/**
 * An HTML page as the sandbox shows it: no scripts (the frame's sandbox - the app's JavaScript bridge reaches every
 * frame, so a script there could drive the shell), no network but images (its CSP), the theme's text colour under its
 * own styles. [still]: its animations off (a card in the chat never draws by itself).
 */
function sandboxed(html: string, still: boolean) {
  const head = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; font-src data:"><meta name="viewport" content="width=device-width"><style>${themeCss()}${still ? "*{animation:none!important;transition:none!important}html{overflow:hidden}" : ""}</style>`;
  return /<head[^>]*>/i.test(html) ? html.replace(/<head[^>]*>/i, (m) => m + head) : `<!doctype html><html><head>${head}</head><body>${html}</body></html>`;
}

function Doc({ p, peek }: { p: Presented; peek: boolean }) {
  if (p.format === "html")
    return <iframe class="present-frame" sandbox="" referrerpolicy="no-referrer" title={p.title} srcdoc={sandboxed(p.body, peek)} tabIndex={peek ? -1 : 0} />;
  return <div class="md present-md" onClick={onLink} dangerouslySetInnerHTML={{ __html: md(p.body) }} />;
}

/** The document full screen, over everything (Back or × closes it): drawn into the page's body, out of the chat. */
function openPresented(p: Presented) {
  const host = document.createElement("div");
  document.body.append(host);
  const close = () => {
    if (topBack.peek() === close) topBack.value = null;
    render(null, host);
    host.remove();
  };
  topBack.value = close;
  render(
    <div class="present-full tile sheet" role="dialog" aria-label={p.title}>
      <div class="present-head">
        <span class="present-title">{p.title}</span>
        <button type="button" class="present-close" aria-label="close" onClick={close}>
          <Icon name="close" />
        </button>
      </div>
      <div class="present-body">
        <Doc p={p} peek={false} />
      </div>
    </div>,
    host,
  );
}

/** A presented document in the chat: its title and its beginning; a tap opens it full screen. */
export function PresentCard({ p }: { p: Presented }) {
  const open = () => openPresented(p);
  return (
    <div class="present" role="button" tabIndex={0} onClick={open} onKeyDown={(e) => e.key === "Enter" && open()}>
      <div class="present-head">
        <Icon name="openInNew" />
        <span class="present-title">{p.title}</span>
      </div>
      <div class="present-peek" aria-hidden="true">
        <Doc p={p} peek={true} />
      </div>
    </div>
  );
}

/** An assistant message: prose as a bubble, its blocks as what they are; a code fence as code. */
export function Said({ text, reply }: { text: string; reply: string | null }) {
  return (
    <>
      {parts(text).map((p, i) => {
        if ("text" in p)
          return (
            <div key={i} class="msg assistant">
              {p.text}
            </div>
          );
        if (p.block === "choices") {
          const c = json<Choices>(p.body);
          if (c && Array.isArray(c.options)) return <ChoiceCard key={i} c={c} reply={reply} />;
        }
        if (p.block === "present") {
          const d = json<Presented>(p.body);
          if (d && typeof d.body === "string") return <PresentCard key={i} p={d} />;
        }
        return (
          <pre key={i} class="msg assistant code">
            {p.body}
          </pre>
        );
      })}
    </>
  );
}
