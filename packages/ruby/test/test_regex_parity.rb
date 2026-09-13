# frozen_string_literal: true

require "minitest/autorun"
require "regex_parity"

class RegexParityTest < Minitest::Test
  RP = RegexParity
  CONFORMANCE = File.expand_path("../../../conformance", __dir__)

  def cp(*code_points)
    code_points.pack("U*")
  end

  def test_a_long_s_does_not_get_past_a_rule
    assert RP.matches?('\bharmless\b', "That is definitely harmle#{cp(0x017F)}s.")
  end

  def test_find_all_reports_ranges_of_the_original_text
    text = "a mela#{cp(0x200B)}noma, order #{cp(0xFF11, 0xFF12, 0xFF13)}"
    assert_equal [RP::Match.new(2, 11, "mela#{cp(0x200B)}noma")], RP.find_all('\bmelanoma\b', text)
    assert_equal cp(0xFF11, 0xFF12, 0xFF13), RP.find_all('\d{3}', text).first.text
  end

  def test_case_sensitivity_is_an_option_and_ascii_only_either_way
    assert RP.matches?('\bTODO\b', "todo")
    refute RP.matches?('\bTODO\b', "todo", case_sensitive: true)
    refute RP.matches?('\bthis\b', "th#{cp(0x0131)}s"), "a dotless i is not an i"
  end

  def test_a_sharp_s_is_not_two_s
    refute RP.matches?('\bstrasse\b', "stra#{cp(0x00DF)}e"), "Ruby's own /i would match this"
    assert RP.matches?('[a-f]+\d', "ABC1")
  end

  def test_an_accented_letter_is_not_a_word_character
    assert RP.matches?('\bcaf\b', "caf#{cp(0x00E9)}")
    refute RP.matches?('^\w+\s', "caf#{cp(0x00E9)} ok")
    refute RP.matches?('^ok', "caf#{cp(0x00E9)}\nok"), "^ is the start of the text, not of a line"
  end

  def test_unless_only_counts_inside_the_same_sentence
    rule = RP::Rule.new("date", ['\bready\s+by\s+friday\b'], ['\bif\b'])
    assert_empty RP.evaluate(rule, "Ready by Friday if it passes.")
    assert_equal 1, RP.evaluate(rule, "Ready by Friday. If you ask me, late.").length
  end

  def test_a_range_found_by_two_patterns_counts_once
    assert_equal 1, RP.evaluate(RP::Rule.new("twice", ['\bharmless\b', "harmless"]), "harmless").length
  end

  def test_folding_keeps_a_map_back_to_the_original_text
    text = "it#{cp(0x2019)}s#{cp(0x000D, 0x2028)}ok #{cp(0x2014)} fine#{cp(0x000B)}!"
    folded = RP.fold(text)
    assert_equal "it's\n\nok - fine !", folded.text
    start, finish = folded.original_range(2, 3)
    assert_equal cp(0x2019), text[start...finish]
  end

  def test_the_sentence_function_includes_its_terminator
    assert_equal [5, 14], RP.sentence_range("One. Two here! Three", 6)
    assert_equal [15, 20], RP.sentence_range("One. Two here! Three", 16)
  end

  def test_patterns_engines_read_differently_are_refused
    backslash = 92.chr
    refused = ["(?=a)", "(?<!a)b", '(a)\1', "(?<name>a)", "(?i)a", "a$", '\p{L}', "a++", "a{,3}", "x{", "[[a]]", "[a&&b]",
               "[a--b]", "[a~~b]", "[]a]", '\x41', "#{backslash}u0041", '\Aa', '\v', "caf#{cp(0x00E9)}", '[\b]', "a{1001}", "a{2,5000}"]
    refused.each { |source| refute_empty RP.check_pattern(source), source }
    accepted = ['\bcolou?r\b', "a{2,3}", "a{2}", '[a-z\]]', '\(\?=', "(?:ab)+?", '\d+\.\d*', "[^.!?]{0,30}", '\$5', "a{1000}"]
    accepted.each do |source|
      assert_empty RP.check_pattern(source), source
      RP.compile(source)
    end
    assert_raises(RP::PatternError) { RP.compile("(?=a)") }
    assert_raises(RP::PatternError) { RP.compile("(a") }
  end

  def test_every_variant_folds_back_to_the_original
    original = %(It's "fine" - order #123456 kept)
    variants = RP.variants(original)
    assert_equal ["long s", "Kelvin sign", "full-width", "zero-width spaces", "no-break spaces", "en dashes", "smart quotes"], variants.map(&:name)
    # The Kelvin sign folds to a capital K, so compare without case.
    variants.each { |v| assert_equal RP.fold(original).text.downcase, RP.fold(v.text).text.downcase, v.name }
  end

  # --- conformance: the same answers as conformance/*.tsv, which every other package also reads ---

  def unescape(text)
    text.gsub(/#{Regexp.escape(92.chr)}u([0-9a-f]{4})/) { [Regexp.last_match(1).to_i(16)].pack("U") }
  end

  def rows(name)
    File.readlines(File.join(CONFORMANCE, name), chomp: true, encoding: "UTF-8")
        .reject { |line| line.empty? || line.start_with?("#") }
        .map { |line| line.split("\t", -1) }
  end

  def conformance_rules
    rules = {}
    rows("rules.tsv").each do |id, kase, role, pattern|
      rule = rules[id] ||= RP::Rule.new(id, [], [], kase == "sensitive")
      (role == "pattern" ? rule.patterns : rule.unless) << unescape(pattern)
    end
    rules
  end

  def test_conformance_every_case_gets_the_recorded_answer_and_findings
    rules = conformance_rules
    cases = rows("cases.tsv")
    assert_operator cases.length, :>, 100
    failures = cases.filter_map do |rule, expect, variant, text, findings|
      found = RP.evaluate(rules[rule], unescape(text))
      spans = found.empty? ? "-" : found.map { |f| "#{f.start}:#{f.end}" }.join(",")
      "#{rule} #{expect} (#{variant}): got #{spans}, want #{findings}" if (!found.empty?) != (expect == "match") || spans != findings
    end
    assert_empty failures, failures.join("\n")
  end

  def test_conformance_variants_are_generated_exactly_as_recorded
    rules = conformance_rules
    groups = []
    rows("cases.tsv").each do |rule, _expect, variant, text, _findings|
      if variant == "as written"
        groups << [rule, unescape(text), []]
      else
        groups.last[2] << [variant, unescape(text)]
      end
    end
    groups.each do |rule, base, expected|
      got = RP.variants(base, case_sensitive: rules[rule].case_sensitive).map { |v| [v.name, v.text] }
      assert_equal expected, got, base
    end
  end

  def test_conformance_every_language_refuses_and_accepts_the_same_patterns
    patterns = rows("patterns.tsv")
    assert_operator patterns.length, :>, 10
    patterns.each do |expect, source|
      assert_equal expect == "refused", !RP.check_pattern(unescape(source)).empty?, source
    end
  end
end
