/**
 * The launcher search's quick math and unit conversions ("12*7", "sqrt(2)", "15% of 80", "5 km in miles", "100 f to c").
 * A small tokenizer and recursive-descent parser over numbers, + - * / ^ %, parentheses and a fixed list of functions
 * and constants: never eval / Function, so nothing typed can run as code. Plain words, a lone number or a phone number
 * are not math (null): they stay a search.
 */

export interface MathAnswer {
  /** What it worked out: "12 × 7", "5 km". */
  expression: string;
  /** The answer as shown: "84", "3.10686 mi". */
  value: string;
}

type Tok = { k: "num"; v: number } | { k: "op"; v: string } | { k: "id"; v: string };

const FUNCS: Record<string, (x: number) => number> = {
  sqrt: Math.sqrt, abs: Math.abs, ln: Math.log, log: Math.log10, exp: Math.exp, round: Math.round, floor: Math.floor, ceil: Math.ceil,
  sin: (x) => Math.sin(x), cos: (x) => Math.cos(x), tan: (x) => Math.tan(x), asin: Math.asin, acos: Math.acos, atan: Math.atan,
};
const CONSTS: Record<string, number> = { pi: Math.PI, "π": Math.PI, e: Math.E, tau: 2 * Math.PI };

const ALIASES: Record<string, string> = { "×": "*", "·": "*", "÷": "/", "−": "-" };

/** The token at [s]'s start, and how many characters it took; null: a character arithmetic has no use for. */
function readToken(s: string, prev: Tok | undefined): [Tok | null, number] | null {
  const c = s[0];
  if (/\s/.test(c)) return [null, 1];
  const num = /^(\d[\d_]*(\.\d*)?|\.\d+)(e[+-]?\d+)?/i.exec(s);
  if (num) return [{ k: "num", v: Number(num[0].replaceAll("_", "")) }, num[0].length];
  // "3 x 4": an x between numbers is a times sign.
  if (/^x\s*[\d.(]/i.test(s) && prev?.k === "num") return [{ k: "op", v: "*" }, 1];
  const id = /^[a-zπ]+/i.exec(s);
  if (id) return [{ k: "id", v: id[0].toLowerCase() }, id[0].length];
  if (s.startsWith("**")) return [{ k: "op", v: "^" }, 2];
  const op = ALIASES[c] ?? c;
  return "+-*/^%()!".includes(op) ? [{ k: "op", v: op }, 1] : null;
}

function tokenize(s: string): Tok[] | null {
  const out: Tok[] = [];
  for (let i = 0; i < s.length;) {
    const read = readToken(s.slice(i), out.at(-1));
    if (!read) return null;
    if (read[0]) out.push(read[0]);
    i += read[1];
  }
  return out;
}

class Parser {
  private i = 0;
  private t: Tok[];
  constructor(t: Tok[]) { this.t = t; }
  private peek() { return this.t[this.i]; }
  private isOp(v: string) { const p = this.peek(); return p?.k === "op" && p.v === v; }
  private isId(test: (v: string) => boolean) { const p = this.peek(); return p?.k === "id" && test(p.v); }
  private take() { return this.t[this.i++]; }
  private expect(v: string) { if (!this.isOp(v)) throw Error(`expected ${v}`); this.take(); }
  done() { return this.i >= this.t.length; }

  // expr := term (('+'|'-') term)*   - "a + b%" is a plus b percent of a, as calculators do.
  expr(): number {
    let v = this.term();
    while (this.isOp("+") || this.isOp("-")) {
      const op = this.take().v;
      const start = this.i;
      let r = this.term();
      const first = this.t[start];
      if (this.t[this.i - 1]?.v === "%" && this.i - start === 2 && first.k === "num") r = (v * first.v) / 100;
      v = op === "+" ? v + r : v - r;
    }
    return v;
  }
  // term := unary (('*'|'/'|'of'|implicit) unary)*
  term(): number {
    let v = this.unary();
    for (let op = this.mulOp(); op; op = this.mulOp()) {
      const r = this.unary();
      v = op === "/" ? v / r : v * r;
    }
    return v;
  }
  /** The multiplication that follows, taken: "*", "/", "of" ("15% of 80"), or implicit before ( or a constant (2pi, 3(4+1)). */
  private mulOp(): string | null {
    if (this.isOp("*") || this.isOp("/")) return this.take().v as string;
    if (this.isId((v) => v === "of")) return (this.take(), "*");
    return this.isOp("(") || this.isId((v) => Object.hasOwn(CONSTS, v)) ? "*" : null;
  }
  // unary := ('-'|'+') unary | power
  unary(): number {
    if (this.isOp("-")) { this.take(); return -this.unary(); }
    if (this.isOp("+")) { this.take(); return this.unary(); }
    return this.power();
  }
  // power := postfix ('^' unary)?   (right-associative, -2^2 = -4)
  power(): number {
    const b = this.postfix();
    if (this.isOp("^")) { this.take(); return Math.pow(b, this.unary()); }
    return b;
  }
  // postfix := atom ('%' | '!')*
  postfix(): number {
    let v = this.atom();
    for (;;) {
      if (this.isOp("%")) { this.take(); v = v / 100; }
      else if (this.isOp("!")) { this.take(); v = factorial(v); }
      else return v;
    }
  }
  atom(): number {
    const t = this.take();
    if (t?.k === "num") return t.v;
    if (t?.k === "op" && t.v === "(") { const v = this.expr(); this.expect(")"); return v; }
    if (t?.k === "id") return this.named(t.v);
    throw Error(`unexpected ${t?.v ?? "end"}`);
  }
  /** A constant, or a function of what follows: sqrt(2), sqrt 9. Any other word isn't arithmetic. */
  private named(name: string): number {
    if (Object.hasOwn(CONSTS, name)) return CONSTS[name];
    const f = Object.hasOwn(FUNCS, name) ? FUNCS[name] : null;
    if (!f) throw Error(`unknown ${name}`);
    if (!this.isOp("(")) return f(this.power());
    this.take();
    const v = this.expr();
    this.expect(")");
    return f(v);
  }
}

function factorial(n: number) {
  if (!Number.isInteger(n) || n < 0 || n > 170) return NaN;
  let r = 1;
  for (let i = 2; i <= n; i++) r *= i;
  return r;
}

/** [text] worked out as arithmetic, or null when it isn't arithmetic (or doesn't give a finite number). */
export function evaluate(text: string): number | null {
  const toks = tokenize(text.trim().replace(/=\s*$/, ""));
  if (!toks?.length) return null;
  try {
    const p = new Parser(toks);
    const v = p.expr();
    return p.done() && Number.isFinite(v) ? v : null;
  } catch {
    return null;
  }
}

/** [v] for reading: at most 10 significant digits, no float noise (0.1+0.2 = 0.3), thousands kept plain. */
export function formatNumber(v: number): string {
  // Float noise round zero (sin(pi) = 1.2e-16) is zero, as a calculator shows it.
  if (Object.is(v, -0) || Math.abs(v) < 1e-12) v = 0;
  if (v !== 0 && (Math.abs(v) >= 1e15 || Math.abs(v) < 1e-9)) return v.toPrecision(6).replace(/\.?0+e/, "e");
  return String(Number(v.toPrecision(10)));
}

// Units: each a factor to its dimension's base unit (m, kg, s, m², l, B, m/s, J); temperatures are their own.
type Unit = { dim: string; f: number; sym: string };
const UNITS: Record<string, Unit> = {};
function unit(dim: string, f: number, sym: string, ...names: string[]) {
  for (const n of [sym, ...names]) UNITS[n.toLowerCase()] = { dim, f, sym };
}
unit("len", 1, "m", "meter", "meters", "metre", "metres");
unit("len", 1000, "km", "kilometer", "kilometers", "kilometre", "kilometres");
unit("len", 0.01, "cm", "centimeter", "centimeters", "centimetre", "centimetres");
unit("len", 0.001, "mm", "millimeter", "millimeters", "millimetre", "millimetres");
unit("len", 1609.344, "mi", "mile", "miles");
unit("len", 0.9144, "yd", "yard", "yards");
unit("len", 0.3048, "ft", "foot", "feet");
unit("len", 0.0254, "in", "inch", "inches");
unit("len", 1852, "nmi", "nautical mile", "nautical miles");
unit("mass", 1, "kg", "kilo", "kilos", "kilogram", "kilograms");
unit("mass", 0.001, "g", "gram", "grams");
unit("mass", 1e-6, "mg", "milligram", "milligrams");
unit("mass", 1000, "t", "tonne", "tonnes", "ton", "tons");
unit("mass", 0.45359237, "lb", "lbs", "pound", "pounds");
unit("mass", 0.028349523125, "oz", "ounce", "ounces");
unit("mass", 6.35029318, "st", "stone", "stones");
unit("time", 1, "s", "sec", "secs", "second", "seconds");
unit("time", 0.001, "ms", "millisecond", "milliseconds");
unit("time", 60, "min", "mins", "minute", "minutes");
unit("time", 3600, "h", "hr", "hrs", "hour", "hours");
unit("time", 86400, "d", "day", "days");
unit("time", 604800, "wk", "week", "weeks");
unit("time", 31557600, "yr", "year", "years");
unit("vol", 1, "l", "liter", "liters", "litre", "litres");
unit("vol", 0.001, "ml", "milliliter", "milliliters", "millilitre", "millilitres");
unit("vol", 0.1, "dl", "deciliter", "deciliters", "decilitre", "decilitres");
unit("vol", 3.785411784, "gal", "gallon", "gallons");
unit("vol", 0.946352946, "qt", "quart", "quarts");
unit("vol", 0.473176473, "pt", "pint", "pints");
unit("vol", 0.2365882365, "cup", "cups");
unit("vol", 0.0295735295625, "fl oz", "floz", "fluid ounce", "fluid ounces");
unit("vol", 0.0147867647813, "tbsp", "tablespoon", "tablespoons");
unit("vol", 0.00492892159375, "tsp", "teaspoon", "teaspoons");
unit("area", 1, "m²", "m2", "sqm", "square meter", "square meters", "square metre", "square metres");
unit("area", 1e6, "km²", "km2", "square kilometer", "square kilometers");
unit("area", 0.09290304, "ft²", "ft2", "sqft", "square foot", "square feet");
unit("area", 4046.8564224, "acre", "acres");
unit("area", 10000, "ha", "hectare", "hectares");
unit("data", 1, "B", "byte", "bytes");
unit("data", 1e3, "KB", "kilobyte", "kilobytes");
unit("data", 1e6, "MB", "megabyte", "megabytes");
unit("data", 1e9, "GB", "gigabyte", "gigabytes");
unit("data", 1e12, "TB", "terabyte", "terabytes");
unit("data", 1024, "KiB", "kibibyte", "kibibytes");
unit("data", 1024 ** 2, "MiB", "mebibyte", "mebibytes");
unit("data", 1024 ** 3, "GiB", "gibibyte", "gibibytes");
unit("speed", 1, "m/s", "mps");
unit("speed", 1000 / 3600, "km/h", "kmh", "kph");
unit("speed", 1609.344 / 3600, "mph");
unit("speed", 1852 / 3600, "kn", "knot", "knots");
unit("energy", 1, "J", "joule", "joules");
unit("energy", 4184, "kcal", "calorie", "calories");
unit("energy", 3.6e6, "kWh");
const TEMPS: Record<string, string> = { c: "°C", "°c": "°C", celsius: "°C", f: "°F", "°f": "°F", fahrenheit: "°F", k: "K", kelvin: "K" };
const toKelvin: Record<string, (v: number) => number> = { "°C": (v) => v + 273.15, "°F": (v) => (v - 32) * 5 / 9 + 273.15, K: (v) => v };
const fromKelvin: Record<string, (v: number) => number> = { "°C": (v) => v - 273.15, "°F": (v) => (v - 273.15) * 9 / 5 + 32, K: (v) => v };

/** "<amount> <unit> in|to|as|= <unit>" converted, or null. The amount may be arithmetic ("2*3 km in mi"). */
export function convert(text: string): MathAnswer | null {
  const m = /^\s*(.+?)\s*([a-z°²µ/][a-z°²/ 0-9]*?)\s+(?:in|to|as|into|=|->)\s+([a-z°²µ/][a-z°²/ 0-9]*?)\s*$/i.exec(text);
  if (!m) return null;
  const amount = evaluate(m[1]);
  if (amount == null) return null;
  const from = m[2].trim().toLowerCase(), to = m[3].trim().toLowerCase();
  const tf = TEMPS[from], tt = TEMPS[to];
  if (tf && tt) {
    return { expression: `${formatNumber(amount)} ${tf}`, value: `${formatNumber(fromKelvin[tt](toKelvin[tf](amount)))} ${tt}` };
  }
  const uf = UNITS[from], ut = UNITS[to];
  if (!uf || !ut || uf.dim !== ut.dim) return null;
  return { expression: `${formatNumber(amount)} ${uf.sym}`, value: `${formatNumber((amount * uf.f) / ut.f)} ${ut.sym}` };
}

/**
 * The search's inline answer to [text]: a conversion, or arithmetic that actually computes something (an operator or
 * a function - a bare number, a date like 2026-11-26 or a phone number like +47 123 45 678 is left to the search).
 */
export function answer(text: string): MathAnswer | null {
  const q = text.trim();
  if (!q || q.length > 200) return null;
  const conv = convert(q);
  if (conv) return conv;
  if (!/[0-9π)]/.test(q)) return null;
  if (/^\+?[\d\s()-]{6,}$/.test(q)) return null; // a phone number
  if (/^\d{4}-\d{1,2}-\d{1,2}$/.test(q)) return null; // a date
  const ops = /[*/^%!×÷·]|\d\s*[-+−]\s*[\d.(]|\b(sqrt|abs|ln|log|exp|sin|cos|tan|asin|acos|atan|round|floor|ceil)\b|\bpi\b|π|\bof\b/i.test(q.replace(/=\s*$/, ""));
  if (!ops) return null;
  const v = evaluate(q);
  if (v == null) return null;
  return { expression: q.replace(/=\s*$/, "").trim(), value: formatNumber(v) };
}
