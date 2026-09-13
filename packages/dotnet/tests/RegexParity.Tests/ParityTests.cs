using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using RegexParity;
using Xunit;

namespace RegexParity.Tests;

public class ParityTests
{
    private static string Cp(params int[] codePoints) => string.Concat(codePoints.Select(char.ConvertFromUtf32));

    [Fact]
    public void ALongSDoesNotGetPastARule() =>
        Assert.True(Parity.Matches(@"\bharmless\b", "That is definitely harmle" + Cp(0x017F) + "s."));

    [Fact]
    public void FindAllReportsRangesOfTheOriginalText()
    {
        var text = "a mela" + Cp(0x200B) + "noma, order " + Cp(0xFF11, 0xFF12, 0xFF13);
        Assert.Equal(new[] { new Match(2, 11, "mela" + Cp(0x200B) + "noma") }, Parity.FindAll(@"\bmelanoma\b", text));
        Assert.Equal(Cp(0xFF11, 0xFF12, 0xFF13), Parity.FindAll(@"\d{3}", text)[0].Text);
    }

    [Fact]
    public void CaseSensitivityIsAnOptionAndAsciiOnlyEitherWay()
    {
        Assert.True(Parity.Matches(@"\bTODO\b", "todo"));
        Assert.False(Parity.Matches(@"\bTODO\b", "todo", caseSensitive: true));
        Assert.False(Parity.Matches(@"\bthis\b", "th" + Cp(0x0131) + "s"));
    }

    [Fact]
    public void CaseInsensitivityDoesNotDependOnTheCurrentCulture()
    {
        var previous = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = new CultureInfo("tr-TR");
            Assert.True(Parity.Matches(@"\bINFO\b", "info (compiled under Turkish)"));
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }
    }

    [Fact]
    public void AnAccentedLetterIsNotAWordCharacter()
    {
        Assert.True(Parity.Matches(@"\bcaf\b", "caf" + Cp(0x00E9)));
        Assert.False(Parity.Matches(@"^\w+\s", "caf" + Cp(0x00E9) + " ok"));
    }

    [Fact]
    public void UnlessOnlyCountsInsideTheSameSentence()
    {
        var rule = new Rule("date", new[] { @"\bready\s+by\s+friday\b" }, new[] { @"\bif\b" });
        Assert.Empty(Parity.Evaluate(rule, "Ready by Friday if it passes."));
        Assert.Single(Parity.Evaluate(rule, "Ready by Friday. If you ask me, late."));
    }

    [Fact]
    public void ARangeFoundByTwoPatternsCountsOnce() =>
        Assert.Single(Parity.Evaluate(new Rule("twice", new[] { @"\bharmless\b", "harmless" }), "harmless"));

    [Fact]
    public void FoldingKeepsAMapBackToTheOriginalText()
    {
        var text = "it" + Cp(0x2019) + "s" + Cp(0x000D, 0x2028) + "ok " + Cp(0x2014) + " fine" + Cp(0x000B) + "!";
        var folded = Parity.Fold(text);
        Assert.Equal("it's\n\nok - fine !", folded.Text);
        var (start, end) = folded.OriginalRange(2, 3);
        Assert.Equal(Cp(0x2019), text.Substring(start, end - start));
    }

    [Fact]
    public void TheSentenceFunctionIncludesItsTerminator()
    {
        Assert.Equal((5, 14), Parity.SentenceRange("One. Two here! Three", 6));
        Assert.Equal((15, 20), Parity.SentenceRange("One. Two here! Three", 16));
    }

    [Fact]
    public void PatternsEnginesReadDifferentlyAreRefused()
    {
        var backslash = ((char)92).ToString();
        var refused = new[]
        {
            "(?=a)", "(?<!a)b", @"(a)\1", "(?<name>a)", "(?i)a", "a$", @"\p{L}", "a++", "a{,3}", "x{", "[[a]]", "[a&&b]",
            "[a--b]", "[a~~b]", "[]a]", @"\x41", backslash + "u0041", @"\Aa", @"\v", "caf" + Cp(0x00E9), @"[\b]", "a{1001}", "a{2,5000}",
        };
        foreach (var source in refused)
        {
            Assert.True(Parity.CheckPattern(source).Count > 0, source);
        }

        var accepted = new[] { @"\bcolou?r\b", "a{2,3}", "a{2}", @"[a-z\]]", @"\(\?=", "(?:ab)+?", @"\d+\.\d*", "[^.!?]{0,30}", @"\$5", "a{1000}" };
        foreach (var source in accepted)
        {
            Assert.Empty(Parity.CheckPattern(source));
            Parity.Compile(source);
        }

        Assert.Throws<PatternException>(() => Parity.Compile("(?=a)"));
        Assert.Throws<PatternException>(() => Parity.Compile("(a"));
    }

    [Fact]
    public void EveryVariantFoldsBackToTheOriginal()
    {
        const string original = "It's \"fine\" - order #123456 kept";
        var variants = Parity.Variants(original);
        Assert.Equal(new[] { "long s", "Kelvin sign", "full-width", "zero-width spaces", "no-break spaces", "en dashes", "smart quotes" }, variants.Select(v => v.Name));
        foreach (var variant in variants)
        {
            // The Kelvin sign folds to a capital K, so compare without case.
            Assert.Equal(Parity.Fold(original).Text.ToLowerInvariant(), Parity.Fold(variant.Text).Text.ToLowerInvariant());
        }
    }

    // --- conformance: the same answers as conformance/*.tsv, which every other package also reads ---

    private static string ConformanceDirectory()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory != null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, "conformance");
            if (File.Exists(Path.Combine(candidate, "cases.tsv")))
            {
                return candidate;
            }
        }

        throw new DirectoryNotFoundException("conformance/cases.tsv not found above " + AppContext.BaseDirectory);
    }

    private static string Unescape(string text)
    {
        var output = new StringBuilder(text.Length);
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] == (char)92 && i + 5 < text.Length && text[i + 1] == 'u')
            {
                output.Append((char)Convert.ToInt32(text.Substring(i + 2, 4), 16));
                i += 5;
            }
            else
            {
                output.Append(text[i]);
            }
        }

        return output.ToString();
    }

    private static List<string[]> Rows(string name) =>
        File.ReadAllLines(Path.Combine(ConformanceDirectory(), name), Encoding.UTF8)
            .Where(line => line.Length > 0 && !line.StartsWith('#'))
            .Select(line => line.Split('\t'))
            .ToList();

    private static Dictionary<string, Rule> ConformanceRules()
    {
        var rules = new Dictionary<string, Rule>();
        foreach (var row in Rows("rules.tsv"))
        {
            if (!rules.TryGetValue(row[0], out var rule))
            {
                rule = new Rule(row[0], new List<string>(), new List<string>(), row[1] == "sensitive");
                rules[row[0]] = rule;
            }

            ((List<string>)(row[2] == "pattern" ? rule.Patterns : rule.Unless!)).Add(Unescape(row[3]));
        }

        return rules;
    }

    [Fact]
    public void ConformanceEveryCaseGetsTheRecordedAnswerAndFindings()
    {
        var rules = ConformanceRules();
        var cases = Rows("cases.tsv");
        Assert.True(cases.Count > 100);
        var failures = new List<string>();
        foreach (var row in cases)
        {
            var found = Parity.Evaluate(rules[row[0]], Unescape(row[3]));
            var spans = found.Count == 0 ? "-" : string.Join(",", found.Select(f => $"{f.Start}:{f.End}"));
            if ((found.Count > 0) != (row[1] == "match") || spans != row[4])
            {
                failures.Add($"{row[0]} {row[1]} ({row[2]}): got {spans}, want {row[4]}");
            }
        }

        Assert.True(failures.Count == 0, string.Join("\n", failures));
    }

    [Fact]
    public void ConformanceVariantsAreGeneratedExactlyAsRecorded()
    {
        var rules = ConformanceRules();
        var groups = new List<(string[] Base, List<Variant> Expected)>();
        foreach (var row in Rows("cases.tsv"))
        {
            if (row[2] == "as written")
            {
                groups.Add((row, new List<Variant>()));
            }
            else
            {
                groups[^1].Expected.Add(new Variant(row[2], Unescape(row[3])));
            }
        }

        foreach (var (baseRow, expected) in groups)
        {
            Assert.Equal(expected, Parity.Variants(Unescape(baseRow[3]), rules[baseRow[0]].CaseSensitive));
        }
    }

    [Fact]
    public void ConformanceEveryLanguageRefusesAndAcceptsTheSamePatterns()
    {
        var patterns = Rows("patterns.tsv");
        Assert.True(patterns.Count > 10);
        foreach (var row in patterns)
        {
            var source = Unescape(row[1]);
            Assert.True((Parity.CheckPattern(source).Count > 0) == (row[0] == "refused"), source);
        }
    }
}
