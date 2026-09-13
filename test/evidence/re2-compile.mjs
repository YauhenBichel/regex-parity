// Compiles every pattern of a rule file in real RE2 (re2js), and checks that RE2 rejects the
// constructs a portable rule may not use. Exits 1 on any surprise.
//
//   node test/evidence/re2-compile.mjs <rules.yaml>
import { readFileSync } from "node:fs";
import { RE2JS } from "re2js";
import { parse } from "yaml";

const file = process.argv[2];
if (!file) {
  console.error("usage: node re2-compile.mjs <rules.yaml>");
  process.exit(2);
}

const problems = [];
let count = 0;
for (const rule of parse(readFileSync(file, "utf8")).rules ?? []) {
  for (const source of [...(rule.patterns ?? []), ...(rule.unless ?? []), ...(rule.except ?? [])]) {
    count++;
    try {
      RE2JS.compile(source, RE2JS.CASE_INSENSITIVE);
    } catch (error) {
      problems.push(`${rule.id}: ${error.message} :: ${source}`);
    }
  }
}

for (const construct of ["(?=x)", "(?!x)", "(?<=x)y", "(?<!x)y", "(a)\\1", "(?>a)", "a*+"]) {
  let compiled = true;
  try {
    RE2JS.compile(construct);
  } catch {
    compiled = false;
  }
  if (compiled) problems.push(`control ${construct} compiled in RE2, but a portable rule may not use it`);
}

if (problems.length) {
  console.error("re2: " + problems.join("\n  "));
  process.exit(1);
}
console.log(`re2: ${count} patterns compile; lookaround, backreferences, atomic groups and possessive quantifiers are rejected`);
