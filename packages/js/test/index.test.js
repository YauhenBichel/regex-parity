import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  PatternError,
  checkPattern,
  compile,
  evaluate,
  findAll,
  fold,
  matches,
  sentenceRange,
  variants,
} from "../src/index.js";

const cp = (...codePoints) => String.fromCodePoint(...codePoints);

test("a long s gets past plain JavaScript, and not past regex-parity", () => {
  const text = `That is definitely harmle${cp(0x017f)}s.`;
  assert.equal(new RegExp("\\bharmless\\b", "gi").test(text), false);
  assert.equal(matches("\\bharmless\\b", text), true);
});

test("findAll reports ranges of the original text", () => {
  const text = `a mela${cp(0x200b)}noma, order ${cp(0xff11, 0xff12, 0xff13)}`;
  const [found] = findAll("\\bmelanoma\\b", text);
  assert.deepEqual(found, { start: 2, end: 11, text: `mela${cp(0x200b)}noma` });
  const [digits] = findAll("\\d{3}", text);
  assert.equal(digits.text, cp(0xff11, 0xff12, 0xff13));
});

test("case sensitivity is an option, and ASCII only either way", () => {
  assert.equal(matches("\\bTODO\\b", "todo"), true);
  assert.equal(matches("\\bTODO\\b", "todo", { caseSensitive: true }), false);
  assert.equal(matches("\\bthis\\b", `th${cp(0x0131)}s`), false, "a dotless i is not an i");
});

test("an accented letter is not a word character", () => {
  assert.equal(matches("\\bcaf\\b", `caf${cp(0x00e9)}`), true);
  assert.equal(matches("^\\w+\\s", `caf${cp(0x00e9)} ok`), false);
});

test("unless only counts inside the same sentence", () => {
  const rule = { id: "date", patterns: ["\\bready\\s+by\\s+friday\\b"], unless: ["\\bif\\b"] };
  assert.equal(evaluate(rule, "Ready by Friday if it passes.").length, 0);
  assert.equal(evaluate(rule, "Ready by Friday. If you ask me, late.").length, 1);
});

test("a range found by two patterns counts once", () => {
  const rule = { id: "twice", patterns: ["\\bharmless\\b", "harmless"] };
  assert.equal(evaluate(rule, "harmless").length, 1);
});

test("folding keeps a map back to the original text", () => {
  const folded = fold(`it${cp(0x2019)}s${cp(0x000d)}${cp(0x2028)}ok ${cp(0x2014)} fine`);
  assert.equal(folded.text, "it's\n\nok - fine");
  assert.equal(folded.starts.length, folded.text.length);
});

test("the sentence function includes its terminator and skips leading spaces", () => {
  const text = "One. Two here! Three";
  assert.deepEqual(sentenceRange(text, 6), [5, 14]);
  assert.deepEqual(sentenceRange(text, 16), [15, 20]);
});

test("patterns that engines read differently are refused", () => {
  const refused = ["(?=a)", "(?<!a)b", "(a)\\1", "(?<name>a)", "(?i)a", "a$", "\\p{L}", "a++", "a{,3}", "x{", "[[a]]", "[a&&b]", "[]a]", "\\x41", String.fromCharCode(92) + "u0041", "\\Aa", "\\v", `caf${cp(0x00e9)}`, "[\\b]"];
  for (const source of refused) assert.notEqual(checkPattern(source).length, 0, source);
  const accepted = ["\\bcolou?r\\b", "a{2,3}", "a{2}", "[a-z\\]]", "\\(\\?=", "(?:ab)+?", "\\d+\\.\\d*", "[^.!?]{0,30}", "\\$5"];
  for (const source of accepted) assert.deepEqual(checkPattern(source), [], source);
  assert.throws(() => compile("(?=a)"), PatternError);
  assert.throws(() => compile("(a"), PatternError);
});

test("every variant folds back to the original", () => {
  const original = `It's "fine" - order #123456 kept`;
  const list = variants(original);
  assert.deepEqual(list.map((v) => v.name), ["long s", "Kelvin sign", "full-width", "zero-width spaces", "no-break spaces", "en dashes", "smart quotes"]);
  // The Kelvin sign folds to a capital K, so compare without case.
  for (const variant of list) assert.equal(fold(variant.text).text.toLowerCase(), fold(original).text.toLowerCase(), variant.name);
});

// --- conformance: the same answers as conformance/cases.tsv, which Python and Java also read ---

const ESCAPE = new RegExp(String.fromCharCode(92, 92) + "u([0-9a-f]{4})", "g");
const unescape = (text) => text.replace(ESCAPE, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
const rows = (name) =>
  readFileSync(new URL(`../../../conformance/${name}`, import.meta.url), "utf8")
    .split("\n")
    .filter((line) => line && !line.startsWith("#"))
    .map((line) => line.split("\t"));

const rules = new Map();
for (const [id, kase, role, pattern] of rows("rules.tsv")) {
  const rule = rules.get(id) ?? { id, case: kase, patterns: [], unless: [] };
  rule[role === "pattern" ? "patterns" : "unless"].push(unescape(pattern));
  rules.set(id, rule);
}
const cases = rows("cases.tsv").map(([rule, expect, variant, text, findings]) => ({ rule, expect, variant, text: unescape(text), findings }));

test("conformance: every case gets the recorded answer and findings", () => {
  assert.ok(cases.length > 100, `only ${cases.length} cases`);
  for (const c of cases) {
    const found = evaluate(rules.get(c.rule), c.text);
    const label = `${c.rule} ${c.expect} (${c.variant})`;
    assert.equal(found.length > 0, c.expect === "match", label);
    assert.equal(found.map((f) => `${f.start}:${f.end}`).join(",") || "-", c.findings, label);
  }
});

test("conformance: variants are generated exactly as recorded", () => {
  let base;
  let expected = [];
  const flush = () => {
    if (base) assert.deepEqual(variants(base.text, { caseSensitive: rules.get(base.rule).case === "sensitive" }).map((v) => [v.name, v.text]), expected, base.text);
  };
  for (const c of cases) {
    if (c.variant === "as written") {
      flush();
      base = c;
      expected = [];
    } else {
      expected.push([c.variant, c.text]);
    }
  }
  flush();
});
