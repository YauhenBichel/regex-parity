# regex-parity (Python)

One set of regular-expression rules, the same answer in Python, JavaScript and Java, even when text
contains accented letters, look-alike characters, smart quotes or invisible characters.

```python
import regex_parity as rp

rp.matches(r"\bharmless\b", "definitely harmleſs")         # True
rp.find_all(r"\border\s+\d{6}\b", "order １２３４５６")     # [Match(start=0, end=12, text='order １２３４５６')]
rule = rp.Rule("date", (r"\bready by friday\b",), unless=(r"\bif\b",))
rp.evaluate(rule, "Ready by Friday if it passes.")          # []
```

No dependencies. See the [main README](https://github.com/YauhenBichel/regex-parity#readme) and
[docs/SPEC.md](https://github.com/YauhenBichel/regex-parity/blob/main/docs/SPEC.md).
