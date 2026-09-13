#!/usr/bin/env bash
# Re-measures section 2 of docs/architecture/0001-design.md: the same patterns in JavaScript,
# Python and Java, before and after folding, and the example rule compiled in real RE2.
# Exits 1 when any engine answers differently from expected.tsv, so a claim in the design cannot
# outlive the behaviour it describes.
#
#   npm ci && npm run evidence          Node 20+, Python 3.10+, Java 17+
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 "$here/no-invisible.py" "$here"

node "$here/engines.mjs" > "$tmp/js"
python3 "$here/engines.py" > "$tmp/python"
java "$here/Engines.java" "$here/cases.tsv" > "$tmp/java"

python3 - "$tmp" > "$tmp/actual.tsv" <<'PY'
import sys
tmp = sys.argv[1]
read = lambda name: [line.split("\t") for line in open(f"{tmp}/{name}", encoding="utf-8").read().splitlines()]
js, py, java = read("js"), read("python"), read("java")
print("\t".join(["case", "js_raw", "python_raw", "java_raw", "js_folded", "python_folded", "java_folded", "java_folded_ascii_b"]))
for j, p, v in zip(js, py, java, strict=True):
    assert j[0] == p[0] == v[0], (j[0], p[0], v[0])
    print("\t".join([j[0], j[1], p[1], v[1], j[2], p[2], v[2], v[3]]))
PY

if diff -u "$here/expected.tsv" "$tmp/actual.tsv"; then
  echo "evidence: every engine answers as expected.tsv records"
else
  echo "evidence: an engine answered differently from expected.tsv (diff above)" >&2
  exit 1
fi

node "$here/re2-compile.mjs" "$here/example-rules.yaml"
