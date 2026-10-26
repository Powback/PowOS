// PORTED unchanged from SpaceTimeAI agents/worker/codemode/common.ts (9aa4c87).
// From src.zip (DESIGN §19.2, common.ts): the shared host-function library. Unchanged.
export class BadArgument extends Error {}

// Normalizes a workspace-relative path and rejects anything that could leave the root.
export function checkPath(file: string): string {
  const parts = file.split("/").filter((part) => part !== "" && part !== ".");
  if (file.startsWith("/") || parts.includes("..")) {
    throw new BadArgument(`path must be relative to the workspace root: ${file}`);
  }
  return parts.join("/");
}

export function sliceLines(
  content: string,
  range?: { start: number; end: number },
): string {
  if (!range) return content;
  const lines = content.split("\n");
  const end = range.end === -1 ? lines.length : range.end;
  return lines.slice(Math.max(range.start, 1) - 1, end).join("\n");
}

export type SearchParams = {
  pattern: string | RegExp;
  path?: string;
  glob?: string[];
  output_mode?: "content" | "files_with_matches" | "count";
  context?: number;
  max_results?: number;
};

export type SearchResults = { results: string[]; truncated: boolean; file?: string };

export type ListParams = {
  path: string;
  recursive?: boolean;
  include_dirs?: boolean;
  pattern?: RegExp;
};

export const DEFAULT_MAX_RESULTS = 1000;

export function capResults(
  lines: string[],
  max = DEFAULT_MAX_RESULTS,
  save: (content: string) => string,
): SearchResults {
  if (lines.length <= max) return { results: lines, truncated: false };
  return { results: lines.slice(0, max), truncated: true, file: save(lines.join("\n") + "\n") };
}

export function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
