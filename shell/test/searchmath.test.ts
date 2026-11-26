// The launcher search's quick math and conversions (shell/searchmath.ts): node --test shell/test/searchmath.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { answer, convert, evaluate, formatNumber } from "../searchmath.ts";

test("arithmetic: precedence, parentheses, unary minus, right-assoc power", () => {
  assert.equal(evaluate("2+3*4"), 14);
  assert.equal(evaluate("(2+3)*4"), 20);
  assert.equal(evaluate("-2^2"), -4);
  assert.equal(evaluate("2^3^2"), 512);
  assert.equal(evaluate("10/4"), 2.5);
  assert.equal(evaluate("7 - -3"), 10);
  assert.equal(evaluate("3 x 4"), 12);
  assert.equal(evaluate("6 × 7 ÷ 2"), 21);
  assert.equal(evaluate("2**10"), 1024);
  assert.equal(evaluate("5!"), 120);
  assert.equal(evaluate("2pi"), 2 * Math.PI);
  assert.equal(evaluate("3(4+1)"), 15);
  assert.equal(evaluate("1_000 * 2"), 2000);
  assert.equal(evaluate("1e3 + 1"), 1001);
});

test("percent: of, postfix and a calculator's plus", () => {
  assert.equal(evaluate("15% of 80"), 12);
  assert.equal(evaluate("50%"), 0.5);
  assert.equal(evaluate("200 + 10%"), 220);
  assert.equal(evaluate("200 - 25%"), 150);
});

test("functions and constants", () => {
  assert.equal(evaluate("sqrt(16)"), 4);
  assert.equal(evaluate("sqrt 9"), 3);
  assert.equal(evaluate("abs(-3)"), 3);
  assert.equal(evaluate("log(1000)"), 3);
  assert.equal(evaluate("ln(e)"), 1);
  assert.equal(formatNumber(evaluate("sin(pi)")!), "0");
});

test("not math: errors, code and plain words give null, never run anything", () => {
  for (const bad of ["", "hello", "2+", "(1+2", "1/0", "alert(1)", "constructor", "__proto__", "process.exit()", "2;3", "a=1", "this", "[1]", "sqrt", "5!!!!!!!!!!!!!!!!!!", "0^-1"])
    assert.equal(evaluate(bad), null, bad);
});

test("formatting drops float noise", () => {
  assert.equal(formatNumber(evaluate("0.1+0.2")!), "0.3");
  assert.equal(formatNumber(1 / 3), "0.3333333333");
  assert.equal(formatNumber(-0), "0");
  assert.equal(formatNumber(1e20), "1e+20");
});

test("conversions", () => {
  assert.deepEqual(convert("5 km in miles"), { expression: "5 km", value: "3.106855961 mi" });
  assert.equal(convert("100 f to c")?.value, "37.77777778 °C");
  assert.equal(convert("0 c in f")?.value, "32 °F");
  assert.equal(convert("10 kg to lb")?.value, "22.04622622 lb");
  assert.equal(convert("1 GiB in MB")?.value, "1073.741824 MB");
  assert.equal(convert("100 km/h to mph")?.value, "62.13711922 mph");
  assert.equal(convert("2*3 ft in m")?.value, "1.8288 m");
  assert.equal(convert("1 fl oz in ml")?.value, "29.57352956 ml");
  assert.equal(convert("5 kg in km"), null); // different dimensions
  assert.equal(convert("5 parsecs in km"), null);
});

test("the search's answer: math only where something is computed", () => {
  assert.deepEqual(answer("12*7"), { expression: "12*7", value: "84" });
  assert.equal(answer("2+2=")?.value, "4");
  assert.equal(answer("5 km in miles")?.value, "3.106855961 mi");
  assert.equal(answer("sqrt(2)")?.value, "1.414213562");
  for (const no of ["42", "spotify", "+47 123 45 678", "2026-11-26", "dock position", "Settings", "2+", "chrome 2"])
    assert.equal(answer(no), null, no);
});
