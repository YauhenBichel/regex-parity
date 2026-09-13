# regex-parity

**The same regular expression can give different answers in JavaScript, Python and Java.** It
happens as soon as text contains accented letters, look-alike characters, smart quotes or invisible
characters, which is most real text.

For example, a rule meant to catch false reassurance, checked against
`That's definitely harmleſs.` (with a long s, U+017F, in "harmless"):

| | JavaScript | Python | Java |
|---|---|---|---|
| Does the rule match? | no | yes | yes |

If you run the same content, safety or privacy rules in more than one language (a web app, a
mobile app and a backend, say), they quietly disagree, and your tests do not notice, because test
examples are almost always plain ASCII.

**regex-parity makes them agree, and proves it.**

- It normalises text the same way in every language before matching, and pins every engine to the
  same ASCII behaviour for `\b`, `\w`, `\d`, `\s` and case.
- It turns each of your test examples into look-alike versions (long s, full-width letters,
  zero-width spaces, smart quotes and more) and requires every language to give the example's answer.
- It checks that every pattern also compiles in RE2, so the rules can move to Go or Rust.

## Status

**Design stage: there is no library to install yet.** This repository holds
[the design](docs/architecture/0001-design.md) and [`test/evidence`](test/evidence), which measures
the problem and the fix in all three languages. CI re-runs it on every change.

The approach has already been applied by hand in one project that runs the same rules in
TypeScript, Python and Java. Its test suite grew from 81 examples to 428 generated cases, on which
its ports had disagreed up to 153 times. Now they agree on every one.

## Try the evidence

```bash
npm ci
npm run evidence        # needs Node 20+, Python 3.10+ and Java 17+
```

For each case it prints whether each language matched, before and after normalising, and fails if
anything differs from [`expected.tsv`](test/evidence/expected.tsv).

| Case | Pattern | JavaScript `gi` | Python `IGNORECASE\|UNICODE` | Java `CASE_INSENSITIVE\|UNICODE_CASE` |
|---|---|---|---|---|
| `definitely harmleſs` (long s) | a false-reassurance rule | no | yes | yes |
| `I Know` (Kelvin sign) | `\bknow\b` | no | yes | yes |
| ten full-width digits | a ten-digit identifier | no | yes | no |
| `café` | `\bcaf\b` | yes | no | no |
| `café` | `^\w+$` | no | yes | no |
| `mela` + zero-width space + `noma` | `\bmelanoma\b` | no | no | no |

After normalising, all three agree on every row; Java also needs `\b` rewritten, because its own
`\b` treats `é` as part of a word.

## Not a medical device

regex-parity checks text with regular expressions. It does not diagnose anything, and it is not a
safety certification for a product built with it. Some examples mention health wording because
that is where the problem was found.

## Licence

Apache-2.0.

## Contributors

<!-- readme: contributors,bots/- -start -->
<p align="center">
  <a href="https://github.com/YauhenBichel" title="Yauhen Bichel" aria-label="Yauhen Bichel"><img src=".github/faces/YauhenBichel.svg" width="87" height="99" alt="Yauhen Bichel" /></a>
</p>
<!-- readme: contributors,bots/- -end -->
