"""Python's answers for cases.tsv.

As rule engines usually compile (IGNORECASE | UNICODE), and on folded text with ASCII semantics
(IGNORECASE | ASCII). Prints: name <TAB> raw <TAB> folded.
"""

import re
import unicodedata
from pathlib import Path

INVISIBLE = re.compile("[\u00ad\u180e\u200b-\u200f\u202a-\u202e\u2060-\u2064\ufeff]")
DASH = re.compile("[\u2010-\u2015\u2212\ufe58\ufe63\uff0d]")


def fold(text: str) -> str:
    """NFKC one code point at a time, invisible characters out, dashes to "-"."""
    out = []
    for character in text:
        for piece in unicodedata.normalize("NFKC", character):
            if INVISIBLE.match(piece):
                continue
            if DASH.match(piece):
                piece = "-"
            elif piece in "\u2028\u2029":
                piece = "\n"
            elif piece == "\u1680":
                piece = " "
            out.append(piece)
    return "".join(out)


def unescape(text: str) -> str:
    return re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m.group(1), 16)), text)


def yes(value) -> str:
    return "yes" if value else "no"


for line in (Path(__file__).parent / "cases.tsv").read_text(encoding="utf-8").splitlines():
    if not line or line.startswith("#"):
        continue
    name, pattern, escaped = line.split("\t")
    text = unescape(escaped)
    raw = re.search(pattern, text, re.IGNORECASE | re.UNICODE)
    folded = re.search(pattern, fold(text), re.IGNORECASE | re.ASCII)
    print("\t".join([name, yes(raw), yes(folded)]))
