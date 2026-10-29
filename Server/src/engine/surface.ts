// What a page knows about itself (Dream/Engine/Surface.swift, Evaluation.swift, Records.swift,
// Formula+Records.swift, Live.swift): finding its inputs, outputs and lists by name, working out
// the calculation, and which inputs feed which results. Pages are plain JSON objects, the shape
// the app's Swift types encode.

import { AGGREGATES, CONSTANTS, FormulaError, aggregate, call, describe, describeError, evaluate as evaluateExpr, name as nameExpr, names, parseCached, totals as totalsOf, tryParse } from "./formula.ts";
import { lower, split, trim } from "./swift.ts";
import type { Block, BlockKind, Entry, Format, Input, RecordCollection, RecordField, RecordValue, Surface } from "./types.ts";

/** A deep copy, as Swift's value types copy on assignment. */
export function copy<T>(value: T): T {
  return structuredClone(value);
}

export function makeBlock(id: string, kind: BlockKind, fields: Partial<Block> = {}): Block {
  return { id, kind, title: "", text: "", ref: "", over: "", items: [], children: [], ...fields };
}

// MARK: - Kinds and formats

const CONTROLS = new Set<BlockKind>(["slider", "stepper", "field", "toggle", "picker"]);
const INFORMATION = new Set<BlockKind>(["paragraph", "facts", "bullets", "steps", "timeline", "stat", "equation", "data", "diagram"]);

export const isContainer = (kind: BlockKind) => kind === "section" || kind === "row";
export const isControl = (kind: BlockKind) => CONTROLS.has(kind);
export const isInformation = (kind: BlockKind) => INFORMATION.has(kind);
export const isNumeric = (format: Format) => format !== "toggle" && format !== "choice";
export const isMeasured = (format: Format) => format === "number" || format === "integer";

/** Whether a control suits a format. */
export function fits(kind: BlockKind, format: Format): boolean {
  switch (kind) {
    case "toggle": return format === "toggle";
    case "picker": return format === "choice";
    case "slider": case "stepper": case "field": return isNumeric(format);
    default: return false;
  }
}

/** The control to use when the model hasn't picked one, or picked one that doesn't fit. */
export function defaultControl(input: Input): BlockKind {
  switch (input.format) {
    case "toggle": return "toggle";
    case "choice": return "picker";
    case "integer": return input.step > 0 && (input.max - input.min) / input.step <= 20 ? "stepper" : "slider";
    case "currency": case "number": return input.step > 0 && (input.max - input.min) / input.step > 2000 ? "field" : "slider";
    case "percent": return "slider";
  }
}

/** Shown with its value, never set: a known fact, or a live value. */
export const isFixed = (input: Input) => input.role === "given" || input.role === "live";

/** A range that's always safe to draw. */
export function safeRange(input: Input): [number, number] {
  if (!(Number.isFinite(input.min) && Number.isFinite(input.max) && input.min < input.max)) return [0, 1];
  return [input.min, input.max];
}

/** The names in a block's `ref`. */
export function refs(block: Block): string[] {
  return block.ref.split(",").map(trim).filter((name) => name !== "");
}

// MARK: - Finding things

export const input = (surface: Surface, name: string) => surface.inputs.find((input) => input.name === name);
export const output = (surface: Surface, name: string) => surface.outputs.find((output) => output.name === name);
export const sound = (surface: Surface, name: string) => surface.sounds?.find((sound) => sound.name === name);
export const recordCollections = (surface: Surface) => surface.collections ?? [];
export const collection = (surface: Surface, name: string) => surface.collections?.find((collection) => collection.name === name);
export const field = (collection: RecordCollection, name: string) => collection.fields.find((field) => field.name === name);
export const liveSources = (surface: Surface) => surface.sources ?? [];
export const liveInputs = (surface: Surface) => surface.inputs.filter((input) => input.role === "live");
export const adjustableInputs = (surface: Surface) => surface.inputs.filter((input) => input.role === "adjustable");

export const hasLogic = (surface: Surface) => surface.inputs.length > 0 || surface.outputs.length > 0;
export const isEmpty = (surface: Surface) => surface.title === "" && surface.summary === "" && surface.blocks.length === 0 && !hasLogic(surface);

export function hasInformation(surface: Surface): boolean {
  return surface.blocks.some((block) => isInformation(block.kind) || block.children.some((child) => isInformation(child.kind)));
}

/** Shows live values without calculating anything, so it needs no results. */
export function showsLiveValues(surface: Surface): boolean {
  return liveInputs(surface).length > 0 && surface.inputs.every(isFixed);
}

/** A binding's two halves: `weather.rainChance` is the field rainChance of the source weather. */
export function binding(input: Input): { source: string; field: string } | null {
  const parts = split(input.source, ".", 1).map(trim);
  if (parts.length !== 2 || parts[0] === "" || parts[1] === "") return null;
  return { source: parts[0], field: parts[1] };
}

/** The source and list that fill a collection: searchNotes.notes. */
export function listSource(collection: RecordCollection): { source: string; list: string } | null {
  if (collection.source === undefined) return null;
  const parts = split(collection.source, ".", 1).map(trim);
  if (parts.length !== 2 || parts[0] === "" || parts[1] === "") return null;
  return { source: parts[0], list: parts[1] };
}

export function collectionLabel(surface: Surface, name: string): string | undefined {
  const parts = split(name, ".", 1);
  const found = parts.length ? collection(surface, parts[0]) : undefined;
  if (!found) return undefined;
  if (parts.length !== 2) return found.label;
  return field(found, parts[1])?.label;
}

export function label(surface: Surface, name: string): string {
  return input(surface, name)?.label ?? output(surface, name)?.label ?? sound(surface, name)?.label ?? collectionLabel(surface, name) ?? name;
}

export function initialValues(surface: Surface): Map<string, number> {
  const values = new Map<string, number>();
  for (const input of surface.inputs) if (!values.has(input.name)) values.set(input.name, input.initial);
  return values;
}

/** Every input and output a block and what it holds refer to, and what charts run along. */
export function refsIn(blocks: Block[], into = new Set<string>()): Set<string> {
  for (const block of blocks) {
    for (const name of refs(block)) into.add(name);
    if (block.kind === "chart" && block.over !== "") into.add(block.over);
    refsIn(block.children, into);
  }
  return into;
}

/** The blocks, plus a plain arrangement of any calculation they don't show yet (Surface.visibleBlocks). */
export function visibleBlocks(surface: Surface): Block[] {
  if (!hasLogic(surface)) return surface.blocks;
  const placed = refsIn(surface.blocks);
  const extra: Block[] = [];
  const main = surface.outputs[0];
  if (main && !placed.has(main.name)) extra.push(makeBlock("auto-hero", "hero", { ref: main.name }));
  const controls = surface.inputs
    .map((input, index) => ({ input, index }))
    .filter(({ input }) => !placed.has(input.name) && input.role === "adjustable")
    .map(({ input, index }) => makeBlock(`auto-input-${index}`, defaultControl(input), { ref: input.name }));
  if (controls.length) extra.push(makeBlock("auto-inputs", "section", { children: controls }));
  const results = surface.outputs
    .map((output, index) => ({ output, index }))
    .slice(1)
    .filter(({ output }) => !placed.has(output.name))
    .map(({ output, index }) => makeBlock(`auto-output-${index}`, "metric", { ref: output.name }));
  if (results.length) extra.push(makeBlock("auto-outputs", "section", { children: results }));
  return [...surface.blocks, ...extra];
}

// MARK: - Lists

/** What names an entry: the first text field, or else the first field. */
export const titleField = (collection: RecordCollection) => collection.fields.find((field) => field.type === "text") ?? collection.fields[0];
export const dateField = (collection: RecordCollection) => collection.fields.find((field) => field.type === "date");
export const isNumericField = (field: RecordField) => ["number", "currency", "rating", "done", "date"].includes(field.type);

/** Names formulas can use for lists: each collection and each of its fields. */
export function columnNames(surface: Surface): Set<string> {
  const result = new Set<string>();
  for (const collection of recordCollections(surface)) {
    result.add(collection.name);
    for (const field of collection.fields) result.add(`${collection.name}.${field.name}`);
  }
  return result;
}

function entryDate(entry: Entry, field: string): number {
  const value = entry.values.get(field);
  return typeof value === "number" ? value : entry.created;
}

/** Oldest first, so `last()` is the latest: by date in a log, otherwise as added. */
function chronological(collection: RecordCollection, entries: Entry[]): Entry[] {
  const date = dateField(collection);
  if (date) {
    return [...entries].sort((a, b) => {
      const [x, y] = [entryDate(a, date.name), entryDate(b, date.name)];
      return x !== y ? x - y : a.created - b.created;
    });
  }
  return [...entries].sort((a, b) => a.created - b.created);
}

/** A list's values as numbers, oldest first. Null when the name isn't a list. */
export function column(surface: Surface, name: string, records: Map<string, Entry[]>): number[] | null {
  const parts = split(name, ".", 1);
  const found = parts.length ? collection(surface, parts[0]) : undefined;
  if (!found) return null;
  const entries = chronological(found, records.get(found.name) ?? []);
  if (parts.length !== 2) return entries.map(() => 1);
  const wanted = field(found, parts[1]);
  if (!wanted) return null;
  const values: number[] = [];
  for (const entry of entries) {
    const value = entry.values.get(wanted.name);
    if (wanted.type === "done") {
      values.push((typeof value === "number" ? value : 0) !== 0 ? 1 : 0);
    } else if (typeof value === "number") {
      values.push(value);
    } else if (typeof value === "string") {
      if (value !== "") values.push(1);
    }
  }
  return values;
}

/** What a new entry starts with when nothing's given. */
function sample(field: RecordField, now: number): RecordValue {
  switch (field.type) {
    case "text": return "Sample";
    case "number": case "currency": case "done": return 1;
    case "rating": return 3;
    case "date": return now;
    case "choice": return field.options[0] ?? "";
  }
}

/** One entry with every field filled, for each collection, so the checker can see whether totals work. */
export function sampleRecords(surface: Surface): Map<string, Entry[]> {
  const now = Date.now() / 1000;
  const result = new Map<string, Entry[]>();
  for (const collection of recordCollections(surface)) {
    if (result.has(collection.name)) continue;
    const values = new Map<string, RecordValue>();
    for (const field of collection.fields) if (!values.has(field.name)) values.set(field.name, sample(field, now));
    result.set(collection.name, [{ values, order: 0, created: now }]);
  }
  return result;
}

/** Each total in the formulas with its value, keyed as it's written: `sum(expenses.amount)`. */
export function totals(surface: Surface, records: Map<string, Entry[]>): Map<string, number> {
  const values = new Map<string, number>();
  for (const output of surface.outputs) {
    const expr = tryParse(output.formula);
    if (!expr) continue;
    for (const total of totalsOf(expr)) {
      const found = column(surface, total.name, records);
      if (found === null) continue;
      let value: number;
      try {
        value = aggregate(total.function, found);
      } catch {
        continue;
      }
      values.set(describe(call(total.function, [nameExpr(total.name)])), value);
    }
  }
  return values;
}

/** The collections an output totals, directly or through other outputs. */
export function collectionsFeeding(surface: Surface, start: string): Set<string> {
  const seen = new Set<string>();
  const found = new Set<string>();
  const walk = (name: string) => {
    if (seen.has(name)) return;
    seen.add(name);
    const formula = output(surface, name);
    const expr = formula ? tryParse(formula.formula) : null;
    if (!expr) return;
    for (const total of totalsOf(expr)) {
      const first = split(total.name, ".")[0];
      if (first !== undefined && collection(surface, first)) found.add(first);
    }
    for (const next of names(expr)) walk(next);
  };
  walk(start);
  return found;
}

// MARK: - Working it out

export interface Evaluation {
  /** Inputs and outputs by name. Outputs that couldn't be calculated are NaN. */
  values: Map<string, number>;
  errors: Map<string, string>;
}

/** Surface.evaluate: `records` are the user's entries, for totals like `sum(expenses.amount)`. */
export function evaluate(surface: Surface, given: Map<string, number>, records: Map<string, Entry[]> = new Map()): Evaluation {
  const values = new Map<string, number>();
  for (const input of surface.inputs) if (!values.has(input.name)) values.set(input.name, given.get(input.name) ?? input.initial);
  const formulas = new Map<string, string>();
  for (const output of surface.outputs) if (!formulas.has(output.name)) formulas.set(output.name, output.formula);
  const errors = new Map<string, string>();
  const resolving = new Set<string>();
  const columns = new Map<string, number[] | null>();
  let listNames: Set<string> | undefined;

  const columnOf = (name: string): number[] | null => {
    if (columns.has(name)) {
      const known = columns.get(name);
      if (known) return known;
    }
    const found = column(surface, name, records);
    columns.set(name, found);
    return found;
  };

  const resolve = (name: string): number => {
    const known = values.get(name);
    if (known !== undefined) return known;
    const formula = formulas.get(name);
    if (formula === undefined) {
      const constant = CONSTANTS.get(name);
      if (constant !== undefined) return constant;
      listNames ??= columnNames(surface);
      if (listNames.has(name)) throw new FormulaError(`'${name}' is a list; total it with sum(${name}), avg, min, max, count or last`);
      throw new FormulaError(`'${name}' isn't an input or output`);
    }
    if (resolving.has(name)) throw new FormulaError(`'${name}' depends on itself`);
    resolving.add(name);
    try {
      const value = evaluateExpr(parseCached(formula), resolve, columnOf);
      values.set(name, value);
      return value;
    } finally {
      resolving.delete(name);
    }
  };

  for (const output of surface.outputs) {
    if (values.has(output.name)) continue;
    try {
      resolve(output.name);
    } catch (error) {
      errors.set(output.name, describeError(error));
      values.set(output.name, NaN);
    }
  }
  // Each total too, so an equation worked through with live numbers can show it.
  if (recordCollections(surface).length) {
    for (const [key, value] of totals(surface, records)) if (!values.has(key)) values.set(key, value);
  }
  return { values, errors };
}

/** Every input an output depends on, directly or through other outputs. */
export function inputsFeeding(surface: Surface, start: string): Set<string> {
  const seen = new Set<string>();
  const found = new Set<string>();
  const walk = (name: string) => {
    if (seen.has(name)) return;
    seen.add(name);
    if (input(surface, name)) {
      found.add(name);
      return;
    }
    const formula = output(surface, name);
    const expr = formula ? tryParse(formula.formula) : null;
    if (!expr) return;
    for (const next of names(expr)) walk(next);
  };
  walk(start);
  return found;
}

/** Whether a name is one of the functions that total a list. */
export const isAggregate = (fn: string) => AGGREGATES.has(fn);

/** Lowercased, for comparing names. */
export const lowered = lower;
