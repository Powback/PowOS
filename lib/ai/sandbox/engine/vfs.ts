// PORTED unchanged from SpaceTimeAI agents/worker/codemode/vfs.ts (9aa4c87).
// [cap.7] From src.zip (DESIGN §19.2, vfs.ts): the per-session scratch workspace, in memory, gone with the session.
// Changed from src.zip: a search's path may name a file, and a glob may hold braces ("*.{ts,mjs}"). In src.zip both
// silently found nothing, which sessions took for "no matches".
import {
  capResults,
  checkPath,
  escapeRegExp,
  sliceLines,
  type ListParams,
  type SearchParams,
  type SearchResults,
} from "./common.ts";

// gitignore-style: a glob without a slash matches the basename anywhere, one
// with a slash matches from the workspace root. Later globs override earlier ones.
// Braces list alternatives, as in ripgrep: "*.{ts,mjs}" is "*.ts" or "*.mjs".
function globToRegExp(glob: string): RegExp {
  const anchored = glob.includes("/");
  const body = glob
    .replace(/^\//, "")
    .replace(/[.+^$()|[\]\\]/g, "\\$&")
    .replace(/\*\*\/?/g, "\0")
    .replace(/\*/g, "[^/]*")
    .replace(/\?/g, "[^/]")
    .replace(/\0/g, "(?:.*/)?")
    .replace(/\{([^{}]*)\}/g, (_, alternatives: string) => `(?:${alternatives.split(",").join("|")})`)
    .replace(/[{}]/g, "\\$&");
  return new RegExp(anchored ? `^${body}$` : `(^|/)${body}$`);
}

function matchesGlobs(file: string, globs: string[]): boolean {
  let included = globs.every((glob) => glob.startsWith("!"));
  for (const glob of globs) {
    const negated = glob.startsWith("!");
    if (globToRegExp(negated ? glob.slice(1) : glob).test(file)) included = !negated;
  }
  return included;
}

// A directory as a path prefix: "" for the root, "dir/" otherwise.
function prefixOf(dir: string) {
  const root = checkPath(dir);
  return root === "" ? "" : root + "/";
}

// Whether a file is in a search's path: the path names a directory above it, or the file itself.
function inPath(file: string, dir: string) {
  const prefix = prefixOf(dir);
  return file.startsWith(prefix) || file + "/" === prefix;
}

// The entries one file contributes to a listing: the file itself and, when recursive, its parent directories.
function entriesOf(rest: string[], prefix: string, recursive: boolean, includeDirs: boolean, pattern?: RegExp): string[] {
  const out: string[] = [];
  for (let i = 1; i <= (recursive ? rest.length : 1); i++) {
    const entry = prefix + rest.slice(0, i).join("/");
    const isDir = i < rest.length;
    if ((includeDirs || !isDir) && (!pattern || pattern.test(entry))) out.push(entry);
  }
  return out;
}

// A string is matched literally; a RegExp keeps its flags except g, which would make test() stateful.
const toRegExp = (pattern: string | RegExp) =>
  typeof pattern === "string" ? new RegExp(escapeRegExp(pattern)) : new RegExp(pattern.source, pattern.flags.replace("g", ""));

// What one file contributes to a search, in the chosen output mode.
function matchLines(file: string, fileLines: string[], regex: RegExp, mode: string, context: number): string[] {
  const hits = fileLines.flatMap((line, i) => (regex.test(line) ? [i] : []));
  if (hits.length === 0) return [];
  if (mode === "files_with_matches") return [file];
  if (mode === "count") return [`${file}:${hits.length}`];
  const shown = new Set(hits.flatMap((i) => Array.from({ length: 2 * context + 1 }, (_, k) => i - context + k)));
  return [...shown].filter((i) => i >= 0 && i < fileLines.length).sort((a, b) => a - b).map((i) => {
    const sep = hits.includes(i) ? ":" : "-";
    return `${file}${sep}${i + 1}${sep}${fileLines[i]}`;
  });
}

export class Vfs {
  private files = new Map<string, string>();
  private outputs = 0;

  private get(file: string): string {
    const content = this.files.get(file);
    if (content === undefined) throw new Error(`no such file: ${file}`);
    return content;
  }

  read({ path: file, range }: { path: string; range?: { start: number; end: number } }) {
    return sliceLines(this.get(checkPath(file)), range);
  }

  write({ path: file, content }: { path: string; content: string }) {
    const clean = checkPath(file);
    if (clean === "") throw new Error("path is empty");
    this.files.set(clean, content);
  }

  edit({ path: file, search, replace }: { path: string; search: string | RegExp; replace: string }) {
    const clean = checkPath(file);
    const content = this.get(clean);
    const found = typeof search === "string" ? content.includes(search) : search.test(content);
    if (!found) throw new Error(`search not found in ${clean}`);
    this.files.set(clean, content.replace(search, replace));
  }

  delete(file: string) {
    const clean = checkPath(file);
    if (!this.files.delete(clean)) throw new Error(`no such file: ${clean}`);
  }

  // Where output too large to return in full is kept for the model to read.
  saveOutput(content: string, prefix = ""): string {
    const file = `out/${prefix}${++this.outputs}.txt`;
    this.files.set(file, content);
    return file;
  }

  list({ path: dir, recursive = false, include_dirs = true, pattern }: ListParams): string[] {
    const prefix = prefixOf(dir);
    const seen = new Set<string>();
    for (const file of this.files.keys()) {
      if (file.startsWith(prefix)) entriesOf(file.slice(prefix.length).split("/"), prefix, recursive, include_dirs, pattern).forEach((e) => seen.add(e));
    }
    return [...seen].sort();
  }

  search(params: SearchParams): SearchResults {
    const { glob = [], output_mode = "content", context = 0 } = params;
    const regex = toRegExp(params.pattern);
    const lines: string[] = [];
    for (const [file, content] of [...this.files].sort()) {
      if (inPath(file, params.path ?? "") && matchesGlobs(file, glob)) lines.push(...matchLines(file, content.split("\n"), regex, output_mode, context));
    }
    return capResults(lines, params.max_results, (content) => this.saveOutput(content, "search-"));
  }
}

