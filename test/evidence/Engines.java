import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.text.Normalizer;
import java.util.regex.Pattern;

/**
 * Java's answers for cases.tsv: as rule engines usually compile (CASE_INSENSITIVE | UNICODE_CASE),
 * on folded text with CASE_INSENSITIVE alone, and the same with {@code \b} rewritten to an explicit
 * ASCII boundary, because Java's own {@code \b} counts letters such as é as word characters.
 *
 * <p>Prints: name TAB raw TAB folded TAB folded-with-ASCII-\b. Run: {@code java Engines.java}
 */
public class Engines {

  private static final String WORD = "[A-Za-z0-9_]";
  private static final String ASCII_BOUNDARY =
      "(?:(?<=" + WORD + ")(?!" + WORD + ")|(?<!" + WORD + ")(?=" + WORD + "))";

  static String fold(String text) {
    StringBuilder out = new StringBuilder();
    int i = 0;
    while (i < text.length()) {
      int next = i + Character.charCount(text.codePointAt(i));
      String normal = Normalizer.normalize(text.substring(i, next), Normalizer.Form.NFKC);
      for (int j = 0; j < normal.length(); ) {
        int c = normal.codePointAt(j);
        j += Character.charCount(c);
        boolean invisible = c == 0x00AD || c == 0x180E || (c >= 0x200B && c <= 0x200F)
            || (c >= 0x202A && c <= 0x202E) || (c >= 0x2060 && c <= 0x2064) || c == 0xFEFF;
        if (invisible) {
          continue;
        }
        boolean dash = (c >= 0x2010 && c <= 0x2015) || c == 0x2212 || c == 0xFE58 || c == 0xFE63 || c == 0xFF0D;
        out.appendCodePoint(dash ? '-' : c == 0x2028 || c == 0x2029 ? '\n' : c == 0x1680 ? ' ' : c);
      }
      i = next;
    }
    return out.toString();
  }

  static String asciiWordBoundaries(String source) {
    StringBuilder out = new StringBuilder();
    boolean inClass = false;
    for (int i = 0; i < source.length(); i++) {
      char c = source.charAt(i);
      if (c == '\\' && i + 1 < source.length()) {
        char next = source.charAt(++i);
        out.append(next == 'b' && !inClass ? ASCII_BOUNDARY : "" + c + next);
        continue;
      }
      if (c == '[') {
        inClass = true;
      } else if (c == ']') {
        inClass = false;
      }
      out.append(c);
    }
    return out.toString();
  }

  static String unescape(String text) {
    StringBuilder out = new StringBuilder();
    for (int i = 0; i < text.length(); i++) {
      if (text.startsWith("\\u", i) && i + 6 <= text.length()) {
        out.append((char) Integer.parseInt(text.substring(i + 2, i + 6), 16));
        i += 5;
      } else {
        out.append(text.charAt(i));
      }
    }
    return out.toString();
  }

  static String yes(boolean value) {
    return value ? "yes" : "no";
  }

  public static void main(String[] args) throws Exception {
    Path cases = Path.of(args.length > 0 ? args[0] : "cases.tsv");
    for (String line : Files.readAllLines(cases, StandardCharsets.UTF_8)) {
      if (line.isEmpty() || line.startsWith("#")) {
        continue;
      }
      String[] part = line.split("\t");
      String text = unescape(part[2]);
      boolean raw = Pattern.compile(part[1], Pattern.CASE_INSENSITIVE | Pattern.UNICODE_CASE).matcher(text).find();
      boolean folded = Pattern.compile(part[1], Pattern.CASE_INSENSITIVE).matcher(fold(text)).find();
      boolean ascii = Pattern.compile(asciiWordBoundaries(part[1]), Pattern.CASE_INSENSITIVE).matcher(fold(text)).find();
      System.out.println(String.join("\t", part[0], yes(raw), yes(folded), yes(ascii)));
    }
  }
}
