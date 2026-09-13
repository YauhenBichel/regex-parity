# frozen_string_literal: true

# One set of regular-expression rules, the same answer in Ruby, JavaScript, Python, Java, Go, Rust, C#
# and the other regex-parity packages, even when text contains accented letters, look-alike
# characters, smart quotes or invisible characters.
#
# docs/SPEC.md in the repository is the algorithm; every package must reproduce
# conformance/cases.tsv. Offsets are character indexes, as String#[] uses.
#
# Ruby's engine differs from the others in three ways this module removes: its case-insensitive
# mode folds some letters to two (the sharp s matches "ss"), its \b counts letters such as e-acute
# as word characters, and its ^ matches after every newline. So case-insensitivity is written into
# the pattern as ASCII letter pairs, \b and \B become explicit ASCII boundaries, and ^ becomes \A.
#
# Characters are written here as numeric code points, so no invisible character can hide in this file.
module RegexParity
  VERSION = "0.2.0"

  Folded = Struct.new(:text, :starts, :ends, :length) do
    # Maps a range of the folded text to a range of the original text.
    def original_range(start, finish)
      from = start < text.length ? starts[start] : length
      [from, finish > start ? ends[finish - 1] : from]
    end
  end

  Match = Struct.new(:start, :end, :text)
  Finding = Struct.new(:rule, :start, :end, :text)
  Variant = Struct.new(:name, :text)
  Rule = Struct.new(:id, :patterns, :unless, :case_sensitive) do
    def initialize(id, patterns, unless_patterns = [], case_sensitive = false)
      super(id, patterns, unless_patterns || [], case_sensitive)
    end
  end

  # A pattern that is not portable, or does not compile.
  class PatternError < ArgumentError
    attr_reader :pattern, :problems

    def initialize(pattern, problems)
      @pattern = pattern
      @problems = problems
      super("not a portable pattern: #{pattern.inspect}: #{problems.join('; ')}")
    end
  end

  INVISIBLE = [0x00AD, 0x180E, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
               0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0xFEFF].freeze
  DASHES = [0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212, 0xFE58, 0xFE63, 0xFF0D].freeze
  APOSTROPHES = [0x2018, 0x2019, 0x201A, 0x201B, 0x02BC, 0x2032].freeze
  QUOTES = [0x201C, 0x201D, 0x201E, 0x201F].freeze
  # Line breaks engines disagree about for "." and \s. All of them become "\n".
  LINE_BREAKS = [0x000D, 0x0085, 0x2028, 0x2029].freeze
  # Spaces some engines' \s does not match: Go's \s leaves out the vertical tab.
  ODD_SPACES = [0x000B, 0x1680].freeze
  LETTER_ESCAPES = "bBdDsSwWtnrf"
  MAX_REPEAT = 1000
  WORD = "[A-Za-z0-9_]"
  BOUNDARY = "(?:(?<=#{WORD})(?!#{WORD})|(?<!#{WORD})(?=#{WORD}))".freeze
  NOT_BOUNDARY = "(?:(?<=#{WORD})(?=#{WORD})|(?<!#{WORD})(?!#{WORD}))".freeze
  BACKSLASH = 92.chr

  module_function

  def chr(code_point)
    [code_point].pack("U")
  end

  def fold_code_point(code_point)
    return "" if INVISIBLE.include?(code_point)
    return "-" if DASHES.include?(code_point)
    return "'" if APOSTROPHES.include?(code_point)
    return '"' if QUOTES.include?(code_point)
    return "\n" if LINE_BREAKS.include?(code_point)
    return " " if ODD_SPACES.include?(code_point)

    nil
  end

  # NFKC one code point at a time, invisible characters removed, dashes, typographic apostrophes and
  # quotes, odd spaces and line breaks written in their ASCII forms.
  def fold(text)
    out = +""
    starts = []
    ends = []
    text.each_char.with_index do |character, index|
      normal = begin
        character.unicode_normalize(:nfkc)
      rescue ArgumentError, Encoding::CompatibilityError
        character
      end
      normal.each_char do |piece|
        folded = fold_code_point(piece.ord) || piece
        folded.each_char do
          starts << index
          ends << index + 1
        end
        out << folded
      end
    end
    Folded.new(out, starts, ends, text.length)
  end

  def too_large?(digits)
    !digits.nil? && !digits.empty? && (digits.length > 4 || digits.to_i > MAX_REPEAT)
  end

  # Why a pattern is not portable, or an empty list. The same checks run in every language.
  def check_pattern(source)
    problems = []
    add = ->(problem) { problems << problem unless problems.include?(problem) }
    add.call("the pattern is empty") if source.empty?
    add.call("non-ASCII character: text is folded before matching, so write the ASCII form") unless source.ascii_only?
    in_class = false
    n = source.length
    i = 0
    while i < n
      c = source[i]
      if c == BACKSLASH
        if i + 1 >= n
          add.call("trailing backslash")
          break
        end
        d = source[i + 1]
        if d.match?(/\A[A-Za-z0-9]\z/)
          if !LETTER_ESCAPES.include?(d)
            add.call("the escape #{BACKSLASH}#{d} is not portable")
          elsif in_class && %w[b B].include?(d)
            add.call("#{BACKSLASH}#{d} inside a character class is not portable")
          end
        end
        i += 2
        next
      end
      if in_class
        if c == "["
          add.call("'[' inside a character class is not portable: Java reads it as a nested class")
        elsif c == "&" && source[i + 1] == "&"
          add.call("'&&' inside a character class is not portable")
        elsif %w[- ~].include?(c) && source[i + 1] == c
          add.call("'--' and '~~' inside a character class are not portable: Rust reads them as set operations")
        elsif c == "]"
          in_class = false
        end
        i += 1
        next
      end
      if c == "["
        in_class = true
        j = i + 1
        j += 1 if source[j] == "^"
        if source[j] == "]"
          add.call("a character class that starts with ']' is not portable")
          j += 1
        end
        i = j
        next
      end
      if c == "(" && source[i + 1] == "?" && source[i + 2] != ":"
        add.call("'(?' other than '(?:' is not portable: lookaround, named groups, inline flags and atomic groups differ between engines or are missing from RE2")
      elsif c == "$"
        add.call("'$' is not portable: Python and Java also match it before a final newline")
      elsif c == "{"
        quantifier = /\A\{(\d+)(?:,(\d*))?\}/.match(source[i..])
        if quantifier.nil?
          add.call("a '{' that is not a {n}, {n,} or {n,m} quantifier is not portable; write #{BACKSLASH}{")
        else
          add.call("a repetition count above 1000 is not portable: RE2 and Go refuse it") if too_large?(quantifier[1]) || too_large?(quantifier[2])
          i += quantifier[0].length
          add.call("possessive quantifiers are not portable") if source[i] == "+"
          next
        end
      elsif %w[* + ?].include?(c) && source[i + 1] == "+"
        add.call("possessive quantifiers are not portable")
      end
      i += 1
    end
    add.call("unclosed character class") if in_class
    problems
  end

  def letter_pair(c)
    c.match?(/\A[A-Za-z]\z/) ? "#{c.downcase}#{c.upcase}" : nil
  end

  # The other-case counterpart of the letters inside an ASCII range, as extra class items.
  def other_case_ranges(low, high)
    extra = +""
    [["a", "z"], ["A", "Z"]].each do |from, to|
      lo = [low, from.ord].max
      hi = [high, to.ord].min
      next if lo > hi

      extra << "#{lo.chr.swapcase}-#{hi.chr.swapcase}"
    end
    extra
  end

  # The pattern Ruby's engine compiles: ^ as \A, \b and \B as ASCII boundaries, and, unless
  # case-sensitive, every ASCII letter written with its other case, so no Unicode case folding applies.
  def ruby_expression(source, case_sensitive)
    out = +""
    in_class = false
    class_start = false
    i = 0
    n = source.length
    while i < n
      c = source[i]
      if c == BACKSLASH && i + 1 < n
        d = source[i + 1]
        if !in_class && d == "b"
          out << BOUNDARY
        elsif !in_class && d == "B"
          out << NOT_BOUNDARY
        else
          out << c << d
        end
        i += 2
        class_start = false
        next
      end
      if in_class
        if c == "]" && !class_start
          in_class = false
          out << c
        elsif !case_sensitive && source[i + 1] == "-" && source[i + 2] && source[i + 2] != "]" && source[i + 2] != BACKSLASH
          out << c << "-" << source[i + 2] << other_case_ranges(c.ord, source[i + 2].ord)
          i += 2
        elsif !case_sensitive && (pair = letter_pair(c))
          out << pair
        else
          out << c
        end
        class_start = false
        i += 1
        next
      end
      if c == "["
        in_class = true
        class_start = true
        out << c
        if source[i + 1] == "^"
          out << "^"
          i += 1
        end
      elsif c == "^"
        out << BACKSLASH << "A"
      elsif !case_sensitive && (pair = letter_pair(c))
        out << "[" << pair << "]"
      else
        out << c
      end
      i += 1
    end
    out
  end

  @compiled = {}
  @lock = Mutex.new

  # Compiles a portable pattern for folded text, case-insensitively unless case_sensitive.
  def compile(source, case_sensitive: false)
    key = [source, case_sensitive]
    @lock.synchronize do
      return @compiled[key] if @compiled.key?(key)

      problems = check_pattern(source)
      raise PatternError.new(source, problems) unless problems.empty?

      begin
        @compiled[key] = Regexp.new(ruby_expression(source, case_sensitive))
      rescue RegexpError => e
        raise PatternError.new(source, [e.message])
      end
    end
  end

  # Non-empty matches, searched the way every other engine searches: after an empty match, one
  # character further on; after a match, from its end.
  def spans(text, regexp)
    out = []
    position = 0
    while position <= text.length && (match = regexp.match(text, position))
      start = match.begin(0)
      finish = match.end(0)
      if finish > start
        out << [start, finish]
        position = finish
      else
        position = start + 1
      end
    end
    out
  end

  # Every match of source in text, as ranges of the original text.
  def find_all(source, text, case_sensitive: false)
    regexp = compile(source, case_sensitive: case_sensitive)
    folded = fold(text)
    spans(folded.text, regexp).map do |s, e|
      start, finish = folded.original_range(s, e)
      Match.new(start, finish, text[start...finish])
    end
  end

  # Whether source matches anywhere in text.
  def matches?(source, text, case_sensitive: false)
    !spans(fold(text).text, compile(source, case_sensitive: case_sensitive)).empty?
  end

  SENTENCE_END = ".!?\n"
  ASCII_SPACE = " \t\n\f\r#{11.chr}".freeze

  # The sentence around index, as [start, end); end includes the terminator.
  def sentence_range(text, index)
    start = index
    start -= 1 while start.positive? && !SENTENCE_END.include?(text[start - 1])
    start += 1 while start < text.length && ASCII_SPACE.include?(text[start])
    finish = index
    finish += 1 while finish < text.length && !SENTENCE_END.include?(text[finish])
    finish += 1 if finish < text.length
    [start, finish]
  end

  # Every match of any of the rule's patterns, except a match whose sentence also matches one of its
  # unless patterns. A range found by two patterns counts once. Sorted by position.
  def evaluate(rule, text)
    folded = fold(text)
    seen = {}
    findings = []
    rule.patterns.each do |source|
      spans(folded.text, compile(source, case_sensitive: rule.case_sensitive)).each do |s, e|
        start, finish = folded.original_range(s, e)
        next if seen[[start, finish]]

        seen[[start, finish]] = true
        unless rule.unless.empty?
          from, to = sentence_range(folded.text, s)
          sentence = folded.text[from...to]
          next if rule.unless.any? { |u| !spans(sentence, compile(u, case_sensitive: rule.case_sensitive)).empty? }
        end
        findings << Finding.new(rule.id, start, finish, text[start...finish])
      end
    end
    findings.sort_by { |f| [f.start, f.end] }
  end

  # The text rewritten the ways real and evasive text writes it. Folding turns each variant back into
  # the original, so a rule must give every variant the original's answer.
  def variants(text, case_sensitive: false)
    characters = text.chars
    full_width = characters.map { |c| c.ord.between?(0x21, 0x7E) ? chr(c.ord + 0xFEE0) : c }.join
    zero_width = +""
    characters.each_with_index do |c, i|
      zero_width << c
      zero_width << chr(0x200B) if c.match?(/\A[A-Za-z]\z/) && characters[i + 1]&.match?(/\A[A-Za-z]\z/)
    end
    kelvin = text.gsub("K", chr(0x212A))
    kelvin = kelvin.gsub("k", chr(0x212A)) unless case_sensitive
    candidates = [
      ["long s", text.gsub("s", chr(0x017F))],
      ["Kelvin sign", kelvin],
      ["full-width", full_width],
      ["zero-width spaces", zero_width],
      ["no-break spaces", text.gsub(" ", chr(0x00A0))],
      ["en dashes", text.gsub("-", chr(0x2013))],
      ["smart quotes", text.gsub("'", chr(0x2019)).gsub('"', chr(0x201D))],
    ]
    seen = { text => true }
    candidates.each_with_object([]) do |(name, rewritten), out|
      next if seen[rewritten]

      seen[rewritten] = true
      out << Variant.new(name, rewritten)
    end
  end
end
