package io.github.yauhenbichel.regexparity;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.github.yauhenbichel.regexparity.RegexParity.Finding;
import io.github.yauhenbichel.regexparity.RegexParity.Match;
import io.github.yauhenbichel.regexparity.RegexParity.PatternException;
import io.github.yauhenbichel.regexparity.RegexParity.Rule;
import io.github.yauhenbichel.regexparity.RegexParity.Variant;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.stream.Collectors;
import org.junit.jupiter.api.Test;

/** The Java package against its own behaviour, and against conformance/cases.tsv. */
class RegexParityTest {

  private static final Path CONFORMANCE = Path.of("..", "..", "conformance");

  private static String cp(int... codePoints) {
    StringBuilder out = new StringBuilder();
    for (int codePoint : codePoints) {
      out.appendCodePoint(codePoint);
    }
    return out.toString();
  }

  @Test
  void aLongSDoesNotGetPastARule() {
    assertTrue(RegexParity.matches("\\bharmless\\b", "That is definitely harmle" + cp(0x017F) + "s.", false));
  }

  @Test
  void findAllReportsRangesOfTheOriginalText() {
    String text = "a mela" + cp(0x200B) + "noma, order " + cp(0xFF11, 0xFF12, 0xFF13);
    assertEquals(List.of(new Match(2, 11, "mela" + cp(0x200B) + "noma")), RegexParity.findAll("\\bmelanoma\\b", text, false));
    assertEquals(cp(0xFF11, 0xFF12, 0xFF13), RegexParity.findAll("\\d{3}", text, false).get(0).text());
  }

  @Test
  void caseSensitivityIsAnOptionAndAsciiOnlyEitherWay() {
    assertTrue(RegexParity.matches("\\bTODO\\b", "todo", false));
    assertFalse(RegexParity.matches("\\bTODO\\b", "todo", true));
    assertFalse(RegexParity.matches("\\bthis\\b", "th" + cp(0x0131) + "s", false), "a dotless i is not an i");
  }

  @Test
  void anAccentedLetterIsNotAWordCharacter() {
    assertTrue(RegexParity.matches("\\bcaf\\b", "caf" + cp(0x00E9), false));
    assertFalse(RegexParity.matches("^\\w+\\s", "caf" + cp(0x00E9) + " ok", false));
  }

  @Test
  void unlessOnlyCountsInsideTheSameSentence() {
    Rule rule = new Rule("date", List.of("\\bready\\s+by\\s+friday\\b"), List.of("\\bif\\b"), false);
    assertEquals(0, RegexParity.evaluate(rule, "Ready by Friday if it passes.").size());
    assertEquals(1, RegexParity.evaluate(rule, "Ready by Friday. If you ask me, late.").size());
  }

  @Test
  void aRangeFoundByTwoPatternsCountsOnce() {
    assertEquals(1, RegexParity.evaluate(new Rule("twice", List.of("\\bharmless\\b", "harmless")), "harmless").size());
  }

  @Test
  void foldingKeepsAMapBackToTheOriginalText() {
    RegexParity.Folded folded = RegexParity.fold("it" + cp(0x2019) + "s" + cp(0x000D, 0x2028) + "ok " + cp(0x2014) + " fine");
    assertEquals("it's\n\nok - fine", folded.text());
    assertEquals(folded.text().length(), folded.starts().length);
  }

  @Test
  void theSentenceFunctionIncludesItsTerminator() {
    assertEquals(List.of(5, 14), List.of(RegexParity.sentenceRange("One. Two here! Three", 6)[0], RegexParity.sentenceRange("One. Two here! Three", 6)[1]));
    assertEquals(List.of(15, 20), List.of(RegexParity.sentenceRange("One. Two here! Three", 16)[0], RegexParity.sentenceRange("One. Two here! Three", 16)[1]));
  }

  @Test
  void patternsEnginesReadDifferentlyAreRefused() {
    String backslash = String.valueOf((char) 92);
    List<String> refused = List.of("(?=a)", "(?<!a)b", "(a)\\1", "(?<name>a)", "(?i)a", "a$", "\\p{L}", "a++", "a{,3}", "x{",
        "[[a]]", "[a&&b]", "[]a]", "\\x41", backslash + "u0041", "\\Aa", "\\v", "caf" + cp(0x00E9), "[\\b]", "a{1001}", "a{2,5000}");
    for (String source : refused) {
      assertFalse(RegexParity.checkPattern(source).isEmpty(), source);
    }
    List<String> accepted = List.of("\\bcolou?r\\b", "a{2,3}", "a{2}", "[a-z\\]]", "\\(\\?=", "(?:ab)+?", "\\d+\\.\\d*", "[^.!?]{0,30}", "\\$5", "a{1000}");
    for (String source : accepted) {
      assertEquals(List.of(), RegexParity.checkPattern(source), source);
    }
    assertThrows(PatternException.class, () -> RegexParity.compile("(?=a)", false));
    assertThrows(PatternException.class, () -> RegexParity.compile("(a", false));
  }

  @Test
  void everyVariantFoldsBackToTheOriginal() {
    String original = "It's \"fine\" - order #123456 kept";
    List<Variant> variants = RegexParity.variants(original, false);
    assertEquals(List.of("long s", "Kelvin sign", "full-width", "zero-width spaces", "no-break spaces", "en dashes", "smart quotes"),
        variants.stream().map(Variant::name).toList());
    for (Variant variant : variants) {
      // The Kelvin sign folds to a capital K, so compare without case.
      assertEquals(RegexParity.fold(original).text().toLowerCase(Locale.ROOT), RegexParity.fold(variant.text()).text().toLowerCase(Locale.ROOT), variant.name());
    }
  }

  // --- conformance: the same answers as conformance/cases.tsv, which JavaScript and Python also read ---

  private static String unescape(String text) {
    StringBuilder out = new StringBuilder();
    for (int i = 0; i < text.length(); i++) {
      char c = text.charAt(i);
      if (c == (char) 92 && i + 5 < text.length() && text.charAt(i + 1) == 'u') {
        out.append((char) Integer.parseInt(text.substring(i + 2, i + 6), 16));
        i += 5;
      } else {
        out.append(c);
      }
    }
    return out.toString();
  }

  private static List<String[]> rows(String name) throws IOException {
    return Files.readAllLines(CONFORMANCE.resolve(name), StandardCharsets.UTF_8).stream()
        .filter(line -> !line.isEmpty() && !line.startsWith("#"))
        .map(line -> line.split("\t", -1))
        .toList();
  }

  private static Map<String, Rule> rules() throws IOException {
    Map<String, List<String>> patterns = new LinkedHashMap<>();
    Map<String, List<String>> unless = new LinkedHashMap<>();
    Map<String, Boolean> sensitive = new LinkedHashMap<>();
    for (String[] row : rows("rules.tsv")) {
      patterns.computeIfAbsent(row[0], k -> new ArrayList<>());
      unless.computeIfAbsent(row[0], k -> new ArrayList<>());
      sensitive.put(row[0], row[1].equals("sensitive"));
      (row[2].equals("pattern") ? patterns : unless).get(row[0]).add(unescape(row[3]));
    }
    Map<String, Rule> out = new LinkedHashMap<>();
    for (String id : patterns.keySet()) {
      out.put(id, new Rule(id, patterns.get(id), unless.get(id), sensitive.get(id)));
    }
    return out;
  }

  @Test
  void conformanceEveryCaseGetsTheRecordedAnswerAndFindings() throws IOException {
    Map<String, Rule> rules = rules();
    List<String[]> cases = rows("cases.tsv");
    assertTrue(cases.size() > 100, "only " + cases.size() + " cases");
    for (String[] row : cases) {
      List<Finding> found = RegexParity.evaluate(rules.get(row[0]), unescape(row[3]));
      String label = row[0] + " " + row[1] + " (" + row[2] + ")";
      assertEquals(row[1].equals("match"), !found.isEmpty(), label);
      String spans = found.stream().map(f -> f.start() + ":" + f.end()).collect(Collectors.joining(","));
      assertEquals(row[4], spans.isEmpty() ? "-" : spans, label);
    }
  }

  @Test
  void conformanceVariantsAreGeneratedExactlyAsRecorded() throws IOException {
    Map<String, Rule> rules = rules();
    String[] base = null;
    List<Variant> expected = new ArrayList<>();
    for (String[] row : rows("cases.tsv")) {
      if (row[2].equals("as written")) {
        if (base != null) {
          assertEquals(expected, RegexParity.variants(unescape(base[3]), rules.get(base[0]).caseSensitive()), base[3]);
        }
        base = row;
        expected = new ArrayList<>();
      } else {
        expected.add(new Variant(row[2], unescape(row[3])));
      }
    }
    assertEquals(expected, RegexParity.variants(unescape(base[3]), rules.get(base[0]).caseSensitive()), base[3]);
  }

  @Test
  void conformanceEveryLanguageRefusesAndAcceptsTheSamePatterns() throws IOException {
    List<String[]> patterns = rows("patterns.tsv");
    assertTrue(patterns.size() > 10);
    for (String[] row : patterns) {
      String source = unescape(row[1]);
      assertEquals(row[0].equals("refused"), !RegexParity.checkPattern(source).isEmpty(), source);
    }
  }
}
