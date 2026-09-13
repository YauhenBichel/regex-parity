//! One set of regular-expression rules, the same answer in Rust, JavaScript, Python, Java, Go and
//! the other regex-parity packages, even when text contains accented letters, look-alike
//! characters, smart quotes or invisible characters.
//!
//! Plain engines disagree as soon as text is not ASCII. regex-parity folds text the same way in
//! every language, runs patterns with ASCII behaviour for `\b`, `\w`, `\d`, `\s` and case, refuses
//! patterns that engines read differently, and maps every match back to the original text.
//! `docs/SPEC.md` in the repository is the algorithm; every package must reproduce
//! `conformance/cases.tsv`.
//!
//! Offsets are byte offsets into the original `&str`, as everywhere in Rust.
//!
//! ```
//! assert!(regex_parity::matches(r"\bharmless\b", "definitely harmle\u{17F}s", false).unwrap());
//! ```

use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::fmt;
use std::sync::{Mutex, OnceLock};
use unicode_normalization::UnicodeNormalization;

const INVISIBLE: &[u32] = &[
    0x00AD, 0x180E, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
    0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0xFEFF,
];
const DASHES: &[u32] = &[
    0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212, 0xFE58, 0xFE63, 0xFF0D,
];
const APOSTROPHES: &[u32] = &[0x2018, 0x2019, 0x201A, 0x201B, 0x02BC, 0x2032];
const QUOTES: &[u32] = &[0x201C, 0x201D, 0x201E, 0x201F];
// Line breaks engines disagree about for "." and \s. All of them become "\n".
const LINE_BREAKS: &[u32] = &[0x000D, 0x0085, 0x2028, 0x2029];
// Spaces some engines' \s does not match: Go's \s leaves out the vertical tab.
const ODD_SPACES: &[u32] = &[0x000B, 0x1680];

fn fold_char(c: char, out: &mut String) {
    let code = c as u32;
    if INVISIBLE.contains(&code) {
        // removed
    } else if DASHES.contains(&code) {
        out.push('-');
    } else if APOSTROPHES.contains(&code) {
        out.push('\'');
    } else if QUOTES.contains(&code) {
        out.push('"');
    } else if LINE_BREAKS.contains(&code) {
        out.push('\n');
    } else if ODD_SPACES.contains(&code) {
        out.push(' ');
    } else {
        out.push(c);
    }
}

/// Text as every language matches it, with the way back to the original.
#[derive(Debug, Clone)]
pub struct Folded {
    /// The folded text.
    pub text: String,
    starts: Vec<usize>,
    ends: Vec<usize>,
    length: usize,
}

impl Folded {
    /// Maps a byte range of the folded text to a byte range of the original text.
    pub fn original_range(&self, start: usize, end: usize) -> (usize, usize) {
        let from = if start < self.text.len() {
            self.starts[start]
        } else {
            self.length
        };
        let to = if end > start {
            self.ends[end - 1]
        } else {
            from
        };
        (from, to)
    }
}

/// NFKC one code point at a time, invisible characters removed, dashes, typographic apostrophes
/// and quotes, odd spaces and line breaks written in their ASCII forms.
pub fn fold(text: &str) -> Folded {
    let mut folded = String::with_capacity(text.len());
    let mut starts = Vec::with_capacity(text.len());
    let mut ends = Vec::with_capacity(text.len());
    for (index, c) in text.char_indices() {
        let end = index + c.len_utf8();
        for piece in std::iter::once(c).nfkc() {
            let before = folded.len();
            fold_char(piece, &mut folded);
            for _ in before..folded.len() {
                starts.push(index);
                ends.push(end);
            }
        }
    }
    Folded {
        text: folded,
        starts,
        ends,
        length: text.len(),
    }
}

const LETTER_ESCAPES: &[u8] = b"bBdDsSwWtnrf";

/// The largest repetition count a portable pattern may use; RE2 and Go refuse more.
pub const MAX_REPEAT: u64 = 1000;

fn add(problems: &mut Vec<String>, problem: impl Into<String>) {
    let problem = problem.into();
    if !problems.contains(&problem) {
        problems.push(problem);
    }
}

fn too_large(digits: &str) -> bool {
    !digits.is_empty()
        && (digits.len() > 4 || digits.parse::<u64>().map_or(true, |n| n > MAX_REPEAT))
}

/// `{n}`, `{n,}` or `{n,m}` at `i`: its length, and the two counts as written.
fn quantifier_at(s: &[u8], i: usize) -> Option<(usize, String, String)> {
    let mut j = i + 1;
    let low_start = j;
    while j < s.len() && s[j].is_ascii_digit() {
        j += 1;
    }
    if j == low_start {
        return None;
    }
    let low = String::from_utf8_lossy(&s[low_start..j]).into_owned();
    let mut high = String::new();
    if j < s.len() && s[j] == b',' {
        j += 1;
        let high_start = j;
        while j < s.len() && s[j].is_ascii_digit() {
            j += 1;
        }
        high = String::from_utf8_lossy(&s[high_start..j]).into_owned();
    }
    if j < s.len() && s[j] == b'}' {
        Some((j + 1 - i, low, high))
    } else {
        None
    }
}

/// Why a pattern is not portable, or an empty list. The same checks run in every language.
pub fn check_pattern(source: &str) -> Vec<String> {
    let mut problems = Vec::new();
    let s = source.as_bytes();
    let n = s.len();
    if n == 0 {
        add(&mut problems, "the pattern is empty");
    }
    if s.iter().any(|&b| b > 127) {
        add(
            &mut problems,
            "non-ASCII character: text is folded before matching, so write the ASCII form",
        );
    }
    let mut in_class = false;
    let mut i = 0;
    while i < n {
        let c = s[i];
        if c == b'\\' {
            if i + 1 >= n {
                add(&mut problems, "trailing backslash");
                break;
            }
            let d = s[i + 1];
            if d.is_ascii_alphanumeric() {
                if !LETTER_ESCAPES.contains(&d) {
                    add(
                        &mut problems,
                        format!("the escape \\{} is not portable", d as char),
                    );
                } else if in_class && (d == b'b' || d == b'B') {
                    add(
                        &mut problems,
                        format!("\\{} inside a character class is not portable", d as char),
                    );
                }
            }
            i += 2;
            continue;
        }
        if in_class {
            if c == b'[' {
                add(
                    &mut problems,
                    "'[' inside a character class is not portable: Java reads it as a nested class",
                );
            } else if c == b'&' && i + 1 < n && s[i + 1] == b'&' {
                add(
                    &mut problems,
                    "'&&' inside a character class is not portable",
                );
            } else if (c == b'-' || c == b'~') && i + 1 < n && s[i + 1] == c {
                add(&mut problems, "'--' and '~~' inside a character class are not portable: Rust reads them as set operations");
            } else if c == b']' {
                in_class = false;
            }
            i += 1;
            continue;
        }
        if c == b'[' {
            in_class = true;
            let mut j = i + 1;
            if j < n && s[j] == b'^' {
                j += 1;
            }
            if j < n && s[j] == b']' {
                add(
                    &mut problems,
                    "a character class that starts with ']' is not portable",
                );
                j += 1;
            }
            i = j;
            continue;
        }
        if c == b'(' && i + 1 < n && s[i + 1] == b'?' && !(i + 2 < n && s[i + 2] == b':') {
            add(&mut problems, "'(?' other than '(?:' is not portable: lookaround, named groups, inline flags and atomic groups differ between engines or are missing from RE2");
        } else if c == b'$' {
            add(
                &mut problems,
                "'$' is not portable: Python and Java also match it before a final newline",
            );
        } else if c == b'{' {
            match quantifier_at(s, i) {
                None => add(
                    &mut problems,
                    "a '{' that is not a {n}, {n,} or {n,m} quantifier is not portable; write \\{",
                ),
                Some((length, low, high)) => {
                    if too_large(&low) || too_large(&high) {
                        add(
                            &mut problems,
                            "a repetition count above 1000 is not portable: RE2 and Go refuse it",
                        );
                    }
                    i += length;
                    if i < n && s[i] == b'+' {
                        add(&mut problems, "possessive quantifiers are not portable");
                    }
                    continue;
                }
            }
        } else if (c == b'*' || c == b'+' || c == b'?') && i + 1 < n && s[i + 1] == b'+' {
            add(&mut problems, "possessive quantifiers are not portable");
        }
        i += 1;
    }
    if in_class {
        add(&mut problems, "unclosed character class");
    }
    problems
}

/// A pattern that is not portable, or does not compile.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PatternError {
    pub pattern: String,
    pub problems: Vec<String>,
}

impl fmt::Display for PatternError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "not a portable pattern: {:?}: {}",
            self.pattern,
            self.problems.join("; ")
        )
    }
}

impl std::error::Error for PatternError {}

/// The expression the regex crate compiles. Its `\d`, `\w` and `\s` are Unicode-aware and its `\b`
/// is too, so each is written as its ASCII form; `(?i)` then folds ASCII only, because folding has
/// already removed the Kelvin sign and the long s.
fn rust_expression(source: &str, case_sensitive: bool) -> String {
    let mut out = String::with_capacity(source.len() + 16);
    if !case_sensitive {
        out.push_str("(?i)");
    }
    let chars: Vec<char> = source.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '\\' && i + 1 < chars.len() {
            let replacement = match chars[i + 1] {
                'd' => Some("[0-9]"),
                'D' => Some("[^0-9]"),
                'w' => Some("[0-9A-Za-z_]"),
                'W' => Some("[^0-9A-Za-z_]"),
                's' => Some("[\\t\\n\\x0B\\x0C\\r ]"),
                'S' => Some("[^\\t\\n\\x0B\\x0C\\r ]"),
                'b' => Some("(?-u:\\b)"),
                'B' => Some("(?-u:\\B)"),
                _ => None,
            };
            match replacement {
                Some(ascii) => out.push_str(ascii),
                None => {
                    out.push(chars[i]);
                    out.push(chars[i + 1]);
                }
            }
            i += 2;
            continue;
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

fn cache() -> &'static Mutex<HashMap<(String, bool), Regex>> {
    static CACHE: OnceLock<Mutex<HashMap<(String, bool), Regex>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Compiles a portable pattern for folded text, case-insensitively unless `case_sensitive`.
pub fn compile(source: &str, case_sensitive: bool) -> Result<Regex, PatternError> {
    let key = (source.to_string(), case_sensitive);
    if let Some(re) = cache().lock().unwrap().get(&key) {
        return Ok(re.clone());
    }
    let problems = check_pattern(source);
    if !problems.is_empty() {
        return Err(PatternError {
            pattern: source.to_string(),
            problems,
        });
    }
    let re =
        Regex::new(&rust_expression(source, case_sensitive)).map_err(|error| PatternError {
            pattern: source.to_string(),
            problems: vec![error.to_string()],
        })?;
    cache().lock().unwrap().insert(key, re.clone());
    Ok(re)
}

fn spans(text: &str, re: &Regex) -> Vec<(usize, usize)> {
    // An empty match has no position every engine agrees on, so none of them count.
    re.find_iter(text)
        .filter(|m| m.end() > m.start())
        .map(|m| (m.start(), m.end()))
        .collect()
}

/// A match, as a byte range of the original text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Match {
    pub start: usize,
    pub end: usize,
    pub text: String,
}

/// Every match of `source` in `text`, as ranges of the original text.
pub fn find_all(
    source: &str,
    text: &str,
    case_sensitive: bool,
) -> Result<Vec<Match>, PatternError> {
    let re = compile(source, case_sensitive)?;
    let folded = fold(text);
    Ok(spans(&folded.text, &re)
        .into_iter()
        .map(|(s, e)| {
            let (start, end) = folded.original_range(s, e);
            Match {
                start,
                end,
                text: text[start..end].to_string(),
            }
        })
        .collect())
}

/// Whether `source` matches anywhere in `text`.
pub fn matches(source: &str, text: &str, case_sensitive: bool) -> Result<bool, PatternError> {
    let re = compile(source, case_sensitive)?;
    Ok(!spans(&fold(text).text, &re).is_empty())
}

/// The sentence around `index` in `text`, as `[start, end)`; `end` includes the terminator.
pub fn sentence_range(text: &str, index: usize) -> (usize, usize) {
    let s = text.as_bytes();
    let mut start = index;
    while start > 0 && !b".!?\n".contains(&s[start - 1]) {
        start -= 1;
    }
    while start < s.len() && b" \t\n\x0B\x0C\r".contains(&s[start]) {
        start += 1;
    }
    let mut end = index;
    while end < s.len() && !b".!?\n".contains(&s[end]) {
        end += 1;
    }
    if end < s.len() {
        end += 1;
    }
    (start, end)
}

/// One rule: its patterns, the `unless` patterns that cancel a match in the same sentence, and
/// whether it is case-sensitive.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Rule {
    pub id: String,
    pub patterns: Vec<String>,
    pub unless: Vec<String>,
    pub case_sensitive: bool,
}

/// A match of a rule, as a byte range of the original text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    pub rule: String,
    pub start: usize,
    pub end: usize,
    pub text: String,
}

/// Every match of any of the rule's patterns, except a match whose sentence also matches one of
/// its `unless` patterns. A range found by two patterns counts once. Sorted by position.
pub fn evaluate(rule: &Rule, text: &str) -> Result<Vec<Finding>, PatternError> {
    let folded = fold(text);
    let mut seen = HashSet::new();
    let mut findings = Vec::new();
    for source in &rule.patterns {
        let re = compile(source, rule.case_sensitive)?;
        for (s, e) in spans(&folded.text, &re) {
            let (start, end) = folded.original_range(s, e);
            if !seen.insert((start, end)) {
                continue;
            }
            if !rule.unless.is_empty() {
                let (from, to) = sentence_range(&folded.text, s);
                let sentence = &folded.text[from..to];
                let mut suppressed = false;
                for unless in &rule.unless {
                    if !spans(sentence, &compile(unless, rule.case_sensitive)?).is_empty() {
                        suppressed = true;
                        break;
                    }
                }
                if suppressed {
                    continue;
                }
            }
            findings.push(Finding {
                rule: rule.id.clone(),
                start,
                end,
                text: text[start..end].to_string(),
            });
        }
    }
    findings.sort_by_key(|f| (f.start, f.end));
    Ok(findings)
}

/// Text rewritten one way real or evasive text writes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Variant {
    pub name: String,
    pub text: String,
}

fn code_point(code: u32) -> String {
    char::from_u32(code)
        .expect("a valid code point")
        .to_string()
}

/// `text` rewritten the ways real and evasive text writes it. Folding turns each variant back into
/// the original, so a rule must give every variant the original's answer.
pub fn variants(text: &str, case_sensitive: bool) -> Vec<Variant> {
    let chars: Vec<char> = text.chars().collect();
    let mut full_width = String::with_capacity(text.len() * 3);
    let mut zero_width = String::with_capacity(text.len() * 2);
    let zero_width_space = code_point(0x200B);
    for (i, &c) in chars.iter().enumerate() {
        let code = c as u32;
        if (0x21..=0x7E).contains(&code) {
            full_width.push_str(&code_point(code + 0xFEE0));
        } else {
            full_width.push(c);
        }
        zero_width.push(c);
        if c.is_ascii_alphabetic() && i + 1 < chars.len() && chars[i + 1].is_ascii_alphabetic() {
            zero_width.push_str(&zero_width_space);
        }
    }
    let kelvin_sign = code_point(0x212A);
    let mut kelvin = text.replace('K', &kelvin_sign);
    if !case_sensitive {
        kelvin = kelvin.replace('k', &kelvin_sign);
    }
    let candidates = [
        ("long s", text.replace('s', &code_point(0x017F))),
        ("Kelvin sign", kelvin),
        ("full-width", full_width),
        ("zero-width spaces", zero_width),
        ("no-break spaces", text.replace(' ', &code_point(0x00A0))),
        ("en dashes", text.replace('-', &code_point(0x2013))),
        (
            "smart quotes",
            text.replace('\'', &code_point(0x2019))
                .replace('"', &code_point(0x201D)),
        ),
    ];
    let mut seen = HashSet::from([text.to_string()]);
    candidates
        .into_iter()
        .filter(|(_, rewritten)| seen.insert(rewritten.clone()))
        .map(|(name, rewritten)| Variant {
            name: name.to_string(),
            text: rewritten,
        })
        .collect()
}
