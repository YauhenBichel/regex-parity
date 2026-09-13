# regex-parity (JavaScript)

One set of regular-expression rules, the same answer in JavaScript, Python and Java, even when text
contains accented letters, look-alike characters, smart quotes or invisible characters.

```js
import { matches, findAll, evaluate } from "regex-parity";

matches("\\bharmless\\b", "definitely harmleſs");   // true; new RegExp(…, "gi") says false
findAll("\\border\\s+\\d{6}\\b", "order １２３４５６");  // [{ start: 0, end: 12, text: "order １２３４５６" }]
evaluate({ id: "date", patterns: ["\\bready by friday\\b"], unless: ["\\bif\\b"] }, "Ready by Friday if it passes.");  // []
```

```bash
npx regex-parity check rules.yaml     # validate rules, compile in RE2, run examples and look-alike variants
npx regex-parity try '\bknow\b' 'I Know'
```

See the [main README](https://github.com/YauhenBichel/regex-parity#readme) and
[docs/SPEC.md](https://github.com/YauhenBichel/regex-parity/blob/main/docs/SPEC.md).
