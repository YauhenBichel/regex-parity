package regexparity

import (
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"
)

func cp(codePoints ...rune) string { return string(codePoints) }

func mustMatch(t *testing.T, pattern, text string, caseSensitive bool) bool {
	t.Helper()
	ok, err := Matches(pattern, text, caseSensitive)
	if err != nil {
		t.Fatalf("%q: %v", pattern, err)
	}
	return ok
}

func TestLongSDoesNotGetPastARule(t *testing.T) {
	if !mustMatch(t, `\bharmless\b`, "That is definitely harmle"+cp(0x017F)+"s.", false) {
		t.Fatal("a long s got past the rule")
	}
}

func TestFindAllReportsRangesOfTheOriginalText(t *testing.T) {
	text := "a mela" + cp(0x200B) + "noma, order " + cp(0xFF11, 0xFF12, 0xFF13)
	found, err := FindAll(`\bmelanoma\b`, text, false)
	if err != nil || len(found) != 1 || found[0].Text != "mela"+cp(0x200B)+"noma" || text[found[0].Start:found[0].End] != found[0].Text {
		t.Fatalf("got %+v, %v", found, err)
	}
	digits, _ := FindAll(`\d{3}`, text, false)
	if len(digits) != 1 || digits[0].Text != cp(0xFF11, 0xFF12, 0xFF13) {
		t.Fatalf("got %+v", digits)
	}
}

func TestCaseSensitivityIsAnOptionAndASCIIOnly(t *testing.T) {
	if !mustMatch(t, `\bTODO\b`, "todo", false) || mustMatch(t, `\bTODO\b`, "todo", true) {
		t.Fatal("case option")
	}
	if mustMatch(t, `\bthis\b`, "th"+cp(0x0131)+"s", false) {
		t.Fatal("a dotless i is not an i")
	}
}

func TestAnAccentedLetterIsNotAWordCharacter(t *testing.T) {
	if !mustMatch(t, `\bcaf\b`, "caf"+cp(0x00E9), false) || mustMatch(t, `^\w+\s`, "caf"+cp(0x00E9)+" ok", false) {
		t.Fatal("accented letter")
	}
}

func TestUnlessOnlyCountsInsideTheSameSentence(t *testing.T) {
	rule := Rule{ID: "date", Patterns: []string{`\bready\s+by\s+friday\b`}, Unless: []string{`\bif\b`}}
	if got, _ := Evaluate(rule, "Ready by Friday if it passes."); len(got) != 0 {
		t.Fatalf("got %+v", got)
	}
	if got, _ := Evaluate(rule, "Ready by Friday. If you ask me, late."); len(got) != 1 {
		t.Fatalf("got %+v", got)
	}
}

func TestARangeFoundByTwoPatternsCountsOnce(t *testing.T) {
	if got, _ := Evaluate(Rule{ID: "twice", Patterns: []string{`\bharmless\b`, "harmless"}}, "harmless"); len(got) != 1 {
		t.Fatalf("got %+v", got)
	}
}

func TestFoldingKeepsAMapBackToTheOriginalText(t *testing.T) {
	text := "it" + cp(0x2019) + "s" + cp(0x000D, 0x2028) + "ok " + cp(0x2014) + " fine" + cp(0x000B) + "!"
	folded := Fold(text)
	if folded.Text != "it's\n\nok - fine !" {
		t.Fatalf("got %q", folded.Text)
	}
	if start, end := folded.OriginalRange(2, 3); text[start:end] != cp(0x2019) {
		t.Fatalf("the apostrophe maps to %q", text[start:end])
	}
}

func TestTheSentenceFunctionIncludesItsTerminator(t *testing.T) {
	text := "One. Two here! Three"
	if s, e := SentenceRange(text, 6); s != 5 || e != 14 {
		t.Fatalf("got %d %d", s, e)
	}
	if s, e := SentenceRange(text, 16); s != 15 || e != 20 {
		t.Fatalf("got %d %d", s, e)
	}
}

func TestPatternsEnginesReadDifferentlyAreRefused(t *testing.T) {
	backslash := string(rune(92))
	refused := []string{"(?=a)", "(?<!a)b", `(a)\1`, "(?<name>a)", "(?i)a", "a$", `\p{L}`, "a++", "a{,3}", "x{",
		"[[a]]", "[a&&b]", "[]a]", `\x41`, backslash + "u0041", `\Aa`, `\v`, "caf" + cp(0x00E9), `[\b]`, "a{1001}", "a{2,5000}"}
	for _, source := range refused {
		if len(CheckPattern(source)) == 0 {
			t.Errorf("accepted %q", source)
		}
	}
	accepted := []string{`\bcolou?r\b`, "a{2,3}", "a{2}", `[a-z\]]`, `\(\?=`, "(?:ab)+?", `\d+\.\d*`, "[^.!?]{0,30}", `\$5`, "a{1000}"}
	for _, source := range accepted {
		if problems := CheckPattern(source); len(problems) != 0 {
			t.Errorf("refused %q: %v", source, problems)
		}
	}
	if _, err := Compile("(?=a)", false); err == nil {
		t.Error("compiled a lookahead")
	}
	if _, err := Compile("(a", false); err == nil {
		t.Error("compiled an unbalanced group")
	}
}

func TestEveryVariantFoldsBackToTheOriginal(t *testing.T) {
	original := `It's "fine" - order #123456 kept`
	variants := Variants(original, false)
	var names []string
	for _, v := range variants {
		names = append(names, v.Name)
		// The Kelvin sign folds to a capital K, so compare without case.
		if strings.ToLower(Fold(v.Text).Text) != strings.ToLower(Fold(original).Text) {
			t.Errorf("%s does not fold back: %q", v.Name, Fold(v.Text).Text)
		}
	}
	want := []string{"long s", "Kelvin sign", "full-width", "zero-width spaces", "no-break spaces", "en dashes", "smart quotes"}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("got %v", names)
	}
}

// --- conformance: the same answers as conformance/*.tsv, which every other package also reads ---

func unescape(text string) string {
	var b strings.Builder
	for i := 0; i < len(text); i++ {
		if text[i] == 92 && i+5 < len(text) && text[i+1] == 'u' {
			code, err := strconv.ParseUint(text[i+2:i+6], 16, 32)
			if err == nil {
				b.WriteRune(rune(code))
				i += 5
				continue
			}
		}
		b.WriteByte(text[i])
	}
	return b.String()
}

func rows(t *testing.T, name string) [][]string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "conformance", name))
	if err != nil {
		t.Fatal(err)
	}
	var out [][]string
	for _, line := range strings.Split(string(data), "\n") {
		if line != "" && !strings.HasPrefix(line, "#") {
			out = append(out, strings.Split(line, "\t"))
		}
	}
	return out
}

func conformanceRules(t *testing.T) map[string]*Rule {
	rules := map[string]*Rule{}
	for _, row := range rows(t, "rules.tsv") {
		rule, ok := rules[row[0]]
		if !ok {
			rule = &Rule{ID: row[0], CaseSensitive: row[1] == "sensitive"}
			rules[row[0]] = rule
		}
		if row[2] == "pattern" {
			rule.Patterns = append(rule.Patterns, unescape(row[3]))
		} else {
			rule.Unless = append(rule.Unless, unescape(row[3]))
		}
	}
	return rules
}

// Conformance positions count characters; Go reports bytes.
func characters(text string, byteOffset int) int { return utf8.RuneCountInString(text[:byteOffset]) }

func TestConformanceEveryCaseGetsTheRecordedAnswerAndFindings(t *testing.T) {
	rules := conformanceRules(t)
	cases := rows(t, "cases.tsv")
	if len(cases) < 100 {
		t.Fatalf("only %d cases", len(cases))
	}
	for _, row := range cases {
		text := unescape(row[3])
		found, err := Evaluate(*rules[row[0]], text)
		if err != nil {
			t.Fatal(err)
		}
		var spans []string
		for _, f := range found {
			spans = append(spans, strconv.Itoa(characters(text, f.Start))+":"+strconv.Itoa(characters(text, f.End)))
		}
		got := strings.Join(spans, ",")
		if got == "" {
			got = "-"
		}
		label := row[0] + " " + row[1] + " (" + row[2] + ")"
		if (len(found) > 0) != (row[1] == "match") || got != row[4] {
			t.Errorf("%s: got %s, want %s", label, got, row[4])
		}
	}
}

func TestConformanceVariantsAreGeneratedExactlyAsRecorded(t *testing.T) {
	rules := conformanceRules(t)
	var base []string
	var expected []Variant
	check := func() {
		if base == nil {
			return
		}
		got := Variants(unescape(base[3]), rules[base[0]].CaseSensitive)
		if len(got) == 0 && len(expected) == 0 {
			return
		}
		if !reflect.DeepEqual(got, expected) {
			t.Errorf("%s: got %q, want %q", base[3], got, expected)
		}
	}
	for _, row := range rows(t, "cases.tsv") {
		if row[2] == "as written" {
			check()
			base, expected = row, nil
		} else {
			expected = append(expected, Variant{Name: row[2], Text: unescape(row[3])})
		}
	}
	check()
}

func TestConformancePortabilityAgrees(t *testing.T) {
	patterns := rows(t, "patterns.tsv")
	if len(patterns) < 10 {
		t.Fatalf("only %d patterns", len(patterns))
	}
	for _, row := range patterns {
		source := unescape(row[1])
		refused := len(CheckPattern(source)) > 0
		if refused != (row[0] == "refused") {
			t.Errorf("%q: refused=%v, want %s", source, refused, row[0])
		}
	}
}
