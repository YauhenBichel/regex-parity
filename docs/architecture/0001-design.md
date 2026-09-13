# 0001: regex-parity design

Status: accepted, 13 September 2026. Version 0.1 builds the runtime half: the same folding, pattern
checks and rule evaluation as small libraries in JavaScript, Python and Java (see [SPEC.md](../SPEC.md)),
a command that checks rule files, and conformance cases all three pass. Code generation (sections 5
and 8) is not built yet; products call the libraries instead.

In short: the same regular expression gives different answers in JavaScript, Python and Java as
soon as text is not plain ASCII, and tests rarely notice, because test examples are ASCII.
regex-parity normalises text identically in every language, pins every engine to the same ASCII
matching behaviour, and multiplies each test example into look-alike variants that every language
must answer the same way.

regex-parity compiles a pack of regular-expression rules, written once as data with examples, into
code for several languages, and proves that every language reaches the same verdict.

## 1. The problem

Three private projects by the same author built the same toolchain independently: rules as YAML
with failing and passing examples ("fixtures"), a build step that generates code, a regex
portability lint, and a CI check that generated files have not drifted.

| | Health-answer guard | Outgoing-message guard | Prompt router |
|---|---|---|---|
| Size | 14 rules, 81 fixtures | 16 rules, 99 fixtures | 11 rules, 61 fixtures |
| Ports | TypeScript, Python, Java | TypeScript | TypeScript |
| Rule kinds | forbid, require | forbid, rate | privacy, escalate, keep-local |
| Severities | block, revise, note | pause, soften, note | none |
| Exclusion | `unless`: matches anywhere in the hit's sentence | `unless`: the same | `except`: must match the whole hit |
| Portability lint | 7 constructs banned | 8 constructs banned | 6 banned; a leading `(?i)` allowed |
| Conformance runner | `ruleId⇥redFlags⇥text` → `verdict⇥firedIds`, in order | `caseId⇥kind⇥input` → `caseId⇥1\|0`, any order | cases generated, no runner |
| Match flags | JS `gi`; Python `IGNORECASE\|UNICODE`; Java `CASE_INSENSITIVE\|UNICODE_CASE` | JS `gi` | JS `i` when a pattern starts `(?i)` |
| Text folded first | no | no | NFKC, invisible characters removed, dashes to `-` |

Most rows are cost: every improvement is made three times, differently. The last two rows produce
wrong verdicts.

## 2. Evidence

Every claim in this section is re-measured by [`test/evidence/`](../../test/evidence) in CI.

### 2.1 The same pattern, three engines

| Case | JS `gi` | Python | Java |
|---|---|---|---|
| long s in `definitely harmleſs`, false-reassurance pattern | no | yes | yes |
| Kelvin sign in `I Know this.`, `\bknow\b` | no | yes | yes |
| ten full-width digits, a ten-digit identifier pattern | no | yes | no |
| `\bcaf\b` in `the café is open` | yes | no | no |
| `^\w+$` on `café` | no | yes | no |
| zero-width space inside `melanoma`, `\bmelanoma\b` | no | no | no |

Five of six disagree between at least two engines. The sixth agrees on the unsafe answer.

### 2.2 In a shipped guard

In the health-answer guard, `That is definitely harmleſs.` was blocked by the Python and Java ports
and passed by the TypeScript port, while all three reported every one of their 81 conformance cases
as passing. Of the 241 fixtures in the three projects, four contain any non-ASCII character, and all
four are em dashes: no fixture could see this.

Applying this design's profile there (section 6), with six generated look-alike variants of every
fixture, took its suite from 81 cases to 428. Before the change the ports disagreed with 145 (TypeScript),
109 (Python) and 153 (Java) of them, and with each other on 80. After it, all three pass all 428.

### 2.3 Syntax is not the gap

All 137 patterns in the three projects compile in real RE2 (re2js 2.8.6), which rejects lookahead,
lookbehind, backreferences, atomic groups and possessive quantifiers. The hand-kept lists held. The
failures are semantic, and no lint over pattern text can see them.

### 2.4 The fix

Fold the input one code point at a time (NFKC, invisible characters removed, dashes to `-`), then
match with ASCII semantics: JS `i` without `u`, Python `IGNORECASE|ASCII`, Java `CASE_INSENSITIVE`.

| Case | JS | Python | Java | Java, `\b` rewritten |
|---|---|---|---|---|
| long s | yes | yes | yes | yes |
| Kelvin sign | yes | yes | yes | yes |
| full-width digits | yes | yes | yes | yes |
| `\bcaf\b` in café | yes | yes | no | yes |
| `^\w+$` on café | no | no | no | no |
| zero-width space | yes | yes | yes | yes |
| `\bsum\b` in résumé | yes | yes | no | yes |

Java treats `é` as a word character for `\b`, so Java code emits an explicit ASCII boundary instead.
Java has lookaround, so generated code may use it even though rule authors may not. Its `\w`, `\d`
and `\s` are already ASCII.

The price: under ASCII semantics an accented letter is not a word character, so `\bcaf\b` matches
inside "café". Right for English rules, wrong for Belarusian or French ones. That is why the
semantics are a named, versioned profile.

## 3. What regex-parity is, and is not

regex-parity is the toolchain around a rule pack. It owns the rule core and its validation; extension
fields, declared by each product in a JSON Schema fragment; the intermediate representation;
pattern portability, checked by compiling; the matching profile and the cases generated from it;
one conformance protocol and its runner; code generators, as plug-ins; generated rule
documentation; and the drift check.

It is not an engine. Verdicts, severities, remediation, routing and rate windows stay in each
product, and products do not depend on regex-parity at run time. It does not replace gitleaks (secret
scanning), Vale (prose style) or Guardrails AI (runtime validators).

## 4. Authoring format

Core rule fields: `id`, `title`, `category`, `rationale`, `patterns`, `unless`, `except`, `case`,
`fixtures.fail`, `fixtures.pass`.

- `unless` suppresses a hit when any of its patterns matches the sentence containing the hit.
- `except` suppresses a hit when any of its patterns matches the whole hit. Different meanings keep
  different names.
- `case` is `insensitive` (the default) or `sensitive`. Inline flags are not allowed.
- Every rule has at least one failing and one passing fixture, each on one line.

Ruleset header: `id`, `version`, `updated`, `profile`, `extension` (the path to the product's schema
fragment). A field in neither the core nor the fragment is an error.

The example, also compiled in RE2 by the evidence:
[`test/evidence/example-rules.yaml`](../../test/evidence/example-rules.yaml).

## 5. Intermediate representation

Flat JSON, fixed key order, optional lists present and empty, rationale trimmed, `irVersion: 1`, and
a published JSON Schema. Declared product fields are carried through. Generators read the IR; a port
never parses YAML. Fixtures appear in the IR and in conformance output, never in runtime output.

A conformance case is `{caseId, ruleId, input, context, fires, origin}`, where `origin` is
`fixture` or `profile`.

## 6. Portability and the matching profile

**Syntax.** `regex-parity check` compiles every pattern, `unless` and `except` with RE2 (re2js: pure
JavaScript, no native build) and with the JavaScript engine. Failing either fails the check.

**Semantics.** Profile `portable-1`, the default:

| | Rule |
|---|---|
| Pattern source | ASCII only |
| Input | folded one code point at a time: NFKC; U+00AD, U+180E, U+200B–U+200F, U+202A–U+202E, U+2060–U+2064 and U+FEFF removed; U+2010–U+2015, U+2212, U+FE58, U+FE63 and U+FF0D to `-`; U+2028 and U+2029 to `\n`; U+1680 to a space |
| Classes and case | ASCII: JS `gi` without `u`; Python `IGNORECASE\|ASCII`; Java `CASE_INSENSITIVE` with `\b` rewritten |
| Whitespace in the sentence function | ASCII: space, `\t`, `\n`, `\v`, `\f`, `\r` |
| Offsets | findings and edits refer to the original text, through a map kept while folding |

**Generated cases.** From every fixture, regex-parity derives variants that must get the fixture's
answer: long s, Kelvin sign, full-width forms, zero-width spaces inside words, no-break spaces, and
en dashes for hyphens.

## 7. Conformance protocol

One protocol for every product and language, tab-separated so a port needs no JSON parser.

```text
stdin    caseId ⇥ context ⇥ input         one case per line
stdout   caseId ⇥ firedRuleIdsCsv          one line per case, any order
stderr   passed through
```

`context` is a string whose meaning the product declares, empty when unused.
`regex-parity conform -- <command…>` runs fixture and profile cases and reports each failure by rule,
origin and input.

## 8. Generators

Plug-ins with the signature `generate(ir, helpers)`, returning `{path: contents}`. The driver knows
no language. Version 0.1 ships `ir`, `typescript`, `python` and `docs`; each emits the profile's
fold function and flags. `java` follows in 0.2. A product may keep private generators.

## 9. Command line

| Command | Does |
|---|---|
| `regex-parity build` | validate, normalise, run the generators, write files |
| `regex-parity check` | schema and extension fragment, RE2 and JS compilation, profile rules |
| `regex-parity conform -- <command…>` | fixture and profile cases against any implementation |
| `regex-parity drift` | rebuild in memory; fail if committed generated files differ |

An npm package for Node 20 or later, with `yaml` and `re2js` as its dependencies.

## 10. Migration of the first users

One project and one pull request at a time: the health-answer guard first (its generated files must
stay byte-identical apart from the header line), then the outgoing-message guard, then the prompt
router. After that, the first new pack: shared privacy rules for secret shapes and UK health
identifiers, which today exist as about a dozen hand-kept copies.

## 11. Open questions

- **Typographic apostrophes.** NFKC leaves `’` (U+2019) unchanged, so a rule written with `'s`
  misses `it’s` as phones type it. Folding `’ ‘ ʼ ′` to `'` and `“ ” ″` to `"` is the likely
  answer, with a generated apostrophe variant.
- A `unicode-1` profile for rules in languages with accented letters.
- Go and Rust generators, where RE2 is native.
- Whether rules that match on conversation shape (rate rules) belong in the core.
- How a ruleset moves from one profile version to the next on purpose.
- Whether the fold and sentence functions ship as small npm and PyPI packages, or stay generated.
