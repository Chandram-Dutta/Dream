// Figures and diagrams (Dream/Engine/Checker+Figures.swift, and from Figure.swift what the checker
// needs of a drawing: where each point is at the starting values, and which shapes can be drawn
// there). A shape that can't be drawn is dropped, and the rest still teach.

import { CONSTANTS, describe, evaluate as evaluateExpr, FormulaError, names as namesIn, parseCached, renamed, tryParse, usesKnownFunctions } from "./formula.ts";
import { closestName, identifier, words } from "./names.ts";
import { evaluate, input, inputsFeeding, isControl, makeBlock, output, safeRange } from "./surface.ts";
import { characters, count, dropLast, lower, suffix, trim, trimAll, upper } from "./swift.ts";
import { join, parts, prose } from "./tex.ts";
import type { Block, BlockKind, Diagram, Figure, FigureShape, Issue, ShapeKind, Surface } from "./types.ts";

// MARK: - Drawing at the starting values

interface Vec2 {
  x: number;
  y: number;
}

const POINT_COUNTS: Record<ShapeKind, [number, number]> = {
  segment: [2, 16], arrow: [2, 2], polygon: [3, 16], square: [2, 3], circle: [1, 1], arc: [1, 1], text: [1, 1], angle: [3, 3], rightAngle: [3, 3], path: [0, 0],
};

const length = (v: Vec2) => Math.hypot(v.x, v.y);
const minus = (a: Vec2, b: Vec2): Vec2 => ({ x: a.x - b.x, y: a.y - b.y });

/** `A.x` → (A, x): another point's coordinate, as figure formulas write it. */
export function coordinate(name: string): { point: string; axis: string } | null {
  const all = characters(name);
  if (all.length <= 2) return null;
  const axis = all[all.length - 1];
  if ((axis !== "x" && axis !== "y") || all[all.length - 2] !== ".") return null;
  return { point: all.slice(0, -2).join(""), axis };
}

/** Where each point is. Points can use each other's coordinates in any order; one that can't be
 * placed (a formula that isn't a number, or that depends on itself) is left out. */
function positions(figure: Figure, values: Map<string, number>): Map<string, Vec2> {
  const byName = new Map<string, Figure["points"][number]>();
  for (const point of figure.points) if (!byName.has(point.name)) byName.set(point.name, point);
  const placed = new Map<string, Vec2>();
  const failed = new Set<string>();
  const resolving = new Set<string>();

  const place = (name: string): Vec2 => {
    const known = placed.get(name);
    if (known) return known;
    const point = byName.get(name);
    if (failed.has(name) || !point) throw new FormulaError(`there's no point '${name}'`);
    if (resolving.has(name)) throw new FormulaError(`'${name}' depends on itself`);
    resolving.add(name);
    try {
      const position = { x: evaluateExpr(parseCached(point.x), lookup), y: evaluateExpr(parseCached(point.y), lookup) };
      if (!(Number.isFinite(position.x) && Number.isFinite(position.y))) throw new FormulaError(`'${name}' isn't at a number`);
      placed.set(name, position);
      return position;
    } finally {
      resolving.delete(name);
    }
  };
  const lookup = (name: string): number => {
    const value = values.get(name);
    if (value !== undefined) return value;
    const found = coordinate(name);
    if (found && byName.has(found.point)) {
      const position = place(found.point);
      return found.axis === "x" ? position.x : position.y;
    }
    const constant = CONSTANTS.get(name);
    if (constant !== undefined) return constant;
    throw new FormulaError(`'${name}' isn't an input, an output or a point`);
  };

  for (const point of figure.points) {
    if (placed.has(point.name)) continue;
    try {
      place(point.name);
    } catch {
      failed.add(point.name);
    }
  }
  return placed;
}

/** Which shapes can be drawn at the starting values, by position, and where the points are. */
function drawable(figure: Figure, surface: Surface): { marks: Set<number>; points: Map<string, Vec2> } {
  const given = new Map<string, number>();
  const values = evaluate(surface, given).values;
  const placed = positions(figure, values);
  const number = (formula: string, locals = new Map<string, number>(), at = values): number | null => {
    const expr = tryParse(formula);
    if (!expr) return null;
    try {
      const value = evaluateExpr(expr, (name) => {
        const local = locals.get(name);
        if (local !== undefined) return local;
        const known = at.get(name);
        if (known !== undefined) return known;
        const found = coordinate(name);
        const position = found ? placed.get(found.point) : undefined;
        if (found && position) return found.axis === "x" ? position.x : position.y;
        const constant = CONSTANTS.get(name);
        if (constant !== undefined) return constant;
        throw new FormulaError(`'${name}' isn't an input, an output or a point`);
      });
      return Number.isFinite(value) ? value : null;
    } catch {
      return null;
    }
  };

  const marks = new Set<number>();
  figure.shapes.forEach((shape, index) => {
    const corners = shape.points.map((name) => placed.get(name)).filter((corner) => corner !== undefined);
    const [low, high] = POINT_COUNTS[shape.kind];
    if (corners.length !== shape.points.length || corners.length < low || corners.length > high) return;
    switch (shape.kind) {
      case "segment": case "arrow":
        if (!corners.slice(1).some((corner, at) => length(minus(corner, corners[at])) > 0)) return;
        break;
      case "polygon":
        break;
      case "square":
        if (!(length(minus(corners[1], corners[0])) > 0)) return;
        break;
      case "circle": case "arc": {
        const radius = number(shape.radius);
        if (radius === null || !(radius > 0)) return;
        if (shape.kind === "arc") {
          const [from, to] = [number(shape.from), number(shape.to)];
          if (from === null || to === null || from === to) return;
        }
        break;
      }
      case "angle": case "rightAngle":
        if (!(length(minus(corners[0], corners[1])) > 0 && length(minus(corners[2], corners[1])) > 0)) return;
        break;
      case "text":
        if (shape.label === "") return;
        break;
      case "path": {
        const along = input(surface, shape.over);
        const range = along ? safeRange(along) : undefined;
        const first = shape.from === "" ? range?.[0] ?? null : number(shape.from);
        const last = shape.to === "" ? range?.[1] ?? null : number(shape.to);
        if (first === null || last === null || first === last) return;
        const samples = 120;
        let found = 0;
        for (let step = 0; step < samples && found < 2; step++) {
          const t = first + ((last - first) * step) / (samples - 1);
          let at = values;
          if (along) {
            const trial = new Map(given);
            trial.set(shape.over, t);
            at = evaluate(surface, trial).values;
          }
          const locals = new Map([[shape.over, t]]);
          if (number(shape.x, locals, at) !== null && number(shape.y, locals, at) !== null) found++;
        }
        if (found < 2) return;
        break;
      }
    }
    marks.add(index);
  });
  return { marks, points: placed };
}

/** The inputs a figure's shapes depend on, directly or through outputs. */
function figureInputs(figure: Figure, surface: Surface): Set<string> {
  const formulas = [...figure.points.flatMap((point) => [point.x, point.y]), ...figure.shapes.flatMap((shape) => [shape.radius, shape.from, shape.to, shape.x, shape.y]).filter((formula) => formula !== "")];
  const found = new Set<string>();
  for (const formula of formulas) {
    const expr = tryParse(formula);
    if (!expr) continue;
    for (const name of namesIn(expr)) for (const fed of inputsFeeding(surface, name)) found.add(fed);
  }
  return found;
}

/** Every formula in a figure, for what else uses an input. */
export function figureFormulas(figure: Figure): string[] {
  return [...figure.points.flatMap((point) => [point.x, point.y]), ...figure.shapes.flatMap((shape) => [shape.radius, shape.from, shape.to, shape.x, shape.y]).filter((formula) => formula !== "")];
}

/** Names that paths run along. A variable a path uses this way needs no control of its own. */
export function figureAxes(surface: Surface): Set<string> {
  return new Set((surface.figures ?? []).flatMap((figure) => figure.shapes.filter((shape) => shape.kind === "path").map((shape) => shape.over)));
}

// MARK: - Checking

/** Names made usable and unique, formulas read with near-miss names repaired, and shapes that
 * can't be drawn at the starting values dropped. Runs before the blocks that show them. */
export function checkFigures(surface: Surface): Issue[] {
  const issues: Issue[] = [];
  const fixed = (message: string) => issues.push({ kind: "fixed", message });
  const calculation = new Set([...surface.inputs.map((item) => item.name), ...surface.outputs.map((item) => item.name)]);
  const taken = new Set(calculation);
  const uniqueName = (raw: string, fallback: string) => {
    const base = identifier(raw) === "" ? fallback : identifier(raw);
    let name = base;
    let suffixNumber = 2;
    while (taken.has(name)) {
      name = `${base}${suffixNumber}`;
      suffixNumber += 1;
    }
    taken.add(name);
    return name;
  };

  if (surface.figures) {
    const reference = surface;
    const figures: Figure[] = [];
    for (const original of surface.figures) {
      let figure: Figure = { ...original, name: uniqueName(original.name, "figure") };
      const before = issues.length;
      figure = checkedFigure(figure, reference, fixed);
      if (!figure.shapes.length && !figure.points.some((point) => point.label !== "")) {
        issues.splice(before);
        fixed(`Dropped the figure '${original.name}', which had nothing that could be drawn.`);
        continue;
      }
      figures.push(figure);
    }
    if (figures.length) surface.figures = figures;
    else delete surface.figures;
  }

  if (surface.diagrams) {
    const diagrams: Diagram[] = [];
    for (const original of surface.diagrams) {
      const diagram = checkedDiagram({ ...original, name: uniqueName(original.name, "diagram") }, fixed);
      if (diagram.nodes.length < 2) {
        fixed(`Dropped the diagram '${diagram.name}', which needs at least two parts.`);
        continue;
      }
      diagrams.push(diagram);
    }
    if (diagrams.length) surface.diagrams = diagrams;
    else delete surface.diagrams;
  }
  return issues;
}

/** A figure or diagram block, pointed at one that exists. Null if there's nothing to show. */
export function visual(original: Block, surface: Surface, fixed: (message: string) => void): Block | null {
  const block: Block = { ...original, over: "", text: "", items: [], children: [] };
  block.ref = trim(block.ref);
  const names = new Set(block.kind === "figure" ? (surface.figures ?? []).map((item) => item.name) : (surface.diagrams ?? []).map((item) => item.name));
  if (names.has(block.ref)) return block;
  const match = closestName(block.ref, names) ?? (names.size === 1 && block.ref === "" ? [...names][0] : null);
  if (match !== null) {
    block.ref = match;
    return block;
  }
  fixed(`Removed a ${block.kind} of '${block.ref}', which isn't defined.`);
  return null;
}

function controls(block: Block): Set<string> {
  if (isControl(block.kind)) return new Set([block.ref]);
  const found = new Set<string>();
  for (const child of block.children) for (const name of controls(child)) found.add(name);
  return found;
}

/** A figure or diagram no block shows still gets shown: a figure just before the controls that
 * move it, a diagram after the opening block. */
export function placeVisuals(surface: Surface): Issue[] {
  const issues: Issue[] = [];
  const ids = (blocks: Block[]): string[] => blocks.flatMap((block) => [block.id, ...ids(block.children)]);
  const shown = (kind: BlockKind, blocks: Block[], into = new Set<string>()): Set<string> => {
    for (const block of blocks) {
      if (block.kind === kind) into.add(block.ref);
      shown(kind, block.children, into);
    }
    return into;
  };
  const used = new Set(ids(surface.blocks));
  const uniqueID = (base: string) => {
    let id = base;
    let suffixNumber = 2;
    while (used.has(id)) {
      id = `${base}-${suffixNumber}`;
      suffixNumber += 1;
    }
    used.add(id);
    return id;
  };

  const figuresShown = shown("figure", surface.blocks);
  for (const figure of surface.figures ?? []) {
    if (figuresShown.has(figure.name)) continue;
    const block = makeBlock(uniqueID(`figure-${figure.name}`), "figure", { ref: figure.name });
    const moving = figureInputs(figure, surface);
    const home = surface.blocks.findIndex((candidate) => [...controls(candidate)].some((name) => moving.has(name)));
    if (home >= 0) {
      if (surface.blocks[home].kind === "section") {
        const children = surface.blocks[home].children;
        const first = children.findIndex((child) => isControl(child.kind));
        children.splice(first < 0 ? 0 : first, 0, block);
      } else {
        surface.blocks.splice(home, 0, block);
      }
    } else {
      surface.blocks.splice(Math.min(1, surface.blocks.length), 0, block);
    }
    issues.push({ kind: "fixed", message: `Showed the figure '${figure.name}'.` });
  }
  const diagramsShown = shown("diagram", surface.blocks);
  for (const diagram of surface.diagrams ?? []) {
    if (diagramsShown.has(diagram.name)) continue;
    surface.blocks.splice(Math.min(1, surface.blocks.length), 0, makeBlock(uniqueID(`diagram-${diagram.name}`), "diagram", { ref: diagram.name }));
    issues.push({ kind: "fixed", message: `Showed the diagram '${diagram.name}'.` });
  }
  return issues;
}

// MARK: - Figures

/** A label's text, trimmed, with live values only for names the calculation has. */
export function labelIn(text: string, surface: Surface): string {
  const kept = parts(trimAll(text)).filter((part) => !("name" in part) || input(surface, part.name) !== undefined || output(surface, part.name) !== undefined);
  return trimAll(join(kept));
}

function checkedFigure(original: Figure, surface: Surface, fixed: (message: string) => void): Figure {
  const figure: Figure = { ...original };
  const calculation = new Set([...surface.inputs.map((item) => item.name), ...surface.outputs.map((item) => item.name)]);

  let pointNames = new Set<string>();
  figure.points = original.points.flatMap((point) => {
    const name = identifier(point.name);
    if (name === "") return [];
    if (pointNames.has(name)) {
      fixed(`In the figure '${figure.name}', dropped a second point named '${name}'.`);
      return [];
    }
    pointNames.add(name);
    return [{ ...point, name, label: labelIn(point.label, surface) }];
  });

  /** A point's name as a shape gives it, or a near miss. */
  const pointName = (raw: string): string | null => {
    const name = trim(raw);
    return pointNames.has(name) ? name : closestName(name, pointNames);
  };

  /** `Ax`, `A_x` and `a.X` as `A.x`. */
  const coordinateOf = (name: string): string | null => {
    const found = coordinate(dropLast(name) + lower(suffix(name, 1)));
    if (found) {
      const match = pointName(found.point);
      if (match !== null) return `${match}.${found.axis}`;
    }
    const last = characters(name).pop();
    const axis = last === undefined ? undefined : lower(last);
    if (axis !== "x" && axis !== "y") return null;
    let point = dropLast(name);
    if (point.endsWith("_")) point = dropLast(point);
    return pointNames.has(point) ? `${point}.${axis}` : null;
  };

  /** A formula that parses and only uses names it can, with near misses renamed. Null if not. */
  const repaired = (formula: string, locals = new Set<string>()): string | null => {
    const source = trim(formula);
    if (source === "") return null;
    const expr = tryParse(source);
    if (!expr || !usesKnownFunctions(expr)) return null;
    const renames = new Map<string, string>();
    for (const name of namesIn(expr)) {
      if (calculation.has(name) || locals.has(name) || CONSTANTS.has(name)) continue;
      const found = coordinate(name);
      if (found && pointNames.has(found.point)) continue;
      const match = coordinateOf(name) ?? closestName(name, new Set([...calculation, ...locals]));
      if (match === null) return null;
      renames.set(name, match);
    }
    return renames.size ? describe(renamed(expr, renames)) : source;
  };

  figure.points = figure.points.flatMap((point) => {
    const x = repaired(point.x === "" && point.y !== "" ? "0" : point.x);
    const y = x === null ? null : repaired(point.y === "" && point.x !== "" ? "0" : point.y);
    if (x === null || y === null) {
      fixed(`In the figure '${figure.name}', dropped the point '${point.name}', whose position can't be read: (${point.x}, ${point.y}).`);
      return [];
    }
    return [{ ...point, x, y }];
  });
  pointNames = new Set(figure.points.map((point) => point.name));

  figure.shapes = original.shapes.flatMap((originalShape): FigureShape[] => {
    const shape: FigureShape = { ...originalShape };
    const kind = lower(words(shape.kind));
    const what = `${"aeiou".includes(characters(kind)[0] ?? "-") ? "an" : "a"} ${kind}${shape.label === "" ? "" : ` '${shape.label}'`}`;
    const drop = (why: string): FigureShape[] => {
      fixed(`In the figure '${figure.name}', dropped ${what}, ${why}.`);
      return [];
    };

    // Points by name. "ABC" is read as A, B, C when those are points.
    const names: string[] = [];
    for (const raw of shape.points.map(trim).filter((name) => name !== "")) {
      const name = pointName(raw);
      if (name !== null) names.push(name);
      else if (count(raw) > 1 && characters(raw).every((character) => pointNames.has(character))) names.push(...characters(raw));
      else return drop(`which uses '${raw}', not a point`);
    }
    const [low, high] = POINT_COUNTS[shape.kind];
    if (names.length < low) return drop(`which needs ${low} points`);
    shape.points = names.slice(0, high);
    shape.label = labelIn(shape.label, surface);

    switch (shape.kind) {
      case "circle": case "arc": {
        const radius = repaired(shape.radius);
        if (radius === null) return drop("whose radius can't be read");
        shape.radius = radius;
        if (shape.kind === "arc") {
          const from = repaired(shape.from);
          const to = from === null ? null : repaired(shape.to);
          if (from === null || to === null) return drop("whose angles can't be read");
          shape.from = from;
          shape.to = to;
        } else {
          shape.from = "";
          shape.to = "";
        }
        shape.over = "";
        shape.x = "";
        shape.y = "";
        break;
      }
      case "path": {
        shape.over = identifier(shape.over) === "" ? "t" : identifier(shape.over);
        const locals = new Set([shape.over]);
        const x = repaired(shape.x, locals);
        const y = x === null ? null : repaired(shape.y, locals);
        if (x === null || y === null) return drop("whose formulas can't be read");
        shape.x = x;
        shape.y = y;
        // Without its own range, a path runs along its variable's.
        const ranged = input(surface, shape.over) !== undefined;
        const from = shape.from === "" && ranged ? "" : repaired(shape.from);
        const to = from === null ? null : shape.to === "" && ranged ? "" : repaired(shape.to);
        if (from === null || to === null) return drop(`which needs a first and last value for ${shape.over}`);
        shape.from = from;
        shape.to = to;
        shape.radius = "";
        break;
      }
      case "text":
        if (shape.label === "") return drop("with nothing to say");
        Object.assign(shape, { radius: "", from: "", to: "", over: "", x: "", y: "" });
        break;
      default:
        Object.assign(shape, { radius: "", from: "", to: "", over: "", x: "", y: "" });
    }
    return [shape];
  });

  // Last, what the formulas can't show until they're worked out.
  const drawing = drawable(figure, surface);
  const missing = figure.points.filter((point) => !drawing.points.has(point.name)).map((point) => point.name);
  if (missing.length) {
    fixed(`In the figure '${figure.name}', dropped ${missing.map((name) => `'${name}'`).join(", ")}, which can't be placed at the starting values.`);
    figure.points = figure.points.filter((point) => !missing.includes(point.name));
  }
  figure.shapes = figure.shapes.filter((shape, index) => {
    if (drawing.marks.has(index)) return true;
    fixed(`In the figure '${figure.name}', dropped a shape (${lower(words(shape.kind))}) that can't be drawn at the starting values.`);
    return false;
  });
  return figure;
}

// MARK: - Diagrams

function checkedDiagram(original: Diagram, fixed: (message: string) => void): Diagram {
  const diagram: Diagram = { ...original };
  const ids = new Set<string>();
  diagram.nodes = original.nodes.flatMap((node) => {
    const label = trimAll(node.label);
    const id = identifier(node.id === "" ? label : node.id);
    if (id === "") return [];
    if (ids.has(id)) {
      fixed(`In the diagram '${diagram.name}', dropped a second part called '${id}'.`);
      return [];
    }
    ids.add(id);
    return [{ id, label: label === "" ? words(id) : label, detail: trimAll(prose(node.detail)) }];
  });

  /** An edge's end, by id or near miss, or by the label the model wrote instead. */
  const nodeID = (raw: string): string | null => {
    const name = trim(raw);
    if (ids.has(name)) return name;
    const match = closestName(name, ids) ?? closestName(identifier(name), ids);
    if (match !== null) return match;
    // caseInsensitiveCompare folds case fully, so ß is ss.
    const folded = (text: string) => lower(upper(text));
    return diagram.nodes.find((node) => folded(node.label) === folded(name))?.id ?? null;
  };

  const seen = new Set<string>();
  diagram.edges = original.edges.flatMap((edge) => {
    const from = nodeID(edge.from);
    const to = from === null ? null : nodeID(edge.to);
    if (from === null || to === null) {
      fixed(`In the diagram '${diagram.name}', dropped an edge from '${edge.from}' to '${edge.to}', which aren't both parts.`);
      return [];
    }
    const key = JSON.stringify([from, to]);
    if (from === to || seen.has(key)) return [];
    seen.add(key);
    return [{ from, to, label: trimAll(edge.label) }];
  });
  return diagram;
}
