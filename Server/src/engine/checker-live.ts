// Checking live inputs, sources and actions (Dream/Engine/Checker+Live.swift), and lists a
// connected service fills (Live+Connections.swift's checkServiceLists). Bindings are part of the
// calculation, so a live input that names no field goes back to the model; actions, like blocks,
// are always fixed locally.

import { CONSTANTS, names as namesIn, tryParse, usesKnownFunctions } from "./formula.ts";
import { closestName, identifier } from "./names.ts";
import { binding, isMeasured, isNumeric, liveInputs, liveSources, makeBlock } from "./surface.ts";
import { characters, count, lower, sorted, split, trim, trimAll } from "./swift.ts";
import { join, parts } from "./tex.ts";
import type { Action, Block, Input, Issue, SourceField, Surface } from "./types.ts";
import { LiveUnits } from "./units.ts";

/** The value in another unit of the same kind, or null when the two don't convert. */
function converted(field: SourceField, target: string): number | null {
  if (target === "" || target === field.unit) return field.value;
  return LiveUnits.convert(field.value, field.unit, target);
}

/** Binds each live input to a field its sources read, and gives it the field's value, format and
 * unit: the model never types a live number. */
export function checkLive(surface: Surface): Issue[] {
  const issues: Issue[] = [];
  const fixed = (message: string) => issues.push({ kind: "fixed", message });
  const problem = (message: string) => issues.push({ kind: "needsModel", message });

  // Every field, by its full name: weather.rainChance.
  const fields = new Map<string, SourceField>();
  for (const source of liveSources(surface)) for (const item of source.fields) fields.set(`${source.name}.${item.name}`, item);
  const names = new Set(fields.keys());
  const byField = new Map<string, string[]>();
  for (const name of sorted(names)) {
    const pieces = split(name, ".");
    const last = pieces[pieces.length - 1];
    if (last !== undefined) byField.set(last, [...(byField.get(last) ?? []), name]);
  }

  /** The field an input means: as written, a near miss, or the only field with the name it gives,
   * or its own name. A field's name alone must match outright: rain isn't rate. */
  const bound = (input: Input): string | null => {
    const written = trim(input.source);
    if (names.has(written)) return written;
    if (written.includes(".")) {
      const match = closestName(written, names);
      if (match !== null) return match;
    }
    const letters = (text: string) => characters(lower(text)).filter((character) => /^\p{Alphabetic}/u.test(character)).join("");
    const pieces = split(written, ".");
    for (const candidate of [pieces[pieces.length - 1] ?? "", input.name]) {
      if (candidate === "") continue;
      const matches = [...byField].filter(([key]) => letters(key) === letters(candidate)).flatMap(([, value]) => value);
      if (matches.length === 1) return matches[0];
    }
    return null;
  };

  for (const input of surface.inputs) {
    if (input.role !== "live") {
      if (input.source === "") continue;
      const full = bound(input);
      if (input.role === "given" && full !== null) {
        input.role = "live";
        fixed(`Made '${input.name}' live, since it shows ${full}.`);
      } else {
        // A what-if the user changes starts where things are now.
        const item = full === null ? undefined : fields.get(full);
        if (input.role === "adjustable" && item && isNumeric(input.format)) {
          const value = converted(item, input.unit) ?? item.value;
          input.initial = value;
          input.min = Math.min(input.min, value);
          input.max = Math.max(input.max, value);
        }
        input.source = "";
        continue;
      }
    }
    const full = bound(input);
    const item = full === null ? undefined : fields.get(full);
    if (full === null || !item) {
      if (!liveSources(surface).length) {
        problem(`'${input.name}' is live, but nothing was fetched for it. Fetch it with the live tool and set its source to a field the tool names, or make it a given if it's a fixed fact.`);
      } else {
        problem(`'${input.name}' is live, but '${input.source}' isn't a field the live tool returned. Set its source to one of ${sorted(names).join(", ")}, or fetch what it needs with the live tool.`);
      }
      continue;
    }
    if (input.source !== "" && input.source !== full) fixed(`Read the source of '${input.name}' as ${full}.`);
    input.source = full;
    // It reads as what the field is: a chance as a percentage, a temperature in degrees.
    if (!(isMeasured(item.format) && isMeasured(input.format))) input.format = item.format;
    if (isMeasured(item.format)) {
      if (input.unit === "" || converted(item, input.unit) === null) input.unit = LiveUnits.local(item.value, item.unit).unit;
    } else {
      input.unit = "";
    }
    input.initial = converted(item, input.unit) ?? item.value;
  }
  return issues;
}

// MARK: - Days and times

const WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

/** Whether LiveDay.date reads a day: today, tomorrow, a weekday, the weekend, "in 3 days" or YYYY-MM-DD. */
export function readsDay(text: string): boolean {
  let words = trimAll(lower(text));
  for (const start of ["this ", "next ", "coming ", "on "]) if (words.startsWith(start)) words = words.slice(start.length);
  if (["", "today", "tonight", "now", "this evening", "this morning", "this afternoon", "tomorrow", "day after tomorrow", "the day after tomorrow", "weekend"].includes(words)) {
    return true;
  }
  if (/^in (\d{1,2}) days?$/u.test(words)) return true;
  const short = characters(words).slice(0, 3).join("");
  if (WEEKDAYS.some((day) => day === words || (day.slice(0, 3) === short && count(words) >= 3 && day.startsWith(words)))) return true;
  return /^(\d{4})-(\d{1,2})-(\d{1,2})$/u.test(words);
}

/** LiveDay.minutes: minutes after midnight for 16:00, 4 pm, 4:30pm or 16. Null if it isn't one. */
export function minutes(text: string): number | null {
  const words = trim(lower(text).replaceAll(".", ""));
  if (words === "noon" || words === "midday") return 12 * 60;
  const match = words.match(/^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$/u);
  if (!match) return null;
  let hour = Number(match[1]);
  const minute = match[2] === undefined ? 0 : Number(match[2]);
  if (match[3] === "pm" && hour < 12) hour += 12;
  else if (match[3] === "am" && hour === 12) hour = 0;
  if (!(hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59)) return null;
  return hour * 60 + minute;
}

/** How someone's getting there, as directions write it. */
function travel(text: string): string {
  const words = lower(text);
  return words.includes("walk") || words.includes("foot") ? "walking"
    : ["transit", "train", "bus", "metro", "public"].some((word) => words.includes(word)) ? "transit"
    : "driving";
}

const TIMING = new Set(["day", "time", "duration"]);

/** Sources no live input shows are dropped. Then each action is tidied: its name, the `{name}`s in
 * its text, and its day, time and length, which must be readable. */
export function checkActions(surface: Surface): Issue[] {
  const issues: Issue[] = [];
  const fixed = (message: string) => issues.push({ kind: "fixed", message });

  const used = new Set(liveInputs(surface).map(binding).filter((item) => item !== null).map((item) => item.source));
  const unused = liveSources(surface).filter((source) => !used.has(source.name));
  if (unused.length) {
    const kept = liveSources(surface).filter((source) => used.has(source.name));
    if (kept.length) surface.sources = kept;
    else delete surface.sources;
    fixed(`Dropped the source${unused.length === 1 ? "" : "s"} ${unused.map((source) => `'${source.name}'`).join(", ")}, which nothing shows.`);
  }

  const original = surface.actions;
  if (!original) return issues;
  const values = new Set([...surface.inputs.map((input) => input.name), ...surface.outputs.map((output) => output.name)]);
  const taken = new Set([...values, ...(surface.sounds ?? []).map((sound) => sound.name)]);

  const formula = (text: string): boolean => {
    const expr = tryParse(text);
    if (!expr || !usesKnownFunctions(expr)) return false;
    for (const name of namesIn(expr)) if (!CONSTANTS.has(name) && !values.has(name)) return false;
    return true;
  };
  /** `{name}`s the calculation can fill; others are dropped. */
  const cleaned = (text: string) => trimAll(join(parts(text).filter((part) => !("name" in part) || values.has(part.name))));

  const names = new Set<string>();
  const actions: Action[] = [];
  for (const candidate of original) {
    const action: Action = { name: candidate.name, kind: candidate.kind, fields: { ...candidate.fields } };
    const get = (key: string) => action.fields[key] ?? "";
    action.name = identifier(action.name === "" ? action.kind : action.name);
    if (action.name === "") {
      fixed("Dropped an action with no name.");
      continue;
    }
    if (taken.has(action.name)) action.name += "Action";
    if (names.has(action.name)) {
      fixed(`Dropped a second action named '${action.name}'.`);
      continue;
    }
    names.add(action.name);
    for (const [key, value] of Object.entries(candidate.fields)) {
      const tidy = TIMING.has(key) ? trimAll(value) : cleaned(value);
      if (tidy === "") delete action.fields[key];
      else action.fields[key] = tidy;
    }

    let dropped = false;
    switch (action.kind) {
      case "calendarEvent":
      case "reminder": {
        if (get("title") === "") action.fields.title = surface.title;
        // An event is on a day; the button says which before anything's added.
        if (action.kind === "calendarEvent" && get("day") === "") action.fields.day = "today";
        const day = get("day");
        if (day !== "" && !readsDay(day)) {
          fixed(`Dropped the action '${action.name}', whose day can't be read: ${day}.`);
          dropped = true;
          break;
        }
        const time = get("time");
        if (time !== "" && minutes(time) === null && !formula(time)) {
          delete action.fields.time;
          fixed(`Made '${action.name}' last all day, since its time can't be read: ${time}.`);
        }
        if (action.kind === "calendarEvent") {
          const duration = get("duration");
          if (get("time") === "") delete action.fields.duration;
          else if (duration === "" || !formula(duration)) action.fields.duration = "60";
        } else {
          delete action.fields.duration;
        }
        break;
      }
      case "directions":
        if (get("place") === "") {
          if (get("title") === "") delete action.fields.place;
          else action.fields.place = get("title");
        }
        if (get("place") === "") {
          fixed(`Dropped the action '${action.name}', which doesn't say where to.`);
          dropped = true;
          break;
        }
        action.fields.travel = travel(get("travel"));
        break;
      default:
        // Another performer's, like a connected service's: it checks its own fields.
        break;
    }
    if (!dropped) actions.push(action);
  }
  if (actions.length) surface.actions = actions;
  else delete surface.actions;
  return issues;
}

/** An action block shows one action: a near miss is read as the action it means, and with only one
 * action, a block naming none shows that. The button says what it does, so no heading. */
export function actionBlock(original: Block, surface: Surface, fixed: (message: string) => void): Block | null {
  const block: Block = { ...original, title: "", over: "", text: "", items: [], children: [] };
  const names = new Set((surface.actions ?? []).map((action) => action.name));
  if (names.has(block.ref)) return block;
  const match = closestName(block.ref, names) ?? (names.size === 1 && block.ref === "" ? [...names][0] : null);
  if (match !== null) {
    block.ref = match;
    return block;
  }
  fixed(`Removed an action block for '${block.ref}', which isn't an action.`);
  return null;
}

/** Every action has one button. One that no block shows gets a block of its own at the end; a row
 * holding a button becomes a section. */
export function placeActions(surface: Surface): Issue[] {
  const actions = surface.actions;
  if (!actions) return [];
  const issues: Issue[] = [];
  const placed = new Set<string>();
  const deduplicated = (blocks: Block[]): Block[] =>
    blocks.flatMap((original) => {
      if (original.kind === "action") {
        if (placed.has(original.ref)) {
          issues.push({ kind: "fixed", message: `Removed a second button for '${original.ref}'.` });
          return [];
        }
        placed.add(original.ref);
        return [original];
      }
      const block = { ...original, children: deduplicated(original.children) };
      if (block.kind === "row" && block.children.some((child) => child.kind === "action")) block.kind = "section";
      if ((block.kind === "section" || block.kind === "row") && !block.children.length) return [];
      return [block];
    });
  surface.blocks = deduplicated(surface.blocks);

  const ids = (blocks: Block[]): string[] => blocks.flatMap((block) => [block.id, ...ids(block.children)]);
  const taken = new Set(ids(surface.blocks));
  for (const action of actions) {
    if (placed.has(action.name)) continue;
    let id = `${action.name}-action`;
    while (taken.has(id)) id += "-2";
    taken.add(id);
    surface.blocks.push(makeBlock(id, "action", { ref: action.name }));
    issues.push({ kind: "fixed", message: `Added a button for '${action.name}'.` });
  }
  return issues;
}

/** A collection a service's list fills must name a list a source read; a near miss is read as the
 * list it means. Its entries are the service's, so it has no starters and no bar to add to it. */
export function checkServiceLists(surface: Surface): Issue[] {
  const collections = surface.collections;
  if (!collections || !collections.some((item) => item.source !== undefined)) return [];
  const issues: Issue[] = [];
  const lists = new Set(liveSources(surface).flatMap((source) => (source.lists ?? []).map((list) => `${source.name}.${list.name}`)));
  for (const item of collections) {
    if (item.source === undefined) continue;
    const written = trim(item.source);
    if (written === "") {
      delete item.source;
      continue;
    }
    if (!lists.has(written)) {
      const match = closestName(written, lists);
      if (match !== null) {
        item.source = match;
        issues.push({ kind: "fixed", message: `Filled '${item.name}' from ${match}, for ${written}.` });
      } else {
        const named = lists.size ? `Lists a service returned: ${sorted(lists).join(", ")}.` : "No service returned a list.";
        issues.push({
          kind: "needsModel",
          message: `The list '${item.name}' is filled from ${written}, which no connected service returned. ${named} Leave its source empty for a list the user keeps.`,
        });
        continue;
      }
    }
    if (item.starters.length) {
      item.starters = [];
      issues.push({ kind: "fixed", message: `Took the starters out of '${item.name}', which a service fills.` });
    }
  }
  const filled = new Set(collections.filter((item) => item.source !== undefined).map((item) => item.name));
  const withoutBars = (blocks: Block[]): Block[] =>
    blocks.flatMap((block) => {
      if (block.kind === "add" && filled.has(block.ref)) {
        issues.push({ kind: "fixed", message: `Removed the bar for adding to '${block.ref}', which a service fills.` });
        return [];
      }
      return [{ ...block, children: withoutBars(block.children) }];
    });
  surface.blocks = withoutBars(surface.blocks);
  return issues;
}
