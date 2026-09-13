using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace RegexParity;

/// <summary>Text as every language matches it, with the way back to the original.</summary>
/// <param name="Text">The folded text.</param>
/// <param name="Starts">For each char of <paramref name="Text"/>, where its original character starts.</param>
/// <param name="Ends">For each char of <paramref name="Text"/>, where its original character ends.</param>
/// <param name="Length">Length of the original text.</param>
public sealed record Folded(string Text, int[] Starts, int[] Ends, int Length)
{
    /// <summary>Maps a range of the folded text to a range of the original text.</summary>
    public (int Start, int End) OriginalRange(int start, int end)
    {
        var from = start < Text.Length ? Starts[start] : Length;
        return (from, end > start ? Ends[end - 1] : from);
    }
}

/// <summary>A match, as a range of the original text.</summary>
public sealed record Match(int Start, int End, string Text);

/// <summary>A match of a rule, as a range of the original text.</summary>
public sealed record Finding(string Rule, int Start, int End, string Text);

/// <summary>Text rewritten one way real or evasive text writes it.</summary>
public sealed record Variant(string Name, string Text);

/// <summary>One rule: its patterns, the unless patterns that cancel a match in the same sentence, and whether it is case-sensitive.</summary>
public sealed record Rule(string Id, IReadOnlyList<string> Patterns, IReadOnlyList<string>? Unless = null, bool CaseSensitive = false);

/// <summary>A pattern that is not portable, or does not compile.</summary>
public sealed class PatternException : ArgumentException
{
    public PatternException(string pattern, IReadOnlyList<string> problems)
        : base($"not a portable pattern: \"{pattern}\": {string.Join("; ", problems)}")
    {
        Pattern = pattern;
        Problems = problems;
    }

    public string Pattern { get; }

    public IReadOnlyList<string> Problems { get; }
}

/// <summary>
/// One set of regular-expression rules, the same answer in C#, JavaScript, Python, Java, Go, Rust and
/// the other regex-parity packages, even when text contains accented letters, look-alike characters,
/// smart quotes or invisible characters. docs/SPEC.md in the repository is the algorithm; every package
/// must reproduce conformance/cases.tsv. Offsets are string indexes (UTF-16 code units), as in JavaScript.
/// </summary>
public static class Parity
{
    private static readonly HashSet<int> Invisible = new()
    {
        0x00AD, 0x180E, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0xFEFF,
    };

    private static readonly HashSet<int> Dashes = new() { 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212, 0xFE58, 0xFE63, 0xFF0D };
    private static readonly HashSet<int> Apostrophes = new() { 0x2018, 0x2019, 0x201A, 0x201B, 0x02BC, 0x2032 };
    private static readonly HashSet<int> Quotes = new() { 0x201C, 0x201D, 0x201E, 0x201F };

    // Line breaks engines disagree about for "." and \s. All of them become "\n".
    private static readonly HashSet<int> LineBreaks = new() { 0x000D, 0x0085, 0x2028, 0x2029 };

    // Spaces some engines' \s does not match: Go's \s leaves out the vertical tab.
    private static readonly HashSet<int> OddSpaces = new() { 0x000B, 0x1680 };

    private const string LetterEscapes = "bBdDsSwWtnrf";
    private const int MaxRepeat = 1000;
    private static readonly Regex Quantifier = new(@"\G\{(\d+)(?:,(\d*))?\}", RegexOptions.CultureInvariant);
    private static readonly ConcurrentDictionary<(string Source, bool CaseSensitive), Regex> Compiled = new();

    private static string? FoldCodePoint(int codePoint) =>
        Invisible.Contains(codePoint) ? string.Empty
        : Dashes.Contains(codePoint) ? "-"
        : Apostrophes.Contains(codePoint) ? "'"
        : Quotes.Contains(codePoint) ? "\""
        : LineBreaks.Contains(codePoint) ? "\n"
        : OddSpaces.Contains(codePoint) ? " "
        : null;

    /// <summary>NFKC one code point at a time, invisible characters removed, dashes, typographic apostrophes and quotes, odd spaces and line breaks written in their ASCII forms.</summary>
    public static Folded Fold(string text)
    {
        var output = new StringBuilder(text.Length);
        var starts = new List<int>(text.Length);
        var ends = new List<int>(text.Length);
        for (var index = 0; index < text.Length;)
        {
            var width = char.IsSurrogatePair(text, index) ? 2 : 1;
            var original = text.Substring(index, width);
            string normal;
            try
            {
                normal = original.Normalize(NormalizationForm.FormKC);
            }
            catch (ArgumentException)
            {
                normal = original; // a lone surrogate has no normal form
            }

            for (var j = 0; j < normal.Length;)
            {
                var pieceWidth = char.IsSurrogatePair(normal, j) ? 2 : 1;
                var codePoint = pieceWidth == 2 ? char.ConvertToUtf32(normal, j) : normal[j];
                var folded = FoldCodePoint(codePoint) ?? normal.Substring(j, pieceWidth);
                output.Append(folded);
                for (var unit = 0; unit < folded.Length; unit++)
                {
                    starts.Add(index);
                    ends.Add(index + width);
                }

                j += pieceWidth;
            }

            index += width;
        }

        return new Folded(output.ToString(), starts.ToArray(), ends.ToArray(), text.Length);
    }

    private static bool TooLarge(string digits) =>
        digits.Length > 0 && (digits.Length > 4 || int.Parse(digits, CultureInfo.InvariantCulture) > MaxRepeat);

    /// <summary>Why a pattern is not portable, or an empty list. The same checks run in every language.</summary>
    public static IReadOnlyList<string> CheckPattern(string source)
    {
        var problems = new List<string>();
        void Add(string problem)
        {
            if (!problems.Contains(problem))
            {
                problems.Add(problem);
            }
        }

        if (source.Length == 0)
        {
            Add("the pattern is empty");
        }

        if (source.Any(c => c > 127))
        {
            Add("non-ASCII character: text is folded before matching, so write the ASCII form");
        }

        var n = source.Length;
        var inClass = false;
        for (var i = 0; i < n;)
        {
            var c = source[i];
            if (c == '\\')
            {
                if (i + 1 >= n)
                {
                    Add("trailing backslash");
                    break;
                }

                var d = source[i + 1];
                if (d < 128 && char.IsLetterOrDigit(d))
                {
                    if (!LetterEscapes.Contains(d))
                    {
                        Add($"the escape \\{d} is not portable");
                    }
                    else if (inClass && (d == 'b' || d == 'B'))
                    {
                        Add($"\\{d} inside a character class is not portable");
                    }
                }

                i += 2;
                continue;
            }

            if (inClass)
            {
                if (c == '[')
                {
                    Add("'[' inside a character class is not portable: Java reads it as a nested class");
                }
                else if (c == '&' && i + 1 < n && source[i + 1] == '&')
                {
                    Add("'&&' inside a character class is not portable");
                }
                else if ((c == '-' || c == '~') && i + 1 < n && source[i + 1] == c)
                {
                    Add("'--' and '~~' inside a character class are not portable: Rust reads them as set operations");
                }
                else if (c == ']')
                {
                    inClass = false;
                }

                i++;
                continue;
            }

            if (c == '[')
            {
                inClass = true;
                var j = i + 1;
                if (j < n && source[j] == '^')
                {
                    j++;
                }

                if (j < n && source[j] == ']')
                {
                    Add("a character class that starts with ']' is not portable");
                    j++;
                }

                i = j;
                continue;
            }

            if (c == '(' && i + 1 < n && source[i + 1] == '?' && !(i + 2 < n && source[i + 2] == ':'))
            {
                Add("'(?' other than '(?:' is not portable: lookaround, named groups, inline flags and atomic groups differ between engines or are missing from RE2");
            }
            else if (c == '$')
            {
                Add("'$' is not portable: Python and Java also match it before a final newline");
            }
            else if (c == '{')
            {
                var quantifier = Quantifier.Match(source, i);
                if (!quantifier.Success)
                {
                    Add("a '{' that is not a {n}, {n,} or {n,m} quantifier is not portable; write \\{");
                }
                else
                {
                    if (TooLarge(quantifier.Groups[1].Value) || TooLarge(quantifier.Groups[2].Value))
                    {
                        Add("a repetition count above 1000 is not portable: RE2 and Go refuse it");
                    }

                    i += quantifier.Length;
                    if (i < n && source[i] == '+')
                    {
                        Add("possessive quantifiers are not portable");
                    }

                    continue;
                }
            }
            else if ((c == '*' || c == '+' || c == '?') && i + 1 < n && source[i + 1] == '+')
            {
                Add("possessive quantifiers are not portable");
            }

            i++;
        }

        if (inClass)
        {
            Add("unclosed character class");
        }

        return problems;
    }

    /// <summary>
    /// Compiles a portable pattern for folded text. ECMAScript mode makes \d, \w, \s and \b ASCII; the regex
    /// is built under the invariant culture, because case-insensitive matching uses the culture current at
    /// construction.
    /// </summary>
    public static Regex Compile(string source, bool caseSensitive = false) =>
        Compiled.GetOrAdd((source, caseSensitive), key =>
        {
            var problems = CheckPattern(key.Source);
            if (problems.Count > 0)
            {
                throw new PatternException(key.Source, problems);
            }

            var options = RegexOptions.ECMAScript | (key.CaseSensitive ? RegexOptions.None : RegexOptions.IgnoreCase);
            var previous = CultureInfo.CurrentCulture;
            try
            {
                CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
                return new Regex(key.Source, options);
            }
            catch (ArgumentException error)
            {
                throw new PatternException(key.Source, new[] { error.Message });
            }
            finally
            {
                CultureInfo.CurrentCulture = previous;
            }
        });

    private static IEnumerable<(int Start, int End)> Spans(string text, Regex regex)
    {
        for (var match = regex.Match(text); match.Success; match = match.NextMatch())
        {
            // An empty match has no position every engine agrees on, so none of them count.
            if (match.Length > 0)
            {
                yield return (match.Index, match.Index + match.Length);
            }
        }
    }

    /// <summary>Every match of <paramref name="source"/> in <paramref name="text"/>, as ranges of the original text.</summary>
    public static IReadOnlyList<Match> FindAll(string source, string text, bool caseSensitive = false)
    {
        var regex = Compile(source, caseSensitive);
        var folded = Fold(text);
        return Spans(folded.Text, regex)
            .Select(span =>
            {
                var (start, end) = folded.OriginalRange(span.Start, span.End);
                return new Match(start, end, text.Substring(start, end - start));
            })
            .ToList();
    }

    /// <summary>Whether <paramref name="source"/> matches anywhere in <paramref name="text"/>.</summary>
    public static bool Matches(string source, string text, bool caseSensitive = false) =>
        Spans(Fold(text).Text, Compile(source, caseSensitive)).Any();

    /// <summary>The sentence around <paramref name="index"/>, as [start, end); end includes the terminator.</summary>
    public static (int Start, int End) SentenceRange(string text, int index)
    {
        const string sentenceEnd = ".!?\n";
        var asciiSpace = " \t\n\f\r" + (char)11;
        var start = index;
        while (start > 0 && sentenceEnd.IndexOf(text[start - 1]) < 0)
        {
            start--;
        }

        while (start < text.Length && asciiSpace.IndexOf(text[start]) >= 0)
        {
            start++;
        }

        var end = index;
        while (end < text.Length && sentenceEnd.IndexOf(text[end]) < 0)
        {
            end++;
        }

        if (end < text.Length)
        {
            end++;
        }

        return (start, end);
    }

    /// <summary>
    /// Every match of any of the rule's patterns, except a match whose sentence also matches one of its unless
    /// patterns. A range found by two patterns counts once. Sorted by position.
    /// </summary>
    public static IReadOnlyList<Finding> Evaluate(Rule rule, string text)
    {
        var folded = Fold(text);
        var seen = new HashSet<(int, int)>();
        var findings = new List<Finding>();
        var unless = rule.Unless ?? Array.Empty<string>();
        foreach (var source in rule.Patterns)
        {
            foreach (var span in Spans(folded.Text, Compile(source, rule.CaseSensitive)))
            {
                var (start, end) = folded.OriginalRange(span.Start, span.End);
                if (!seen.Add((start, end)))
                {
                    continue;
                }

                if (unless.Count > 0)
                {
                    var (from, to) = SentenceRange(folded.Text, span.Start);
                    var sentence = folded.Text.Substring(from, to - from);
                    if (unless.Any(u => Spans(sentence, Compile(u, rule.CaseSensitive)).Any()))
                    {
                        continue;
                    }
                }

                findings.Add(new Finding(rule.Id, start, end, text.Substring(start, end - start)));
            }
        }

        return findings.OrderBy(f => f.Start).ThenBy(f => f.End).ToList();
    }

    private static string CodePoint(int codePoint) => char.ConvertFromUtf32(codePoint);

    private static bool AsciiLetter(char c) => (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');

    /// <summary>
    /// The text rewritten the ways real and evasive text writes it. Folding turns each variant back into the
    /// original, so a rule must give every variant the original's answer.
    /// </summary>
    public static IReadOnlyList<Variant> Variants(string text, bool caseSensitive = false)
    {
        var fullWidth = new StringBuilder();
        var zeroWidth = new StringBuilder();
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            fullWidth.Append(c >= 0x21 && c <= 0x7E ? (char)(c + 0xFEE0) : c);
            zeroWidth.Append(c);
            if (AsciiLetter(c) && i + 1 < text.Length && AsciiLetter(text[i + 1]))
            {
                zeroWidth.Append(CodePoint(0x200B));
            }
        }

        var kelvin = text.Replace("K", CodePoint(0x212A));
        if (!caseSensitive)
        {
            kelvin = kelvin.Replace("k", CodePoint(0x212A));
        }

        var candidates = new[]
        {
            new Variant("long s", text.Replace("s", CodePoint(0x017F))),
            new Variant("Kelvin sign", kelvin),
            new Variant("full-width", fullWidth.ToString()),
            new Variant("zero-width spaces", zeroWidth.ToString()),
            new Variant("no-break spaces", text.Replace(" ", CodePoint(0x00A0))),
            new Variant("en dashes", text.Replace("-", CodePoint(0x2013))),
            new Variant("smart quotes", text.Replace("'", CodePoint(0x2019)).Replace("\"", CodePoint(0x201D))),
        };
        var seen = new HashSet<string> { text };
        return candidates.Where(candidate => seen.Add(candidate.Text)).ToList();
    }
}
