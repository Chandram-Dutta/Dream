// Checks a generated page before it's shown (Dream/Engine/Checker.swift): it fixes what it can
// on its own and reports the rest, so the model only spends a repair round on real mistakes.
// Messages are the app's, word for word, since they go back to the model.
//
// Like the Swift, these change the page they're given and return what they found.

import { checkActions, actionBlock, checkLive, checkServiceLists, placeActions } from "./checker-live.ts";
import { boundData, checkCollections, closestColumn, placeLists, recordBlock, totalsRecords } from "./checker-lists.ts";
import { checkFigures, figureAxes, figureFormulas, placeVisuals, visual } from "./checker-figures.ts";
import { checkScenes, drivesScenes, placeScenes, sceneAxes, sceneBlock, sceneFormulas } from "./checker-scenes.ts";
import { checkSounds, placeSounds, soundBlock } from "./checker-sounds.ts";
import { checkUnits, removeRepeatedUnits } from "./checker-units.ts";
import { checkCitations } from "./citations.ts";
import { CONSTANTS, describe, describeError, FUNCTIONS, functionNames, names as namesIn, parse, renamed, tryParse, type Expr } from "./formula.ts";
import { closestName, identifier, looksLikeMoney, niceStep, words } from "./names.ts";
import {
  adjustableInputs, collectionsFeeding, columnNames, copy, defaultControl, evaluate, fits, hasLogic, initialValues, input, inputsFeeding, isContainer,
  isControl, isFixed, isNumeric, makeBlock, output, refs, refsIn, sampleRecords, showsLiveValues,
} from "./surface.ts";
import { characters, count, double, isLetter, lower, max, min, plain, round, sorted, trim, trimAll, upper } from "./swift.ts";
import { displayMath, join, parts, prose, segments, texSymbol } from "./tex.ts";
import type { Block, Input, Issue, Surface } from "./types.ts";
import { Currency } from "./units.ts";

// MARK: - The calculation

/** Checker.checkLogic: names, formats, units, live values, ranges and formulas. */
export function checkLogic(surface: Surface): Issue[] {
  // Collections first: formulas can total them.
  const listIssues = checkCollections(surface);
  if (!hasLogic(surface)) return listIssues;
  const issues: Issue[] = [...listIssues];
  const fixed = (message: string) => issues.push({ kind: "fixed", message });
  const problem = (message: string) => issues.push({ kind: "needsModel", message });
  const warning = (message: string) => issues.push({ kind: "warning", message });
  const hasProblems = () => issues.some((issue) => issue.kind === "needsModel");

  // Names must be usable in formulas, and unique.
  const inputNames = new Set<string>();
  surface.inputs = surface.inputs.flatMap((original) => {
    const item: Input = { ...original, options: [...original.options] };
    item.name = identifier(item.name === "" ? item.label : item.name);
    if (item.name === "") {
      fixed("Dropped an input with no name.");
      return [];
    }
    if (inputNames.has(item.name)) {
      fixed(`Dropped a second input named '${item.name}'.`);
      return [];
    }
    inputNames.add(item.name);
    if (trim(item.label) === "") item.label = words(item.name);
    item.symbol = texSymbol(item.symbol);
    // Only numbers can be fixed facts or run along a chart.
    if (item.role !== "adjustable" && item.role !== "live" && !isNumeric(item.format)) {
      fixed(`Made '${item.name}' adjustable, since a ${item.format} can't be ${item.role === "given" ? "a given" : "a chart's axis"}.`);
      item.role = "adjustable";
    }
    return [item];
  });
  const outputNames = new Set<string>();
  surface.outputs = surface.outputs.flatMap((original) => {
    const item = { ...original };
    item.name = identifier(item.name === "" ? item.label : item.name);
    if (item.name === "") {
      fixed("Dropped an output with no name.");
      return [];
    }
    if (outputNames.has(item.name)) {
      fixed(`Dropped a second output named '${item.name}'.`);
      return [];
    }
    outputNames.add(item.name);
    if (inputNames.has(item.name)) {
      problem(`'${item.name}' is both an input and an output. If the user enters it, keep only the input; otherwise rename the output.`);
    }
    if (trim(item.label) === "") item.label = words(item.name);
    item.symbol = texSymbol(item.symbol);
    // A result can be a yes or no, like whether to take an umbrella; never a choice.
    if (item.format === "choice") item.format = "number";
    return [item];
  });

  // The model often calls money a plain number. Not one it gave a unit of its own, like % or years.
  const unmeasured = (unit: string) => unit === "" || Currency.isCode(upper(unit)) || "$€£¥₹".includes(unit);
  const madeCurrency: string[] = [];
  for (const item of [...surface.inputs, ...surface.outputs]) {
    if (item.format === "number" && unmeasured(item.unit) && looksLikeMoney(item.name + " " + item.label)) {
      item.format = "currency";
      madeCurrency.push(item.name);
    }
  }
  if (madeCurrency.length) fixed(`Showed ${madeCurrency.map((name) => `'${name}'`).join(", ")} as money.`);
  issues.push(...checkUnits(surface));
  issues.push(...checkLive(surface));
  issues.push(...checkServiceLists(surface));

  if (!surface.inputs.length && !totalsRecords(surface)) problem("The calculation has results but no inputs, so nothing can change.");
  if (!surface.outputs.length && !showsLiveValues(surface) && !drivesScenes(surface)) problem("The calculation has inputs but no results calculated from them.");

  surface.inputs = surface.inputs.map((item) => checkedRange(item, fixed, problem));

  // Choices are numbers (the option's position), but models often compare them to text.
  for (const item of surface.outputs) {
    const rewritten = numberedChoices(item.formula, surface.inputs);
    if (rewritten !== item.formula) {
      fixed(`In '${item.name}', compared choices by position instead of by name.`);
      item.formula = rewritten;
    }
  }

  // Formulas must parse and only use names that exist. Near misses are renamed.
  const names = new Set([...inputNames, ...outputNames, ...columnNames(surface)]);
  for (const item of surface.outputs) {
    const written = item.formula;
    let expr: Expr;
    try {
      expr = parse(written);
    } catch (error) {
      problem(`The formula for '${item.name}' can't be read (${describeError(error)}): ${written}`);
      continue;
    }
    for (const fn of sorted([...functionNames(expr)].filter((fn) => !FUNCTIONS.has(fn)))) {
      problem(`The formula for '${item.name}' uses ${fn}(), which isn't available. Use only: ${sorted(FUNCTIONS).join(", ")}.`);
    }
    const renames = new Map<string, string>();
    for (const name of sorted([...namesIn(expr)].filter((name) => !names.has(name) && !CONSTANTS.has(name)))) {
      const match = closestName(name, names) ?? closestColumn(name, surface);
      if (match !== null) renames.set(name, match);
      else problem(`The formula for '${item.name}' uses '${name}', which isn't an input or output. Add it as an input, or use one of: ${sorted(names).join(", ")}.`);
    }
    if (renames.size) {
      item.formula = describe(renamed(expr, renames));
      const list = sorted(renames.keys()).map((from) => `'${from}' as '${renames.get(from)}'`);
      fixed(`In '${item.name}', read ${list.join(", ")}.`);
    }
  }
  if (hasProblems()) return issues;

  // Starting values that break results, usually a count of 0 that something divides by.
  let current = surface;
  if (broken(current, initialValues(current)) > 0) {
    for (let index = 0; index < current.inputs.length; index++) {
      const item = current.inputs[index];
      if (!(isNumeric(item.format) && item.initial === 0 && !isFixed(item))) continue;
      const trial = copy(current);
      const nudge = trial.inputs[index].format === "integer" ? 1 : max(trial.inputs[index].step, 1);
      trial.inputs[index].initial = nudge;
      trial.inputs[index].max = max(trial.inputs[index].max, nudge);
      if (broken(trial, initialValues(trial)) < broken(current, initialValues(current))) {
        current = trial;
        fixed(`Started '${trial.inputs[index].name}' at ${plain(nudge)} instead of 0, which broke the results.`);
      }
    }
    Object.assign(surface, current);
  }
  const start = evaluate(surface, initialValues(surface), sampleRecords(surface));
  for (const item of surface.outputs) {
    const error = start.errors.get(item.name);
    const value = start.values.get(item.name);
    if (error !== undefined) {
      problem(`'${item.name}' can't be calculated: ${error}.`);
    } else if (!(value !== undefined && Number.isFinite(value))) {
      problem(`'${item.name}' isn't a number at the starting values (${item.formula}). Avoid dividing by something that can be zero.`);
    } else if (!inputsFeeding(surface, item.name).size && !collectionsFeeding(surface, item.name).size) {
      problem(`'${item.name}' doesn't use any input, so it never changes. Calculate it from the inputs, or make it an input if the user should enter it.`);
    }
  }
  // A chart of something the calculation doesn't have, usually the very curve the page is about.
  for (const chart of charts(surface.blocks)) {
    const plotted = refs(chart);
    if (plotted.length && !plotted.some((name) => output(surface, name))) {
      problem(`The chart plots '${chart.ref}', which isn't a result. Add what it plots as an output, calculated from the inputs, and chart that.`);
    }
  }
  if (hasProblems()) return issues;

  // Minimums that break results: raise them by one step if that's enough.
  for (const item of surface.inputs) {
    if (!(isNumeric(item.format) && item.role === "adjustable")) continue;
    const values = initialValues(surface);
    values.set(item.name, item.min);
    if (!(broken(surface, values) > 0)) continue;
    const lowest = item.format === "integer" ? 1 : item.step;
    values.set(item.name, lowest);
    if (item.min <= 0 && lowest > 0 && lowest <= item.max && broken(surface, values) === 0) {
      const name = item.name;
      item.min = lowest;
      item.initial = max(item.initial, lowest);
      fixed(`Raised the minimum of '${name}' to ${plain(lowest)} so results never divide by zero.`);
    } else {
      warning(`Some results break when '${item.name}' is at its minimum.`);
    }
  }

  // A control that changes nothing is a broken tool: usually one side of a comparison the results
  // forgot, like the rent in rent or buy. A given that's unused is only clutter.
  const used = inputsUsedElsewhere(surface);
  for (const item of surface.outputs) for (const name of inputsFeeding(surface, item.name)) used.add(name);
  for (const item of surface.inputs) {
    if (used.has(item.name) || item.role === "live") continue;
    if (item.role === "adjustable") {
      problem(`'${item.name}' is a control that changes no result. Use it in the results it should change (both sides of a comparison), or remove it.`);
    } else {
      warning(`'${item.name}' doesn't affect any result.`);
    }
  }
  return issues;
}

function checkedRange(original: Input, fixed: (message: string) => void, problem: (message: string) => void): Input {
  const item: Input = { ...original };
  const name = item.name;
  // A given is one known value; it has no range to check. Nor has a live one.
  if (isFixed(item)) {
    if (!Number.isFinite(item.initial)) problem(`'${name}' is a given without a value.`);
    item.min = item.initial;
    item.max = item.initial;
    return item;
  }
  switch (item.format) {
    case "toggle":
      item.min = 0;
      item.max = 1;
      item.step = 1;
      item.initial = item.initial !== 0 ? 1 : 0;
      break;
    case "choice":
      item.options = item.options.map(trim).filter((option) => option !== "");
      if (item.options.length < 2) {
        problem(`'${name}' is a choice with ${item.options.length === 0 ? "no options" : "only one option"}. Give it at least two options, or use another format.`);
      }
      item.min = 0;
      item.max = max(item.options.length - 1, 0);
      item.step = 1;
      item.initial = min(max(round(item.initial), 0), item.max);
      break;
    default:
      if (!(Number.isFinite(item.initial) && Number.isFinite(item.min) && Number.isFinite(item.max))) {
        problem(`'${name}' has a starting value or range that isn't a number.`);
        return item;
      }
      if (item.format === "percent" && item.max <= 1 && item.initial > 0 && item.initial < 1) {
        problem(`'${name}' is a percent written as a fraction. Use whole numbers (18 means 18%) and divide by 100 in formulas.`);
      }
      if (item.min > item.max) {
        [item.min, item.max] = [item.max, item.min];
        fixed(`Swapped the minimum and maximum of '${name}'.`);
      }
      if (item.initial < item.min || item.initial > item.max) {
        item.min = min(item.min, item.initial);
        item.max = max(item.max, item.initial);
        fixed(`Widened the range of '${name}' to include its starting value.`);
      }
      if (item.min === item.max) {
        item.max = item.min + max(1, Math.abs(item.min));
        fixed(`Gave '${name}' a range.`);
      }
      if (item.format === "integer") {
        item.min = Math.floor(item.min);
        item.max = Math.ceil(item.max);
        item.initial = round(item.initial);
        item.step = max(1, round(item.step));
      } else if (!(item.step > 0) || item.step > item.max - item.min) {
        item.step = niceStep((item.max - item.min) / 100);
        fixed(`Picked a step for '${name}'.`);
      }
  }
  return item;
}

/** What NSRegularExpression.escapedPattern escapes, as a JavaScript pattern. */
const escaped = (text: string) => text.replace(/[\\^$.*+?()[\]{}|/]/g, "\\$&");
/** ICU's word characters, which its \b goes by. */
const WORD = "[\\p{Alphabetic}\\p{M}\\p{Nd}\\p{Pc}\\u200C\\u200D]";

/** `unit == 'cups'` → `unit == 1`, when `unit` is a choice with "cups" as its second option. */
export function numberedChoices(formula: string, inputs: Input[]): string {
  if (!formula.includes("'") && !formula.includes('"')) return formula;
  let result = formula;
  for (const item of inputs) {
    if (item.format !== "choice") continue;
    item.options.forEach((option, position) => {
      const name = escaped(item.name);
      const quoted = `['"]\\s*${escaped(option)}\\s*['"]`;
      const before = `(?<!${WORD})`;
      const after = `(?!${WORD})`;
      for (const pattern of [`${before}${name}\\s*(==|!=)\\s*${quoted}`, `${quoted}\\s*(==|!=)\\s*${before}${name}${after}`]) {
        let regex: RegExp;
        try {
          regex = new RegExp(pattern, "giu");
        } catch {
          continue;
        }
        result = result.replace(regex, (_whole, op: string) => `${item.name} ${op} ${position}`);
      }
    });
  }
  return result;
}

/** How many outputs aren't finite numbers at these values. */
function broken(surface: Surface, values: Map<string, number>): number {
  const evaluation = evaluate(surface, values, sampleRecords(surface));
  return surface.outputs.filter((item) => {
    const value = evaluation.values.get(item.name);
    return !(value !== undefined && Number.isFinite(value));
  }).length;
}

/** Inputs something other than a result uses: a figure, a scene, a sound, a button, a chart
 * running along it, or a live value in the text. */
function inputsUsedElsewhere(surface: Surface): Set<string> {
  const formulas = [
    ...(surface.figures ?? []).flatMap(figureFormulas),
    ...(surface.scenes ?? []).flatMap(sceneFormulas),
    ...(surface.sounds ?? []).flatMap((sound) => sound.tones.flatMap((tone) => [tone.frequency, tone.amplitude])),
    ...(surface.actions ?? []).flatMap((action) => Object.values(action.fields)),
  ];
  const axes = (blocks: Block[]): string[] => blocks.flatMap((block) => [...(block.kind === "chart" && block.over !== "" ? [block.over] : []), ...axes(block.children)]);
  // Not the blocks' own refs: a slider refers to the very input it sets.
  const names = new Set(axes(surface.blocks));
  for (const formula of formulas) {
    const expr = tryParse(formula);
    if (expr) for (const name of namesIn(expr)) names.add(name);
  }
  const texts = (blocks: Block[]): string[] =>
    blocks.flatMap((block) => [block.text, block.title, ...block.items.flatMap((item) => [item.label, item.value]), ...texts(block.children)]);
  const written = [...texts(surface.blocks), surface.summary, ...(surface.actions ?? []).flatMap((action) => Object.values(action.fields))].join(" ");
  for (const match of written.matchAll(/\{([\p{Alphabetic}\p{M}\p{Nd}\p{Pc}‌‍]+)\}/gu)) names.add(match[1]);
  const found = new Set<string>();
  for (const name of names) for (const fed of inputsFeeding(surface, name)) found.add(fed);
  return found;
}

function charts(blocks: Block[]): Block[] {
  return blocks.flatMap((block) => (block.kind === "chart" ? [block] : charts(block.children)));
}

// MARK: - The blocks

/** A data point's value: the first number in it, so "1,210.9 million" still reads as 1210.9. */
function itemNumber(value: string): number | null {
  const match = value.replaceAll(",", "").match(/-?\p{Nd}+(?:\.\p{Nd}+)?/u);
  return match ? double(match[0]) : null;
}

/** Checker.checkBlocks: block mistakes are always fixed locally, since a wrong block is cheaper to
 * drop or adjust than to send back, and the calculation it shows is already checked. */
export function checkBlocks(surface: Surface): Issue[] {
  const issues: Issue[] = [];
  const fixed = (message: string) => issues.push({ kind: "fixed", message });
  issues.push(...checkFigures(surface));
  issues.push(...checkScenes(surface));

  // A variable no chart runs along would have no control at all, so the reader sets it instead.
  const axes = new Set([...charts(surface.blocks).map((chart) => chart.over), ...figureAxes(surface), ...sceneAxes(surface)]);
  for (const item of surface.inputs) {
    if (item.role === "variable" && !axes.has(item.name)) {
      item.role = "adjustable";
      fixed(`Gave '${item.name}' a control, since no chart runs along it.`);
    }
  }
  issues.push(...checkSounds(surface));
  issues.push(...checkActions(surface));
  issues.push(...checkCitations(surface, null));
  const reference = copy(surface);

  /** `{name}` placeholders the calculation can fill; others are dropped. */
  const cleaned = (text: string) =>
    trimAll(join(parts(text).filter((part) => !("name" in part) || input(reference, part.name) !== undefined || output(reference, part.name) !== undefined)));

  const ids = new Set<string>();
  const uniqueID = (raw: string) => {
    const base = raw === "" ? "block" : raw;
    let id = base;
    let suffix = 2;
    while (ids.has(id)) {
      id = `${base}-${suffix}`;
      suffix += 1;
    }
    ids.add(id);
    return id;
  };

  const controlled = new Set<string>();
  const shown = new Set<string>();
  let heroes = 0;

  const clean = (original: Block, depth: number): Block | null => {
    let block: Block = { ...original, items: original.items, children: original.children };
    block.id = uniqueID(trim(block.id));
    block.title = trimAll(block.title);
    block.text = trimAll(block.text);
    block.items = block.items.map((item) => ({ label: trimAll(item.label), value: cleaned(item.value) })).filter((item) => item.value !== "");

    switch (block.kind) {
      case "section":
      case "row": {
        block.ref = "";
        block.over = "";
        block.text = "";
        block.items = [];
        block.children = block.children.map((child) => clean(child, depth + 1)).filter((child) => child !== null);
        if (block.kind === "row" && (block.children.length > 3 || block.children.some((child) => isContainer(child.kind)))) block.kind = "section";
        if (block.kind === "row") {
          block.title = "";
          // Side by side, results share the weight.
          for (const child of block.children) {
            if (child.kind === "hero") {
              child.kind = "metric";
              heroes -= 1;
            }
          }
        }
        if (!block.children.length) return null;
        break;
      }
      case "hero":
      case "metric": {
        block.over = "";
        block.text = "";
        block.items = [];
        block.children = [];
        const isGiven = input(reference, block.ref)?.role === "given";
        if (!(output(reference, block.ref) || isGiven || input(reference, block.ref)?.role === "live")) {
          // An adjustable input already shows its value in its control, and a chart shows its variable.
          fixed(`Removed a ${block.kind} for '${block.ref}', which isn't a result.`);
          return null;
        }
        shown.add(block.ref);
        if (isGiven) block.kind = "metric";
        if (block.kind === "hero") {
          heroes += 1;
          if (heroes > 1) block.kind = "metric";
        }
        break;
      }
      case "slider":
      case "stepper":
      case "field":
      case "toggle":
      case "picker": {
        block.over = "";
        block.text = "";
        block.items = [];
        block.children = [];
        const found = input(reference, block.ref);
        if (!found || found.role !== "adjustable") {
          const isResult = output(reference, block.ref) !== undefined;
          if (isResult || (found && isFixed(found))) {
            shown.add(block.ref);
            block.kind = "metric";
            fixed(`'${block.ref}' is ${isResult ? "a result" : found?.role === "live" ? "live" : "a given"}, so it's shown instead of edited.`);
            return block;
          }
          fixed(`Removed a control for '${block.ref}', which isn't an adjustable input.`);
          return null;
        }
        if (controlled.has(found.name)) {
          fixed(`Removed a second control for '${found.name}'.`);
          return null;
        }
        controlled.add(found.name);
        // Fields are for exact amounts; percentages and counts are easier to slide or step.
        if (!fits(block.kind, found.format) || (block.kind === "field" && found.format !== "currency" && found.format !== "number")) {
          block.kind = defaultControl(found);
        }
        break;
      }
      case "chart": {
        block.text = "";
        block.items = [];
        block.children = [];
        const series = refs(block).filter((name) => output(reference, name));
        if (!series.length) {
          fixed(`Removed a chart of '${block.ref}', which isn't a result.`);
          return null;
        }
        block.ref = series.slice(0, 4).join(", ");
        const feeding = new Set<string>();
        for (const name of series) for (const fed of inputsFeeding(reference, name)) feeding.add(fed);
        const runsAlong = (item: Input) => isNumeric(item.format) && !isFixed(item) && feeding.has(item.name);
        const over = input(reference, block.over);
        if (over && runsAlong(over)) {
          // Fine as it is.
        } else {
          const replacement = reference.inputs.find((item) => item.role === "variable" && runsAlong(item)) ?? reference.inputs.find(runsAlong);
          if (!replacement) {
            fixed(`Removed a chart of '${block.ref}', which nothing the reader changes moves.`);
            return null;
          }
          block.over = replacement.name;
        }
        for (const name of series) shown.add(name);
        break;
      }
      case "equation": {
        block.over = "";
        block.children = [];
        block.items = block.items.map((item) => ({ label: texSymbol(item.label), value: item.value }));
        if (block.ref !== "") {
          if (output(reference, block.ref)) {
            // The calculation's own formula: the text isn't needed, and its symbols are explained
            // from the calculation itself.
            block.text = "";
            block.items = [];
            shown.add(block.ref);
          } else {
            block.ref = "";
          }
        }
        if (block.ref === "") {
          block.text = displayMath(block.text);
          if (block.text === "") {
            fixed("Dropped an empty equation.");
            return null;
          }
          // Words around $-delimited maths make it prose that holds maths, not an equation.
          const pieces = segments(block.text);
          if (pieces.some((piece) => "math" in piece) && pieces.some((piece) => "text" in piece && characters(piece.text).some(isLetter))) {
            block.kind = "paragraph";
            block.text = cleaned(prose(block.text));
            block.items = [];
            fixed("Showed an equation written as sentences as a paragraph.");
          }
        }
        break;
      }
      case "list":
      case "add": {
        const result = recordBlock(block, reference);
        if (result.fix !== null) fixed(result.fix);
        if (!result.keep) return null;
        break;
      }
      case "data": {
        // A chart of the user's entries.
        if (boundData(block, reference)) break;
        block.ref = "";
        block.over = "";
        block.children = [];
        block.text = "";
        const points = block.items.filter((item) => itemNumber(item.value) !== null && item.label !== "");
        if (points.length >= 2) {
          block.items = points;
        } else if (block.items.length) {
          block.kind = "facts";
          fixed("Showed a data block with fewer than two numbers as facts.");
        } else {
          return null;
        }
        break;
      }
      case "paragraph":
        block.ref = "";
        block.over = "";
        block.children = [];
        if (block.text === "") block.text = block.items.map((item) => item.value).join(" ");
        block.items = [];
        block.text = cleaned(prose(block.text));
        if (block.text === "") return null;
        break;
      case "sound": {
        const checked = soundBlock(block, reference, fixed);
        if (!checked) return null;
        block = checked;
        break;
      }
      case "figure":
      case "diagram": {
        const checked = visual(block, reference, fixed);
        if (!checked) return null;
        block = checked;
        break;
      }
      case "action": {
        const checked = actionBlock(block, reference, fixed);
        if (!checked) return null;
        block = checked;
        break;
      }
      case "scene": {
        const checked = sceneBlock(block, reference, fixed);
        if (!checked) return null;
        block = checked;
        break;
      }
      case "facts":
      case "bullets":
      case "steps":
      case "timeline":
      case "stat":
        block.ref = "";
        block.over = "";
        block.children = [];
        if (!block.items.length) {
          if (block.text === "") {
            fixed(`Dropped an empty ${block.kind} block.`);
            return null;
          }
          block.kind = "paragraph";
        } else {
          // The model tends to repeat the items as prose here; the items are what's shown.
          block.text = "";
        }
        break;
    }
    return block;
  };

  surface.blocks = surface.blocks.map((block) => clean(block, 0)).filter((block) => block !== null);
  issues.push(...placeVisuals(surface));
  issues.push(...placeScenes(surface));
  issues.push(...removeRepeatedUnits(surface));

  const title = lower(surface.title);
  const seenTopics = new Set<string>();
  surface.related = surface.related
    .map(trimAll)
    .filter((topic) => {
      if (topic === "" || lower(topic) === title || seenTopics.has(lower(topic))) return false;
      seenTopics.add(lower(topic));
      return true;
    })
    .slice(0, 6);

  issues.push(...placeLists(surface));
  issues.push(...placeActions(surface));

  // A calculation the blocks don't show is still placed, so it's never lost.
  if (!hasLogic(surface)) return [...issues, ...placeSounds(surface)];
  const main = surface.outputs[0]?.name;
  if (heroes === 0 && main !== undefined) {
    const lead = surface.blocks.find((block) => block.kind === "metric" && block.ref === main);
    if (lead) {
      lead.kind = "hero";
      heroes = 1;
      fixed(`Made '${main}' the main result.`);
    }
  }
  const missingControls = adjustableInputs(surface).filter((item) => !controlled.has(item.name));
  if (missingControls.length) {
    const controls = missingControls.map((item) => makeBlock(uniqueID(`${item.name}-control`), defaultControl(item), { ref: item.name }));
    surface.blocks.push(makeBlock(uniqueID("more-inputs"), "section", { children: controls }));
    fixed(`Added controls for ${missingControls.map((item) => `'${item.name}'`).join(", ")}.`);
  }
  const missingGivens = surface.inputs.filter((item) => isFixed(item) && !shown.has(item.name));
  if (missingGivens.length) {
    // Beside the controls, so the reader sees what the calculation takes as fixed.
    const metrics = missingGivens.map((item) => makeBlock(uniqueID(`${item.name}-given`), "metric", { ref: item.name }));
    const row = makeBlock(uniqueID("givens"), metrics.length <= 3 ? "row" : "section", { children: metrics });
    const home = surface.blocks.find((block) => block.kind === "section" && block.children.some((child) => isControl(child.kind)));
    if (home) home.children.push(row);
    else surface.blocks.push(makeBlock(uniqueID("given"), "section", { children: [row] }));
    fixed(`Showed the givens ${missingGivens.map((item) => `'${item.name}'`).join(", ")}.`);
  }
  let missingOutputs = surface.outputs.filter((item) => !shown.has(item.name));
  if (missingOutputs.length) {
    fixed(`Added ${missingOutputs.map((item) => `'${item.name}'`).join(", ")} to the screen.`);
    const first = missingOutputs[0];
    if (heroes === 0 && first.name === surface.outputs[0]?.name) {
      const hero = makeBlock(uniqueID(`${first.name}-hero`), "hero", { ref: first.name });
      // Above the first control, so the answer comes before the knobs.
      const position = surface.blocks.findIndex((block) => refsIn([block]).size > 0);
      surface.blocks.splice(position < 0 ? surface.blocks.length : position, 0, hero);
      missingOutputs = missingOutputs.slice(1);
    }
    // A step on the way to another result, like a monthly rate, shows how it's worked out rather
    // than standing as a result of its own.
    const feeding = new Set(surface.outputs.flatMap((item) => {
      const expr = tryParse(item.formula);
      return expr ? [...namesIn(expr)] : [];
    }));
    const steps = missingOutputs.filter((item) => feeding.has(item.name));
    const results = missingOutputs.filter((item) => !feeding.has(item.name));
    if (results.length) {
      const metrics = results.map((item) => makeBlock(uniqueID(`${item.name}-metric`), "metric", { ref: item.name }));
      surface.blocks.push(makeBlock(uniqueID("more-results"), "section", { children: metrics }));
    }
    if (steps.length) {
      const equations = steps.map((item) => makeBlock(uniqueID(`${item.name}-working`), "equation", { ref: item.name }));
      surface.blocks.push(makeBlock(uniqueID("working"), "section", { children: equations }));
    }
  }
  issues.push(...placeCharts(surface));
  issues.push(...placeSounds(surface));
  return issues;
}

/** A chart belongs with the controls that shape it, above them: one instrument. */
function placeCharts(surface: Surface): Issue[] {
  const issues: Issue[] = [];
  const adjustable = new Set(adjustableInputs(surface).map((item) => item.name));
  const shaping = (chart: Block) => {
    const found = new Set<string>();
    for (const name of refs(chart)) for (const fed of inputsFeeding(surface, name)) if (adjustable.has(fed)) found.add(fed);
    return found;
  };
  const controls = (block: Block): Set<string> => {
    if (isControl(block.kind)) return new Set([block.ref]);
    const found = new Set<string>();
    for (const child of block.children) for (const name of controls(child)) found.add(name);
    return found;
  };
  // Charts on their own, moved into the one section that holds their controls.
  for (let index = surface.blocks.length - 1; index >= 0; index--) {
    const chart = surface.blocks[index];
    if (chart.kind !== "chart") continue;
    const inputs = shaping(chart);
    const holders = surface.blocks.map((_, at) => at).filter((at) => at !== index && [...controls(surface.blocks[at])].some((name) => inputs.has(name)));
    if (holders.length !== 1 || surface.blocks[holders[0]].kind !== "section") continue;
    surface.blocks.splice(index, 1);
    const home = holders[0] > index ? holders[0] - 1 : holders[0];
    surface.blocks[home].children.splice(0, 0, chart);
    issues.push({ kind: "fixed", message: `Put the chart of '${chart.ref}' with the controls that shape it.` });
  }
  // Within a section, the chart comes before the controls.
  for (const section of surface.blocks) {
    if (section.kind !== "section") continue;
    const children = section.children;
    const firstControl = children.findIndex((child) => isControl(child.kind));
    if (firstControl < 0) continue;
    for (let at = children.length - 1; at >= 0; at--) {
      if (children[at].kind !== "chart" || !(at > firstControl)) continue;
      const [chart] = children.splice(at, 1);
      children.splice(firstControl, 0, chart);
    }
  }
  return issues;
}

// MARK: - Loops

/** Small models occasionally loop: one block that never ends, or the same sentence again and
 * again. Real blocks are short, so either is a sign to stop and keep what came before. */
export function isRepeatingItself(surface: Surface): boolean {
  if (count(surface.summary) > 600) return true;
  const seenTexts = new Set<string>();
  const loops = (blocks: Block[]): boolean => {
    for (const block of blocks) {
      if (count(block.text) > 1400) return true;
      if (block.items.some((item) => count(item.value) > 500 || count(item.label) > 200)) return true;
      const sentences = lower(block.text).split(/[.!?\n]/).map(trim).filter((sentence) => count(sentence) >= 24);
      if (new Set(sentences).size < sentences.length) return true;
      if (block.text !== "") {
        if (seenTexts.has(lower(block.text))) return true;
        seenTexts.add(lower(block.text));
      }
      const values = block.items.map((item) => lower(item.value));
      if (values.length >= 4 && new Set(values).size <= Math.trunc(values.length / 2)) return true;
      if (loops(block.children)) return true;
    }
    return false;
  };
  return loops(surface.blocks);
}
