# frozen_string_literal: true

require_relative "lib/regex_parity"

Gem::Specification.new do |spec|
  spec.name = "regex-parity"
  spec.version = RegexParity::VERSION
  spec.authors = ["Yauhen Bichel"]
  spec.summary = "One set of regular-expression rules, the same answer in Ruby, JavaScript, Python, Java, Go, Rust and C#."
  spec.description = "Folds text the same way in every language, runs patterns with ASCII behaviour, refuses patterns " \
                     "engines read differently, and maps every match back to the original text, so accented, " \
                     "look-alike and invisible characters no longer make copies of a rule disagree."
  spec.license = "Apache-2.0"
  spec.homepage = "https://github.com/YauhenBichel/regex-parity"
  spec.metadata = {
    "homepage_uri" => "https://yauhenbichel.github.io/regex-parity/",
    "source_code_uri" => "https://github.com/YauhenBichel/regex-parity/tree/main/packages/ruby",
    "rubygems_mfa_required" => "true",
  }
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*.rb"] + ["README.md", "regex-parity.gemspec"]
  spec.require_paths = ["lib"]
end
