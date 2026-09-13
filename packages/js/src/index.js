// regex-parity: one set of regular-expression rules, the same answer in JavaScript, Python and Java.
//
// Plain engines disagree as soon as text is not ASCII: case folding, \b, \w, \d, \s and "." each
// treat accented, look-alike and invisible characters differently. regex-parity folds the text the
// same way in every language, pins every engine to ASCII behaviour, and accepts only patterns that
// every engine reads the same way. docs/SPEC.md is the algorithm; the Python and Java packages
// implement it too, and all three must pass conformance/cases.tsv.
//
// Characters are written here as numeric code points, never as escapes inside string literals, so
// no invisible character can hide in this file.

const INVISIBLE = new Set([
  0x00ad, 0x180e, 0x200b, 0x200c, 0x200d, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e,
  0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0xfeff,
]);
const DASHES = new Set([0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212, 0xfe58, 0xfe63, 0xff0d]);
const APOSTROPHES = new Set([0x2018, 0x2019, 0x201a, 0x201b, 0x02bc, 0x2032]);
const QUOTES = new Set([0x201c, 0x201d, 0x201e, 0x201f]);
// Line breaks engines disagree about for "." and \s. All of them become "\n".
const LINE_BREAKS = new Set([0x000d, 0x0085, 0x2028, 0x2029]);
const OGHAM_SPACE_MARK = 0x1680;

function foldCodePoint(codePoint) {
  if (INVISIBLE.has(codePoint)) return "";
  if (DASHES.has(codePoint)) return "-";
  if (APOSTROPHES.has(codePoint)) return "'";
  if (QUOTES.has(codePoint)) return '"';
  if (LINE_BREAKS.has(codePoint)) return "\n";
  if (codePoint === OGHAM_SPACE_MARK) return " ";
  return String.fromCodePoint(codePoint);
}

/**
 * Text as every language matches it: NFKC one code point at a time, invisible characters removed,
 * dashes, typographic apostrophes and quotes to their ASCII forms, line breaks to "\n". For every
 * code unit of the folded text, `starts` and `ends` give the original character it came from.
 */
export function fold(text) {
  let folded = "";
  const starts = [];
  const ends = [];
  let index = 0;
  for (const character of text) {
    const end = index + character.length;
    for (const piece of character.normalize("NFKC")) {
      const out = foldCodePoint(piece.codePointAt(0));
      for (let unit = 0; unit < out.length; unit += 1) {
        starts.push(index);
        ends.push(end);
      }
      folded += out;
    }
    index = end;
  }
  return { text: folded, starts, ends, length: text.length };
}

function originalRange(folded, start, end) {
  const from = start < folded.text.length ? folded.starts[start] : folded.length;
  const to = end > start ? folded.ends[end - 1] : from;
  return [from, to];
}

const LETTER_ESCAPES = "bBdDsSwWtnrf";
const QUANTIFIER = /^\{\d+(?:,\d*)?\}/;

/** Why a pattern is not portable, or an empty list. The same checks run in every language. */
export function checkPattern(source) {
  const problems = [];
  const add = (problem) => {
    if (!problems.includes(problem)) problems.push(problem);
  };
  if (source.length === 0) add("the pattern is empty");
  for (let i = 0; i < source.length; i += 1) {
    if (source.charCodeAt(i) > 127) {
      add("non-ASCII character: text is folded before matching, so write the ASCII form");
      break;
    }
  }
  let inClass = false;
  let i = 0;
  while (i < source.length) {
    const c = source[i];
    if (c === "\\") {
      if (i + 1 >= source.length) {
        add("trailing backslash");
        break;
      }
      const d = source[i + 1];
      if (/[A-Za-z0-9]/.test(d)) {
        if (!LETTER_ESCAPES.includes(d)) add(`the escape \\${d} is not portable`);
        else if (inClass && (d === "b" || d === "B")) add(`\\${d} inside a character class is not portable`);
      }
      i += 2;
      continue;
    }
    if (inClass) {
      if (c === "[") add("'[' inside a character class is not portable: Java reads it as a nested class");
      else if (c === "&" && source[i + 1] === "&") add("'&&' inside a character class is not portable");
      else if (c === "]") inClass = false;
      i += 1;
      continue;
    }
    if (c === "[") {
      inClass = true;
      let j = i + 1;
      if (source[j] === "^") j += 1;
      if (source[j] === "]") {
        add("a character class that starts with ']' is not portable");
        j += 1;
      }
      i = j;
      continue;
    }
    if (c === "(" && source[i + 1] === "?" && source[i + 2] !== ":") {
      add("'(?' other than '(?:' is not portable: lookaround, named groups, inline flags and atomic groups differ between engines or are missing from RE2");
    } else if (c === "$") {
      add("'$' is not portable: Python and Java also match it before a final newline");
    } else if (c === "{") {
      const quantifier = QUANTIFIER.exec(source.slice(i));
      if (!quantifier) {
        add("a '{' that is not a {n}, {n,} or {n,m} quantifier is not portable; write \\{");
      } else {
        i += quantifier[0].length;
        if (source[i] === "+") add("possessive quantifiers are not portable");
        continue;
      }
    } else if ((c === "*" || c === "+" || c === "?") && source[i + 1] === "+") {
      add("possessive quantifiers are not portable");
    }
    i += 1;
  }
  if (inClass) add("unclosed character class");
  return problems;
}

export class PatternError extends Error {
  constructor(pattern, problems) {
    super(`not a portable pattern: ${JSON.stringify(pattern)}: ${problems.join("; ")}`);
    this.name = "PatternError";
    this.pattern = pattern;
    this.problems = problems;
  }
}

const compiled = new Map();

/**
 * Compiles a portable pattern for folded text. The flags are "g", plus "i" unless `caseSensitive`,
 * and never "u": without it \b, \w, \d and case folding are ASCII, as in the Python and Java ports.
 */
export function compile(source, { caseSensitive = false } = {}) {
  const key = (caseSensitive ? "s:" : "i:") + source;
  let pattern = compiled.get(key);
  if (!pattern) {
    const problems = checkPattern(source);
    if (problems.length) throw new PatternError(source, problems);
    try {
      pattern = new RegExp(source, caseSensitive ? "g" : "gi");
    } catch (error) {
      throw new PatternError(source, [error.message]);
    }
    compiled.set(key, pattern);
  }
  return pattern;
}

function* spans(text, pattern) {
  for (const match of text.matchAll(pattern)) {
    // An empty match has no position every engine agrees on, so none of them count.
    if (match[0].length === 0) continue;
    yield [match.index, match.index + match[0].length];
  }
}

/** Every match of `source` in `text`, as ranges of the original text. */
export function findAll(source, text, options = {}) {
  const folded = fold(text);
  return [...spans(folded.text, compile(source, options))].map(([s, e]) => {
    const [start, end] = originalRange(folded, s, e);
    return { start, end, text: text.slice(start, end) };
  });
}

/** Whether `source` matches anywhere in `text`. */
export function matches(source, text, options = {}) {
  return !spans(fold(text).text, compile(source, options)).next().done;
}

const SENTENCE_END = ".!?\n";
const ASCII_SPACE = " \t\n\v\f\r";

/** The sentence around `index` in `text`, as [start, end); `end` includes the terminator. */
export function sentenceRange(text, index) {
  let start = index;
  while (start > 0 && !SENTENCE_END.includes(text[start - 1])) start -= 1;
  while (start < text.length && ASCII_SPACE.includes(text[start])) start += 1;
  let end = index;
  while (end < text.length && !SENTENCE_END.includes(text[end])) end += 1;
  if (end < text.length) end += 1;
  return [start, end];
}

/**
 * Applies one rule: every match of any of its patterns, except a match whose sentence also matches
 * one of its `unless` patterns. A range found by two patterns counts once. Findings are ranges of
 * the original text, sorted by position.
 */
export function evaluate(rule, text) {
  const options = { caseSensitive: rule.case === "sensitive" };
  const folded = fold(text);
  const seen = new Set();
  const findings = [];
  for (const source of rule.patterns) {
    for (const [s, e] of spans(folded.text, compile(source, options))) {
      const [start, end] = originalRange(folded, s, e);
      const key = `${start}:${end}`;
      if (seen.has(key)) continue;
      seen.add(key);
      if (rule.unless?.length) {
        const [from, to] = sentenceRange(folded.text, s);
        const sentence = folded.text.slice(from, to);
        if (rule.unless.some((u) => !spans(sentence, compile(u, options)).next().done)) continue;
      }
      findings.push({ rule: rule.id, start, end, text: text.slice(start, end) });
    }
  }
  return findings.sort((a, b) => a.start - b.start || a.end - b.end);
}

const LONG_S = String.fromCodePoint(0x017f);
const KELVIN_SIGN = String.fromCodePoint(0x212a);
const ZERO_WIDTH_SPACE = String.fromCodePoint(0x200b);
const NO_BREAK_SPACE = String.fromCodePoint(0x00a0);
const EN_DASH = String.fromCodePoint(0x2013);
const RIGHT_SINGLE_QUOTE = String.fromCodePoint(0x2019);
const RIGHT_DOUBLE_QUOTE = String.fromCodePoint(0x201d);

const VARIANTS = [
  ["long s", (t) => t.replaceAll("s", LONG_S)],
  ["Kelvin sign", (t, caseSensitive) => t.replace(caseSensitive ? /K/g : /[kK]/g, KELVIN_SIGN)],
  ["full-width", (t) => t.replace(/[!-~]/g, (c) => String.fromCodePoint(c.charCodeAt(0) + 0xfee0))],
  ["zero-width spaces", (t) => t.replace(/([A-Za-z])(?=[A-Za-z])/g, (_, letter) => letter + ZERO_WIDTH_SPACE)],
  ["no-break spaces", (t) => t.replaceAll(" ", NO_BREAK_SPACE)],
  ["en dashes", (t) => t.replaceAll("-", EN_DASH)],
  ["smart quotes", (t) => t.replaceAll("'", RIGHT_SINGLE_QUOTE).replaceAll('"', RIGHT_DOUBLE_QUOTE)],
];

/**
 * `text` rewritten the ways real and evasive text writes it. Folding turns each variant back into
 * the original, so a rule must give every variant the original's answer. A variant identical to the
 * original or to an earlier variant is left out.
 */
export function variants(text, { caseSensitive = false } = {}) {
  const seen = new Set([text]);
  const out = [];
  for (const [name, rewrite] of VARIANTS) {
    const rewritten = rewrite(text, caseSensitive);
    if (seen.has(rewritten)) continue;
    seen.add(rewritten);
    out.push({ name, text: rewritten });
  }
  return out;
}
