# Changelog

## 0.2.0 (not yet published)

- Go package in `go/` (`github.com/YauhenBichel/regex-parity/go`).
- Rust crate in `packages/rust` (`regex-parity`).
- .NET package in `packages/dotnet` (`RegexParity`, .NET 8+).
- Ruby gem in `packages/ruby` (`regex-parity`, Ruby 3.1+).
- Folding turns a vertical tab (U+000B) into a space, because Go's `\s` does not match it.
- Patterns with a repetition count above 1000 are refused, because RE2 and Go refuse them.
- `--` and `~~` inside a character class are refused, because Rust reads them as set operations.
- One tag releases every package: `release.yml` checks that all versions match, then publishes to
  npm, PyPI, Maven Central, crates.io, NuGet and RubyGems, and tags the Go module ([docs/RELEASING.md](docs/RELEASING.md)).
- `conformance/patterns.tsv`: every language must refuse and accept the same patterns.

## 0.1.0 (not yet published)

- The same library in JavaScript (`packages/js`), Python (`packages/python`) and Java
  (`packages/java`): `fold`, `checkPattern`, `compile`, `matches`, `findAll`, `evaluate` and
  `variants`, specified in [docs/SPEC.md](docs/SPEC.md).
- `regex-parity check`, which validates a rule file, compiles every pattern in RE2 as well, and runs
  each example and its seven look-alike variants.
- `regex-parity cases` and the shared `conformance/` files, which all three test suites must
  reproduce exactly.
- A live demo in `docs/demo`, published to GitHub Pages from `main`.
