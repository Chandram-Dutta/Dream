// Checking the lists a page keeps, the blocks that show them, and charts of the user's entries
// (Dream/Engine/Checker+Lists.swift). Mistakes here are always fixed locally.

import { AGGREGATES, totals, tryParse } from "./formula.ts";
import { closestName, identifier, looksLikeMoney, words } from "./names.ts";
import { parseValue } from "./records.ts";
import { collection, dateField, field, isNumericField, makeBlock, recordCollections, titleField } from "./surface.ts";
import { characters, count, lower, split, trim, trimAll } from "./swift.ts";
import type { Block, Issue, RecordCollection, RecordField, RecordValue, Surface } from "./types.ts";

/** Names usable in formulas and unique, labels filled in, choices with real options, and starters
 * keyed by the fields they fill. */
export function checkCollections(surface: Surface): Issue[] {
  const collections = surface.collections;
  if (!collections || !collections.length) {
    delete surface.collections;
    return [];
  }
  const issues: Issue[] = [];
  const fixed = (message: string) => issues.push({ kind: "fixed", message });
  const taken = new Set([...surface.inputs.map((input) => input.name), ...surface.outputs.map((output) => output.name)]);
  const names = new Set<string>();
  const checked: RecordCollection[] = [];
  for (const original of collections.slice(0, 4)) {
    const list: RecordCollection = { ...original, fields: original.fields, starters: original.starters };
    list.name = identifier(list.name === "" ? list.label : list.name);
    if (list.name === "") {
      fixed("Dropped a list with no name.");
      continue;
    }
    if (taken.has(list.name)) {
      fixed(`Renamed the list '${list.name}' to '${list.name}List', since an input or output has its name.`);
      list.name += "List";
    }
    if (names.has(list.name)) {
      fixed(`Dropped a second list named '${list.name}'.`);
      continue;
    }
    names.add(list.name);
    list.label = trimAll(list.label);
    if (list.label === "") list.label = words(list.name);
    list.entry = lower(trimAll(list.entry));
    if (list.entry === "" || count(list.entry) > 30) list.entry = singular(lower(list.label));

    // Fields, remembering renames so starters stay with their fields.
    const renames = new Map<string, string>();
    const fieldNames = new Set<string>();
    const fields: RecordField[] = [];
    for (const originalField of original.fields.slice(0, 8)) {
      const item: RecordField = { ...originalField, options: [...originalField.options] };
      item.name = identifier(item.name === "" ? item.label : item.name);
      if (item.name === "" || fieldNames.has(item.name)) continue;
      fieldNames.add(item.name);
      renames.set(originalField.name, item.name);
      item.label = trimAll(item.label);
      if (item.label === "") item.label = words(item.name);
      if (item.type === "number" && looksLikeMoney(item.name + " " + item.label)) {
        item.type = "currency";
        fixed(`Showed '${list.name}.${item.name}' as money.`);
      }
      if (item.type === "choice") {
        const seen = new Set<string>();
        item.options = item.options.map(trim).filter((option) => {
          if (option === "" || seen.has(lower(option))) return false;
          seen.add(lower(option));
          return true;
        });
        if (item.options.length < 2) {
          fixed(`Made '${list.name}.${item.name}' text, since a choice needs at least two options.`);
          item.type = "text";
          item.options = [];
        }
      } else {
        item.options = [];
      }
      fields.push(item);
    }
    list.fields = fields;
    if (!list.fields.length) {
      list.fields = [{ name: "name", label: "Name", type: "text", options: [] }];
      fixed(`Gave '${list.name}' a name for each entry, since it had no fields.`);
    }

    // Starters: only known fields, each entry named, no repeats.
    const title = titleField(list);
    const titles = new Set<string>();
    const starters: Record<string, RecordValue>[] = [];
    for (const starter of original.starters.slice(0, 40)) {
      const values: Record<string, RecordValue> = {};
      for (const [name, value] of Object.entries(starter)) {
        const known = field(list, renames.get(name) ?? name);
        if (!known) continue;
        // Text is read again as the field's type; a number stays only in a field that adds up.
        const parsed = typeof value === "string" ? parseValue(known, value) : null;
        const kept = parsed ?? (isNumericField(known) ? value : null);
        if (kept !== null) values[known.name] = kept;
        else delete values[known.name];
      }
      if (title && title.type === "text") {
        const named = values[title.name];
        if (typeof named !== "string" || titles.has(lower(named))) continue;
        titles.add(lower(named));
      }
      if (Object.keys(values).length) starters.push(values);
    }
    list.starters = starters;
    checked.push(list);
  }
  if (checked.length) surface.collections = checked;
  else delete surface.collections;
  return issues;
}

/** A list or an add bar shows one collection. A near-miss name is read as the one it means; with
 * only one collection, that's the one. */
export function recordBlock(block: Block, surface: Surface): { keep: boolean; fix: string | null } {
  block.over = "";
  block.text = "";
  block.items = [];
  block.children = [];
  const kind = block.kind === "add" ? "bar for adding to" : "list of";
  const collections = recordCollections(surface);
  if (!collections.length) return { keep: false, fix: `Removed the ${kind} '${block.ref}', since the screen keeps no list.` };
  if (collection(surface, block.ref)) return { keep: true, fix: null };
  const wanted = split(block.ref, ".")[0] ?? "";
  const names = new Set(collections.map((item) => item.name));
  const match = collection(surface, wanted)?.name
    ?? closestName(wanted, names)
    ?? collections.find((item) => lower(item.label) === lower(wanted))?.name
    ?? (collections.length === 1 ? collections[0].name : null);
  if (match === null) return { keep: false, fix: `Removed the ${kind} '${block.ref}', which isn't a list.` };
  const fix = `Read the ${kind} '${block.ref}' as '${match}'.`;
  block.ref = match;
  return { keep: true, fix: block.ref === wanted ? null : fix };
}

/** A data block drawn from the user's entries: `ref` is what's measured and `over` what it runs
 * along or is compared by. False when the block isn't about a collection. */
export function boundData(block: Block, surface: Surface): boolean {
  const collections = recordCollections(surface);
  if (!collections.length || block.ref === "") return false;
  const parts = split(block.ref, ".", 1).map(trim);
  const names = new Set(collections.map((item) => item.name));
  const first = parts[0];
  if (first === undefined) return false;
  const name = collection(surface, first)?.name ?? closestName(first, names);
  const found = name === null ? undefined : collection(surface, name);
  if (!found) return false;
  let measured = found.name;
  if (parts.length === 2) {
    const numeric = new Set(found.fields.filter((item) => isNumericField(item) && item.type !== "date").map((item) => item.name));
    const fieldName = numeric.has(parts[1]) ? parts[1] : closestName(parts[1], numeric);
    if (fieldName === null) return false;
    measured += `.${fieldName}`;
  }
  const along = split(block.over, ".", 1).pop() ?? "";
  const groups = new Set(found.fields.filter((item) => ["date", "choice", "text"].includes(item.type)).map((item) => item.name));
  const over = groups.has(along)
    ? along
    : closestName(along, groups) ?? dateField(found)?.name ?? found.fields.find((item) => item.type === "choice")?.name ?? titleField(found)?.name;
  if (over === undefined) return false;
  block.ref = measured;
  block.over = `${found.name}.${over}`;
  block.text = "";
  block.items = [];
  block.children = [];
  return true;
}

function allBlocks(blocks: Block[]): Block[] {
  return blocks.flatMap((block) => [block, ...allBlocks(block.children)]);
}

/** Every collection is shown, and every list has a bar to add to it, just above it. A row is too
 * narrow for a list, so a row holding one becomes a section. */
export function placeLists(surface: Surface): Issue[] {
  if (!recordCollections(surface).length) return [];
  const issues: Issue[] = [];
  const ids = new Set(allBlocks(surface.blocks).map((block) => block.id));
  const uniqueID = (base: string) => {
    let id = base;
    let suffix = 2;
    while (ids.has(id)) {
      id = `${base}-${suffix}`;
      suffix += 1;
    }
    ids.add(id);
    return id;
  };
  const widened = (blocks: Block[]): Block[] =>
    blocks.map((block) => ({
      ...block,
      kind: block.kind === "row" && block.children.some((child) => child.kind === "list" || child.kind === "add") ? "section" : block.kind,
      children: widened(block.children),
    }));
  surface.blocks = widened(surface.blocks);

  const all = allBlocks(surface.blocks);
  const adding = new Set(all.filter((block) => block.kind === "add").map((block) => block.ref));
  const withAddBars = (blocks: Block[]): Block[] =>
    blocks.flatMap((original) => {
      const block = { ...original, children: withAddBars(original.children) };
      // A list a service fills is the service's to add to.
      const found = collection(surface, block.ref);
      if (block.kind !== "list" || adding.has(block.ref) || !found || found.source !== undefined) return [block];
      issues.push({ kind: "fixed", message: `Added a bar for adding to '${found.name}'.` });
      return [makeBlock(uniqueID(`${found.name}-add`), "add", { ref: found.name }), block];
    });
  surface.blocks = withAddBars(surface.blocks);

  const shown = new Set(all.filter((block) => block.kind === "list" || block.kind === "add").map((block) => block.ref));
  const missing = recordCollections(surface).filter((item) => !shown.has(item.name));
  if (missing.length) {
    // After the lists already shown; with none, after the main result if it leads, or else first.
    let lastList = -1;
    surface.blocks.forEach((block, index) => {
      if (allBlocks([block]).some((inner) => inner.kind === "list" || inner.kind === "add")) lastList = index;
    });
    const position = lastList >= 0 ? lastList + 1 : surface.blocks[0]?.kind === "hero" ? 1 : 0;
    const blocks = missing.flatMap((item) => [
      makeBlock(uniqueID(`${item.name}-add`), "add", { ref: item.name }),
      makeBlock(uniqueID(`${item.name}-list`), "list", { ref: item.name }),
    ]);
    surface.blocks.splice(Math.min(position, surface.blocks.length), 0, ...blocks);
    issues.push({ kind: "fixed", message: `Showed the lists ${missing.map((item) => `'${item.name}'`).join(", ")}.` });
  }
  return issues;
}

/** RecordChecker.field: a field by name, by label, or by a near miss. */
export function fieldNamed(raw: string, list: RecordCollection): RecordField | undefined {
  const exact = field(list, raw);
  if (exact) return exact;
  const wanted = lower(raw);
  const byLabel = list.fields.find((item) => lower(item.label) === wanted);
  if (byLabel) return byLabel;
  const match = closestName(identifier(raw), new Set(list.fields.map((item) => item.name)));
  return match === null ? undefined : field(list, match);
}

/** A list or field a formula means, part by part: `expences.amout` → `expenses.amount`. */
export function closestColumn(name: string, surface: Surface): string | null {
  const parts = split(name, ".", 1);
  const first = parts[0];
  if (first === undefined) return null;
  const collections = recordCollections(surface);
  // A plain name is only read as a list when it's clearly one, so a misspelt input isn't.
  const fuzzyName = parts.length === 2 ? closestName(first, new Set(collections.map((item) => item.name))) : null;
  const fuzzy = fuzzyName === null ? undefined : collection(surface, fuzzyName);
  const found = collection(surface, first) ?? fuzzy
    ?? collections.find((item) => [item.name, item.entry, item.label].map(lower).includes(lower(first)));
  if (!found) return null;
  if (parts.length !== 2) return found.name;
  const matched = fieldNamed(parts[1], found);
  return matched ? `${found.name}.${matched.name}` : null;
}

/** Whether any formula totals a list, even under a name that still needs repairing. */
export function totalsRecords(surface: Surface): boolean {
  const collections = new Set(recordCollections(surface).map((item) => lower(item.name)));
  if (!collections.size) return false;
  return surface.outputs.some((output) => {
    const expr = tryParse(output.formula);
    if (!expr) return false;
    return totals(expr).some((total) => AGGREGATES.has(total.function) && (total.name.includes(".") || collections.has(lower(total.name))));
  });
}

/** "Expenses" → "expense", roughly; only for naming an entry when the model didn't. */
function singular(word: string): string {
  const pieces = split(word, " ");
  const last = pieces.length ? pieces[pieces.length - 1] : word;
  const drop = (n: number) => characters(last).slice(0, -n).join("");
  const stem = last.endsWith("ies") ? drop(3) + "y"
    : last.endsWith("sses") || last.endsWith("shes") || last.endsWith("ches") ? drop(2)
    : last.endsWith("s") && !last.endsWith("ss") ? drop(1)
    : last;
  return stem === "" ? "entry" : stem;
}
