# regex-parity for Ruby

One set of regular-expression rules, the same answer in Ruby, JavaScript, Python, Java, Go, Rust
and C#, even when text contains accented letters, look-alike characters, smart quotes or invisible
characters.

```bash
gem install regex-parity
```

```ruby
require "regex_parity"

RegexParity.matches?('\bharmless\b', "definitely harmleſs")           # => true
RegexParity.find_all('\border\s+\d{6}\b', "order １２３４５６")            # => [#<struct RegexParity::Match start=0, end=12, text="order １２３４５６">]
promise = RegexParity::Rule.new("promise", ['\bready\s+by\s+friday\b'], ['\bif\b'])
RegexParity.evaluate(promise, "Ready by Friday if the review passes.") # => []
```

Ruby 3.1 or later, no dependencies. Offsets are character indexes. Ruby's own engine would match
`ß` against `ss`, treat `é` as a word character for `\b`, and match `^` after every newline;
regex-parity removes all three differences. See the
[main README](https://github.com/YauhenBichel/regex-parity#readme) and
[docs/SPEC.md](https://github.com/YauhenBichel/regex-parity/blob/main/docs/SPEC.md).
