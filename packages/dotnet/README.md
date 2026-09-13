# RegexParity for .NET

One set of regular-expression rules, the same answer in C#, JavaScript, Python, Java, Go and Rust,
even when text contains accented letters, look-alike characters, smart quotes or invisible
characters.

```bash
dotnet add package RegexParity
```

```csharp
using RegexParity;

Parity.Matches(@"\bharmless\b", "definitely harmleſs");            // true
Parity.FindAll(@"\border\s+\d{6}\b", "order １２３４５６");            // [Match { Start = 0, End = 12, Text = order １２３４５６ }]
var promise = new Rule("promise", new[] { @"\bready\s+by\s+friday\b" }, new[] { @"\bif\b" });
Parity.Evaluate(promise, "Ready by Friday if the review passes."); // empty
```

.NET 8 or later, no dependencies. Offsets are string indexes (UTF-16 code units), as in JavaScript.
Case-insensitive matching does not depend on the current culture. See the
[main README](https://github.com/YauhenBichel/regex-parity#readme) and
[docs/SPEC.md](https://github.com/YauhenBichel/regex-parity/blob/main/docs/SPEC.md).
