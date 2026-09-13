# ruleproof

Write a pack of regular-expression rules once, as data with examples. Compile it for several
languages, and prove that every language reaches the same verdict.

**Status: design.** There is no library code yet. This repository holds the design and the
evidence behind it, and CI re-measures that evidence on every change.

## Why

A rule written once and run in three languages is three rules as soon as the text is not ASCII.
The same pattern, each engine with the flags rule engines usually use:

| Case | Pattern | JavaScript `gi` | Python `IGNORECASE\|UNICODE` | Java `CASE_INSENSITIVE\|UNICODE_CASE` |
|---|---|---|---|---|
| `definitely harmleſs` (long s) | a false-reassurance rule | no | yes | yes |
| `I Know` (Kelvin sign) | `\bknow\b` | no | yes | yes |
| ten full-width digits | a ten-digit identifier | no | yes | no |
| `café` | `\bcaf\b` | yes | no | no |
| `café` | `^\w+$` | no | yes | no |
| `mela` + zero-width space + `noma` | `\bmelanoma\b` | no | no | no |

In one shipped guard with three ports, this let a false-reassurance sentence through one port
while all three passed every example they had, because every example was ASCII.

Folding the text first (NFKC, invisible characters removed, dashes to `-`) and matching with ASCII
semantics makes the three engines agree on all of these. Java also needs `\b` rewritten. The
[design](docs/architecture/0001-design.md) turns that into a toolchain: one rule format, a real RE2
check, a matching profile, examples multiplied into look-alike variants, and one conformance
protocol for every port.

## Reproduce the evidence

```bash
npm ci
npm run evidence        # Node 20+, Python 3.10+, Java 17+
```

[`test/evidence/`](test/evidence) runs each case in all three engines, raw and folded, compares
the answers with [`expected.tsv`](test/evidence/expected.tsv), and compiles the example rule in RE2.

## Not a medical device

ruleproof checks text with regular expressions. It does not diagnose anything, and it is not a
safety certification for a product built with it. Some examples mention health wording because
that is where the problem was found.

## Licence

Apache-2.0.

## Contributors

<!-- readme: contributors,bots/- -start -->
<!-- readme: contributors,bots/- -end -->
