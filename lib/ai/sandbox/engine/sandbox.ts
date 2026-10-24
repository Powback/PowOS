// PORTED from SpaceTimeAI agents/worker/codemode/sandbox.ts (SpaceTimeAI 9aa4c87, itself from src.zip, DESIGN §19.1):
// TypeScript type-checked against the declarations of exactly the host functions this job was granted, then run in
// QuickJS (WebAssembly: its own heap, no fs/net/process/timers/imports) with a memory cap and a deadline. The only way
// out is the host functions. Changes for PowOS, nothing else:
//   - the declarations are ../powos.d.ts (PowOS's capabilities), not SpaceTimeAI's sandbox.d.ts;
//   - the deadline and the memory cap are per job (Limits) instead of fixed 5 min / 256 MB: the phone runs it too;
//   - SandboxError's `thrown` is a plain field (Node's type stripping refuses parameter properties; Bun ran either);
//   - evalModule (a checkout's own modules) is dropped: PowOS jobs are snippets or saved workspace scripts.
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  getQuickJS,
  shouldInterruptAfterDeadline,
  type QuickJSContext,
  type QuickJSHandle,
} from "quickjs-emscripten";
import ts from "typescript";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

export type Hosts = Record<string, (params: any) => unknown>;

// What one job may use: its wall-clock deadline (QuickJS's interrupt handler, so a busy loop is cut too) and the
// VM's heap. SpaceTimeAI's fixed values are the ceilings (lib/ai/sandbox/caps.ts clamps a job's ask to them).
export type Limits = { timeoutMs: number; memoryBytes: number };
export const MAX_LIMITS: Limits = { timeoutMs: 5 * 60 * 1000, memoryBytes: 256 * 1024 * 1024 };
export const DEFAULT_LIMITS: Limits = { timeoutMs: 60 * 1000, memoryBytes: 64 * 1024 * 1024 };

export const SANDBOX_DTS = fileURLToPath(new URL("../powos.d.ts", import.meta.url));
const MAIN = "/sandbox/main.ts";

const compilerOptions: ts.CompilerOptions = {
  target: ts.ScriptTarget.ES2023,
  module: ts.ModuleKind.ESNext,
  lib: ["lib.es2023.d.ts"],
  strict: true,
  // [agent.29] Strict types a caught error as `unknown`, so `catch (e) { e.message }` was a type error and the call
  // never ran. Host functions reject with an Error, so the caught error is `any`, as code written for them expects.
  useUnknownInCatchVariables: false,
  noEmit: true,
  types: [],
};

// [d.runtime.14] [d.runtime.39] A session is told about, and type-checked against, exactly the functions it has: sandbox.d.ts
// declares them all, and each session keeps the types and the `declare function`s its hosts provide (a session
// without a checkout has no codebase, only a verifier with a preview has the browser). A call to anything else is
// a type error before it runs, never a failure inside it.
const FULL_DTS = readFileSync(SANDBOX_DTS, "utf8");
const fullSource = ts.createSourceFile(SANDBOX_DTS, FULL_DTS, ts.ScriptTarget.ES2023, true);
const declFiles = new Map<string, string>();
const declared = new Map<string, { text: string; file: string }>();
export function declarationsFor(hosts: Hosts) {
  const key = Object.keys(hosts).sort().join(",");
  if (!declared.has(key)) {
    const kept = fullSource.statements.filter((st) => !ts.isFunctionDeclaration(st) || (st.name !== undefined && st.name.text in hosts));
    const text = kept.map((st) => FULL_DTS.slice(st.getFullStart(), st.getEnd())).join("").trim();
    const file = `/sandbox/declarations-${createHash("sha256").update(text).digest("hex").slice(0, 16)}.d.ts`;
    declFiles.set(file, text);
    declared.set(key, { text, file });
  }
  return declared.get(key)!;
}

// The declarations and the standard library are the same on every call, so parse them once.
const cachedSources = new Map<string, ts.SourceFile | undefined>();
let mainSource: ts.SourceFile;
const host = ts.createCompilerHost(compilerOptions, true);
const { getSourceFile, fileExists, readFile } = host;
host.getSourceFile = (fileName, language, onError) => {
  if (fileName === MAIN) return mainSource;
  if (declFiles.has(fileName) && !cachedSources.has(fileName)) cachedSources.set(fileName, ts.createSourceFile(fileName, declFiles.get(fileName)!, compilerOptions.target!, true));
  if (!cachedSources.has(fileName)) {
    cachedSources.set(fileName, getSourceFile.call(host, fileName, language, onError));
  }
  return cachedSources.get(fileName);
};
host.fileExists = (fileName) => fileName === MAIN || declFiles.has(fileName) || fileExists.call(host, fileName);
host.readFile = (fileName) => (fileName === MAIN ? mainSource.text : declFiles.get(fileName) ?? readFile.call(host, fileName));
host.writeFile = () => {};

// `thrown` is what the code itself threw, when it threw something: runhost.ts hands that on rather than this description.
export class SandboxError extends Error {
  readonly thrown?: { name?: string; message: string; stack?: string };
  constructor(message: string, thrown?: { name?: string; message: string; stack?: string }) {
    super(message);
    this.thrown = thrown;
  }
}

// Same line as the code, so diagnostics and stack traces keep the user's line numbers.
// A module so the code runs in strict mode without an emitted directive.
const WRAPPER_PREFIX = "export default (async () => {";
const wrap = (code: string) => `${WRAPPER_PREFIX}${code}\n})()`;


// Type-checks the wrapped code and returns the statements of the wrapper's body.
function typeCheck(code: string, declarations: string) {
  mainSource = ts.createSourceFile(MAIN, code, compilerOptions.target!, true);
  const program = ts.createProgram([declarations, MAIN], compilerOptions, host);
  const errors = ts
    .getPreEmitDiagnostics(program)
    .filter((d) => d.category === ts.DiagnosticCategory.Error);
  if (errors.length > 0) {
    const lines = errors.map((d) => {
      const text = ts.flattenDiagnosticMessageText(d.messageText, "\n");
      if (!d.file || d.start === undefined) return text;
      const { line, character } = d.file.getLineAndCharacterOfPosition(d.start);
      const column = line === 0 ? character - WRAPPER_PREFIX.length : character;
      return `${line + 1}:${column + 1} ${text}`;
    });
    throw new SandboxError(`type errors:\n${lines.join("\n")}`);
  }
  const call = (mainSource.statements[0] as ts.ExportAssignment).expression as ts.CallExpression;
  const arrow = (call.expression as ts.ParenthesizedExpression).expression as ts.ArrowFunction;
  return { source: mainSource, statements: (arrow.body as ts.Block).statements };
}

// The emitter puts the body on its own line after the wrapper; joining them keeps
// runtime line numbers equal to the user's.
const transpile = (code: string) =>
  ts.transpileModule(code, { compilerOptions }).outputText.replace("\n", "");

// JSON cannot carry a RegExp, so the fields that may hold one are re-read from the handle.
const REGEXP_FIELDS = ["pattern", "search"];

function readParams(context: QuickJSContext, handle: QuickJSHandle): unknown {
  const params = context.dump(handle);
  if (!params || typeof params !== "object") return params;
  for (const field of REGEXP_FIELDS) {
    if (!params[field] || typeof params[field] !== "object") continue;
    const regexp = context.getProp(handle, field);
    const source = context.getProp(regexp, "source").consume(context.getString);
    const flags = context.getProp(regexp, "flags").consume(context.getString);
    regexp.dispose();
    params[field] = new RegExp(source, flags);
  }
  return params;
}

// Primitives map one to one; anything else is null here and built by toHandle.
function primitive(context: QuickJSContext, value: unknown): QuickJSHandle | null {
  if (value === undefined) return context.undefined;
  if (value === null) return context.null;
  if (typeof value === "string") return context.newString(value);
  if (typeof value === "number") return context.newNumber(value);
  if (typeof value === "boolean") return value ? context.true : context.false;
  return null;
}

function toHandle(context: QuickJSContext, newDate: QuickJSHandle, value: unknown): QuickJSHandle {
  const simple = primitive(context, value);
  if (simple) return simple;
  if (value instanceof Date) {
    return context
      .newNumber(value.getTime())
      .consume((ms) => context.unwrapResult(context.callFunction(newDate, context.undefined, ms)));
  }
  if (Array.isArray(value)) {
    const array = context.newArray();
    value.forEach((item, i) => toHandle(context, newDate, item).consume((h) => context.setProp(array, i, h)));
    return array;
  }
  const object = context.newObject();
  for (const [key, item] of Object.entries(value as object)) {
    toHandle(context, newDate, item).consume((h) => context.setProp(object, key, h));
  }
  return object;
}

// Errors from the file system, rg, and git name absolute paths, and the model
// should only ever see workspace-relative ones.
function hideWorkspaceRoot(message: string, root: string): string {
  if (!root) return message;
  return message.split(root + path.sep).join("").split(root).join(".");
}

const isThrown = (dumped: unknown): dumped is { name?: string; message: string; stack?: string } =>
  !!dumped && typeof dumped === "object" && "message" in dumped;

function describeError(dumped: unknown): SandboxError {
  if (isThrown(dumped)) {
    const { name, message, stack } = dumped;
    return new SandboxError(`${name ?? "Error"}: ${message}${stack ? `\n${stack}` : ""}`, dumped);
  }
  return new SandboxError(String(dumped));
}

// One job: a fresh runtime and context, the granted host functions as globals, `args`, a console that prints to the result.
async function run(js: string, hosts: Hosts, root: string, args: Record<string, unknown>, limits: Limits): Promise<{ value: unknown; stdout: string }> {
  const QuickJS = await getQuickJS();
  const runtime = QuickJS.newRuntime();
  runtime.setMemoryLimit(limits.memoryBytes);
  runtime.setInterruptHandler(shouldInterruptAfterDeadline(Date.now() + limits.timeoutMs));
  const context = runtime.newContext();
  const newDate = context.unwrapResult(context.evalCode("(ms) => new Date(ms)"));
  const inflight = new Set<Promise<void>>();
  let stdout = "";

  for (const [name, fn] of Object.entries(hosts)) {
    context
      .newFunction(name, (paramsHandle) => {
        const params = paramsHandle ? readParams(context, paramsHandle) : undefined;
        const deferred = context.newPromise();
        const pending = Promise.resolve()
          .then(() => fn(params))
          .then(
            (result) => toHandle(context, newDate, result).consume(deferred.resolve),
            (error: Error) => context.newError(hideWorkspaceRoot(error.message, root)).consume(deferred.reject),
          )
          .then(() => {
            deferred.dispose();
            inflight.delete(pending);
            runtime.executePendingJobs();
          });
        inflight.add(pending);
        return deferred.handle;
      })
      .consume((h) => context.setProp(context.global, name, h));
  }

  // The arguments eval was given, as a global the code reads (declared in sandbox.d.ts).
  toHandle(context, newDate, args).consume((h) => context.setProp(context.global, "args", h));

  const print = context.newFunction("log", (...printed) => {
    stdout +=
      printed
        .map((h) => (context.typeof(h) === "string" ? context.getString(h) : JSON.stringify(context.dump(h)) ?? String(context.dump(h))))
        .join(" ") + "\n";
  });
  const consoleObject = context.newObject();
  for (const level of ["log", "info", "warn", "error", "debug"]) context.setProp(consoleObject, level, print);
  print.dispose();
  consoleObject.consume((h) => context.setProp(context.global, "console", h));

  try {
    const evaluated = context.evalCode(js, "main.js", { type: "module" });
    if (evaluated.error) {
      const dumped = context.dump(evaluated.error);
      evaluated.error.dispose();
      throw describeError(dumped);
    }
    const loading = context.resolvePromise(evaluated.value);
    evaluated.value.dispose();
    runtime.executePendingJobs();
    const namespace = context.unwrapResult(await loading);
    const settled = namespace.consume((ns) => context.getProp(ns, "default")).consume(context.resolvePromise);
    runtime.executePendingJobs();
    const outcome = await settled;
    if (outcome.error) {
      const dumped = context.dump(outcome.error);
      outcome.error.dispose();
      throw describeError(dumped);
    }
    const value = context.dump(outcome.value);
    outcome.value.dispose();
    return { value, stdout };
  } catch (error) {
    if (error instanceof SandboxError) throw error;
    throw new SandboxError((error as Error).message);
  } finally {
    // A host call still in flight would touch the context after disposal, and a
    // job still queued keeps objects alive that the runtime then refuses to free.
    await Promise.allSettled([...inflight]);
    runtime.executePendingJobs();
    newDate.dispose();
    context.dispose();
    try {
      runtime.dispose();
    } catch (error) {
      // After a large search result is read and split in the VM, QuickJS is
      // sometimes left holding one reference to the context and asserts here.
      // The result was already produced, so leak this runtime rather than fail.
      console.warn(`sandbox: runtime not freed: ${(error as Error).message}`);
    }
  }
}

export async function evalCode(code: string, hosts: Hosts, root = "", args: Record<string, unknown> = {}, limits: Limits = DEFAULT_LIMITS): Promise<{ value: unknown; stdout: string }> {
  let wrapped = wrap(code);
  const { source, statements } = typeCheck(wrapped, declarationsFor(hosts).file);
  // A final expression statement becomes the value eval hands back.
  const last = statements.at(-1);
  if (last && ts.isExpressionStatement(last)) {
    const start = last.expression.getStart(source);
    wrapped = `${wrapped.slice(0, start)}return ${wrapped.slice(start)}`;
  }
  return run(transpile(wrapped), hosts, root, args, limits);
}
