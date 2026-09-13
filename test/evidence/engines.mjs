// JavaScript's answers for cases.tsv: as rule engines usually compile (flags `gi`), and on folded
// text with ASCII semantics (`i`, never `u`). Prints: name <TAB> raw <TAB> folded.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const INVISIBLE = /[\u00ad\u180e\u200b-\u200f\u202a-\u202e\u2060-\u2064\ufeff]/;
const DASH = /[\u2010-\u2015\u2212\ufe58\ufe63\uff0d]/;

// NFKC one code point at a time, invisible characters out, dashes to "-".
export function fold(text) {
  let out = "";
  for (const character of text) {
    for (const piece of character.normalize("NFKC")) {
      if (INVISIBLE.test(piece)) continue;
      out += DASH.test(piece) ? "-" : piece === "\u2028" || piece === "\u2029" ? "\n" : piece === "\u1680" ? " " : piece;
    }
  }
  return out;
}

const unescape = (s) => s.replace(/\\u([0-9a-fA-F]{4})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
const yes = (b) => (b ? "yes" : "no");

const file = join(dirname(fileURLToPath(import.meta.url)), "cases.tsv");
for (const line of readFileSync(file, "utf8").split("\n")) {
  if (!line || line.startsWith("#")) continue;
  const [name, pattern, escaped] = line.split("\t");
  const input = unescape(escaped);
  const raw = new RegExp(pattern, "gi").test(input);
  const folded = new RegExp(pattern, "i").test(fold(input));
  console.log([name, yes(raw), yes(folded)].join("\t"));
}
