// How the checker reads names (Dream/Engine/Checker.swift's helpers): labels made into names and
// names into labels, near misses matched, and money told apart from what only sits beside it.

import { characters, compare, count, isLetter, isNumber, isUppercase, lower, sorted, splitWhere, upper } from "./swift.ts";

/** "Tip percent" → "tipPercent". Names that are already identifiers are left alone. */
export function identifier(raw: string): string {
  const parts = splitWhere(raw, (character) => !(isLetter(character) || isNumber(character) || character === "_"));
  const first = parts[0];
  if (first === undefined) return "";
  const capitalized = (part: string) => {
    const all = characters(part);
    return upper(all[0] ?? "") + all.slice(1).join("");
  };
  let result = parts.length === 1 ? first : (() => {
    const all = characters(first);
    return lower(all[0] ?? "") + all.slice(1).join("") + parts.slice(1).map(capitalized).join("");
  })();
  if (isNumber(characters(result)[0])) result = "n" + result;
  return result;
}

/** "tipPercent" → "Tip percent". */
export function words(name: string): string {
  let result = "";
  for (const character of characters(name)) {
    if (isUppercase(character) && result !== "") result += " " + lower(character);
    else result += character;
  }
  const all = characters(result);
  return upper(all[0] ?? "") + all.slice(1).join("");
}

export function niceStep(raw: number): number {
  if (!(raw > 0 && Number.isFinite(raw))) return 1;
  const magnitude = Math.pow(10, Math.floor(Math.log10(raw)));
  const leading = raw / magnitude;
  return (leading < 1.5 ? 1 : leading < 3.5 ? 2 : leading < 7.5 ? 5 : 10) * magnitude;
}

/** A name as one of `names`: the same but for case or punctuation, a near spelling, or the only
 * one it starts. Null when nothing is close. */
export function closestName(name: string, names: Iterable<string>): string | null {
  const wanted = lower(name);
  const candidates = sorted(names);
  const exact = candidates.find((candidate) => lower(candidate) === wanted);
  if (exact !== undefined) return exact;
  const compactOf = (text: string) => characters(lower(text)).filter((character) => isLetter(character) || isNumber(character)).join("");
  const compact = compactOf(name);
  const loose = candidates.find((candidate) => compactOf(candidate) === compact);
  if (loose !== undefined) return loose;
  if (count(wanted) >= 4) {
    const near = candidates.filter((candidate) => distance(wanted, lower(candidate)) <= 2);
    if (near.length === 1) return near[0];
  }
  if (count(wanted) >= 3) {
    const prefixed = candidates.filter((candidate) => lower(candidate).startsWith(wanted));
    if (prefixed.length === 1) return prefixed[0];
  }
  return null;
}

/** Edit distance, Character by Character. */
function distance(x: string, y: string): number {
  const a = characters(x);
  const b = characters(y);
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;
  let previous = Array.from({ length: b.length + 1 }, (_, index) => index);
  for (let i = 1; i <= a.length; i++) {
    const current = [i, ...Array(b.length).fill(0)];
    for (let j = 1; j <= b.length; j++) {
      current[j] = Math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    previous = current;
  }
  return previous[b.length];
}

const MONEY_WORDS = new Set([
  "cost", "price", "bill", "rent", "salary", "income", "saving", "payment", "budget", "loan", "fee", "spend", "spending",
  "expense", "deposit", "principal", "balance", "fare", "wage", "profit", "revenue", "debt", "money", "cash", "tip",
  "earning", "investment", "mortgage", "pension", "tax", "emi", "fund",
]);

/** What a quantity is, even beside a money word: a loan's rate or term, how fast rent grows. */
const NOT_MONEY_WORDS = new Set([
  "rate", "growth", "percent", "percentage", "pct", "ratio", "yield", "inflation", "appreciation",
  "tenure", "term", "month", "year", "day", "week", "period", "duration", "count", "people", "person",
]);

/** Whole words only, so "billions" isn't a bill. Words split at camel case, keeping acronyms like EMI whole. */
export function looksLikeMoney(text: string): boolean {
  const found = Array.from(text.matchAll(/[A-Z]+(?![a-z])|[A-Z]?[a-z]+/g), (match) => lower(match[0]));
  const any = (list: Set<string>) => found.some((word) => list.has(word) || (word.endsWith("s") && list.has(word.slice(0, -1))));
  return any(MONEY_WORDS) && !any(NOT_MONEY_WORDS);
}

/** Sorting by Swift's order, for messages that list names. */
export { compare, sorted };
