# regex-parity for Go

One set of regular-expression rules, the same answer in Go, JavaScript, Python, Java and the other
regex-parity packages, even when text contains accented letters, look-alike characters, smart quotes
or invisible characters.

```bash
go get github.com/YauhenBichel/regex-parity/go
```

```go
import regexparity "github.com/YauhenBichel/regex-parity/go"

ok, _ := regexparity.Matches(`\bharmless\b`, "definitely harmleſs", false)   // true
found, _ := regexparity.FindAll(`\border\s+\d{6}\b`, "order １２３４５６", false) // one Match, Text "order １２３４５６"
rule := regexparity.Rule{ID: "promise", Patterns: []string{`\bready\s+by\s+friday\b`}, Unless: []string{`\bif\b`}}
findings, _ := regexparity.Evaluate(rule, "Ready by Friday if the review passes.")  // none
```

Offsets are byte offsets into your string, as everywhere in Go. The only dependency is
`golang.org/x/text`, for Unicode NFKC. See the
[main README](https://github.com/YauhenBichel/regex-parity#readme) and
[docs/SPEC.md](https://github.com/YauhenBichel/regex-parity/blob/main/docs/SPEC.md).
