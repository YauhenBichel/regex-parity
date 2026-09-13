package io.github.yauhenbichel.regexparity;

import java.text.Normalizer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.regex.PatternSyntaxException;

/**
 * One set of regular-expression rules, the same answer in Java, JavaScript and Python.
 *
 * <p>Plain engines disagree as soon as text is not ASCII: case folding, {@code \b}, {@code \w},
 * {@code \d}, {@code \s} and {@code .} each treat accented, look-alike and invisible characters
 * differently. This class folds text exactly as the JavaScript and Python packages do, pins
 * {@code java.util.regex} to ASCII behaviour, and accepts only patterns every engine reads the same
 * way. docs/SPEC.md is the algorithm; all three packages must pass conformance/cases.tsv.
 *
 * <p>Offsets are {@code String} indexes (UTF-16 code units), the same as JavaScript's.
 */
public final class RegexParity {

  private static final Set<Integer> INVISIBLE =
      Set.of(0x00AD, 0x180E, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D,
          0x202E, 0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0xFEFF);
  private static final Set<Integer> DASHES =
      Set.of(0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212, 0xFE58, 0xFE63, 0xFF0D);
  private static final Set<Integer> APOSTROPHES = Set.of(0x2018, 0x2019, 0x201A, 0x201B, 0x02BC, 0x2032);
  private static final Set<Integer> QUOTES = Set.of(0x201C, 0x201D, 0x201E, 0x201F);
  // Line breaks engines disagree about for "." and \s. All of them become "\n".
  private static final Set<Integer> LINE_BREAKS = Set.of(0x000D, 0x0085, 0x2028, 0x2029);
  private static final int OGHAM_SPACE_MARK = 0x1680;

  private static final String LETTER_ESCAPES = "bBdDsSwWtnrf";
  private static final Pattern QUANTIFIER = Pattern.compile("\\{\\d+(?:,\\d*)?\\}");
  private static final String WORD = "[A-Za-z0-9_]";
  // Java's own \b counts letters such as é as word characters; every other port does not.
  private static final String BOUNDARY =
      "(?:(?<=" + WORD + ")(?!" + WORD + ")|(?<!" + WORD + ")(?=" + WORD + "))";
  private static final String NOT_BOUNDARY =
      "(?:(?<=" + WORD + ")(?=" + WORD + ")|(?<!" + WORD + ")(?!" + WORD + "))";
  private static final Map<String, Pattern> COMPILED = new ConcurrentHashMap<>();

  private RegexParity() {}

  /** Text as every language matches it; {@code starts[i]} and {@code ends[i]} locate char i in the original. */
  public record Folded(String text, int[] starts, int[] ends, int length) {
    public int[] originalRange(int start, int end) {
      int from = start < text.length() ? starts[start] : length;
      return new int[] {from, end > start ? ends[end - 1] : from};
    }
  }

  /** A match, as a range of the original text. */
  public record Match(int start, int end, String text) {}

  public record Finding(String rule, int start, int end, String text) {}

  public record Variant(String name, String text) {}

  public record Rule(String id, List<String> patterns, List<String> unless, boolean caseSensitive) {
    public Rule {
      patterns = List.copyOf(patterns);
      unless = unless == null ? List.of() : List.copyOf(unless);
    }

    public Rule(String id, List<String> patterns) {
      this(id, patterns, List.of(), false);
    }
  }

  /** A pattern that is not portable, or does not compile. */
  public static final class PatternException extends IllegalArgumentException {
    private final String pattern;
    private final List<String> problems;

    PatternException(String pattern, List<String> problems) {
      super("not a portable pattern: \"" + pattern + "\": " + String.join("; ", problems));
      this.pattern = pattern;
      this.problems = List.copyOf(problems);
    }

    public String pattern() {
      return pattern;
    }

    public List<String> problems() {
      return problems;
    }
  }

  // ------------------------------------------------------------------------------------ folding --

  private static String foldCodePoint(int codePoint) {
    if (INVISIBLE.contains(codePoint)) {
      return "";
    }
    if (DASHES.contains(codePoint)) {
      return "-";
    }
    if (APOSTROPHES.contains(codePoint)) {
      return "'";
    }
    if (QUOTES.contains(codePoint)) {
      return "\"";
    }
    if (LINE_BREAKS.contains(codePoint)) {
      return "\n";
    }
    if (codePoint == OGHAM_SPACE_MARK) {
      return " ";
    }
    return new String(Character.toChars(codePoint));
  }

  /**
   * NFKC one code point at a time, invisible characters removed, dashes, typographic apostrophes and
   * quotes to their ASCII forms, line breaks to newline.
   */
  public static Folded fold(String text) {
    StringBuilder out = new StringBuilder(text.length());
    int[] starts = new int[text.length() + 16];
    int[] ends = new int[text.length() + 16];
    int index = 0;
    while (index < text.length()) {
      int next = index + Character.charCount(text.codePointAt(index));
      String normal = Normalizer.normalize(text.substring(index, next), Normalizer.Form.NFKC);
      for (int j = 0; j < normal.length(); ) {
        int piece = normal.codePointAt(j);
        j += Character.charCount(piece);
        int before = out.length();
        out.append(foldCodePoint(piece));
        if (out.length() > starts.length) {
          starts = Arrays.copyOf(starts, out.length() * 2);
          ends = Arrays.copyOf(ends, out.length() * 2);
        }
        for (int unit = before; unit < out.length(); unit++) {
          starts[unit] = index;
          ends[unit] = next;
        }
      }
      index = next;
    }
    return new Folded(out.toString(), Arrays.copyOf(starts, out.length()), Arrays.copyOf(ends, out.length()), text.length());
  }

  // ----------------------------------------------------------------------------------- patterns --

  /** Why a pattern is not portable, or an empty list. The same checks run in every language. */
  public static List<String> checkPattern(String source) {
    Set<String> problems = new LinkedHashSet<>();
    if (source.isEmpty()) {
      problems.add("the pattern is empty");
    }
    if (source.chars().anyMatch(c -> c > 127)) {
      problems.add("non-ASCII character: text is folded before matching, so write the ASCII form");
    }
    boolean inClass = false;
    int n = source.length();
    int i = 0;
    while (i < n) {
      char c = source.charAt(i);
      if (c == '\\') {
        if (i + 1 >= n) {
          problems.add("trailing backslash");
          break;
        }
        char d = source.charAt(i + 1);
        if (d < 128 && Character.isLetterOrDigit(d)) {
          if (LETTER_ESCAPES.indexOf(d) < 0) {
            problems.add("the escape \\" + d + " is not portable");
          } else if (inClass && (d == 'b' || d == 'B')) {
            problems.add("\\" + d + " inside a character class is not portable");
          }
        }
        i += 2;
        continue;
      }
      if (inClass) {
        if (c == '[') {
          problems.add("'[' inside a character class is not portable: Java reads it as a nested class");
        } else if (c == '&' && i + 1 < n && source.charAt(i + 1) == '&') {
          problems.add("'&&' inside a character class is not portable");
        } else if (c == ']') {
          inClass = false;
        }
        i += 1;
        continue;
      }
      if (c == '[') {
        inClass = true;
        int j = i + 1;
        if (j < n && source.charAt(j) == '^') {
          j += 1;
        }
        if (j < n && source.charAt(j) == ']') {
          problems.add("a character class that starts with ']' is not portable");
          j += 1;
        }
        i = j;
        continue;
      }
      if (c == '(' && i + 1 < n && source.charAt(i + 1) == '?' && !(i + 2 < n && source.charAt(i + 2) == ':')) {
        problems.add("'(?' other than '(?:' is not portable: lookaround, named groups, inline flags and "
            + "atomic groups differ between engines or are missing from RE2");
      } else if (c == '$') {
        problems.add("'$' is not portable: Python and Java also match it before a final newline");
      } else if (c == '{') {
        Matcher quantifier = QUANTIFIER.matcher(source).region(i, n);
        if (!quantifier.lookingAt()) {
          problems.add("a '{' that is not a {n}, {n,} or {n,m} quantifier is not portable; write \\{");
        } else {
          i = quantifier.end();
          if (i < n && source.charAt(i) == '+') {
            problems.add("possessive quantifiers are not portable");
          }
          continue;
        }
      } else if ((c == '*' || c == '+' || c == '?') && i + 1 < n && source.charAt(i + 1) == '+') {
        problems.add("possessive quantifiers are not portable");
      }
      i += 1;
    }
    if (inClass) {
      problems.add("unclosed character class");
    }
    return List.copyOf(problems);
  }

  /** Compiles a portable pattern for folded text: CASE_INSENSITIVE (ASCII only) unless caseSensitive. */
  public static Pattern compile(String source, boolean caseSensitive) {
    return COMPILED.computeIfAbsent((caseSensitive ? "s:" : "i:") + source, key -> {
      List<String> problems = checkPattern(source);
      if (!problems.isEmpty()) {
        throw new PatternException(source, problems);
      }
      try {
        return Pattern.compile(asciiBoundaries(source), caseSensitive ? 0 : Pattern.CASE_INSENSITIVE);
      } catch (PatternSyntaxException error) {
        throw new PatternException(source, List.of(error.getDescription()));
      }
    });
  }

  /** Rewrites \b and \B to explicit ASCII boundaries. checkPattern has already refused them inside classes. */
  static String asciiBoundaries(String source) {
    StringBuilder out = new StringBuilder();
    for (int i = 0; i < source.length(); i++) {
      char c = source.charAt(i);
      if (c == '\\' && i + 1 < source.length()) {
        char next = source.charAt(++i);
        if (next == 'b') {
          out.append(BOUNDARY);
        } else if (next == 'B') {
          out.append(NOT_BOUNDARY);
        } else {
          out.append(c).append(next);
        }
        continue;
      }
      out.append(c);
    }
    return out.toString();
  }

  private static List<int[]> spans(String text, Pattern pattern) {
    List<int[]> out = new ArrayList<>();
    Matcher matcher = pattern.matcher(text);
    while (matcher.find()) {
      // An empty match has no position every engine agrees on, so none of them count.
      if (matcher.end() > matcher.start()) {
        out.add(new int[] {matcher.start(), matcher.end()});
      }
    }
    return out;
  }

  private static boolean anySpan(String text, Pattern pattern) {
    Matcher matcher = pattern.matcher(text);
    while (matcher.find()) {
      if (matcher.end() > matcher.start()) {
        return true;
      }
    }
    return false;
  }

  /** Every match of {@code source} in {@code text}, as ranges of the original text. */
  public static List<Match> findAll(String source, String text, boolean caseSensitive) {
    Folded folded = fold(text);
    List<Match> out = new ArrayList<>();
    for (int[] span : spans(folded.text(), compile(source, caseSensitive))) {
      int[] range = folded.originalRange(span[0], span[1]);
      out.add(new Match(range[0], range[1], text.substring(range[0], range[1])));
    }
    return out;
  }

  /** Whether {@code source} matches anywhere in {@code text}. */
  public static boolean matches(String source, String text, boolean caseSensitive) {
    return anySpan(fold(text).text(), compile(source, caseSensitive));
  }

  // -------------------------------------------------------------------------------------- rules --

  /** The sentence around {@code index}, as [start, end); end includes the terminator. */
  public static int[] sentenceRange(String text, int index) {
    int start = index;
    while (start > 0 && ".!?\n".indexOf(text.charAt(start - 1)) < 0) {
      start--;
    }
    while (start < text.length() && (" \t\n" + (char) 11 + "\f\r").indexOf(text.charAt(start)) >= 0) {
      start++;
    }
    int end = index;
    while (end < text.length() && ".!?\n".indexOf(text.charAt(end)) < 0) {
      end++;
    }
    if (end < text.length()) {
      end++;
    }
    return new int[] {start, end};
  }

  /**
   * Every match of any of the rule's patterns, except a match whose sentence also matches one of its
   * {@code unless} patterns. A range found by two patterns counts once. Sorted by position.
   */
  public static List<Finding> evaluate(Rule rule, String text) {
    Folded folded = fold(text);
    Set<String> seen = new HashSet<>();
    List<Finding> findings = new ArrayList<>();
    for (String source : rule.patterns()) {
      for (int[] span : spans(folded.text(), compile(source, rule.caseSensitive()))) {
        int[] range = folded.originalRange(span[0], span[1]);
        if (!seen.add(range[0] + ":" + range[1])) {
          continue;
        }
        if (!rule.unless().isEmpty()) {
          int[] sentence = sentenceRange(folded.text(), span[0]);
          String words = folded.text().substring(sentence[0], sentence[1]);
          if (rule.unless().stream().anyMatch(u -> anySpan(words, compile(u, rule.caseSensitive())))) {
            continue;
          }
        }
        findings.add(new Finding(rule.id(), range[0], range[1], text.substring(range[0], range[1])));
      }
    }
    findings.sort(Comparator.comparingInt(Finding::start).thenComparingInt(Finding::end));
    return findings;
  }

  // ----------------------------------------------------------------------------------- variants --

  private static String chars(int codePoint) {
    return new String(Character.toChars(codePoint));
  }

  private static boolean asciiLetter(char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
  }

  /**
   * {@code text} rewritten the ways real and evasive text writes it. Folding turns each variant back
   * into the original, so a rule must give every variant the original's answer.
   */
  public static List<Variant> variants(String text, boolean caseSensitive) {
    StringBuilder fullWidth = new StringBuilder();
    StringBuilder zeroWidth = new StringBuilder();
    for (int i = 0; i < text.length(); i++) {
      char c = text.charAt(i);
      fullWidth.append(c >= 0x21 && c <= 0x7E ? (char) (c + 0xFEE0) : c);
      zeroWidth.append(c);
      if (asciiLetter(c) && i + 1 < text.length() && asciiLetter(text.charAt(i + 1))) {
        zeroWidth.append(chars(0x200B));
      }
    }
    String kelvin = caseSensitive
        ? text.replace("K", chars(0x212A))
        : text.replace("k", chars(0x212A)).replace("K", chars(0x212A));
    List<Variant> candidates = List.of(
        new Variant("long s", text.replace("s", chars(0x017F))),
        new Variant("Kelvin sign", kelvin),
        new Variant("full-width", fullWidth.toString()),
        new Variant("zero-width spaces", zeroWidth.toString()),
        new Variant("no-break spaces", text.replace(" ", chars(0x00A0))),
        new Variant("en dashes", text.replace("-", chars(0x2013))),
        new Variant("smart quotes", text.replace("'", chars(0x2019)).replace("\"", chars(0x201D))));
    Set<String> seen = new HashSet<>(Set.of(text));
    List<Variant> out = new ArrayList<>();
    for (Variant candidate : candidates) {
      if (seen.add(candidate.text())) {
        out.add(candidate);
      }
    }
    return out;
  }
}
