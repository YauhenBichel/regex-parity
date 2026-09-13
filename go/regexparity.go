// Package regexparity gives one set of regular-expression rules the same answer in Go, JavaScript,
// Python, Java and the other regex-parity packages, even when text contains accented letters,
// look-alike characters, smart quotes or invisible characters.
//
// Plain engines disagree as soon as text is not ASCII. regex-parity folds text the same way in every
// language, runs patterns with ASCII behaviour for \b, \w, \d, \s and case, refuses patterns that
// engines read differently, and maps every match back to the original text. docs/SPEC.md in the
// repository is the algorithm; every package must reproduce conformance/cases.tsv.
//
// Offsets are byte offsets into the original string, as everywhere in Go.
//
// Characters are written here as numeric code points, so no invisible character can hide in this
// file.
package regexparity

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

func runeSet(runes ...rune) map[rune]bool {
	set := make(map[rune]bool, len(runes))
	for _, r := range runes {
		set[r] = true
	}
	return set
}

var (
	invisible = runeSet(0x00AD, 0x180E, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C,
		0x202D, 0x202E, 0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0xFEFF)
	dashes      = runeSet(0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212, 0xFE58, 0xFE63, 0xFF0D)
	apostrophes = runeSet(0x2018, 0x2019, 0x201A, 0x201B, 0x02BC, 0x2032)
	quotes      = runeSet(0x201C, 0x201D, 0x201E, 0x201F)
	// Line breaks engines disagree about for "." and \s. All of them become "\n".
	lineBreaks = runeSet(0x000D, 0x0085, 0x2028, 0x2029)
	// Spaces some engines' \s does not match: Go's \s leaves out the vertical tab.
	oddSpaces = runeSet(0x000B, 0x1680)
)

func foldRune(r rune) string {
	switch {
	case invisible[r]:
		return ""
	case dashes[r]:
		return "-"
	case apostrophes[r]:
		return "'"
	case quotes[r]:
		return "\""
	case lineBreaks[r]:
		return "\n"
	case oddSpaces[r]:
		return " "
	}
	return string(r)
}

// Folded is text as every language matches it, with the way back to the original.
type Folded struct {
	// Text is the folded text.
	Text   string
	starts []int
	ends   []int
	length int
}

// OriginalRange maps a byte range of the folded text to a byte range of the original text.
func (f Folded) OriginalRange(start, end int) (int, int) {
	from := f.length
	if start < len(f.Text) {
		from = f.starts[start]
	}
	to := from
	if end > start {
		to = f.ends[end-1]
	}
	return from, to
}

// Fold applies NFKC one code point at a time, removes invisible characters, and writes dashes,
// typographic apostrophes and quotes, odd spaces and line breaks in their ASCII forms.
func Fold(text string) Folded {
	var b strings.Builder
	starts := make([]int, 0, len(text))
	ends := make([]int, 0, len(text))
	for i := 0; i < len(text); {
		r, width := utf8.DecodeRuneInString(text[i:])
		for _, piece := range norm.NFKC.String(string(r)) {
			out := foldRune(piece)
			for k := 0; k < len(out); k++ {
				starts = append(starts, i)
				ends = append(ends, i+width)
			}
			b.WriteString(out)
		}
		i += width
	}
	return Folded{Text: b.String(), starts: starts, ends: ends, length: len(text)}
}

const letterEscapes = "bBdDsSwWtnrf"

// MaxRepeat is the largest repetition count a portable pattern may use; RE2 and Go refuse more.
const MaxRepeat = 1000

var quantifier = regexp.MustCompile(`^\{(\d+)(?:,(\d*))?\}`)

func isASCIIAlnum(c byte) bool {
	return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

func tooLarge(digits string) bool {
	if digits == "" {
		return false
	}
	n, err := strconv.Atoi(digits)
	return err != nil || n > MaxRepeat
}

// CheckPattern returns why a pattern is not portable, or nothing. The same checks run in every
// language.
func CheckPattern(source string) []string {
	var problems []string
	add := func(problem string) {
		for _, p := range problems {
			if p == problem {
				return
			}
		}
		problems = append(problems, problem)
	}
	if source == "" {
		add("the pattern is empty")
	}
	for i := 0; i < len(source); i++ {
		if source[i] > 127 {
			add("non-ASCII character: text is folded before matching, so write the ASCII form")
			break
		}
	}
	n := len(source)
	inClass := false
	for i := 0; i < n; {
		c := source[i]
		if c == '\\' {
			if i+1 >= n {
				add("trailing backslash")
				break
			}
			d := source[i+1]
			if isASCIIAlnum(d) {
				if !strings.ContainsRune(letterEscapes, rune(d)) {
					add(fmt.Sprintf("the escape \\%c is not portable", d))
				} else if inClass && (d == 'b' || d == 'B') {
					add(fmt.Sprintf("\\%c inside a character class is not portable", d))
				}
			}
			i += 2
			continue
		}
		if inClass {
			switch {
			case c == '[':
				add("'[' inside a character class is not portable: Java reads it as a nested class")
			case c == '&' && i+1 < n && source[i+1] == '&':
				add("'&&' inside a character class is not portable")
			case (c == '-' || c == '~') && i+1 < n && source[i+1] == c:
				add("'--' and '~~' inside a character class are not portable: Rust reads them as set operations")
			case c == ']':
				inClass = false
			}
			i++
			continue
		}
		switch {
		case c == '[':
			inClass = true
			j := i + 1
			if j < n && source[j] == '^' {
				j++
			}
			if j < n && source[j] == ']' {
				add("a character class that starts with ']' is not portable")
				j++
			}
			i = j
			continue
		case c == '(' && i+1 < n && source[i+1] == '?' && !(i+2 < n && source[i+2] == ':'):
			add("'(?' other than '(?:' is not portable: lookaround, named groups, inline flags and atomic groups differ between engines or are missing from RE2")
		case c == '$':
			add("'$' is not portable: Python and Java also match it before a final newline")
		case c == '{':
			m := quantifier.FindStringSubmatch(source[i:])
			if m == nil {
				add("a '{' that is not a {n}, {n,} or {n,m} quantifier is not portable; write \\{")
				break
			}
			if tooLarge(m[1]) || tooLarge(m[2]) {
				add("a repetition count above 1000 is not portable: RE2 and Go refuse it")
			}
			i += len(m[0])
			if i < n && source[i] == '+' {
				add("possessive quantifiers are not portable")
			}
			continue
		case (c == '*' || c == '+' || c == '?') && i+1 < n && source[i+1] == '+':
			add("possessive quantifiers are not portable")
		}
		i++
	}
	if inClass {
		add("unclosed character class")
	}
	return problems
}

// PatternError is a pattern that is not portable, or does not compile.
type PatternError struct {
	Pattern  string
	Problems []string
}

func (e *PatternError) Error() string {
	return fmt.Sprintf("not a portable pattern: %q: %s", e.Pattern, strings.Join(e.Problems, "; "))
}

var compiled sync.Map

// Compile compiles a portable pattern for folded text, case-insensitively unless caseSensitive.
// Go's \b, \w, \d and \s are already ASCII; after folding, its case-insensitive matching is too.
func Compile(source string, caseSensitive bool) (*regexp.Regexp, error) {
	key := "i:" + source
	if caseSensitive {
		key = "s:" + source
	}
	if re, ok := compiled.Load(key); ok {
		return re.(*regexp.Regexp), nil
	}
	if problems := CheckPattern(source); len(problems) > 0 {
		return nil, &PatternError{Pattern: source, Problems: problems}
	}
	expression := source
	if !caseSensitive {
		expression = "(?i)" + source
	}
	re, err := regexp.Compile(expression)
	if err != nil {
		return nil, &PatternError{Pattern: source, Problems: []string{err.Error()}}
	}
	compiled.Store(key, re)
	return re, nil
}

func spans(text string, re *regexp.Regexp) [][2]int {
	var out [][2]int
	for _, m := range re.FindAllStringIndex(text, -1) {
		// An empty match has no position every engine agrees on, so none of them count.
		if m[1] > m[0] {
			out = append(out, [2]int{m[0], m[1]})
		}
	}
	return out
}

// Match is a match, as a byte range of the original text.
type Match struct {
	Start int
	End   int
	Text  string
}

// FindAll returns every match of source in text, as ranges of the original text.
func FindAll(source, text string, caseSensitive bool) ([]Match, error) {
	re, err := Compile(source, caseSensitive)
	if err != nil {
		return nil, err
	}
	folded := Fold(text)
	var out []Match
	for _, span := range spans(folded.Text, re) {
		start, end := folded.OriginalRange(span[0], span[1])
		out = append(out, Match{Start: start, End: end, Text: text[start:end]})
	}
	return out, nil
}

// Matches reports whether source matches anywhere in text.
func Matches(source, text string, caseSensitive bool) (bool, error) {
	re, err := Compile(source, caseSensitive)
	if err != nil {
		return false, err
	}
	return len(spans(Fold(text).Text, re)) > 0, nil
}

// SentenceRange returns the sentence around index in text as [start, end); end includes the
// terminator.
func SentenceRange(text string, index int) (int, int) {
	start := index
	for start > 0 && !strings.ContainsRune(".!?\n", rune(text[start-1])) {
		start--
	}
	for start < len(text) && strings.ContainsRune(" \t\n\v\f\r", rune(text[start])) {
		start++
	}
	end := index
	for end < len(text) && !strings.ContainsRune(".!?\n", rune(text[end])) {
		end++
	}
	if end < len(text) {
		end++
	}
	return start, end
}

// Rule is one rule: its patterns, the unless patterns that cancel a match in the same sentence, and
// whether it is case-sensitive.
type Rule struct {
	ID            string
	Patterns      []string
	Unless        []string
	CaseSensitive bool
}

// Finding is a match of a rule, as a byte range of the original text.
type Finding struct {
	Rule  string
	Start int
	End   int
	Text  string
}

// Evaluate returns every match of any of the rule's patterns, except a match whose sentence also
// matches one of its unless patterns. A range found by two patterns counts once. Findings are
// sorted by position.
func Evaluate(rule Rule, text string) ([]Finding, error) {
	folded := Fold(text)
	seen := map[[2]int]bool{}
	var findings []Finding
	for _, source := range rule.Patterns {
		re, err := Compile(source, rule.CaseSensitive)
		if err != nil {
			return nil, err
		}
		for _, span := range spans(folded.Text, re) {
			start, end := folded.OriginalRange(span[0], span[1])
			key := [2]int{start, end}
			if seen[key] {
				continue
			}
			seen[key] = true
			if len(rule.Unless) > 0 {
				from, to := SentenceRange(folded.Text, span[0])
				sentence := folded.Text[from:to]
				suppressed := false
				for _, u := range rule.Unless {
					ure, err := Compile(u, rule.CaseSensitive)
					if err != nil {
						return nil, err
					}
					if len(spans(sentence, ure)) > 0 {
						suppressed = true
						break
					}
				}
				if suppressed {
					continue
				}
			}
			findings = append(findings, Finding{Rule: rule.ID, Start: start, End: end, Text: text[start:end]})
		}
	}
	sort.SliceStable(findings, func(i, j int) bool {
		if findings[i].Start != findings[j].Start {
			return findings[i].Start < findings[j].Start
		}
		return findings[i].End < findings[j].End
	})
	return findings, nil
}

// Variant is text rewritten one way real or evasive text writes it.
type Variant struct {
	Name string
	Text string
}

func isASCIILetter(r rune) bool {
	return (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z')
}

// Variants rewrites text the ways real and evasive text writes it. Folding turns each variant back
// into the original, so a rule must give every variant the original's answer.
func Variants(text string, caseSensitive bool) []Variant {
	var fullWidth, zeroWidth strings.Builder
	runes := []rune(text)
	for i, r := range runes {
		if r >= 0x21 && r <= 0x7E {
			fullWidth.WriteRune(r + 0xFEE0)
		} else {
			fullWidth.WriteRune(r)
		}
		zeroWidth.WriteRune(r)
		if isASCIILetter(r) && i+1 < len(runes) && isASCIILetter(runes[i+1]) {
			zeroWidth.WriteRune(0x200B)
		}
	}
	kelvin := strings.ReplaceAll(text, "K", string(rune(0x212A)))
	if !caseSensitive {
		kelvin = strings.ReplaceAll(kelvin, "k", string(rune(0x212A)))
	}
	candidates := []Variant{
		{"long s", strings.ReplaceAll(text, "s", string(rune(0x017F)))},
		{"Kelvin sign", kelvin},
		{"full-width", fullWidth.String()},
		{"zero-width spaces", zeroWidth.String()},
		{"no-break spaces", strings.ReplaceAll(text, " ", string(rune(0x00A0)))},
		{"en dashes", strings.ReplaceAll(text, "-", string(rune(0x2013)))},
		{"smart quotes", strings.ReplaceAll(strings.ReplaceAll(text, "'", string(rune(0x2019))), "\"", string(rune(0x201D)))},
	}
	seen := map[string]bool{text: true}
	var out []Variant
	for _, candidate := range candidates {
		if !seen[candidate.Text] {
			seen[candidate.Text] = true
			out = append(out, candidate)
		}
	}
	return out
}
