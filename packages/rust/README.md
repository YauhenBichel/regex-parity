# regex-parity for Rust

One set of regular-expression rules, the same answer in Rust, JavaScript, Python, Java and Go, even
when text contains accented letters, look-alike characters, smart quotes or invisible characters.

```toml
[dependencies]
regex-parity = "0.2"
```

```rust
use regex_parity::{evaluate, find_all, matches, Rule};

assert!(matches(r"\bharmless\b", "definitely harmleſs", false)?);
let found = find_all(r"\border\s+\d{6}\b", "order １２３４５６", false)?;   // one Match: start 0, end 24 (bytes)
let promise = Rule {
    id: "promise".into(),
    patterns: vec![r"\bready\s+by\s+friday\b".into()],
    unless: vec![r"\bif\b".into()],
    ..Default::default()
};
assert!(evaluate(&promise, "Ready by Friday if the review passes.")?.is_empty());
```

Offsets are byte offsets into your `&str`, as everywhere in Rust. Dependencies: `regex` and
`unicode-normalization`. See the [main README](https://github.com/YauhenBichel/regex-parity#readme)
and [docs/SPEC.md](https://github.com/YauhenBichel/regex-parity/blob/main/docs/SPEC.md).
