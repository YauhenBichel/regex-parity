"""regex-parity: one set of regular-expression rules, the same answer in Python, JavaScript and Java.

Plain engines disagree as soon as text is not ASCII: case folding, \\b, \\w, \\d, \\s and "." each
treat accented, look-alike and invisible characters differently. regex-parity folds text the same
way in every language, pins every engine to ASCII behaviour, and accepts only patterns that every
engine reads the same way. docs/SPEC.md is the algorithm; the JavaScript and Java packages implement
it too, and all three must pass conformance/cases.tsv.

    import regex_parity
    regex_parity.matches(r"\\bharmless\\b", "definitely harmle" + chr(0x17F) + "s")   # True

Offsets are str indexes (code points). For characters below U+10000 they equal the JavaScript and
Java offsets.

Characters are written here as numeric code points, so no invisible character can hide in this file.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

__version__ = "0.1.0"
__all__ = [
    "Finding",
    "Folded",
    "Match",
    "PatternError",
    "Rule",
    "Variant",
    "check_pattern",
    "compile_pattern",
    "evaluate",
    "find_all",
    "fold",
    "matches",
    "sentence_range",
    "variants",
]

_INVISIBLE = frozenset({
    0x00AD, 0x180E, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
    0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0xFEFF,
})
_DASHES = frozenset({0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212, 0xFE58, 0xFE63, 0xFF0D})
_APOSTROPHES = frozenset({0x2018, 0x2019, 0x201A, 0x201B, 0x02BC, 0x2032})
_QUOTES = frozenset({0x201C, 0x201D, 0x201E, 0x201F})
# Line breaks engines disagree about for "." and \s. All of them become "\n".
_LINE_BREAKS = frozenset({0x000D, 0x0085, 0x2028, 0x2029})
# Spaces some engines' \s does not match: Go's \s leaves out the vertical tab.
_ODD_SPACES = frozenset({0x000B, 0x1680})


def _fold_code_point(code_point: int) -> str:
    if code_point in _INVISIBLE:
        return ""
    if code_point in _DASHES:
        return "-"
    if code_point in _APOSTROPHES:
        return "'"
    if code_point in _QUOTES:
        return '"'
    if code_point in _LINE_BREAKS:
        return "\n"
    if code_point in _ODD_SPACES:
        return " "
    return chr(code_point)


@dataclass(frozen=True)
class Folded:
    """Text as every language matches it; starts[i] and ends[i] locate its i-th character in the original."""

    text: str
    starts: tuple[int, ...]
    ends: tuple[int, ...]
    length: int

    def original_range(self, start: int, end: int) -> tuple[int, int]:
        begin = self.starts[start] if start < len(self.text) else self.length
        return begin, (self.ends[end - 1] if end > start else begin)


def fold(text: str) -> Folded:
    """NFKC one code point at a time, invisible characters removed, dashes, typographic apostrophes
    and quotes to their ASCII forms, line breaks to newline."""
    out: list[str] = []
    starts: list[int] = []
    ends: list[int] = []
    for index, character in enumerate(text):
        for piece in unicodedata.normalize("NFKC", character):
            folded = _fold_code_point(ord(piece))
            for _ in folded:
                starts.append(index)
                ends.append(index + 1)
            out.append(folded)
    return Folded("".join(out), tuple(starts), tuple(ends), len(text))


_LETTER_ESCAPES = "bBdDsSwWtnrf"
_QUANTIFIER = re.compile(r"\{(\d+)(?:,(\d*))?\}")
_MAX_REPEAT = 1000  # RE2 and Go refuse more


def check_pattern(source: str) -> list[str]:
    """Why a pattern is not portable, or an empty list. The same checks run in every language."""
    problems: list[str] = []

    def add(problem: str) -> None:
        if problem not in problems:
            problems.append(problem)

    if not source:
        add("the pattern is empty")
    if any(ord(c) > 127 for c in source):
        add("non-ASCII character: text is folded before matching, so write the ASCII form")
    in_class = False
    i = 0
    n = len(source)
    while i < n:
        c = source[i]
        if c == "\\":
            if i + 1 >= n:
                add("trailing backslash")
                break
            d = source[i + 1]
            if d.isascii() and d.isalnum():
                if d not in _LETTER_ESCAPES:
                    add(f"the escape \\{d} is not portable")
                elif in_class and d in "bB":
                    add(f"\\{d} inside a character class is not portable")
            i += 2
            continue
        if in_class:
            if c == "[":
                add("'[' inside a character class is not portable: Java reads it as a nested class")
            elif c == "&" and source[i + 1 : i + 2] == "&":
                add("'&&' inside a character class is not portable")
            elif c in "-~" and source[i + 1 : i + 2] == c:
                add("'--' and '~~' inside a character class are not portable: Rust reads them as set operations")
            elif c == "]":
                in_class = False
            i += 1
            continue
        if c == "[":
            in_class = True
            j = i + 1
            if source[j : j + 1] == "^":
                j += 1
            if source[j : j + 1] == "]":
                add("a character class that starts with ']' is not portable")
                j += 1
            i = j
            continue
        if c == "(" and source[i + 1 : i + 2] == "?" and source[i + 2 : i + 3] != ":":
            add("'(?' other than '(?:' is not portable: lookaround, named groups, inline flags and "
                "atomic groups differ between engines or are missing from RE2")
        elif c == "$":
            add("'$' is not portable: Python and Java also match it before a final newline")
        elif c == "{":
            quantifier = _QUANTIFIER.match(source, i)
            if not quantifier:
                add("a '{' that is not a {n}, {n,} or {n,m} quantifier is not portable; write \\{")
            else:
                if int(quantifier.group(1)) > _MAX_REPEAT or int(quantifier.group(2) or 0) > _MAX_REPEAT:
                    add("a repetition count above 1000 is not portable: RE2 and Go refuse it")
                i = quantifier.end()
                if source[i : i + 1] == "+":
                    add("possessive quantifiers are not portable")
                continue
        elif c in "*+?" and source[i + 1 : i + 2] == "+":
            add("possessive quantifiers are not portable")
        i += 1
    if in_class:
        add("unclosed character class")
    return problems


class PatternError(ValueError):
    """A pattern that is not portable, or does not compile."""

    def __init__(self, pattern: str, problems: list[str]) -> None:
        super().__init__(f"not a portable pattern: {pattern!r}: {'; '.join(problems)}")
        self.pattern = pattern
        self.problems = problems


_compiled: dict[tuple[str, bool], re.Pattern[str]] = {}


def compile_pattern(source: str, case_sensitive: bool = False) -> re.Pattern[str]:
    """Compile a portable pattern for folded text: re.ASCII always, re.IGNORECASE unless case_sensitive."""
    key = (source, case_sensitive)
    pattern = _compiled.get(key)
    if pattern is None:
        problems = check_pattern(source)
        if problems:
            raise PatternError(source, problems)
        try:
            pattern = re.compile(source, re.ASCII if case_sensitive else re.ASCII | re.IGNORECASE)
        except re.error as error:
            raise PatternError(source, [str(error)]) from error
        _compiled[key] = pattern
    return pattern


def _spans(text: str, pattern: re.Pattern[str]):
    for match in pattern.finditer(text):
        # An empty match has no position every engine agrees on, so none of them count.
        if match.end() > match.start():
            yield match.start(), match.end()


@dataclass(frozen=True)
class Match:
    start: int
    end: int
    text: str


def find_all(source: str, text: str, case_sensitive: bool = False) -> list[Match]:
    """Every match of `source` in `text`, as ranges of the original text."""
    folded = fold(text)
    out = []
    for s, e in _spans(folded.text, compile_pattern(source, case_sensitive)):
        start, end = folded.original_range(s, e)
        out.append(Match(start, end, text[start:end]))
    return out


def matches(source: str, text: str, case_sensitive: bool = False) -> bool:
    """Whether `source` matches anywhere in `text`."""
    return next(_spans(fold(text).text, compile_pattern(source, case_sensitive)), None) is not None


_SENTENCE_END = ".!?\n"
_ASCII_SPACE = " \t\n\v\f\r"


def sentence_range(text: str, index: int) -> tuple[int, int]:
    """The sentence around `index`, as [start, end); end includes the terminator."""
    start = index
    while start > 0 and text[start - 1] not in _SENTENCE_END:
        start -= 1
    while start < len(text) and text[start] in _ASCII_SPACE:
        start += 1
    end = index
    while end < len(text) and text[end] not in _SENTENCE_END:
        end += 1
    if end < len(text):
        end += 1
    return start, end


@dataclass(frozen=True)
class Rule:
    id: str
    patterns: tuple[str, ...]
    unless: tuple[str, ...] = ()
    case_sensitive: bool = False

    @classmethod
    def from_dict(cls, data: dict) -> "Rule":
        """From the shape a rules.yaml entry has: id, patterns, unless, case."""
        return cls(data["id"], tuple(data["patterns"]), tuple(data.get("unless") or ()), data.get("case") == "sensitive")


@dataclass(frozen=True)
class Finding:
    rule: str
    start: int
    end: int
    text: str


def evaluate(rule: Rule, text: str) -> list[Finding]:
    """Every match of any of the rule's patterns, except a match whose sentence also matches one of its
    `unless` patterns. A range found by two patterns counts once. Sorted by position."""
    folded = fold(text)
    seen: set[tuple[int, int]] = set()
    findings: list[Finding] = []
    for source in rule.patterns:
        for s, e in _spans(folded.text, compile_pattern(source, rule.case_sensitive)):
            start, end = folded.original_range(s, e)
            if (start, end) in seen:
                continue
            seen.add((start, end))
            if rule.unless:
                begin, finish = sentence_range(folded.text, s)
                sentence = folded.text[begin:finish]
                if any(next(_spans(sentence, compile_pattern(u, rule.case_sensitive)), None) for u in rule.unless):
                    continue
            findings.append(Finding(rule.id, start, end, text[start:end]))
    findings.sort(key=lambda f: (f.start, f.end))
    return findings


@dataclass(frozen=True)
class Variant:
    name: str
    text: str


def _zero_width_spaces(text: str) -> str:
    out = []
    for i, c in enumerate(text):
        out.append(c)
        if c.isascii() and c.isalpha() and i + 1 < len(text) and text[i + 1].isascii() and text[i + 1].isalpha():
            out.append(chr(0x200B))
    return "".join(out)


_VARIANTS = (
    ("long s", lambda t, cs: t.replace("s", chr(0x017F))),
    ("Kelvin sign", lambda t, cs: t.replace("K", chr(0x212A)) if cs else t.replace("k", chr(0x212A)).replace("K", chr(0x212A))),
    ("full-width", lambda t, cs: "".join(chr(ord(c) + 0xFEE0) if 0x21 <= ord(c) <= 0x7E else c for c in t)),
    ("zero-width spaces", lambda t, cs: _zero_width_spaces(t)),
    ("no-break spaces", lambda t, cs: t.replace(" ", chr(0x00A0))),
    ("en dashes", lambda t, cs: t.replace("-", chr(0x2013))),
    ("smart quotes", lambda t, cs: t.replace("'", chr(0x2019)).replace('"', chr(0x201D))),
)


def variants(text: str, case_sensitive: bool = False) -> list[Variant]:
    """`text` rewritten the ways real and evasive text writes it. Folding turns each variant back into
    the original, so a rule must give every variant the original's answer."""
    seen = {text}
    out = []
    for name, rewrite in _VARIANTS:
        rewritten = rewrite(text, case_sensitive)
        if rewritten in seen:
            continue
        seen.add(rewritten)
        out.append(Variant(name, rewritten))
    return out
