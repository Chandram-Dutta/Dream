// Reading a list's values from text (Dream/Engine/Records.swift, RecordField.parse), as the model
// writes a starter: "₹1,200", "2026-10-26", "yes", "Food", "4".
//
// Not ported: the app also finds dates the system's date detector reads in free text, like
// "Oct 26"; here only ISO days and today, yesterday and tomorrow are read, at noon UTC.

import { closestName, identifier } from "./names.ts";
import { characters, double, lower, round, trimAll } from "./swift.ts";
import type { RecordField, RecordValue } from "./types.ts";

/** The first number in some text, so "₹1,200.50" reads as 1200.5 and "4,5" as 4.5. */
export function numberIn(text: string): number | null {
  const cleaned = text.replace(/(\p{Nd}),(\p{Nd}{3})(?!\p{Nd})/gu, "$1$2");
  const match = cleaned.match(/-?\p{Nd}+(?:[.,]\p{Nd}+)?/u);
  if (!match) return null;
  return double(match[0].replaceAll(",", "."));
}

const DAY = 86_400;

/** A date in some text: ISO days and the usual relative words. Seconds since 1970. */
export function dateIn(text: string, now = Date.now() / 1000): number | null {
  const lowered = trimAll(lower(text));
  const noon = Math.floor(now / DAY) * DAY + 12 * 3600;
  switch (lowered) {
    case "today": case "now": case "": return now;
    case "yesterday": return noon - DAY;
    case "tomorrow": return noon + DAY;
  }
  const match = characters(lowered).slice(0, 10).join("").match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (match) {
    const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
    const date = new Date(Date.UTC(year, month - 1, day, 12));
    // DateFormatter reads only real days.
    if (date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day) return date.getTime() / 1000;
  }
  return null;
}

/** The option this text means: the same words, or close enough. */
export function optionMatching(field: RecordField, text: string): string | null {
  const wanted = lower(trimAll(text));
  if (wanted === "") return null;
  const exact = field.options.find((option) => lower(option) === wanted);
  if (exact !== undefined) return exact;
  const keyed = new Map<string, string>();
  for (const option of field.options) {
    const key = identifier(option);
    if (!keyed.has(key)) keyed.set(key, option);
  }
  const match = closestName(identifier(wanted), keyed.keys());
  return match === null ? null : keyed.get(match) ?? null;
}

const YES = new Set(["yes", "true", "done", "1", "y", "x", "✓", "✔", "checked", "on", "packed", "bought"]);
const NO = new Set(["no", "false", "0", "n", "", "off", "not done", "unchecked"]);

/** RecordField.parse: a value from text, or null when it isn't one for this field. */
export function parseValue(field: RecordField, raw: string): RecordValue | null {
  const text = trimAll(raw);
  switch (field.type) {
    case "text": return text === "" ? null : text;
    case "number": case "currency": return numberIn(text);
    case "rating": {
      const stars = characters(text).filter((character) => character === "★" || character === "⭐").length;
      const value = stars > 0 ? stars : numberIn(text);
      return value === null ? null : Math.min(Math.max(round(value), 1), 5);
    }
    case "done": {
      const word = lower(text);
      if (YES.has(word)) return 1;
      if (NO.has(word)) return 0;
      return null;
    }
    case "date": return dateIn(text);
    case "choice": return optionMatching(field, text);
  }
}
