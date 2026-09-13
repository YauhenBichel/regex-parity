#!/usr/bin/env node
// The regex-parity command line: check a rule file, write the conformance files the Python and Java
// tests read, or put plain JavaScript next to regex-parity on one text.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { RE2JS } from "re2js";
import { parse } from "yaml";
import { checkPattern, compile, evaluate, findAll, fold, variants } from "./index.js";

const USAGE = `regex-parity: one set of regex rules, the same answer in JavaScript, Python, Java and Go

  regex-parity check <rules.yaml>          validate the rules, compile them in RE2 too, and run
                                           every example and its look-alike variants
  regex-parity cases <rules.yaml> <dir>    write rules.tsv and cases.tsv, which other languages'
                                           tests read to prove they give the same answers
  regex-parity try <pattern> <text>        plain JavaScript next to regex-parity, on one text
`;

const BACKSLASH = String.fromCharCode(92);

// Control characters, everything outside printable ASCII, and the backslash itself become
// backslash-u escapes, so the TSV files stay readable and unambiguous.
function escape(text) {
  let out = "";
  for (let i = 0; i < text.length; i += 1) {
    const code = text.charCodeAt(i);
    out += code < 32 || code > 126 || code === 92 ? BACKSLASH + "u" + code.toString(16).padStart(4, "0") : text[i];
  }
  return out;
}

const FIELDS = ["id", "title", "patterns", "unless", "case", "examples"];

function loadRules(path) {
  const document = parse(readFileSync(path, "utf8"));
  const problems = [];
  const rules = [];
  const ids = new Set();
  const stringList = (value) => Array.isArray(value) && value.every((item) => typeof item === "string");
  for (const [index, raw] of (document?.rules ?? []).entries()) {
    const at = `rule ${raw?.id ?? `#${index + 1}`}`;
    if (typeof raw?.id !== "string" || raw.id === "" || /\s/.test(raw.id)) {
      problems.push(`${at}: needs an id without spaces`);
      continue;
    }
    if (ids.has(raw.id)) problems.push(`${at}: duplicate id`);
    ids.add(raw.id);
    const unknown = Object.keys(raw).filter((key) => !FIELDS.includes(key));
    if (unknown.length) problems.push(`${at}: unknown field ${unknown.join(", ")}`);
    const patterns = raw.patterns ?? [];
    const unless = raw.unless ?? [];
    const match = raw.examples?.match ?? [];
    const noMatch = raw.examples?.no_match ?? [];
    if (!stringList(patterns) || patterns.length === 0) problems.push(`${at}: patterns must be a list of at least one string`);
    if (!stringList(unless)) problems.push(`${at}: unless must be a list of strings`);
    if (!["insensitive", "sensitive"].includes(raw.case ?? "insensitive")) problems.push(`${at}: case must be insensitive or sensitive`);
    if (!stringList(match) || match.length === 0) problems.push(`${at}: needs at least one examples.match`);
    if (!stringList(noMatch) || noMatch.length === 0) problems.push(`${at}: needs at least one examples.no_match`);
    for (const example of [...(stringList(match) ? match : []), ...(stringList(noMatch) ? noMatch : [])]) {
      if ([...example].some((c) => c.codePointAt(0) > 0xffff)) {
        problems.push(`${at}: examples must use characters below U+10000, where every language counts offsets alike`);
      }
    }
    rules.push({
      id: raw.id,
      title: raw.title ?? "",
      patterns: stringList(patterns) ? patterns : [],
      unless: stringList(unless) ? unless : [],
      case: raw.case ?? "insensitive",
      match: stringList(match) ? match : [],
      noMatch: stringList(noMatch) ? noMatch : [],
    });
  }
  if (!rules.length && !problems.length) problems.push(`${path}: no rules found under "rules:"`);
  return { rules, problems };
}

function check(path) {
  const { rules, problems } = loadRules(path);
  const report = rules.map((rule) => {
    const ruleProblems = [];
    const caseSensitive = rule.case === "sensitive";
    for (const source of [...rule.patterns, ...rule.unless]) {
      const portability = checkPattern(source);
      for (const problem of portability) ruleProblems.push(`${JSON.stringify(source)}: ${problem}`);
      try {
        RE2JS.compile(source, caseSensitive ? 0 : RE2JS.CASE_INSENSITIVE);
      } catch (error) {
        ruleProblems.push(`${JSON.stringify(source)}: RE2 cannot compile it (${error.message})`);
      }
      if (!portability.length) {
        try {
          compile(source, { caseSensitive });
        } catch (error) {
          ruleProblems.push(error.message);
        }
      }
    }
    let variantCount = 0;
    if (!ruleProblems.length) {
      for (const [examples, expected] of [[rule.match, true], [rule.noMatch, false]]) {
        const want = expected ? "should match" : "should not match";
        for (const example of examples) {
          if (evaluate(rule, example).length > 0 !== expected) {
            ruleProblems.push(`${want}: ${JSON.stringify(example)}`);
            continue;
          }
          for (const variant of variants(example, { caseSensitive })) {
            variantCount += 1;
            if (evaluate(rule, variant.text).length > 0 !== expected) {
              ruleProblems.push(`${want} with ${variant.name}: ${escape(variant.text)}`);
            }
          }
        }
      }
    }
    return { rule, problems: ruleProblems, variantCount };
  });
  return { rules, problems, report, failed: problems.length > 0 || report.some((r) => r.problems.length > 0) };
}

function printCheck(result) {
  for (const problem of result.problems) console.log(`FAIL ${problem}`);
  for (const { rule, problems, variantCount } of result.report) {
    if (problems.length) {
      console.log(`FAIL ${rule.id}`);
      for (const problem of problems) console.log(`       ${problem}`);
    } else {
      console.log(`ok   ${rule.id}  ${rule.match.length + rule.noMatch.length} examples, ${variantCount} look-alike variants`);
    }
  }
  console.log(
    result.failed
      ? "regex-parity: these rules are not ready"
      : `regex-parity: ${result.rules.length} rules give the same answers in every regex-parity language`,
  );
}

function writeCases(path, directory) {
  const result = check(path);
  if (result.failed) {
    printCheck(result);
    return 1;
  }
  const rules = ["# rule\tcase\trole\tpattern (backslashes and non-ASCII as backslash-u escapes)"];
  const cases = ["# rule\texpect\tvariant\ttext (escaped like the patterns)\tfindings as start:end, or -"];
  for (const rule of result.rules) {
    for (const source of rule.patterns) rules.push([rule.id, rule.case, "pattern", escape(source)].join("\t"));
    for (const source of rule.unless) rules.push([rule.id, rule.case, "unless", escape(source)].join("\t"));
    for (const [examples, expect] of [[rule.match, "match"], [rule.noMatch, "no_match"]]) {
      for (const example of examples) {
        const rows = [{ name: "as written", text: example }, ...variants(example, { caseSensitive: rule.case === "sensitive" })];
        for (const { name, text } of rows) {
          const findings = evaluate(rule, text).map((f) => `${f.start}:${f.end}`).join(",") || "-";
          cases.push([rule.id, expect, name, escape(text), findings].join("\t"));
        }
      }
    }
  }
  const portability = parse(readFileSync(path, "utf8"))?.portability ?? {};
  const patterns = ["# expect\tpattern (escaped like the others): every language must refuse or accept it alike"];
  for (const [list, expect] of [[portability.refused ?? [], "refused"], [portability.accepted ?? [], "accepted"]]) {
    for (const source of list) {
      const refused = checkPattern(source).length > 0;
      if (refused !== (expect === "refused")) {
        console.log(`FAIL portability: ${JSON.stringify(source)} is listed as ${expect} but is ${refused ? "refused" : "accepted"}`);
        return 1;
      }
      patterns.push([expect, escape(source)].join("\t"));
    }
  }
  mkdirSync(directory, { recursive: true });
  if (patterns.length > 1) writeFileSync(join(directory, "patterns.tsv"), patterns.join("\n") + "\n");
  writeFileSync(join(directory, "rules.tsv"), rules.join("\n") + "\n");
  writeFileSync(join(directory, "cases.tsv"), cases.join("\n") + "\n");
  console.log(`regex-parity: wrote ${rules.length - 1} patterns and ${cases.length - 1} cases to ${directory}`);
  return 0;
}

function tryOne(pattern, text) {
  let plain;
  try {
    plain = [...text.matchAll(new RegExp(pattern, "gi"))].map((m) => m[0]).filter(Boolean);
  } catch (error) {
    plain = error.message;
  }
  const show = (found) => (found.length ? `matches ${JSON.stringify(found)}` : "no match");
  console.log(`text           ${escape(text)}`);
  console.log(`folded         ${escape(fold(text).text)}`);
  console.log(`plain JS (gi)  ${Array.isArray(plain) ? show(plain) : `error: ${plain}`}`);
  try {
    console.log(`regex-parity   ${show(findAll(pattern, text).map((m) => m.text))}`);
  } catch (error) {
    console.log(`regex-parity   ${error.message}`);
    return 1;
  }
  return 0;
}

const [command, ...args] = process.argv.slice(2);
if (command === "check" && args.length === 1) {
  const result = check(args[0]);
  printCheck(result);
  process.exitCode = result.failed ? 1 : 0;
} else if (command === "cases" && args.length === 2) {
  process.exitCode = writeCases(args[0], args[1]);
} else if (command === "try" && args.length === 2) {
  process.exitCode = tryOne(args[0], args[1]);
} else {
  process.stdout.write(USAGE);
  process.exitCode = command === undefined || command === "help" || command === "--help" ? 0 : 2;
}
