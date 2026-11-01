/**
 * Markdown as one line of plain text, for a preview that shows text, not markup (a notification's message in a widget
 * row: the user, 2026-11-01: "**⚠️ Friction**" read literally). Drops emphasis/code marks, keeps a link's or image's
 * words, a heading's or quote's or list item's text, and folds whitespace. The full renderer is shell/ui/md.ts.
 *
 * `@powos/shared/mdplain` (apps/build.sh aliases @powos/shared to shell/ui/shared).
 */
export function mdPlain(text: string): string {
  return text
    .replace(/^\s*(```|~~~).*$/gm, "")
    .replace(/^\s{0,3}(#{1,6}\s+|>\s?|([-*+]|\d+[.)])\s+)/gm, "")
    .replace(/!?\[([^\]\n]*)\]\([^)\s]*\)/g, "$1")
    .replace(/`([^`\n]+)`/g, "$1")
    .replace(/(\*\*|__)(?=\S)([^\n]*?\S)\1/g, "$2")
    .replace(/(^|[^*\w])\*(?=\S)([^*\n]*?\S)\*(?![*\w])/g, "$1$2")
    .replace(/(^|[^\w])_(?=\S)([^_\n]*?\S)_(?!\w)/g, "$1$2")
    .replace(/~~(?=\S)([^\n]*?\S)~~/g, "$1")
    .replace(/\s+/g, " ")
    .trim();
}
