// The PowOS sandbox's declarations: the code of a job is type-checked against exactly the functions its grants give
// it (engine/sandbox.ts declarationsFor keeps only those `declare function`s), so a call to anything else is a type
// error before anything runs. The console, args and *Vfs part is SpaceTimeAI's sandbox.d.ts (9aa4c87) unchanged; the
// PowOS part (each function's capability is in its first doc line) is below it. caps.ts implements them.

/**
 * Prints to the tool result. Strings are printed as-is, anything else as JSON.
 */
declare var console: {
    log(...args: unknown[]): void;
    info(...args: unknown[]): void;
    warn(...args: unknown[]): void;
    error(...args: unknown[]): void;
    debug(...args: unknown[]): void;
};

/**
 * The arguments this eval was given (its `args`), so a script saved in the virtual workspace can be run again by
 * path with different inputs. An empty object when none were given.
 */
declare const args: Record<string, unknown>;

type ReadParams = {
    /**
     * The path of the file to read, relative to the virtual workspace root.
     */
    path: string;

    /**
     * An optional range of lines to read from the file, 1-based and inclusive.
     * If not provided, the entire file will be read. end = -1 means read to the end of the file.
     */
    range?: { start: number; end: number };
};

/**
 * Reads a file from the virtual workspace.
 * @returns A promise that resolves to the contents of the file as a string.
 * @throws An error if the file does not exist or cannot be read.
 */
declare function readVfs(params: ReadParams): Promise<string>;

type WriteParams = {
    /**
     * The path of the file to write, relative to the virtual workspace root.
     */
    path: string;

    /**
     * The content to write to the file.
     */
    content: string;
};

/**
 * Writes a file to the virtual workspace.
 * @returns A promise that resolves when the file has been written.
 * @throws An error if the file cannot be written.
 */
declare function writeVfs(params: WriteParams): Promise<void>;

type EditParams = {
    /**
     * The path of the file to edit, relative to the virtual workspace root.
     */
    path: string;

    /**
     * The string or pattern to find in the file.
     */
    search: string | RegExp;

    /**
     * The replacement string.
     */
    replace: string;
};

/**
 * Edits a file in the virtual workspace. A string search replaces the first occurrence,
 * a RegExp search follows String.prototype.replace semantics.
 * @returns A promise that resolves when the file has been edited.
 * @throws An error if the file does not exist or the search is not found.
 */
declare function editVfs(params: EditParams): Promise<void>;

/**
 * Deletes a file from the virtual workspace.
 * @param path The path of the file to delete, relative to the virtual workspace root.
 * @returns A promise that resolves when the file has been deleted.
 * @throws An error if the file does not exist or cannot be deleted.
 */
declare function deleteVfs(path: string): Promise<void>;

type SearchParams = {
    /**
     * What to search for. A string is matched literally, character for character:
     * "a|b" finds the three characters a|b, not a or b. Pass a RegExp for
     * alternation, character classes, or case-insensitive matching, e.g. /drop.?set/i.
     */
    pattern: string | RegExp;

    /**
     * The path to search, relative to the virtual workspace root. Defaults to the virtual workspace root.
     */
    path?: string;

    /**
     * Include/exclude globs, gitignore-style. Prefix with '!' to exclude. Later globs override earlier ones.
     */
    glob?: string[];

    /**
     * What to return: 'content' returns matching lines with file:line prefixes; 'files_with_matches' returns only paths; 'count' returns per-file match counts. Defaults to 'content'.
     */
    output_mode?: "content" | "files_with_matches" | "count";

    /**
     * Number of context lines to include before and after each match. Only applies when output_mode is 'content'.
     */
    context?: number;

    /**
     * Cap on lines (content), files (files_with_matches), or entries (count). Defaults to 1000. Result reports whether it was truncated.
     */
    max_results?: number;
};

type SearchResults = {
    /**
     * One line per result, in the format of the chosen output_mode.
     */
    results: string[];

    /**
     * Whether max_results cut the results short.
     */
    truncated: boolean;

    /**
     * When truncated, the path of a file in the virtual workspace holding every result line,
     * for readVfs or searchVfs. A search with more than a few megabytes of output is stopped
     * partway and the file says so on its last line.
     */
    file?: string;
};

/**
 * Searches for files in the virtual workspace with ripgrep semantics.
 * @throws An error if the search fails.
 */
declare function searchVfs(params: SearchParams): Promise<SearchResults>;

type ListParams = {
    /**
     * The path to list, relative to the virtual workspace root.
     */
    path: string;

    /**
     * Whether to list directories recursively. Defaults to false.
     */
    recursive?: boolean;

    /**
     * Whether to include directories in the listing. Defaults to true.
     */
    include_dirs?: boolean;

    /**
     * Limit results to paths matching this pattern.
     */
    pattern?: RegExp;
};

/**
 * Lists files / directories in the virtual workspace. Paths are relative to the virtual workspace root.
 * @throws An error if the listing fails.
 */
declare function listVfs(params: ListParams): Promise<string[]>;
// ---- PowOS capabilities (caps.ts). A job is granted some of: comms.read, comms.send, board.read, board.write,
// checks.queue, phone.read. Each call runs one fixed PowOS command (no shell); a job has a cap on its calls.

type Message = {
    id: string;
    from: string;
    to: string;
    /** message | escalate | notify */
    kind: string;
    priority: "low" | "normal" | "high" | "urgent";
    iso: string;
    /** The whole body, as sent. */
    body: string;
    [key: string]: unknown;
};

/**
 * [comms.read] The messages waiting in this agent's own inbox, oldest first. Only looks: nothing is consumed.
 */
declare function commsInbox(params?: { limit?: number }): Promise<Message[]>;

/**
 * [comms.send] Sends a message to another agent's inbox (manager, coder, devops, powos-verify, ...), from this agent.
 * @throws An error if the name is not a valid agent name or the body is empty.
 */
declare function sendMessage(params: { to: string; body: string; priority?: "low" | "normal" | "high" | "urgent" }): Promise<{ sent: true; to: string }>;

/** A board task as `powos agents task list --json` prints it. */
type BoardTask = {
    id: string;
    title: string;
    /** Its TRUE state, computed from facts: working | awaiting-check | no-check | stalled | blocked | done. */
    truth?: string;
    /** Only what someone typed; report `truth`. */
    status?: string;
    owner?: string;
    project?: string;
    note?: string;
    [key: string]: unknown;
};

/**
 * [board.read] The work board's open tasks (all: done ones too), optionally only one state / owner / project.
 */
declare function boardTasks(params?: { state?: string; owner?: string; project?: string; all?: boolean }): Promise<BoardTask[]>;

/**
 * [board.read] The board's phone checks (queued jobs and results), for one task or all.
 */
declare function boardChecks(params?: { task?: string }): Promise<Record<string, unknown>[]>;

/**
 * [board.write] Changes a board task (its exact id): what it is doing now, a note, progress, the plan, the status
 * or the owner. Returns what the board printed.
 */
declare function boardSetTask(params: { task: string; step?: string; note?: string; progress?: string; plan?: string; status?: string; owner?: string }): Promise<string>;

/**
 * [board.write] Adds a board task (or finds the open one with the same id or a very similar title). Returns its id.
 */
declare function boardAddTask(params: { title: string; owner?: string; note?: string; project?: string }): Promise<string>;

/**
 * [checks.queue] Queues an on-device check on the Mac's verify queue (tools/phone/verify/queue.sh add) and returns at
 * once; its result lands on the board task. `check` is a script in tools/phone/verify/ ("window-max.sh"), each of
 * `args` one separate word. close: a PASS closes the task.
 * @throws An error if the check is not a script in tools/phone/verify/, or there is no verify queue on this host.
 */
declare function queueCheck(params: { task: string; check: string; args?: string[]; close?: boolean; name?: string; screen?: "inner" | "cover"; budgetS?: number }): Promise<string>;

/**
 * [checks.queue] The verify queue: queued, running, paused and the last results (queue.sh list).
 */
declare function checkQueue(): Promise<string>;

/**
 * [phone.read] One read-only view of the phone's PowOS state (never changes anything; at most a few per job):
 * overview (JSON: model, image, deploys, disk), status (text), units (JSON: installed and running units),
 * sleep (JSON: what is asleep and why), apps.running (text: Android tasks), shell.errors (text: the shell's errors).
 */
declare function phoneState(params: { what: "overview" | "status" | "units" | "sleep" | "apps.running" | "shell.errors" }): Promise<unknown>;
