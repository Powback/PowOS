/**
 * Markdown for what PowOS AI writes (after SpaceTimeAI's console md.ts): everything is escaped first, so nothing the
 * model writes becomes markup by itself. Blocks: paragraphs, headings, lists (nested by indent), quotes, fenced code,
 * tables and rules; inline: code, bold, italic, links (https only, opened outside: data-link) and images (https or
 * data:image). A reply cut off mid-block (an open fence, a table without its rule yet) renders as far as it came.
 */

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

type Block = (ls: string[], i: number) => [html: string, next: number] | null;

const FENCE = /^\s*(```|~~~)/;
const RULE = /^\s*([-*_])(\s*\1){2,}\s*$/;
const ITEM = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;
const TROW = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;
const STARTS = /^\s*(```|~~~|#{1,6}\s|>|([-*+]|\d+[.)])\s)/;

// On escaped text: a URL's & is &amp; already, which is what an attribute wants.
const spans = (h: string) =>
  h
    .replace(/!\[([^\]\n]*)\]\(((?:https:\/\/|data:image\/)[^\s)]+)\)/g, '<img src="$2" alt="$1" loading="lazy">')
    .replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" data-link>$1</a>')
    .replace(/\*\*([^*\n]+)\*\*/g, "<b>$1</b>")
    .replace(/(^|[^*\w])\*([^*\s][^*\n]*)\*(?![*\w])/g, "$1<i>$2</i>")
    .replace(/(^|[^\w])_([^_\s][^_\n]*)_(?!\w)/g, "$1<i>$2</i>");
// Code spans first, so nothing inside them reads as emphasis or a link.
const inline = (s: string) =>
  s
    .split(/(`[^`\n]+`)/)
    .map((p, k) => (k % 2 ? `<code>${esc(p.slice(1, -1))}</code>` : spans(esc(p))))
    .join("");

/** Consecutive lines from i while each fits; the index after the run. */
function runOf(ls: string[], i: number, fits: (l: string) => boolean) {
  let j = i;
  while (j < ls.length && fits(ls[j])) j++;
  return j;
}

const fence: Block = (ls, i) => {
  if (!FENCE.test(ls[i])) return null;
  const end = runOf(ls, i + 1, (l) => !FENCE.test(l));
  return [`<pre><code>${esc(ls.slice(i + 1, end).join("\n"))}</code></pre>`, end + 1];
};
const heading: Block = (ls, i) => {
  const m = ls[i].match(/^\s*(#{1,6})\s+(.*)$/);
  if (!m) return null;
  const h = Math.min(m[1].length + 2, 5);
  return [`<h${h}>${inline(m[2])}</h${h}>`, i + 1];
};
const rule: Block = (ls, i) => (RULE.test(ls[i]) ? ["<hr>", i + 1] : null);
const quote: Block = (ls, i) => {
  if (!/^\s*>/.test(ls[i])) return null;
  const end = runOf(ls, i, (l) => /^\s*>/.test(l));
  return [`<blockquote>${md(ls.slice(i, end).map((l) => l.replace(/^\s*>\s?/, "")).join("\n"))}</blockquote>`, end];
};

const cells = (l: string) =>
  l
    .trim()
    .replace(/^\||\|$/g, "")
    .split("|")
    .map((c) => inline(c.trim()));
const table: Block = (ls, i) => {
  if (!ls[i].includes("|") || !TROW.test(ls[i + 1] ?? "")) return null;
  const end = runOf(ls, i + 2, (l) => l.includes("|") && l.trim() !== "");
  const body = ls
    .slice(i + 2, end)
    .map((l) => `<tr>${cells(l).map((c) => `<td>${c}</td>`).join("")}</tr>`)
    .join("");
  const head = cells(ls[i])
    .map((c) => `<th>${c}</th>`)
    .join("");
  return [`<div class="md-table"><table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`, end];
};

const indentOf = (l: string) => l.match(/^\s*/)![0].length;
const orderedAt = (l: string | undefined) => {
  const m = l?.match(ITEM);
  return m ? /\d/.test(m[2]) : null;
};
/**
 * A list: its items at the first one's indent and of its kind (numbered or not), each with the lines that continue it
 * and a list nested under it (deeper items). A change of kind at the same indent starts the next list.
 */
const list: Block = (ls, i) => {
  const ordered = orderedAt(ls[i]);
  if (ordered === null) return null;
  const at = indentOf(ls[i]);
  const items: string[] = [];
  let j = i;
  while (j < ls.length && orderedAt(ls[j]) === ordered && indentOf(ls[j]) === at) {
    const m = ls[j].match(ITEM)!;
    const more = runOf(ls, j + 1, (l) => l.trim() !== "" && !ITEM.test(l) && indentOf(l) > at);
    let html = [m[3], ...ls.slice(j + 1, more).map((l) => l.trim())].map(inline).join("<br>");
    j = more;
    while (j < ls.length && ITEM.test(ls[j]) && indentOf(ls[j]) > at) {
      const [sub, next] = list(ls, j)!;
      html += sub;
      j = next;
    }
    items.push(`<li>${html}</li>`);
  }
  return [`<${ordered ? "ol" : "ul"}>${items.join("")}</${ordered ? "ol" : "ul"}>`, j];
};

const BLOCKS: Block[] = [fence, heading, rule, quote, table, list];
const paragraph: Block = (ls, i) => {
  const end = runOf(ls, i + 1, (l) => l.trim() !== "" && !STARTS.test(l) && !RULE.test(l));
  return [`<p>${ls.slice(i, end).map(inline).join("<br>")}</p>`, end];
};

/** Markdown to HTML, safe to set as innerHTML. */
export function md(text: string): string {
  const ls = String(text ?? "")
    .replace(/\r\n?/g, "\n")
    .split("\n");
  const out: string[] = [];
  let i = 0;
  while (i < ls.length) {
    if (ls[i].trim() === "") {
      i++;
      continue;
    }
    const [html, next] = BLOCKS.reduce<ReturnType<Block>>((hit, b) => hit ?? b(ls, i), null) ?? paragraph(ls, i)!;
    out.push(html);
    i = next;
  }
  return out.join("");
}
