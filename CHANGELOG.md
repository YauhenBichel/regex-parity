# Changelog

## 0.1.0 (not yet published)

- The same library in JavaScript (`packages/js`), Python (`packages/python`) and Java
  (`packages/java`): `fold`, `checkPattern`, `compile`, `matches`, `findAll`, `evaluate` and
  `variants`, specified in [docs/SPEC.md](docs/SPEC.md).
- `regex-parity check`, which validates a rule file, compiles every pattern in RE2 as well, and runs
  each example and its seven look-alike variants.
- `regex-parity cases` and the shared `conformance/` files, which all three test suites must
  reproduce exactly.
- A live demo in `docs/demo`, published to GitHub Pages from `main`.
