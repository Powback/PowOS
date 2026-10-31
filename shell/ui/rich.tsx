/**
 * The conversation's rich parts (after SpaceTimeAI's console): what PowOS AI's chat (chat.tsx) and its page (powai.tsx)
 * draw beyond plain lines.
 *   Thread    the items, consecutive tool calls folded into one ToolRun
 *   ToolRun   a run of tool calls on one line - the newest (or the running one) and how many; a tap lists them all, a
 *             tap on one shows what it returned
 *   Said      an assistant message: its prose (Markdown: md.ts), and the blocks the manager's comms tools put in it (manager.py
 *             _rich_block: a fence named for the block, one JSON line) - ```choices: the question with tappable options
 *             (a tap answers it: the next turn, in the user's words); ```present: a document (Markdown, or an HTML page)
 *             as a card with its beginning, a tap opens it full screen
 */
import { Fragment, render } from "preact";
import { useState } from "preact/hooks";
import { signal } from "@preact/signals";
import type { ChatItem } from "../types.ts";
import { Icon, type IconName } from "./icons.tsx";
import { askQueued, openAssistant, unqueue, waiting } from "./assistant.ts";
import { powos } from "../bridge.ts";
import { topBack } from "../state.ts";
import { openLink } from "../apps/native.ts";
import { md } from "./md.ts";

export type ToolItem = Extract<ChatItem, { kind: "tool" }>;

/** The tool's own name: an MCP tool's last part ("mcp__comms__send_message" -> "send_message"). */
const bare = (name: string) => name.split("__").at(-1) ?? name;

/** Calls the chat draws as something else (a choice card, a presentation): not listed as steps. */
export const shownElsewhere = (t: ToolItem) => /^(present|present_choices|present_try)$/.test(bare(t.name));

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
/**
 * What a step says, in plain words (the user, 2026-10-31 13:03: "It looks complete trash" - "SendMessage a06c1853… 2
 * steps"): never a tool's internal name or an id. Unknown tools read by what they touch, else "worked on it".
 */
const PLAIN: Record<string, string> = {
  Bash: "ran a command",
  Read: "read a file",
  Edit: "edited a file",
  Write: "wrote a file",
  NotebookEdit: "edited a file",
  Grep: "searched the code",
  Glob: "looked for files",
  WebFetch: "read a web page",
  WebSearch: "searched the web",
  Task: "asked an agent",
  Agent: "asked an agent",
  SendMessage: "messaged an agent",
  TaskStop: "stopped an agent",
  TodoWrite: "planned",
};
const PLAIN_MCP: [RegExp, string][] = [
  [/board|task|work|progress/, "checked the board"],
  [/mail|message|send|inbox/, "messaged an agent"],
  [/agent|spawn|session/, "checked the agents"],
  [/screen|shot|phone|device/, "looked at the phone"],
];
const iconOf = (t: ToolItem): IconName => ICON[t.name] ?? (t.name.startsWith("mcp__") ? "chip" : "cogOutline");
/** What a step line says: "read a file", "checked the board". */
export const toolLabel = (t: ToolItem) => PLAIN[t.name] ?? PLAIN_MCP.find(([re]) => re.test(bare(t.name).toLowerCase()))?.[1] ?? "worked on it";

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
        <span class="tl-count">
          {" · "}
          {failed ? `${failed} failed · ` : null}
          {shown.length} steps
        </span>
      </button>
    </div>
  );
}

type NoteItem = Extract<ChatItem, { kind: "note" }>;
type Entry = { tools: ToolItem[] } | { mails: NoteItem[] } | { item: Exclude<ChatItem, ToolItem> };

const isMail = (i: ChatItem): i is NoteItem => i.kind === "note" && !i.error && !!mailOf(i.text);
/** The host's "didn't answer" after a turn that did act (tool steps, a block): not an error the user should see. */
const quietFail = (i: ChatItem, acted: boolean) => acted && i.kind === "note" && i.error && /didn't answer/.test(i.text);

/** [item] onto [out]: a tool call onto the run before it, an agent's mail onto the mail before it, else its own entry. */
function push(out: Entry[], item: ChatItem) {
  const last = out.at(-1);
  if (item.kind === "tool") return last && "tools" in last ? void last.tools.push(item) : void out.push({ tools: [item] });
  if (isMail(item)) return last && "mails" in last ? void last.mails.push(item) : void out.push({ mails: [item] });
  out.push({ item });
}

/** The items with each run of consecutive tool calls as one entry, each run of agents' mail as one. */
export function entries(items: ChatItem[]): Entry[] {
  const out: Entry[] = [];
  let acted = false;
  for (const item of items) {
    if (item.kind === "user") acted = false;
    else if (item.kind === "tool" || item.kind === "assistant") acted = true;
    if (!quietFail(item, acted)) push(out, item);
  }
  return out;
}

/** Agents' messages to the user: one plain line ("2 updates from agents"); a tap opens them, another folds them. */
export function AgentUpdates({ n, children }: { n: number; children: preact.ComponentChildren }) {
  const [open, setOpen] = useState(false);
  return (
    <div class={`ai-updates ${open ? "open" : ""}`}>
      <button type="button" class="ai-updates-head" aria-expanded={open} onClick={() => setOpen(!open)}>
        {n === 1 ? "1 update from an agent" : `${n} updates from agents`}
        <span class="mail-chev" aria-hidden="true" />
      </button>
      {open && <div class="ai-updates-list">{children}</div>}
    </div>
  );
}

/** What the user said next after entry [i] (a question's answer), null while nothing yet. */
const replyAfter = (list: Entry[], i: number) => {
  const next = list.slice(i + 1).find((e) => "item" in e && e.item.kind === "user") as { item: { text: string } } | undefined;
  return next ? next.item.text : null;
};

/** One entry: a tool run's line, agents' mail as one line, or the item as [render] draws it. */
function EntryView({ e, reply, render }: { e: Entry; reply: () => string | null; render: (item: Exclude<ChatItem, ToolItem>, reply: string | null) => preact.ComponentChild }) {
  if ("tools" in e) return <ToolRun tools={e.tools} />;
  if ("mails" in e)
    return (
      <AgentUpdates n={e.mails.length}>
        {e.mails.map((m, j) => (
          <MailCard key={j} text={m.text} />
        ))}
      </AgentUpdates>
    );
  return <>{render(e.item, reply())}</>;
}

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
      {list.map((e, i) => (
        <EntryView key={i} e={e} reply={() => replyAfter(list, i)} render={render} />
      ))}
    </>
  );
}

type Part = { text: string } | { block: string; body: string };

/** The fences that are blocks of their own (manager.py _rich_block); any other fence is code, part of the prose. */
const BLOCK = /^\s*```(choices|present|try)\s*$/;

/** Prose (Markdown, its code fences in it) and blocks, in order. A fence left open (a reply cut off) runs to the end. */
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
    const open = /^\s*```/.test(lines[i]);
    const end = open ? lines.findIndex((l, j) => j > i && /^\s*```\s*$/.test(l)) : -1;
    const stop = end < 0 ? lines.length : end;
    const m = lines[i].match(BLOCK);
    if (!m) {
      // A code fence goes to the prose whole: a "```present" line inside it is code.
      prose.push(...lines.slice(i, open ? stop + 1 : i + 1));
      if (open) i = stop;
      continue;
    }
    flush();
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
    // Home: the pill; over an app (assist mode): the panel's own field.
    document.querySelector<HTMLElement>(".bar textarea, .assist-ask input")?.focus();
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
/** [title] and [body] full screen, over everything (Back or x closes it): drawn into the page's body, out of the chat. */
export function openFull(title: string, body: preact.ComponentChild) {
  const host = document.createElement("div");
  document.body.append(host);
  const close = () => {
    if (topBack.peek() === close) topBack.value = null;
    render(null, host);
    host.remove();
  };
  topBack.value = close;
  render(
    <div class="present-full tile sheet" role="dialog" aria-label={title}>
      <div class="present-head">
        <span class="present-title">{title}</span>
        <button type="button" class="present-close" aria-label="close" onClick={close}>
          <Icon name="close" />
        </button>
      </div>
      <div class="present-body">{body}</div>
    </div>,
    host,
  );
}

const openPresented = (p: Presented) => openFull(p.title, <Doc p={p} peek={false} />);

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

/**
 * Blocks drawn by a module of their own, by fence name (trycard.tsx: ```try): it registers here on import, as this
 * module can't import it (it imports this one). A renderer's null: the block shows as code.
 */
export const blocks: Record<string, (body: string, reply: string | null) => preact.ComponentChild> = {};

/** An assistant message: its prose as Markdown in a bubble, its blocks as what they are. */
export function Said({ text, reply }: { text: string; reply: string | null }) {
  return (
    <>
      {parts(text).map((p, i) => {
        if ("text" in p) return <div key={i} class="msg assistant md" onClick={onLink} dangerouslySetInnerHTML={{ __html: md(p.text) }} />;
        if (p.block === "choices") {
          const c = json<Choices>(p.body);
          if (c && Array.isArray(c.options)) return <ChoiceCard key={i} c={c} reply={reply} />;
        }
        if (p.block === "present") {
          const d = json<Presented>(p.body);
          if (d && typeof d.body === "string") return <PresentCard key={i} p={d} />;
        }
        const own = blocks[p.block]?.(p.body, reply);
        if (own) return <Fragment key={i}>{own}</Fragment>;
        // A block that can't be read: shown as what it is.
        return <div key={i} class="msg assistant md" dangerouslySetInnerHTML={{ __html: md("```\n" + p.body + "\n```") }} />;
      })}
    </>
  );
}

/** The question, not the screen text the side button sends along with it (assist.tsx). */
const asked = (text: string) => text.split("\n\n[What's on my screen right now")[0];

/**
 * What the user sent while a turn was under way, oldest first: their words at once, right-aligned with no bubble yet,
 * marked "queued", each with a x that takes it back. Its turn starting, it becomes a normal bubble (the chat's own).
 */
export function Queued() {
  const q = waiting.value;
  if (!q.length) return null;
  return (
    <>
      {q.map((w) => (
        <div key={w.id} class="msg user queued">
          <span class="queued-text">{asked(w.text)}</span>
          <SentImages text={w.text} />
          <span class="queued-mark">
            queued
            <button type="button" class="queued-x" aria-label="don't send" onClick={() => unqueue(w.id)}>
              <Icon name="close" />
            </button>
          </span>
        </div>
      ))}
    </>
  );
}

/**
 * The images a message sent (the side button's screen and circled part, live frames, shares): their paths are in its
 * stored text, so the history keeps them. The circled part alone when there is one (it's what the user meant).
 */
const SENT = /\/run\/powos-app\/powos-ai-shared\/([A-Za-z0-9._-]+\.(?:png|jpg))\b/g;
export function sentImages(text: string): string[] {
  const circled = text.match(/the part of the screen I circled: \/run\/powos-app\/powos-ai-shared\/([A-Za-z0-9._-]+\.(?:png|jpg))/);
  if (circled) return [circled[1]];
  return [...new Set([...text.matchAll(SENT)].map((m) => m[1]))].filter((n) => !n.includes(".."));
}

/**
 * The host serves /_shared/ (an image of it loaded): only then does a missing one mean "cleaned up" - an older app
 * has no such route, and there the thumbnails simply don't show.
 */
const sharedServed = signal(false);

/** One sent image: a thumbnail (a tap: full screen), or a quiet "no longer available" once it's been cleaned up. */
function Sent({ name }: { name: string }) {
  const [gone, setGone] = useState(false);
  const url = `/_shared/${encodeURIComponent(name)}`;
  if (gone) return sharedServed.value ? <span class="sent-gone">image no longer available</span> : null;
  return (
    <button type="button" class="sent-img" onClick={() => openFull("what you sent", <img class="ai-img-full" src={url} alt="" />)}>
      <img src={url} alt="what you sent" loading="lazy" onLoad={() => (sharedServed.value = true)} onError={() => setGone(true)} />
    </button>
  );
}

/** The images [text] sent, as thumbnails (nothing when it sent none). */
export function SentImages({ text }: { text: string }) {
  const names = sentImages(text);
  if (!names.length) return null;
  return (
    <span class="sent-imgs">
      {names.map((n) => (
        <Sent key={n} name={n} />
      ))}
    </span>
  );
}

/** A design-qa review image as the page can load it (ShellHost /_qa/: a bare name of that folder), else null. */
export const qaUrl = (path: string) =>
  /^\/home\/powos\/design-qa\/[A-Za-z0-9._-]+\.(png|jpg)$/.test(path) && !path.includes("..") ? `/_qa/${encodeURIComponent(path.split("/").pop()!)}` : null;

/**
 * A review image as the page can load it: design-qa's (/_qa/) or one PowOS AI was sent (powos-ai-shared, /_shared/:
 * the side button's screen, a "still broken" screenshot), else null.
 */
export function imageUrl(path: string): string | null {
  const shared = path.match(/\/powos-ai-shared\/([A-Za-z0-9._-]+\.(?:png|jpg))$/);
  return qaUrl(path) ?? (shared && !shared[1].includes("..") ? `/_shared/${encodeURIComponent(shared[1])}` : null);
}

/** "mail from coder: …" (PowosAiChat's line for an agent's message): who sent it and what it says. */
export function mailOf(text: string): { from: string; body: string } | null {
  const m = text.match(/^mail from ([^:]{1,40}): ([\s\S]*)$/);
  if (!m) return null;
  // The agent often starts with its own name again ("coder: ack - ...").
  return { from: m[1], body: m[2].replace(new RegExp(`^${m[1].replace(/[^\w-]/g, "")}:\s*`), "").trim() };
}

/** Commit hashes and agent ids ("611b9f8a", "(ae943ed)") out of what a person reads. */
const unhashed = (t: string) => t.replace(/\s*\((?:[0-9a-f]{7,40}(?:[,\s/]+)?)+\)/g, "").replace(/\b[0-9a-f]{7,40}\b/g, "").replace(/[ \t]{2,}/g, " ");

/**
 * Its first sentence, plain: what the mail is about - asides in brackets, review image paths and a status lead word
 * ("SHIPPED:") out, the first letter capital; one line, so the card folds to who + this.
 */
const firstSentence = (body: string) => {
  const t = unhashed(body)
    .replace(/\s+/g, " ")
    .replace(/,?\s*(review\s+)?\/home\/powos\/design-qa\/[A-Za-z0-9._-]+\.(png|jpg)/g, "")
    .replace(/\s*\([^()]{0,120}\)/g, "")
    .replace(/^(ack|fyi|note)\s*[-:]\s*/i, "")
    .replace(/^(SHIPPED|IN PROGRESS|BLOCKED|DONE|NEXT|WAITING ON YOU|WAITING)\b:?\s*(-\s*)?/, "")
    .replace(/\s+([.,;:!?])/g, "$1")
    .trim();
  const m = t.match(/^(.{12,160}?[.!?])(\s|$)/);
  const one = (m ? m[1] : t.length > 140 ? `${t.slice(0, 140).trimEnd()}…` : t).replace(/[:;,]$/, "");
  return one.charAt(0).toUpperCase() + one.slice(1);
};

/** The body as Markdown: "SHIPPED:" / "IN PROGRESS" / "X:" lead lines as quiet headers, " - " runs as a list. */
function mailMd(body: string) {
  return unhashed(body)
    // Review images show as thumbnails under it: their paths aren't words to read.
    .replace(/,?\s*(review\s+)?\/home\/powos\/design-qa\/[A-Za-z0-9._-]+\.(png|jpg)/g, "")
    // Status words anywhere ("... tweaks IN PROGRESS: - ...") start a section.
    .replace(/\s*\b(SHIPPED|IN PROGRESS|BLOCKED|DONE|NEXT|WAITING ON YOU|WAITING)\b:?\s*/g, "\n\n##### $1\n")
    .replace(/\s+-\s+(?=[A-Za-z(])/g, "\n- ")
    .split("\n")
    .map((l) => (/^\s*([A-Z][A-Z /]{2,30}|[A-Z][\w -]{1,24}):\s*$/.test(l) ? `##### ${l.trim().replace(/:$/, "")}` : l.replace(/^\s*([A-Z][A-Z /]{3,30}):\s+/, "##### $1\n")))
    .join("\n");
}

/**
 * An agent's message in the chat: folded, one line - who and the gist, a chevron; a tap opens it (Markdown, its
 * images), another folds it again.
 */
export function MailCard({ text }: { text: string }) {
  const [open, setOpen] = useState(false);
  const mail = mailOf(text)!;
  const images = [...mail.body.matchAll(/\/home\/powos\/design-qa\/[A-Za-z0-9._-]+\.(?:png|jpg)/g)].map((m) => m[0]);
  return (
    <div class={`mail ${open ? "open" : ""}`}>
      <button type="button" class="mail-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <span class="ai-dot on" />
        <span class="mail-from">{mail.from}</span>
        {!open && <span class="mail-sum">{firstSentence(mail.body)}</span>}
        <span class="mail-chev" aria-hidden="true" />
      </button>
      {open && (
        <>
          <div class="md mail-body" onClick={onLink} dangerouslySetInnerHTML={{ __html: md(mailMd(mail.body)) }} />
          {images.length > 0 && (
            <div class="ai-imgs">
              {images.map((p) => {
                const url = qaUrl(p)!;
                return (
                  <button key={p} type="button" class="ai-img" onClick={() => openFull(p.split("/").pop()!, <img class="ai-img-full" src={url} alt="" />)}>
                    <img src={url} alt="" loading="lazy" />
                  </button>
                );
              })}
            </div>
          )}
        </>
      )}
    </div>
  );
}
