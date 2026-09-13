# Contributing

Thanks for looking. Issues and pull requests are both welcome.

## The most useful contribution right now

**An engine case that breaks the design.** regex-parity rests on one claim: fold the text first, match
with ASCII semantics, and JavaScript, Python and Java give the same answer. If you find an input,
a pattern or an engine version where that is false, add a line to `test/evidence/cases.tsv`, run
the evidence, and open a pull request with what each engine said. That is worth more than any code
at this stage.

## Working here

```bash
npm ci
npm run evidence        # Node 20+, Python 3.10+, Java 17+; a few seconds, no network
```

`expected.tsv` records what each engine answers. Change it only together with the case that
changes it, and say in the pull request which engine and version you ran.

Please keep to the shape of what is there:

- **Claims carry their evidence.** A number or behaviour stated in the design is measured by
  `test/evidence/`, and CI re-measures it on every change.
- **Portable patterns only**: no lookaround, backreferences, atomic groups, possessive quantifiers,
  named groups, `\p{…}` or non-ASCII characters. `re2-compile.mjs` checks the example rules.
- **Pin actions by commit SHA** in workflows.
- **Examples carry no real data**: no credentials, no personal or health data, not even fake
  shapes that a secret scanner would flag.
