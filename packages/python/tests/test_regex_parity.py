"""The Python package against its own behaviour, and against conformance/cases.tsv.

The conformance cases are the answers the JavaScript package gave; the Java tests read the same
file. unittest only, so the package needs nothing installed to be tested.

    python3 -m unittest discover -s tests -t .
"""

import re
import unittest
from pathlib import Path

import regex_parity as rp

CONFORMANCE = Path(__file__).resolve().parents[3] / "conformance"


def cp(*code_points: int) -> str:
    return "".join(chr(c) for c in code_points)


class Behaviour(unittest.TestCase):
    def test_a_long_s_does_not_get_past_a_rule(self):
        text = "That is definitely harmle" + cp(0x017F) + "s."
        self.assertTrue(rp.matches(r"\bharmless\b", text))

    def test_find_all_reports_ranges_of_the_original_text(self):
        text = "a mela" + cp(0x200B) + "noma, order " + cp(0xFF11, 0xFF12, 0xFF13)
        found = rp.find_all(r"\bmelanoma\b", text)
        self.assertEqual(found, [rp.Match(2, 11, "mela" + cp(0x200B) + "noma")])
        self.assertEqual(rp.find_all(r"\d{3}", text)[0].text, cp(0xFF11, 0xFF12, 0xFF13))

    def test_case_sensitivity_is_an_option_and_ascii_only_either_way(self):
        self.assertTrue(rp.matches(r"\bTODO\b", "todo"))
        self.assertFalse(rp.matches(r"\bTODO\b", "todo", case_sensitive=True))
        self.assertFalse(rp.matches(r"\bthis\b", "th" + cp(0x0131) + "s"), "a dotless i is not an i")

    def test_an_accented_letter_is_not_a_word_character(self):
        self.assertTrue(rp.matches(r"\bcaf\b", "caf" + cp(0x00E9)))
        self.assertFalse(rp.matches(r"^\w+\s", "caf" + cp(0x00E9) + " ok"))

    def test_unless_only_counts_inside_the_same_sentence(self):
        rule = rp.Rule("date", (r"\bready\s+by\s+friday\b",), (r"\bif\b",))
        self.assertEqual(rp.evaluate(rule, "Ready by Friday if it passes."), [])
        self.assertEqual(len(rp.evaluate(rule, "Ready by Friday. If you ask me, late.")), 1)

    def test_a_range_found_by_two_patterns_counts_once(self):
        rule = rp.Rule("twice", (r"\bharmless\b", "harmless"))
        self.assertEqual(len(rp.evaluate(rule, "harmless")), 1)

    def test_folding_keeps_a_map_back_to_the_original_text(self):
        folded = rp.fold("it" + cp(0x2019) + "s" + cp(0x000D, 0x2028) + "ok " + cp(0x2014) + " fine")
        self.assertEqual(folded.text, "it's\n\nok - fine")
        self.assertEqual(len(folded.starts), len(folded.text))

    def test_the_sentence_function_includes_its_terminator(self):
        text = "One. Two here! Three"
        self.assertEqual(rp.sentence_range(text, 6), (5, 14))
        self.assertEqual(rp.sentence_range(text, 16), (15, 20))

    def test_patterns_engines_read_differently_are_refused(self):
        refused = ["(?=a)", "(?<!a)b", r"(a)\1", "(?P<name>a)", "(?i)a", "a$", r"\p{L}", "a++", "a{,3}", "x{",
                   "[[a]]", "[a&&b]", "[]a]", r"\x41", chr(92) + "u0041", r"\Aa", r"\v", "caf" + cp(0x00E9), r"[\b]"]
        for source in refused:
            self.assertTrue(rp.check_pattern(source), source)
        accepted = [r"\bcolou?r\b", "a{2,3}", "a{2}", r"[a-z\]]", r"\(\?=", "(?:ab)+?", r"\d+\.\d*", "[^.!?]{0,30}", r"\$5"]
        for source in accepted:
            self.assertEqual(rp.check_pattern(source), [], source)
        with self.assertRaises(rp.PatternError):
            rp.compile_pattern("(?=a)")
        with self.assertRaises(rp.PatternError):
            rp.compile_pattern("(a")

    def test_every_variant_folds_back_to_the_original(self):
        original = "It's \"fine\" - order #123456 kept"
        found = rp.variants(original)
        self.assertEqual([v.name for v in found], ["long s", "Kelvin sign", "full-width", "zero-width spaces",
                                                    "no-break spaces", "en dashes", "smart quotes"])
        for variant in found:
            # The Kelvin sign folds to a capital K, so compare without case.
            self.assertEqual(rp.fold(variant.text).text.lower(), rp.fold(original).text.lower(), variant.name)


_ESCAPE = re.compile(re.escape(chr(92)) + "u([0-9a-f]{4})")


def _unescape(text: str) -> str:
    return _ESCAPE.sub(lambda m: chr(int(m.group(1), 16)), text)


def _rows(name: str) -> list[list[str]]:
    lines = (CONFORMANCE / name).read_text(encoding="utf-8").splitlines()
    return [line.split("\t") for line in lines if line and not line.startswith("#")]


class Conformance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        specs: dict[str, dict] = {}
        for rule_id, case, role, pattern in _rows("rules.tsv"):
            spec = specs.setdefault(rule_id, {"id": rule_id, "case": case, "patterns": [], "unless": []})
            spec["patterns" if role == "pattern" else "unless"].append(_unescape(pattern))
        cls.rules = {rule_id: rp.Rule.from_dict(spec) for rule_id, spec in specs.items()}
        cls.cases = [
            {"rule": r, "expect": e, "variant": v, "text": _unescape(t), "findings": f}
            for r, e, v, t, f in _rows("cases.tsv")
        ]

    def test_every_case_gets_the_recorded_answer_and_findings(self):
        self.assertGreater(len(self.cases), 100)
        for case in self.cases:
            found = rp.evaluate(self.rules[case["rule"]], case["text"])
            label = f"{case['rule']} {case['expect']} ({case['variant']})"
            self.assertEqual(bool(found), case["expect"] == "match", label)
            self.assertEqual(",".join(f"{f.start}:{f.end}" for f in found) or "-", case["findings"], label)

    def test_variants_are_generated_exactly_as_recorded(self):
        groups = []
        for case in self.cases:
            if case["variant"] == "as written":
                groups.append((case, []))
            else:
                groups[-1][1].append((case["variant"], case["text"]))
        for base, expected in groups:
            rule = self.rules[base["rule"]]
            got = [(v.name, v.text) for v in rp.variants(base["text"], rule.case_sensitive)]
            self.assertEqual(got, expected, base["text"])


if __name__ == "__main__":
    unittest.main()
