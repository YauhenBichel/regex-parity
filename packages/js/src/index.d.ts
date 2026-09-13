/** Text as every language matches it, with the way back to the original. */
export interface Folded {
  text: string;
  /** For each code unit of `text`, where its original character starts. */
  starts: number[];
  /** For each code unit of `text`, where its original character ends. */
  ends: number[];
  /** Length of the original text. */
  length: number;
}

/** A match, as a range of the original text. */
export interface Match {
  start: number;
  end: number;
  text: string;
}

export interface Rule {
  id: string;
  patterns: string[];
  /** A match is dropped when one of these matches the same sentence. */
  unless?: string[];
  /** Default "insensitive". */
  case?: "insensitive" | "sensitive";
}

export interface Finding {
  rule: string;
  start: number;
  end: number;
  text: string;
}

export interface Variant {
  name: string;
  text: string;
}

export interface Options {
  caseSensitive?: boolean;
}

export declare class PatternError extends Error {
  readonly pattern: string;
  readonly problems: string[];
}

export declare function fold(text: string): Folded;
export declare function checkPattern(source: string): string[];
export declare function compile(source: string, options?: Options): RegExp;
export declare function findAll(source: string, text: string, options?: Options): Match[];
export declare function matches(source: string, text: string, options?: Options): boolean;
export declare function sentenceRange(text: string, index: number): [number, number];
export declare function evaluate(rule: Rule, text: string): Finding[];
export declare function variants(text: string, options?: Options): Variant[];
