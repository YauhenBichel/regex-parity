# regex-parity specification, version 0.1 (profile `portable-1`)

What every implementation does, precisely enough to write another one without reading the existing
three. The JavaScript, Python and Java packages all follow it, and all must reproduce
[`conformance/cases.tsv`](../conformance/cases.tsv).

Code points are written U+XXXX.

## 1. Folding

`fold(text)` reads `text` one code point at a time. For each code point:

1. Apply Unicode NFKC to that code point alone. Per code point, not per string, so every language
   produces the same result and the map back to the original stays simple.
2. For each code point of that result, write:

| Code points | Written as |
|---|---|
| U+00AD, U+180E, U+200B–U+200F, U+202A–U+202E, U+2060–U+2064, U+FEFF | nothing |
| U+2010–U+2015, U+2212, U+FE58, U+FE63, U+FF0D | `-` |
| U+2018, U+2019, U+201A, U+201B, U+02BC, U+2032 | `'` |
| U+201C–U+201F | `"` |
| U+000D, U+0085, U+2028, U+2029 | newline (U+000A) |
| U+1680 | space |
| anything else | itself |

Every unit written records the start and end of the original code point it came from. JavaScript
and Java count UTF-16 code units; Python counts code points. For text below U+10000 the offsets are
identical.

A range `[s, e)` of folded text maps back to `[start of unit s, end of unit e-1]`. An empty range
maps to the start of unit `s`, or to the length of the original when `s` is the end.

## 2. Portable patterns

A pattern is refused, with a reason, when it contains any of:

- a character above U+007F (text is folded, so write the ASCII form);
- a backslash followed by a letter or digit other than `b B d D s S w W t n r f`
  (this excludes backreferences, `\p{…}`, `\x`, `\u`, `\A`, `\z`, `\v`, `\h` and the rest);
- `\b` or `\B` inside a character class;
- `(?` not followed by `:` (lookaround, named groups, inline flags, atomic groups, comments);
- `$` outside a character class (Python and Java also match it before a final newline);
- `{` that does not begin a `{n}`, `{n,}` or `{n,m}` quantifier;
- a possessive quantifier: `*+`, `++`, `?+`, `}+`;
- inside a character class: `[` (Java reads a nested class), `&&` (Java reads an intersection), or
  a class that starts with `]` or `^]`;
- an unclosed character class, or a trailing backslash.

Every accepted pattern must also compile in the language's own engine; `regex-parity check`
additionally compiles it in RE2.

## 3. Matching

Patterns run on the folded text, case-insensitively unless the rule says `case: sensitive`, with
ASCII semantics for `\b \B \w \W \d \D \s \S` and for case:

| Engine | Setting |
|---|---|
| JavaScript | flags `g` plus `i`; never `u` |
| Python `re` | `re.ASCII`, plus `re.IGNORECASE` |
| Java `java.util.regex` | `CASE_INSENSITIVE` without `UNICODE_CASE`; `\b` and `\B` rewritten to `(?:(?<=W)(?!W)\|(?<!W)(?=W))` and `(?:(?<=W)(?=W)\|(?<!W)(?!W))` with `W` = `[A-Za-z0-9_]`, because Java's own `\b` treats letters such as `é` as word characters |

Matches are the engine's non-overlapping matches in order. **Empty matches are ignored**, because
engines disagree about where they are.

A consequence: an accented letter is not a word character, so `\bcaf\b` matches inside `café`.

## 4. Sentences

`sentenceRange(text, index)` returns `[start, end)`:

1. `start` = `index`; while `start > 0` and `text[start-1]` is not `.` `!` `?` or newline, step back.
2. While `text[start]` is space, tab, newline, U+000B, U+000C or U+000D, step forward.
3. `end` = `index`; while `end` is inside the text and `text[end]` is not `.` `!` `?` or newline,
   step forward.
4. If `end` is inside the text, step once more, to include the terminator.

## 5. Rules

A rule has an `id`, one or more `patterns`, zero or more `unless` patterns, and `case`
(`insensitive` by default).

`evaluate(rule, text)`:

1. Fold `text`.
2. For each pattern in order, for each match in the folded text: map it to the original range. If
   that range was already seen for this rule, skip it; otherwise mark it seen, **before** the next
   step.
3. If the rule has `unless` patterns, take the sentence around the match start in the folded text.
   If any `unless` pattern matches inside that sentence, drop the match.
4. Otherwise record a finding: rule id, original start, original end, and the original text in that
   range.
5. Sort findings by start, then end.

## 6. Variants

`variants(text, caseSensitive)` rewrites `text` in this order and returns each result that differs
from the text and from every earlier result:

| Name | Rewrite |
|---|---|
| long s | every `s` to U+017F |
| Kelvin sign | every `K`, and also every `k` unless case-sensitive, to U+212A |
| full-width | every character U+0021–U+007E to that code point plus U+FEE0 |
| zero-width spaces | U+200B after every ASCII letter that is followed by an ASCII letter |
| no-break spaces | every space to U+00A0 |
| en dashes | every `-` to U+2013 |
| smart quotes | every `'` to U+2019, then every `"` to U+201D |

Folding turns every variant back into the original (the Kelvin sign into a capital `K`, which is
why it leaves `k` alone for case-sensitive rules), so a rule must give every variant the
original's answer.

## 7. Conformance files

`regex-parity cases <rules.yaml> <dir>` writes two tab-separated files. Lines starting with `#` are
comments. In both, a backslash, every control character and every character above U+007E is
written as a backslash, `u` and four lower-case hexadecimal digits.

- `rules.tsv`: `rule`, `case`, `role` (`pattern` or `unless`), `pattern`.
- `cases.tsv`: `rule`, `expect` (`match` or `no_match`), `variant` (`as written` or a variant
  name), `text`, and the findings as `start:end` joined by commas, or `-` for none. Each example is
  followed by its variants, in the order of section 6.

An implementation conforms when, for every row, `evaluate` gives a non-empty result exactly when
`expect` is `match`, the findings are exactly the recorded ranges, and `variants` of each example
produce exactly the rows that follow it.
