// Maths and live values in text (Dream/Engine/TeX.swift's segments and repaired, and
// Formatting.swift's Placeholders): where `$...$` is maths and `{name}` is a live value, which the
// checker keeps only for names the calculation has.

import { characters, count, dropFirst, dropLast, isNumber, isWhitespace, trim, trimAll, trimSet } from "./swift.ts";

export type Segment = { text: string } | { math: string };

/** Splits text into prose and maths: between `$` signs, `$$` pairs, or `\(` and `\)`. A `$` opens
 * maths only before something that isn't a space, and closes it only after something that isn't
 * a space and before something that isn't a digit, so "$5 to $10" stays prose. */
export function segments(text: string): Segment[] {
  if (!text.includes("$") && !text.includes("\\(") && !text.includes("\\[")) return [{ text }];
  // Form feeds, backspaces and tabs are LaTeX commands that JSON read as escapes.
  const all = characters(text.replaceAll("\u000C", "\\f").replaceAll("\u0008", "\\b").replaceAll("\t", "\\t"));
  const result: Segment[] = [];
  let prose = "";
  let index = 0;
  const at = (position: number): string | undefined => all[position];
  const find = (marker: string, start: number): number | null => {
    const wanted = characters(marker);
    for (let position = start; position + wanted.length <= all.length; position++) {
      if (wanted.every((character, offset) => all[position + offset] === character)) return position;
    }
    return null;
  };
  const math = (from: number, to: number, next: number) => {
    if (prose !== "") result.push({ text: prose });
    prose = "";
    result.push({ math: repaired(all.slice(from, to).join("")) });
    index = next;
  };

  while (index < all.length) {
    const character = all[index];
    if (character === "\\" && at(index + 1) === "$") {
      prose += "$";
      index += 2;
      continue;
    }
    const after = at(index + 1);
    if (character === "\\" && (after === "(" || after === "[")) {
      const end = find(after === "(" ? "\\)" : "\\]", index + 2);
      if (end !== null) {
        math(index + 2, end, end + 2);
        continue;
      }
    }
    if (character === "$") {
      if (after === "$") {
        const end = find("$$", index + 2);
        if (end !== null && end > index + 2) {
          math(index + 2, end, end + 2);
          continue;
        }
      }
      if (after !== undefined && !isWhitespace(after)) {
        let end: number | null = null;
        for (let position = index + 1; position < all.length; position++) {
          const candidate = all[position];
          if (candidate === "\n" && at(position + 1) === "\n") break;
          if (candidate === "$" && all[position - 1] !== "\\" && !isWhitespace(all[position - 1]) && !isNumber(at(position + 1))) {
            end = position;
            break;
          }
        }
        if (end !== null) {
          math(index + 1, end, end + 1);
          continue;
        }
      }
    }
    prose += character;
    index += 1;
  }
  if (prose !== "") result.push({ text: prose });
  return result;
}

/** JSON reads `\f`, `\b`, `\t`, `\r` and `\n` as control characters, which turns `\frac` into a
 * form feed and "rac". Maths never holds control characters, so they go back. */
export function repaired(tex: string): string {
  const scalars = Array.from(tex);
  let result = "";
  for (let index = 0; index < scalars.length; index++) {
    const scalar = scalars[index];
    switch (scalar) {
      case "\u000C": result += "\\f"; break;
      case "\u0008": result += "\\b"; break;
      case "\t": result += "\\t"; break;
      case "\r": result += "\\r"; break;
      case "\n": {
        const next = index + 1 < scalars.length ? scalars[index + 1] : " ";
        // CharacterSet.letters: every letter and mark.
        result += /^[\p{L}\p{M}]/u.test(next) ? "\\n" : " ";
        break;
      }
      default: result += scalar;
    }
  }
  return trimAll(result);
}

export type Part = { text: string } | { name: string } | { math: string };

/** Text with `{name}` placeholders and maths. Braces inside maths are LaTeX, never placeholders. */
export function parts(text: string): Part[] {
  return segments(text).flatMap((segment): Part[] => ("math" in segment ? [{ math: segment.math }] : names(segment.text)));
}

function names(text: string): Part[] {
  const result: Part[] = [];
  let rest = text;
  while (true) {
    const open = rest.indexOf("{");
    if (open < 0) break;
    const close = rest.indexOf("}", open);
    if (close < 0) break;
    if (open > 0) result.push({ text: rest.slice(0, open) });
    const name = trim(rest.slice(open + 1, close));
    result.push(name === "" ? { text: "{}" } : { name });
    rest = rest.slice(close + 1);
  }
  if (rest !== "") result.push({ text: rest });
  return result;
}

export function join(list: Part[]): string {
  return list.map((part) => ("text" in part ? part.text : "name" in part ? `{${part.name}}` : `$${part.math}$`)).join("");
}

/** A symbol as LaTeX: no dollar signs, and short (Checker.symbol). */
export function texSymbol(raw: string): string {
  const tex = trimSet(repaired(raw), "$ ");
  return count(tex) <= 40 ? tex : "";
}

/** Small models sometimes write a line break as the two characters \n (Checker.prose). */
export function prose(text: string): string {
  return text.replace(/\\n(?![a-zA-Z])/g, " ").replaceAll("  ", " ");
}

/** An equation's LaTeX without the delimiters models sometimes wrap it in (Checker.displayMath). */
export function displayMath(raw: string): string {
  let tex = repaired(raw);
  for (const [open, close] of [["$$", "$$"], ["\\[", "\\]"], ["\\(", "\\)"], ["$", "$"]]) {
    if (tex.startsWith(open) && tex.endsWith(close) && count(tex) > open.length + close.length) {
      tex = trimAll(dropLast(dropFirst(tex, open.length), close.length));
      break;
    }
  }
  return tex;
}
