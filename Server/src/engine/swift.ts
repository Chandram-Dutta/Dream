// What Swift means by a string and a number, where the engine depends on it. A Swift String is a
// list of Characters (grapheme clusters, so "क्ष" and "\r\n" are one each), a Character's
// properties are its first scalar's, and `count`, `prefix` and comparisons go by Characters. Swift
// prints doubles its own way, rounds halves away from zero, and its min and max treat NaN by their
// own rules. Every function here matches the Swift it names, so the port reads like the original.

const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const ASCII = /^[\x00-\x7f]*$/;

/** A string's Characters, as Swift iterates them. */
export function characters(text: string): string[] {
  if (ASCII.test(text) && !text.includes("\r\n")) return text.split("");
  return Array.from(segmenter.segment(text), (part) => part.segment);
}

/** `String.count`: how many Characters. */
export function count(text: string): number {
  if (ASCII.test(text) && !text.includes("\r\n")) return text.length;
  let total = 0;
  for (const _ of segmenter.segment(text)) total++;
  return total;
}

/** `String.prefix(n)`: the first n Characters. */
export function prefix(text: string, n: number): string {
  if (ASCII.test(text) && !text.includes("\r\n")) return text.slice(0, Math.max(0, n));
  return characters(text).slice(0, Math.max(0, n)).join("");
}

/** `String.dropFirst(n)`. */
export function dropFirst(text: string, n = 1): string {
  return characters(text).slice(n).join("");
}

/** `String.dropLast(n)`. */
export function dropLast(text: string, n = 1): string {
  const all = characters(text);
  return all.slice(0, Math.max(0, all.length - n)).join("");
}

/** `String.suffix(n)`. */
export function suffix(text: string, n: number): string {
  const all = characters(text);
  return all.slice(Math.max(0, all.length - n)).join("");
}

/** Han characters that are also numbers (一, 二, 万…), which Swift's `isNumber` counts and `\p{N}` doesn't. */
const NUMERIC_LETTERS = new Set(
  ("3405 3483 382A 3B4D 4E00 4E03 4E07 4E09 4E24 4E5D 4E8C 4E94 4E96 4EAC 4EBF 4EC0 4EDF 4EE8 4F0D 4F70 4FE9 5006 5104 5146 5169 516B 516D 5341 5343 " +
    "5344 5345 534C 53C1 53C2 53C3 53C4 56DB 58F1 58F9 5E7A 5EFE 5EFF 5F0C 5F0D 5F0E 5F10 62D0 62FE 634C 67D2 6D1E 6F06 7396 767E 7695 79ED 8086 " +
    "842C 8CAE 8CB3 8D30 920E 94A9 9621 9646 964C 9678 96F6 F96B F973 F978 F9B2 F9D1 F9D3 F9FD 12038 12039 12079 12226 1222B 1230B 1230D 12399 " +
    "20001 20064 200E2 20121 2092A 20983 2098C 2099C 20AEA 20AFD 20B19 22390 22998 23B1B 2626D 2F890")
    .split(" ")
    .map((hex) => parseInt(hex, 16)),
);

/** `Character.isLetter`: its first scalar is alphabetic. */
export function isLetter(character: string | undefined): boolean {
  return character !== undefined && character !== "" && /^\p{Alphabetic}/u.test(character);
}

/** `Character.isNumber`: its first scalar has a numeric value. */
export function isNumber(character: string | undefined): boolean {
  if (character === undefined || character === "") return false;
  return /^\p{N}/u.test(character) || NUMERIC_LETTERS.has(character.codePointAt(0) ?? 0);
}

/** `Character.isWhitespace`. */
export function isWhitespace(character: string | undefined): boolean {
  return character !== undefined && character !== "" && /^\p{White_Space}/u.test(character);
}

export function isPunctuation(character: string): boolean {
  return /^\p{P}/u.test(character);
}

export function isSymbol(character: string): boolean {
  return /^\p{S}/u.test(character);
}

/** `Character.isASCII`: every scalar in it. */
export function isASCII(character: string): boolean {
  return ASCII.test(character);
}

/** `Character.isASCII && Character.isNumber`: 0 to 9. */
export function isDigit(character: string | undefined): boolean {
  return character !== undefined && character.length === 1 && character >= "0" && character <= "9";
}

/** `Character.isUppercase`, which also counts a cased character that upper-casing leaves alone. */
export function isUppercase(character: string): boolean {
  const single = Array.from(character).length === 1;
  if (single && /^\p{Uppercase}/u.test(character)) return true;
  if (upper(character) !== character) return false;
  return (single && /^\p{Cased}/u.test(character)) || lower(character) !== character;
}

/** `String.lowercased()`: scalar by scalar, so Σ is always σ, never the final ς. */
export function lower(text: string): string {
  if (ASCII.test(text)) return text.toLowerCase();
  let result = "";
  for (const scalar of text) result += scalar.toLowerCase();
  return result;
}

/** `String.uppercased()`. */
export function upper(text: string): string {
  if (ASCII.test(text)) return text.toUpperCase();
  let result = "";
  for (const scalar of text) result += scalar.toUpperCase();
  return result;
}

/** `Character.lowercased()` of one Character, kept separate for clarity. */
export const lowerCharacter = lower;

// CharacterSet.whitespaces is Zs and tab; .whitespacesAndNewlines adds U+000A to U+000D, U+0085,
// U+2028 and U+2029. JavaScript's trim() differs (it takes U+FEFF and leaves U+0085).
const WHITESPACES = "\\p{Zs}\\t";
const NEWLINES = "\\n\\u000b\\f\\r\\u0085\\u2028\\u2029";
const TRIM_SPACES = new RegExp(`^[${WHITESPACES}]+|[${WHITESPACES}]+$`, "gu");
const TRIM_ALL = new RegExp(`^[${WHITESPACES}${NEWLINES}]+|[${WHITESPACES}${NEWLINES}]+$`, "gu");

/** `trimmingCharacters(in: .whitespaces)`. */
export function trim(text: string): string {
  return text.replace(TRIM_SPACES, "");
}

/** `trimmingCharacters(in: .whitespacesAndNewlines)`. */
export function trimAll(text: string): string {
  return text.replace(TRIM_ALL, "");
}

/** `trimmingCharacters(in: CharacterSet(charactersIn: set))`. */
export function trimSet(text: string, set: string): string {
  const scalars = new Set(Array.from(set));
  const all = Array.from(text);
  let start = 0;
  let end = all.length;
  while (start < end && scalars.has(all[start])) start++;
  while (end > start && scalars.has(all[end - 1])) end--;
  return all.slice(start, end).join("");
}

/** `String.split(separator:)` and `split(whereSeparator:)`, which leave out empty pieces. */
export function splitWhere(text: string, isSeparator: (character: string) => boolean, maxSplits = Infinity): string[] {
  const pieces: string[] = [];
  let current = "";
  let splits = 0;
  const all = characters(text);
  for (let index = 0; index < all.length; index++) {
    const character = all[index];
    if (splits < maxSplits && isSeparator(character)) {
      if (current !== "") {
        pieces.push(current);
        splits++;
      }
      current = "";
      if (splits >= maxSplits) {
        const rest = all.slice(index + 1).join("");
        if (rest !== "") pieces.push(rest);
        return pieces;
      }
      continue;
    }
    current += character;
  }
  if (current !== "") pieces.push(current);
  return pieces;
}

/** `String.split(separator: c, maxSplits:)`, empty pieces left out. */
export function split(text: string, separator: string, maxSplits = Infinity): string[] {
  return splitWhere(text, (character) => character === separator, maxSplits);
}

/** Swift orders strings by their Unicode canonical form, scalar by scalar. */
export function compare(a: string, b: string): number {
  if (a === b) return 0;
  const x = ASCII.test(a) ? a : a.normalize("NFC");
  const y = ASCII.test(b) ? b : b.normalize("NFC");
  const xs = Array.from(x);
  const ys = Array.from(y);
  for (let index = 0; index < Math.min(xs.length, ys.length); index++) {
    const d = (xs[index].codePointAt(0) ?? 0) - (ys[index].codePointAt(0) ?? 0);
    if (d !== 0) return d;
  }
  return xs.length - ys.length;
}

/** `Set<String>.sorted()`. */
export function sorted(values: Iterable<string>): string[] {
  return Array.from(values).sort(compare);
}

// MARK: - Numbers

/** `Double.rounded()`: halves away from zero. */
export function round(value: number): number {
  return value < 0 ? -Math.round(-value) : Math.round(value);
}

/** `Swift.min(x, y)`: y only when it's smaller, so a NaN x stays. */
export function min(x: number, y: number, ...rest: number[]): number {
  let result = y < x ? y : x;
  for (const value of rest) if (value < result) result = value;
  return result;
}

/** `Swift.max(x, y)`: y unless it's smaller. */
export function max(x: number, y: number, ...rest: number[]): number {
  let result = y >= x ? y : x;
  for (const value of rest) if (value >= result) result = value;
  return result;
}

/** `Sequence.min()`: the first value nothing later is below. */
export function minOf(values: number[]): number | undefined {
  if (values.length === 0) return undefined;
  let result = values[0];
  for (const value of values.slice(1)) if (value < result) result = value;
  return result;
}

/** `Sequence.max()`. */
export function maxOf(values: number[]): number | undefined {
  if (values.length === 0) return undefined;
  let result = values[0];
  for (const value of values.slice(1)) if (result < value) result = value;
  return result;
}

/** C's pow, which Foundation calls: 1 to any power is 1, and so is -1 to an infinite one. */
export function pow(base: number, exponent: number): number {
  if (base === 1) return 1;
  if (base === -1 && (exponent === Infinity || exponent === -Infinity)) return 1;
  return Math.pow(base, exponent);
}

const LANCZOS = [
  0.99999999999980993, 676.5203681218851, -1259.1392167224028, 771.32342877765313, -176.61502916214059, 12.507343278686905,
  -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7,
];

/** C's tgamma. Whole numbers are worked out exactly, as the C library gives them. */
export function tgamma(x: number): number {
  if (Number.isNaN(x)) return NaN;
  if (x === Infinity) return Infinity;
  if (Number.isInteger(x)) {
    if (x <= 0) return NaN;
    if (x > 171) return Infinity;
    let result = 1;
    for (let k = 2; k < x; k++) result *= k;
    return result;
  }
  if (x < 0.5) return Math.PI / (Math.sin(Math.PI * x) * tgamma(1 - x));
  if (x > 171.7) return Infinity;
  // Γ(x) = (x - 1) Γ(x - 1): brought between 1 and 2, where Γ(1.5) is √π / 2 exactly and the
  // rest is Lanczos's approximation, so a half like fact(3.5) comes out as the C library's.
  let product = 1;
  let y = x;
  while (y >= 2) {
    y -= 1;
    product *= y;
  }
  if (y === 1.5) return product * (Math.sqrt(Math.PI) / 2);
  const z = y - 1;
  let sum = LANCZOS[0];
  for (let k = 1; k < LANCZOS.length; k++) sum += LANCZOS[k] / (z + k);
  const t = z + 7.5;
  return product * Math.sqrt(2 * Math.PI) * Math.pow(t, z + 0.5) * Math.exp(-t) * sum;
}

/** C's lgamma, for the arguments the engine gives it (1 and up), and the rest by reflection. */
export function lgamma(x: number): number {
  if (Number.isNaN(x)) return NaN;
  if (x === 1 || x === 2) return 0;
  if (x < 0.5) return Math.log(Math.PI / Math.abs(Math.sin(Math.PI * x))) - lgamma(1 - x);
  const z = x - 1;
  let sum = LANCZOS[0];
  for (let k = 1; k < LANCZOS.length; k++) sum += LANCZOS[k] / (z + k);
  const t = z + 7.5;
  return 0.5 * Math.log(2 * Math.PI) + (z + 0.5) * Math.log(t) - t + Math.log(sum);
}

/** `Double(String)`: the whole text as a decimal number, or null. */
export function double(text: string): number | null {
  if (!/^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(text)) return null;
  return Number(text);
}

/** `String(Double)`, Swift's shortest form: 12.0, 0.1, 1e-05, 1e+16. */
export function describe(value: number): string {
  if (Number.isNaN(value)) return "nan";
  if (value === Infinity) return "inf";
  if (value === -Infinity) return "-inf";
  if (value === 0) return Object.is(value, -0) ? "-0.0" : "0.0";
  const magnitude = Math.abs(value);
  const [mantissa, exponentText] = value.toExponential().split("e");
  const exponent = Number(exponentText);
  if (magnitude < 1e-4 || magnitude > 2 ** 53) {
    return `${mantissa}e${exponent < 0 ? "-" : "+"}${String(Math.abs(exponent)).padStart(2, "0")}`;
  }
  // Decimal: the shortest digits, placed by the exponent.
  const negative = value < 0;
  const digits = mantissa.replace("-", "").replace(".", "");
  let text: string;
  if (exponent < 0) {
    text = "0." + "0".repeat(-exponent - 1) + digits;
  } else if (digits.length <= exponent + 1) {
    text = digits + "0".repeat(exponent + 1 - digits.length) + ".0";
  } else {
    text = digits.slice(0, exponent + 1) + "." + digits.slice(exponent + 1);
  }
  return (negative ? "-" : "") + text;
}

/** `Double.plain` (Formatting.swift): 12 rather than 12.0, for prompts and formulas. */
export function plain(value: number): string {
  if (value === round(value) && Math.abs(value) < 1e15) return String(Math.trunc(value) === 0 ? 0 : Math.trunc(value));
  return describe(value);
}

/** Whether a JSON value is a finite number, as Swift's Double holds it. */
export function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}
