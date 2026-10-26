// The check a page passes before it's published (shares.ts). Anyone with a link can read a shared
// page, so the obvious abuse is refused before it's stored: slurs, sexual content involving
// children, and someone's private details. Everything else is left to readers' reports and an
// admin's takedown (safety.ts).
//
// It's a short list and a few patterns, run in the Worker, rather than a model such as Llama Guard
// on Workers AI. Dream's pages are mostly explanations: of history, the body, crime, the law. A
// classifier flags those far more often than abuse that's actually there, and it costs time and
// money on every share, can change its mind, and can't run in the tests. Each rule here instead
// asks for something an honest page has almost no reason to contain:
//
// - **slur:** one of a few racial and ethnic slurs that have no other everyday meaning, as a whole
//   word, after folding accents, l33t spelling and stretched letters. A page that quotes a slur,
//   say a history of the word, is refused too; that's the main false positive.
// - **minors:** a word for a child (or an age under 16) in the same sentence as an explicit sex
//   word, or one of the few words that only ever mean sexual material of children. Clinical words
//   (sex, sexual, abuse) don't count, so pages about keeping children safe aren't refused.
// - **private:** an ID or card number in a valid shape (a US Social Security number, an Indian
//   Aadhaar number, or a payment card number that passes its checksum), apart from well-known
//   examples; or a person's home address given together with their phone number.
//
// Listed words are kept as hashes (`wordHash`), so they aren't written out here. To add one, run
// `node scripts/blockword.mjs <word>` and add what it prints. Each list also holds one made-up
// word (like an antivirus test file), so the tests can check the lists work without quoting them.

import type { Json, JsonObject, Shared } from "./payload";

export type Concern = "slur" | "minors" | "private";

export interface Refusal {
  reason: Concern;
  message: string;
}

/** What the sharer is told. The app shows its own words for each reason (ShareServer.swift). */
const MESSAGES: Record<Concern, string> = {
  slur: "This page uses a slur, so it can't be shared.",
  minors: "This page puts children together with sexual content, so it can't be shared.",
  private: "This page seems to include someone's private details, like an ID or card number, or a home address and phone number, so it can't be shared.",
};

/** Slurs (and the test word "dreamslurcheck"). */
const SLURS = new Set(["apbz1vuek6", "48q06ewngi", "c1mwtuu65y", "xssljfj3fm", "1esejwxgph7", "z3e8dzzwnv", "2gglnb00bcs", "1ljppt6xvp3", "zal5qviqw6", "ujmfer6xo6", "1mw25hspoql"]);
/** Explicit sex words, which count in a sentence with a word for a child (and "dreamexplicitcheck"). */
const EXPLICIT = new Set(["1wowsfqjxju", "16jnp45xfby", "2et88jnid9i", "28b9wneaue5", "6z8hnw7puz", "19cktdqwzg3", "nc1i0zdamp", "qww4sx78io", "1cin2nc6vy4", "1ha1qg7eg11", "20p0ipvvog2", "2apcfs30itj", "2fvo5p8huad"]);
/** Slang for pornography, which counts right after a word for a child (and "dreamporncheck"). */
const PORN = new Set(["2e59924v9d5", "k8y5k0o7te", "e9dwbxen5w"]);
/** Words that only ever mean sexual material of children (and "dreamcsamcheck"). */
const CSAM = new Set(["2gb52y4rpqz", "vcd9g7epgj", "1gnxszh8ech", "gjl0nz797x", "q4xfvlu1l6", "1qc0fgap7gp", "1zl2a8ccvby"]);

/** Words for a child. "Boy", "girl" and "teen" aren't here: they're used of adults too. */
const CHILD = new Set(["child", "children", "childs", "kid", "kids", "kiddie", "kiddies", "kiddy", "minor", "minors", "underage", "preteen", "preteens", "prepubescent", "toddler", "toddlers", "infant", "infants", "schoolgirl", "schoolgirls", "schoolboy", "schoolboys"]);
/** An age under 16, like "12-year-old", "12 yrs old" or "12yo". */
const YOUNG_AGE = /(?:^|[^\d])(?:[1-9]|1[0-5])\s*-?\s*(?:years?|yrs?)\s*-?\s*old\b|(?:^|[^\d])(?:[1-9]|1[0-5])\s*(?:yo|y\/o)\b/i;
const LITTLE_CHILD = /\blittle\s+(?:girl|boy)s?\b/i;

/** A quick 53-bit hash (cyrb53), so the listed words needn't be written out. */
export function wordHash(word: string): string {
  let h1 = 0xdeadbeef ^ 31;
  let h2 = 0x41c6ce57 ^ 31;
  for (let index = 0; index < word.length; index++) {
    const code = word.charCodeAt(index);
    h1 = Math.imul(h1 ^ code, 2654435761);
    h2 = Math.imul(h2 ^ code, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507);
  h1 ^= Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507);
  h2 ^= Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(36);
}

const LEET: Record<string, string> = { "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", $: "s" };

/** The words in some text, folded the way the lists are: no accents, lower case, l33t spelling
 * read as letters, letters stretched past two brought back to two, and letters spelled out one
 * at a time ("s l u r") joined up. */
export function words(text: string): string[] {
  const folded = text
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/[013457@$]/g, (character) => LEET[character] ?? character);
  const tokens = folded.split(/[^\p{L}]+/u).filter(Boolean).map((token) => token.replace(/(\p{L})\1{2,}/gu, "$1$1"));
  const joined: string[] = [];
  let spelled = "";
  for (const token of [...tokens, ""]) {
    if (token.length === 1) {
      spelled += token;
      continue;
    }
    if (spelled.length >= 4) joined.push(spelled);
    else if (spelled) joined.push(...spelled);
    spelled = "";
    if (token) joined.push(token);
  }
  return joined;
}

const listed = (list: Set<string>, word: string) => list.has(wordHash(word)) || (word.length > 3 && word.endsWith("s") && list.has(wordHash(word.slice(0, -1))));

/** Keys whose values are names, addresses or formulas rather than words a reader sees. */
const NOT_PROSE = new Set(["id", "kind", "ref", "refs", "over", "accent", "symbol", "formula", "url", "imageURL", "audioURL", "pageURL", "format", "role", "type", "name", "measurementSystem", "language", "date", "unit"]);

/** Every piece of text a reader of the page could see. */
function prose(value: Json, key: string | null, into: string[]): string[] {
  if (typeof value === "string") {
    if (key === null || !NOT_PROSE.has(key)) into.push(value);
  } else if (Array.isArray(value)) {
    for (const item of value) prose(item, key, into);
  } else if (value !== null && typeof value === "object") {
    for (const [name, item] of Object.entries(value)) prose(item, name, into);
  }
  return into;
}

function hasSlur(texts: string[]): boolean {
  return texts.some((text) => words(text).some((word) => listed(SLURS, word)));
}

function sexualizesChildren(texts: string[]): boolean {
  for (const text of texts) {
    for (const sentence of text.split(/[.!?;\n]+/)) {
      const found = words(sentence);
      if (found.some((word) => listed(CSAM, word))) return true;
      const childAt = found.flatMap((word, index) => (CHILD.has(word) ? [index] : []));
      const child = childAt.length > 0 || YOUNG_AGE.test(sentence) || LITTLE_CHILD.test(sentence);
      if (!child) continue;
      if (found.some((word) => listed(EXPLICIT, word))) return true;
      if (childAt.some((index) => index + 1 < found.length && listed(PORN, found[index + 1]))) return true;
    }
  }
  return false;
}

// MARK: - Private details

/** Examples printed in guides, which are nobody's. */
const EXAMPLES = new Set(["123456789", "078051120", "219099999", "4111111111111111", "4242424242424242", "4012888888881881", "5555555555554444", "5105105105105100", "378282246310005", "371449635398431", "6011111111111117", "4000056655665556"]);

function luhn(digits: string): boolean {
  let sum = 0;
  for (let index = 0; index < digits.length; index++) {
    let digit = Number(digits[digits.length - 1 - index]);
    if (index % 2 === 1) {
      digit *= 2;
      if (digit > 9) digit -= 9;
    }
    sum += digit;
  }
  return sum % 10 === 0;
}

const VERHOEFF_D = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 2, 3, 4, 0, 6, 7, 8, 9, 5], [2, 3, 4, 0, 1, 7, 8, 9, 5, 6], [3, 4, 0, 1, 2, 8, 9, 5, 6, 7], [4, 0, 1, 2, 3, 9, 5, 6, 7, 8],
  [5, 9, 8, 7, 6, 0, 4, 3, 2, 1], [6, 5, 9, 8, 7, 1, 0, 4, 3, 2], [7, 6, 5, 9, 8, 2, 1, 0, 4, 3], [8, 7, 6, 5, 9, 3, 2, 1, 0, 4], [9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
];
const VERHOEFF_P = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 5, 7, 6, 2, 8, 3, 0, 9, 4], [5, 8, 0, 3, 7, 9, 6, 1, 4, 2], [8, 9, 1, 6, 0, 4, 3, 5, 2, 7],
  [9, 4, 5, 3, 1, 2, 6, 8, 7, 0], [4, 2, 8, 6, 5, 7, 3, 9, 0, 1], [2, 7, 9, 3, 8, 0, 6, 4, 1, 5], [7, 0, 4, 6, 9, 1, 3, 2, 5, 8],
];

/** Aadhaar numbers end in a Verhoeff check digit. */
function verhoeff(digits: string): boolean {
  let check = 0;
  for (let index = 0; index < digits.length; index++) check = VERHOEFF_D[check][VERHOEFF_P[index % 8][Number(digits[digits.length - 1 - index])]];
  return check === 0;
}

// Each is a whole number on its own, not a run of digit groups inside a longer one.
/** US Social Security numbers, written with hyphens, in the ranges ever issued. */
const SSN = /(?<![\d-]|\d )(?!000|666|9\d\d)(\d{3})-(?!00)(\d{2})-(?!0000)(\d{4})(?![\d-]| \d)/g;
/** Aadhaar numbers, grouped in fours. */
const AADHAAR = /(?<![\d-]|\d )([2-9]\d{3})[ -](\d{4})[ -](\d{4})(?![\d-]| \d)/g;
/** Card numbers: sixteen digits in fours, or American Express's 4-6-5. */
const CARD = /(?<![\d-]|\d )(?:(\d{4})([ -])(\d{4})\2(\d{4})\2(\d{4})|(3[47]\d{2})([ -])(\d{6})\7(\d{5}))(?![\d-]| \d)/g;
const CARD_PREFIX = /^(?:4|5[1-5]|2[2-7]|3[47]|6011|65)/;

const HOME_ADDRESS = /\b(?:his|her|their)\s+(?:home\s+|house\s+)?address\s*(?:is|:|-)?\s*\d/i;
const PHONE = /\b(?:his|her|their)\s+(?:personal\s+|home\s+|mobile\s+|cell\s+)?(?:phone|mobile|cell)(?:\s+number)?\s*(?:is|:|-)?\s*\+?\d[\d\s().-]{6,}/i;

function hasPrivateDetails(texts: string[]): boolean {
  const text = texts.join("\n");
  const digitsOf = (match: RegExpMatchArray) => match[0].replace(/\D/g, "");
  for (const match of text.matchAll(SSN)) if (!EXAMPLES.has(digitsOf(match))) return true;
  for (const match of text.matchAll(AADHAAR)) if (verhoeff(digitsOf(match))) return true;
  for (const match of text.matchAll(CARD)) {
    const digits = digitsOf(match);
    if (CARD_PREFIX.test(digits) && luhn(digits) && !EXAMPLES.has(digits)) return true;
  }
  return HOME_ADDRESS.test(text) && PHONE.test(text);
}

/** Why a page can't be published, or null when it can. Only the page's own text is read; the
 * sharer's numbers and the web viewer's working are numbers worked out from it. */
export function checkPublish(shared: Shared): Refusal | null {
  const texts = prose(shared.surface as JsonObject, null, []);
  const concern: Concern | null = hasSlur(texts) ? "slur" : sexualizesChildren(texts) ? "minors" : hasPrivateDetails(texts) ? "private" : null;
  return concern ? { reason: concern, message: MESSAGES[concern] } : null;
}
