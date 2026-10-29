// Checks the server's page engine (src/engine) against the app's own (Dream/Engine), case by case:
// each model answer in test/golden/cases goes through what the composer does with it (reading it,
// then checkLogic, checkSourcing, checkCitations and checkBlocks), and every page, issue and line
// of shorthand must be what Tools/engine-golden.sh wrote from the Swift engine into
// test/golden/expected. Numbers may differ in their last digits; nothing else may.
//
//   node test/engine.mjs [name filter]

import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  addMolecules, addRecordings, checkBlocks, checkCitations, checkLogic, checkSourcing, hasLogic, isEmpty, isRepeatingItself, logicSummary, outline,
  parsePartial, surfaceFromPartial, surfaceFromWire, wireIsReadable, wireIsWhole,
} from "../src/engine/index.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "golden");
const filter = process.argv[2] ?? "";

/** The readers the cases are written for, as the app's Locale.current would be for each. */
const LOCALES = {
  en_US: { language: "en", region: "US", currency: "USD", currencySymbol: "$", measurementSystem: "ussystem" },
  en_IN: { language: "en", region: "IN", currency: "INR", currencySymbol: "₹", measurementSystem: "metric" },
  en_GB: { language: "en", region: "GB", currency: "GBP", currencySymbol: "£", measurementSystem: "uksystem" },
  de_DE: { language: "de", region: "DE", currency: "EUR", currencySymbol: "€", measurementSystem: "metric" },
  hi_IN: { language: "hi", region: "IN", currency: "INR", currencySymbol: "₹", measurementSystem: "metric" },
  ja_JP: { language: "ja", region: "JP", currency: "JPY", currencySymbol: "¥", measurementSystem: "metric" },
};

/** Plain JSON, as Swift would have encoded it: nothing undefined. */
const plainJSON = (value) => JSON.parse(JSON.stringify(value));

const facts = (surface) => ({
  isEmpty: isEmpty(surface), hasLogic: hasLogic(surface), isRepeatingItself: isRepeatingItself(surface),
  outline: outline(surface), logicSummary: logicSummary(surface),
});

/** What the TypeScript engine makes of a case, in the shape the Swift tool writes. */
function run(input, expected) {
  const result = {};
  const reference = input.reference ?? null;
  // A case that leaves properties out has them filled in by the Swift tool, which writes the answer it read.
  let wire = input.fill ? expected.content : input.wire ?? {};
  if (typeof input.text === "string") {
    const parsed = parsePartial(input.text);
    if (parsed === null) {
      result.decodes = { json: false };
      return result;
    }
    wire = parsed;
  }
  const whole = wireIsWhole(wire);
  const readable = wireIsReadable(wire);
  result.decodes = { json: true, whole, partial: readable };
  result.content = wire;
  const asWhole = whole && input.text === undefined && input.partial !== true;
  if (!asWhole && !readable) return result;
  const surface = asWhole ? surfaceFromWire(wire, reference) : surfaceFromPartial(wire, reference);
  result.converted = plainJSON(surface);
  result.convertedFacts = facts(surface);

  if (input.sources) {
    if (input.sources.length) surface.sources = structuredClone(input.sources);
    else delete surface.sources;
  }
  if (input.services) {
    if (input.services.length) surface.services = [...input.services];
    else delete surface.services;
  }
  const read = input.read ?? [];
  const locale = LOCALES[input.locale ?? "en_US"];
  if (!locale) throw new Error(`No reader for ${input.locale}; add one to LOCALES`);

  result.logic = { issues: checkLogic(surface, locale).issues, surface: plainJSON(surface) };
  result.sourcing = checkSourcing(surface, read);
  addRecordings(surface, new Map(Object.entries(input.recordings ?? {})));
  addMolecules(surface, new Map(Object.entries(input.molecules ?? {})));
  result.citations = { issues: checkCitations(surface, read).issues, surface: plainJSON(surface) };
  result.blocks = { issues: checkBlocks(surface, locale).issues, surface: plainJSON(surface) };
  result.final = facts(surface);
  return result;
}

/** Where two JSON values differ, or null. Numbers within a hair of each other are the same. */
function difference(expected, actual, path = "") {
  if (typeof expected === "number" && typeof actual === "number") {
    const close = expected === actual || Math.abs(expected - actual) <= 1e-9 * Math.max(1, Math.abs(expected), Math.abs(actual));
    return close ? null : `${path}: expected ${expected}, got ${actual}`;
  }
  if (Array.isArray(expected) || Array.isArray(actual)) {
    if (!Array.isArray(expected) || !Array.isArray(actual)) return `${path}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`;
    if (expected.length !== actual.length) {
      return `${path}: expected ${expected.length} items, got ${actual.length}\n      expected ${JSON.stringify(expected).slice(0, 600)}\n      got      ${JSON.stringify(actual).slice(0, 600)}`;
    }
    for (let index = 0; index < expected.length; index++) {
      const found = difference(expected[index], actual[index], `${path}[${index}]`);
      if (found) return found;
    }
    return null;
  }
  if (expected && actual && typeof expected === "object" && typeof actual === "object") {
    for (const key of new Set([...Object.keys(expected), ...Object.keys(actual)])) {
      if (!(key in expected)) return `${path}.${key}: not expected, got ${JSON.stringify(actual[key]).slice(0, 300)}`;
      if (!(key in actual)) return `${path}.${key}: missing, expected ${JSON.stringify(expected[key]).slice(0, 300)}`;
      const found = difference(expected[key], actual[key], `${path}.${key}`);
      if (found) return found;
    }
    return null;
  }
  if (expected === actual) return null;
  if (typeof expected === "string" && typeof actual === "string") {
    let at = 0;
    while (at < expected.length && expected[at] === actual[at]) at++;
    return `${path}: differs at character ${at}\n      expected …${JSON.stringify(expected.slice(Math.max(0, at - 40), at + 120))}\n      got      …${JSON.stringify(actual.slice(Math.max(0, at - 40), at + 120))}`;
  }
  return `${path}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`;
}

const SECTIONS = ["decodes", "content", "converted", "convertedFacts", "logic", "sourcing", "citations", "blocks", "final"];

let failures = 0;
let cases = 0;
console.log("The server's engine against the app's");
for (const file of readdirSync(join(root, "cases")).filter((name) => name.endsWith(".json") && name.includes(filter)).sort()) {
  const input = JSON.parse(readFileSync(join(root, "cases", file), "utf8"));
  let expected;
  try {
    expected = JSON.parse(readFileSync(join(root, "expected", file), "utf8"));
  } catch {
    console.log(`  FAIL  ${file}: no expected output; run Tools/engine-golden.sh`);
    failures++;
    continue;
  }
  cases++;
  let actual;
  try {
    actual = run(input, expected);
  } catch (error) {
    console.log(`  FAIL  ${file}: threw ${error?.stack ?? error}`);
    failures++;
    continue;
  }
  const problems = [];
  for (const section of SECTIONS) {
    if (!(section in expected) && !(section in actual)) continue;
    const found = difference(expected[section], actual[section], section);
    if (found) problems.push(found);
  }
  if (problems.length) {
    failures++;
    console.log(`  FAIL  ${file}`);
    for (const problem of problems) console.log(`        ${problem}`);
  } else {
    console.log(`  ok    ${file}`);
  }
}
if (!cases) {
  console.log("  FAIL  no cases");
  failures++;
}
console.log(failures ? `\n${failures} failed` : `\nAll ${cases} cases match`);
process.exit(failures ? 1 : 0);
