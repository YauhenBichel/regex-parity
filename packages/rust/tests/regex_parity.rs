use regex_parity::*;
use std::fs;

fn cp(codes: &[u32]) -> String {
    codes.iter().map(|&c| char::from_u32(c).unwrap()).collect()
}

#[test]
fn a_long_s_does_not_get_past_a_rule() {
    let text = format!("That is definitely harmle{}s.", cp(&[0x017F]));
    assert!(matches(r"\bharmless\b", &text, false).unwrap());
}

#[test]
fn find_all_reports_ranges_of_the_original_text() {
    let text = format!(
        "a mela{}noma, order {}",
        cp(&[0x200B]),
        cp(&[0xFF11, 0xFF12, 0xFF13])
    );
    let found = find_all(r"\bmelanoma\b", &text, false).unwrap();
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].text, format!("mela{}noma", cp(&[0x200B])));
    assert_eq!(&text[found[0].start..found[0].end], found[0].text);
    assert_eq!(
        find_all(r"\d{3}", &text, false).unwrap()[0].text,
        cp(&[0xFF11, 0xFF12, 0xFF13])
    );
}

#[test]
fn case_sensitivity_is_an_option_and_ascii_only_either_way() {
    assert!(matches(r"\bTODO\b", "todo", false).unwrap());
    assert!(!matches(r"\bTODO\b", "todo", true).unwrap());
    assert!(
        !matches(r"\bthis\b", &format!("th{}s", cp(&[0x0131])), false).unwrap(),
        "a dotless i is not an i"
    );
}

#[test]
fn an_accented_letter_is_not_a_word_character() {
    assert!(matches(r"\bcaf\b", &format!("caf{}", cp(&[0x00E9])), false).unwrap());
    assert!(!matches(r"^\w+\s", &format!("caf{} ok", cp(&[0x00E9])), false).unwrap());
}

#[test]
fn unless_only_counts_inside_the_same_sentence() {
    let rule = Rule {
        id: "date".into(),
        patterns: vec![r"\bready\s+by\s+friday\b".into()],
        unless: vec![r"\bif\b".into()],
        case_sensitive: false,
    };
    assert!(evaluate(&rule, "Ready by Friday if it passes.")
        .unwrap()
        .is_empty());
    assert_eq!(
        evaluate(&rule, "Ready by Friday. If you ask me, late.")
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn a_range_found_by_two_patterns_counts_once() {
    let rule = Rule {
        id: "twice".into(),
        patterns: vec![r"\bharmless\b".into(), "harmless".into()],
        ..Default::default()
    };
    assert_eq!(evaluate(&rule, "harmless").unwrap().len(), 1);
}

#[test]
fn folding_keeps_a_map_back_to_the_original_text() {
    let text = format!(
        "it{}s{}ok {} fine{}!",
        cp(&[0x2019]),
        cp(&[0x000D, 0x2028]),
        cp(&[0x2014]),
        cp(&[0x000B])
    );
    let folded = fold(&text);
    assert_eq!(folded.text, "it's\n\nok - fine !");
    let (start, end) = folded.original_range(2, 3);
    assert_eq!(&text[start..end], cp(&[0x2019]));
}

#[test]
fn the_sentence_function_includes_its_terminator() {
    assert_eq!(sentence_range("One. Two here! Three", 6), (5, 14));
    assert_eq!(sentence_range("One. Two here! Three", 16), (15, 20));
}

#[test]
fn patterns_engines_read_differently_are_refused() {
    let backslash_u = format!("{}u0041", char::from(92u8));
    let e_acute = format!("caf{}", cp(&[0x00E9]));
    let refused = [
        "(?=a)",
        "(?<!a)b",
        r"(a)\1",
        "(?<name>a)",
        "(?i)a",
        "a$",
        r"\p{L}",
        "a++",
        "a{,3}",
        "x{",
        "[[a]]",
        "[a&&b]",
        "[a--b]",
        "[a~~b]",
        "[]a]",
        r"\x41",
        &backslash_u,
        r"\Aa",
        r"\v",
        &e_acute,
        r"[\b]",
        "a{1001}",
        "a{2,5000}",
    ];
    for source in refused {
        assert!(!check_pattern(source).is_empty(), "accepted {source:?}");
    }
    let accepted = [
        r"\bcolou?r\b",
        "a{2,3}",
        "a{2}",
        r"[a-z\]]",
        r"\(\?=",
        "(?:ab)+?",
        r"\d+\.\d*",
        "[^.!?]{0,30}",
        r"\$5",
        "a{1000}",
    ];
    for source in accepted {
        assert_eq!(
            check_pattern(source),
            Vec::<String>::new(),
            "refused {source:?}"
        );
        compile(source, false).unwrap_or_else(|e| panic!("{e}"));
    }
    assert!(compile("(?=a)", false).is_err());
    assert!(compile("(a", false).is_err());
}

#[test]
fn every_variant_folds_back_to_the_original() {
    let original = r#"It's "fine" - order #123456 kept"#;
    let found = variants(original, false);
    let names: Vec<&str> = found.iter().map(|v| v.name.as_str()).collect();
    assert_eq!(
        names,
        [
            "long s",
            "Kelvin sign",
            "full-width",
            "zero-width spaces",
            "no-break spaces",
            "en dashes",
            "smart quotes"
        ]
    );
    for variant in &found {
        // The Kelvin sign folds to a capital K, so compare without case.
        assert_eq!(
            fold(&variant.text).text.to_lowercase(),
            fold(original).text.to_lowercase(),
            "{}",
            variant.name
        );
    }
}

// --- conformance: the same answers as conformance/*.tsv, which every other package also reads ---

fn unescape(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 92 && i + 5 < bytes.len() && bytes[i + 1] == b'u' {
            if let Ok(code) = u32::from_str_radix(&text[i + 2..i + 6], 16) {
                out.push(char::from_u32(code).unwrap());
                i += 6;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

fn rows(name: &str) -> Vec<Vec<String>> {
    let path = format!("{}/../../conformance/{}", env!("CARGO_MANIFEST_DIR"), name);
    fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("{path}: {e}"))
        .lines()
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|line| line.split('\t').map(String::from).collect())
        .collect()
}

fn conformance_rules() -> std::collections::HashMap<String, Rule> {
    let mut rules: std::collections::HashMap<String, Rule> = std::collections::HashMap::new();
    for row in rows("rules.tsv") {
        let rule = rules.entry(row[0].clone()).or_insert_with(|| Rule {
            id: row[0].clone(),
            case_sensitive: row[1] == "sensitive",
            ..Default::default()
        });
        if row[2] == "pattern" {
            rule.patterns.push(unescape(&row[3]));
        } else {
            rule.unless.push(unescape(&row[3]));
        }
    }
    rules
}

// Conformance positions count characters; Rust reports bytes.
fn characters(text: &str, byte_offset: usize) -> usize {
    text[..byte_offset].chars().count()
}

#[test]
fn conformance_every_case_gets_the_recorded_answer_and_findings() {
    let rules = conformance_rules();
    let cases = rows("cases.tsv");
    assert!(cases.len() > 100, "only {} cases", cases.len());
    let mut failures = Vec::new();
    for row in &cases {
        let text = unescape(&row[3]);
        let found = evaluate(&rules[&row[0]], &text).unwrap();
        let spans: Vec<String> = found
            .iter()
            .map(|f| {
                format!(
                    "{}:{}",
                    characters(&text, f.start),
                    characters(&text, f.end)
                )
            })
            .collect();
        let got = if spans.is_empty() {
            "-".to_string()
        } else {
            spans.join(",")
        };
        if (!found.is_empty()) != (row[1] == "match") || got != row[4] {
            failures.push(format!(
                "{} {} ({}): got {}, want {}",
                row[0], row[1], row[2], got, row[4]
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "{} cases disagree:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

#[test]
fn conformance_variants_are_generated_exactly_as_recorded() {
    let rules = conformance_rules();
    let mut groups: Vec<(Vec<String>, Vec<Variant>)> = Vec::new();
    for row in rows("cases.tsv") {
        if row[2] == "as written" {
            groups.push((row, Vec::new()));
        } else {
            let text = unescape(&row[3]);
            groups.last_mut().unwrap().1.push(Variant {
                name: row[2].clone(),
                text,
            });
        }
    }
    for (base, expected) in groups {
        let got = variants(&unescape(&base[3]), rules[&base[0]].case_sensitive);
        assert_eq!(got, expected, "{}", base[3]);
    }
}

#[test]
fn conformance_every_language_refuses_and_accepts_the_same_patterns() {
    let patterns = rows("patterns.tsv");
    assert!(patterns.len() > 10);
    for row in patterns {
        let source = unescape(&row[1]);
        assert_eq!(
            !check_pattern(&source).is_empty(),
            row[0] == "refused",
            "{source:?}"
        );
    }
}
