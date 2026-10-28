// 3D scenes (Dream/Engine/Checker+Scenes.swift, and from ScenePlacement.swift and
// SceneDrawing.swift what the checker needs of a drawing: which objects can be placed at the
// starting values, and which plots have a surface there). An object that can't be placed is
// dropped, and the rest still teach.

import {
  CONSTANTS, call, describe, evaluate as evaluateExpr, type Expr, FormulaError, name as nameExpr, names as namesIn, number as numberExpr, parse,
  parseCached, renamed, tryParse, usesKnownFunctions,
} from "./formula.ts";
import { closestName, identifier, words } from "./names.ts";
import { evaluate, initialValues, input, inputsFeeding, isControl, isNumeric, makeBlock, safeRange } from "./surface.ts";
import { dropFirst, dropLast, lower, max, min, plain, round, trim, trimAll } from "./swift.ts";
import { labelIn } from "./checker-figures.ts";
import type { Block, Issue, Scene3D, SceneObject, ScenePlot, SolidKind, Surface } from "./types.ts";

// MARK: - Placement

type Vec3 = [number, number, number];
const add = (a: Vec3, b: Vec3): Vec3 => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const sub = (a: Vec3, b: Vec3): Vec3 => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const scale = (a: Vec3, k: number): Vec3 => [a[0] * k, a[1] * k, a[2] * k];
const ZERO: Vec3 = [0, 0, 0];

interface Helper {
  arguments: ("place" | "number")[];
  required: number;
}

const HELPERS = new Map<string, Helper>([
  ["orbit", { arguments: ["place", "number", "number"], required: 3 }],
  ["on", { arguments: ["place", "number"], required: 0 }],
  ["beside", { arguments: ["place", "number"], required: 1 }],
  ["between", { arguments: ["place", "place", "number"], required: 2 }],
  ["ring", { arguments: ["place", "number", "number", "number"], required: 3 }],
  ["row", { arguments: ["place", "number", "number"], required: 3 }],
  ["stack", { arguments: ["place", "number"], required: 2 }],
  ["grid", { arguments: ["place", "number", "number", "number", "number", "number"], required: 3 }],
]);

/** Words models reach for instead, read as the helper they mean. */
const SYNONYMS = new Map(Object.entries({
  around: "orbit", orbiting: "orbit", circle: "ring", above: "on", atop: "on", onto: "on", ontop: "on",
  next: "beside", nextto: "beside", besides: "beside", midpoint: "between", line: "row", column: "stack",
  pile: "stack", lattice: "grid", array: "grid", point: "at", position: "at", pos: "at", vec: "at",
  vector: "at", vec3: "at", offset: "at", translate: "at",
}));

const GROUND = "ground";
const MAX_COPIES = 216;

const isHelper = (name: string) => name === "at" || HELPERS.has(name);

interface Spot {
  center: Vec3;
  half: Vec3;
}

function isPlace(argument: Expr, objects: Set<string>): boolean {
  if (argument.kind === "call") return isHelper(argument.function);
  if (argument.kind === "name") return argument.name === GROUND || objects.has(argument.name);
  return false;
}

/** ScenePlacement.places: where a position puts its object, or its copies. */
function places(expr: Expr, half: Vec3, objects: Set<string>, spot: (name: string) => Spot, number: (expr: Expr) => number): Vec3[] {
  const base = (argument: Expr | undefined): Spot => {
    if (!argument) return { center: ZERO, half: ZERO };
    if (argument.kind === "name") return spot(argument.name);
    if (argument.kind === "call" && isHelper(argument.function)) {
      const first = places(argument, ZERO, objects, spot, number)[0];
      if (!first) throw new FormulaError("an empty place");
      return { center: first, half: ZERO };
    }
    throw new FormulaError(`${describe(argument)} isn't a place`);
  };
  const value = (argument: Expr | undefined, fallback: number): number => {
    if (!argument) return fallback;
    const result = number(argument);
    if (!Number.isFinite(result)) throw new FormulaError(`${describe(argument)} isn't a number`);
    return result;
  };
  const count = (argument: Expr | undefined): number => Math.trunc(min(max(round(value(argument, 1)), 0), MAX_COPIES));
  const degrees = (value: number) => (value * Math.PI) / 180;

  if (expr.kind === "name") return [spot(expr.name).center];
  if (expr.kind !== "call") throw new FormulaError(`${describe(expr)} isn't a place`);
  const args = expr.arguments;
  switch (expr.function) {
    case "at": {
      if (args[0] && isPlace(args[0], objects)) {
        const from = base(args[0]);
        const rest = args.slice(1);
        return [add(from.center, [value(rest[0], 0), value(rest[1], 0), value(rest[2], 0)])];
      }
      if (!(args.length >= 1 && args.length <= 3)) throw new FormulaError("at() needs x, y and z");
      return [[value(args[0], 0), value(args[1], 0), value(args[2], 0)]];
    }
    case "orbit": {
      if (args.length < 3) throw new FormulaError("orbit() needs a centre, a radius and an angle");
      const center = base(args[0]).center;
      const radius = value(args[1], 1);
      const angle = degrees(value(args[2], 0));
      return [add(center, scale([Math.cos(angle), Math.sin(angle), 0], radius))];
    }
    case "on": {
      const below = base(args[0]);
      const gap = value(args[1], 0);
      return [[below.center[0], below.center[1], below.center[2] + below.half[2] + gap + half[2]]];
    }
    case "beside": {
      if (!args[0]) throw new FormulaError("beside() needs something to stand beside");
      const other = base(args[0]);
      const gap = value(args[1], 0.3 * max(other.half[0], half[0]));
      return [[other.center[0] + other.half[0] + gap + half[0], other.center[1], other.center[2] - other.half[2] + half[2]]];
    }
    case "between": {
      if (args.length < 2) throw new FormulaError("between() needs two places");
      const [a, b] = [base(args[0]).center, base(args[1]).center];
      const fraction = value(args[2], 0.5);
      return [add(a, scale(sub(b, a), fraction))];
    }
    case "ring": {
      if (args.length < 3) throw new FormulaError("ring() needs a centre, a radius and a count");
      const center = base(args[0]).center;
      const radius = value(args[1], 1);
      const n = count(args[2]);
      const start = degrees(value(args[3], 0));
      return Array.from({ length: n }, (_, k) => {
        const angle = start + (2 * Math.PI * k) / n;
        return add(center, scale([Math.cos(angle), Math.sin(angle), 0], radius));
      });
    }
    case "row": {
      if (args.length < 3) throw new FormulaError("row() needs a start, a spacing and a count");
      const start = base(args[0]).center;
      const spacing = value(args[1], 1);
      return Array.from({ length: count(args[2]) }, (_, k) => add(start, [k * spacing, 0, 0]));
    }
    case "stack": {
      if (args.length < 2) throw new FormulaError("stack() needs a base and a count");
      const below = base(args[0]);
      return Array.from({ length: count(args[1]) }, (_, k): Vec3 => [below.center[0], below.center[1], below.center[2] + below.half[2] + half[2] * (2 * k + 1)]);
    }
    case "grid": {
      if (args.length < 3) throw new FormulaError("grid() needs a start, a spacing and how many along x");
      const start = base(args[0]).center;
      const spacing = value(args[1], 1);
      const counts = [count(args[2]), count(args[3]), count(args[4])];
      const parity = args[5] ? Math.trunc(round(value(args[5], 0))) & 1 : null;
      if (counts[0] * counts[1] * counts[2] > MAX_COPIES * (parity === null ? 1 : 2)) throw new FormulaError(`grid() would make more than ${MAX_COPIES} copies`);
      const result: Vec3[] = [];
      for (let k = 0; k < counts[2]; k++) {
        for (let j = 0; j < counts[1]; j++) {
          for (let i = 0; i < counts[0]; i++) {
            if (parity === null || ((i + j + k) & 1) === parity) result.push(add(start, scale([i, j, k], spacing)));
          }
        }
      }
      return result;
    }
    default:
      throw new FormulaError(`${expr.function}() isn't a placement`);
  }
}

// MARK: - Drawing at the starting values

type Quaternion = [number, number, number, number];

const rotationAbout = (angle: number, axis: Vec3): Quaternion => {
  const s = Math.sin(angle / 2);
  return [axis[0] * s, axis[1] * s, axis[2] * s, Math.cos(angle / 2)];
};

function product(a: Quaternion, b: Quaternion): Quaternion {
  const [ax, ay, az, aw] = a;
  const [bx, by, bz, bw] = b;
  return [aw * bx + bw * ax + (ay * bz - az * by), aw * by + bw * ay + (az * bx - ax * bz), aw * bz + bw * az + (ax * by - ay * bx), aw * bw - (ax * bx + ay * by + az * bz)];
}

/** How far a turned box reaches along each axis: the rotation's matrix, made positive, times its half sizes. */
function turned(rotation: Quaternion, local: Vec3): Vec3 {
  const [x, y, z, w] = rotation;
  const columns: Vec3[] = [
    [1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)],
    [2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x)],
    [2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y)],
  ];
  return [0, 1, 2].map((row) => columns.reduce((sum, column, j) => sum + Math.abs(column[row]) * local[j], 0)) as Vec3;
}

const SIZE_NAMES: Record<SolidKind, number> = { sphere: 1, box: 3, cylinder: 2, cone: 2, tube: 1, arrow: 1, ring: 2, plane: 2, axes: 1, text: 0 };
const isSpan = (kind: SolidKind) => kind === "tube" || kind === "arrow";

/** Sizes with the ones left out filled in: a box given one side is a cube. */
function sizes(given: number[], kind: SolidKind): number[] {
  switch (kind) {
    case "sphere": return [given[0] ?? 1];
    case "box": {
      const width = given[0] ?? 1;
      const depth = given.length > 1 ? given[1] : width;
      return [width, depth, given.length > 2 ? given[2] : depth];
    }
    case "cylinder": case "cone": {
      const radius = given[0] ?? 1;
      return [radius, given.length > 1 ? given[1] : radius * 2];
    }
    case "plane": {
      const width = given[0] ?? 1;
      return [width, given.length > 1 ? given[1] : width];
    }
    case "ring": return [given[0] ?? 1, ...given.slice(1, 2)];
    case "tube": case "arrow": case "axes": return given.slice(0, 1);
    case "text": return [];
  }
}

function reach(kind: SolidKind, sized: number[], rotation: Quaternion): Vec3 {
  let local: Vec3;
  switch (kind) {
    case "sphere": local = [sized[0], sized[0], sized[0]]; break;
    case "box": local = [sized[0] / 2, sized[1] / 2, sized[2] / 2]; break;
    case "cylinder": case "cone": local = [sized[0], sized[0], sized[1] / 2]; break;
    case "plane": local = [sized[0] / 2, sized[1] / 2, 0]; break;
    case "ring": local = [sized[0], sized[0], 0]; break;
    case "axes": local = [sized[0] ?? 0, sized[0] ?? 0, sized[0] ?? 0]; break;
    default: return ZERO;
  }
  return turned(rotation, local);
}

/** `formula` with each output it names replaced by that output's own formula (Surface.inlined). */
function inlined(surface: Surface, formula: string): Expr | null {
  const formulas = new Map<string, string>();
  for (const item of surface.outputs) if (!formulas.has(item.name)) formulas.set(item.name, item.formula);
  const expand = (expr: Expr, depth: number): Expr | null => {
    if (depth >= 24) return null;
    switch (expr.kind) {
      case "number": return expr;
      case "name": {
        const source = formulas.get(expr.name);
        if (source === undefined || input(surface, expr.name)) return expr;
        const parsed = tryParse(source);
        return parsed ? expand(parsed, depth + 1) : null;
      }
      case "unary": {
        const operand = expand(expr.operand, depth);
        return operand ? { kind: "unary", op: expr.op, operand } : null;
      }
      case "binary": {
        const [lhs, rhs] = [expand(expr.lhs, depth), expand(expr.rhs, depth)];
        return lhs && rhs ? { kind: "binary", op: expr.op, lhs, rhs } : null;
      }
      case "conditional": {
        const [condition, then, otherwise] = [expand(expr.condition, depth), expand(expr.then, depth), expand(expr.otherwise, depth)];
        return condition && then && otherwise ? { kind: "conditional", condition, then, otherwise } : null;
      }
      case "call": {
        const expanded = expr.arguments.map((argument) => expand(argument, depth)).filter((argument) => argument !== null);
        return expanded.length === expr.arguments.length ? call(expr.function, expanded) : null;
      }
    }
  };
  const parsed = tryParse(formula);
  return parsed ? expand(parsed, 0) : null;
}

/** Whether a plot has a surface at these values: SceneDrawing.sample and SceneMesh.surface, on a 12 by 12 grid. */
function plotDraws(plot: ScenePlot, surface: Surface, values: Map<string, number>): boolean {
  const lookup = (locals: Map<string, number>) => (name: string): number => {
    const local = locals.get(name);
    if (local !== undefined) return local;
    const known = values.get(name);
    if (known !== undefined) return known;
    const constant = CONSTANTS.get(name);
    if (constant !== undefined) return constant;
    throw new FormulaError(`'${name}' isn't an input or an output`);
  };
  const value = (formula: string): number | null => {
    const expr = tryParse(formula);
    if (!expr) return null;
    try {
      const result = evaluateExpr(expr, lookup(new Map()));
      return Number.isFinite(result) ? result : null;
    } catch {
      return null;
    }
  };
  const [x0, x1, y0, y1] = [value(plot.xFrom), value(plot.xTo), value(plot.yFrom), value(plot.yTo)];
  if (x0 === null || x1 === null || y0 === null || y1 === null || !(x0 < x1) || !(y0 < y1)) return false;
  const z = inlined(surface, plot.z);
  if (!z) return false;
  const grid = 12;
  const heights: number[][] = [];
  for (let j = 0; j <= grid; j++) {
    const y = y0 + ((y1 - y0) * j) / grid;
    const row: number[] = [];
    for (let i = 0; i <= grid; i++) {
      const x = x0 + ((x1 - x0) * i) / grid;
      try {
        row.push(evaluateExpr(z, lookup(new Map([["x", x], ["y", y]]))));
      } catch {
        row.push(NaN);
      }
    }
    heights.push(row);
  }
  const ordered = heights.flat().filter(Number.isFinite).sort((a, b) => a - b);
  if (!ordered.length) return false;
  const low = ordered[Math.trunc((ordered.length - 1) * 0.02)];
  const high = ordered[Math.trunc((ordered.length - 1) * 0.98)];
  const margin = max(high - low, 1e-9) * 1.5;
  const kept = heights.map((row) => row.map((height) => (height >= low - margin && height <= high + margin ? height : NaN)));
  // A mesh needs one square of the grid with all four corners.
  for (let j = 0; j < grid; j++) {
    for (let i = 0; i < grid; i++) {
      if ([kept[j][i], kept[j][i + 1], kept[j + 1][i + 1], kept[j + 1][i]].every(Number.isFinite)) return true;
    }
  }
  return false;
}

/** What the checker needs of Scene3D.drawing: the objects placed, and the plots drawn, by position. */
function drawing(scene: Scene3D, surface: Surface, values: Map<string, number>): { placed: Set<string>; plots: Set<number> } {
  const lookup = (name: string): number => {
    const known = values.get(name);
    if (known !== undefined) return known;
    const constant = CONSTANTS.get(name);
    if (constant !== undefined) return constant;
    throw new FormulaError(`'${name}' isn't an input or an output`);
  };
  const number = (expr: Expr): number => {
    const result = evaluateExpr(expr, lookup);
    if (!Number.isFinite(result)) throw new FormulaError(`${describe(expr)} isn't a number`);
    return result;
  };
  const numbers = (list: string): number[] | null => {
    if (trim(list) === "") return [];
    const expr = tryParse(`size(${list})`);
    if (!expr || expr.kind !== "call") return null;
    try {
      return expr.arguments.map(number);
    } catch {
      return null;
    }
  };
  const angle = (formula: string): number | null => {
    if (formula === "") return 0;
    try {
      return (number(parseCached(formula)) * Math.PI) / 180;
    } catch {
      return null;
    }
  };

  const bodies = new Map<string, Vec3>();
  for (const object of scene.objects) {
    if (bodies.has(object.name)) continue;
    const given = numbers(object.size);
    const turn = angle(object.turn);
    const tilt = angle(object.tilt);
    if (given === null || turn === null || tilt === null) continue;
    const sized = sizes(given, object.kind);
    if (!sized.every((size) => size >= 0)) continue;
    const rotation = product(rotationAbout(tilt, [0, 1, 0]), rotationAbout(turn, [0, 0, 1]));
    bodies.set(object.name, reach(object.kind, sized, rotation));
  }

  const names = new Set(scene.objects.map((object) => object.name));
  const byName = new Map<string, SceneObject>();
  for (const object of scene.objects) if (!byName.has(object.name)) byName.set(object.name, object);
  const placed = new Map<string, Vec3[]>();
  const failed = new Set<string>();
  const resolving = new Set<string>();
  const spot = (name: string): Spot => {
    if (name === GROUND && !byName.has(name)) return { center: ZERO, half: ZERO };
    const first = place(name)[0];
    const body = bodies.get(name);
    if (!first || !body) throw new FormulaError(`'${name}' has nowhere to be`);
    return { center: first, half: body };
  };
  const placesOf = (position: string, half: Vec3) => places(parseCached(position), half, names, spot, number);
  const place = (name: string): Vec3[] => {
    const known = placed.get(name);
    if (known) return known;
    const object = byName.get(name);
    const body = bodies.get(name);
    if (failed.has(name) || !object || !body) throw new FormulaError(`there's no object '${name}'`);
    if (resolving.has(name)) throw new FormulaError(`'${name}' is placed against itself`);
    resolving.add(name);
    try {
      const result = placesOf(object.position, body);
      placed.set(name, result);
      return result;
    } finally {
      resolving.delete(name);
    }
  };
  for (const object of scene.objects) {
    if (placed.has(object.name)) continue;
    try {
      place(object.name);
    } catch {
      failed.add(object.name);
    }
  }
  const ends = new Map<string, Vec3[]>();
  for (const object of scene.objects) {
    if (!isSpan(object.kind)) continue;
    try {
      ends.set(object.name, placesOf(object.to, ZERO));
    } catch {
      ends.delete(object.name);
    }
  }
  const placedNames = new Set([...placed.keys()].filter((name) => {
    const object = byName.get(name);
    return object !== undefined && (!isSpan(object.kind) || ends.has(name));
  }));
  const plots = new Set<number>();
  scene.plots.forEach((plot, index) => {
    if (plotDraws(plot, surface, values)) plots.add(index);
  });
  return { placed: placedNames, plots };
}

// MARK: - Finding them

/** Every formula in the scene: placements and sizes, angles and plots. */
export function sceneFormulas(scene: Scene3D): string[] {
  return [
    ...scene.objects.flatMap((object) => [object.position, object.to, object.size === "" ? "" : `size(${object.size})`, object.turn, object.tilt]),
    ...scene.plots.flatMap((plot) => [plot.z, plot.xFrom, plot.xTo, plot.yFrom, plot.yTo]),
  ];
}

/** The inputs the scene depends on. A plot's own x and y aren't inputs, even where the calculation has inputs with those names. */
function sceneInputs(scene: Scene3D, surface: Surface): Set<string> {
  const plotFormulas = new Set(scene.plots.map((plot) => plot.z));
  const found = new Set<string>();
  for (const formula of sceneFormulas(scene)) {
    if (formula === "") continue;
    const expr = tryParse(formula);
    if (!expr) continue;
    for (const name of namesIn(expr)) {
      if (plotFormulas.has(formula) && (name === "x" || name === "y")) continue;
      for (const fed of inputsFeeding(surface, name)) found.add(fed);
    }
  }
  return found;
}

/** What scenes run along on their own: the inputs they play, and the inputs a plot is drawn over. */
export function sceneAxes(surface: Surface): Set<string> {
  return new Set((surface.scenes ?? []).flatMap((scene) => [
    ...(scene.time === "" ? [] : [scene.time]),
    ...(scene.plots.length ? ["x", "y"].filter((name) => input(surface, name)?.role === "variable") : []),
  ]));
}

/** Whether any scene moves with an input, so the inputs have something to show even with no results. */
export function drivesScenes(surface: Surface): boolean {
  return (surface.scenes ?? []).some((scene) =>
    sceneFormulas(scene).some((formula) => {
      let expr: Expr;
      try {
        expr = parse(formula);
      } catch {
        return false;
      }
      return [...namesIn(expr)].some((name) => input(surface, name) !== undefined);
    }));
}

// MARK: - Checking

function unique(raw: string, fallback: string, taken: Set<string>): string {
  const base = raw === "" ? fallback : raw;
  let name = base;
  let suffix = 2;
  while (taken.has(name)) {
    name = `${base}${suffix}`;
    suffix += 1;
  }
  taken.add(name);
  return name;
}

/** Names made usable and unique, placements and formulas repaired, and what can't be drawn at the
 * starting values dropped. Runs after figures and before the blocks that show scenes. */
export function checkScenes(surface: Surface): Issue[] {
  const scenes = surface.scenes;
  if (!scenes) return [];
  const issues: Issue[] = [];
  const fixed = (message: string) => issues.push({ kind: "fixed", message });
  const taken = new Set([
    ...surface.inputs.map((item) => item.name), ...surface.outputs.map((item) => item.name),
    ...(surface.figures ?? []).map((item) => item.name), ...(surface.diagrams ?? []).map((item) => item.name),
  ]);
  const checked: Scene3D[] = [];
  for (const original of scenes) {
    let scene: Scene3D = { ...original, name: unique(identifier(original.name), "scene", taken) };
    scene = checkedScene(scene, surface, fixed);
    if (!scene.objects.length && !scene.plots.length && !scene.molecule) {
      fixed(`Dropped the scene '${scene.name}', which had nothing that could be drawn.`);
      continue;
    }
    checked.push(scene);
  }
  if (checked.length) surface.scenes = checked;
  else delete surface.scenes;
  return issues;
}

function checkedScene(original: Scene3D, surface: Surface, fixed: (message: string) => void): Scene3D {
  const scene: Scene3D = { ...original };
  const calculation = new Set([...surface.inputs.map((item) => item.name), ...surface.outputs.map((item) => item.name)]);

  if (scene.molecule) {
    const molecule = { ...scene.molecule, name: trimAll(scene.molecule.name) };
    if (molecule.name === "") {
      delete scene.molecule;
    } else if (!molecule.structure) {
      fixed(`In the scene '${scene.name}', dropped the molecule '${molecule.name}': PubChem has no 3D structure for it.`);
      delete scene.molecule;
    } else {
      scene.molecule = molecule;
    }
  }

  const objectNames = new Set<string>();
  scene.objects = original.objects.map((object, index) => {
    const base = identifier(object.name) === "" ? `${object.kind}${index + 1}` : identifier(object.name);
    return { ...object, name: unique(base, object.kind, objectNames) };
  });

  const repairedExpr = (expr: Expr, locals: Set<string>): Expr | null => {
    if (!usesKnownFunctions(expr)) return null;
    const renames = new Map<string, string>();
    for (const name of namesIn(expr)) {
      if (calculation.has(name) || locals.has(name) || CONSTANTS.has(name)) continue;
      const match = closestName(name, new Set([...calculation, ...locals]));
      if (match === null) return null;
      renames.set(name, match);
    }
    return renames.size ? renamed(expr, renames) : expr;
  };
  /** A formula that parses and only uses names it can, with near misses renamed. Null if not. */
  const repaired = (formula: string, locals = new Set<string>()): string | null => {
    const source = trim(formula);
    if (source === "") return null;
    const expr = tryParse(source);
    if (!expr || !usesKnownFunctions(expr)) return null;
    const fixedExpr = repairedExpr(expr, locals);
    return fixedExpr ? describe(fixedExpr) : null;
  };

  /** An object, the ground, or a nested placement, as a place argument. */
  const placeArgument = (argument: Expr, placing: string): Expr | null => {
    if (argument.kind === "name") {
      const raw = argument.name;
      if (objectNames.has(raw)) return raw === placing ? null : argument;
      switch (lower(raw)) {
        case "ground": case "floor": case "table": case "surface": return nameExpr(GROUND);
        case "origin": case "center": case "centre": case "o": return call("at", [numberExpr(0), numberExpr(0), numberExpr(0)]);
      }
      const match = closestName(raw, objectNames);
      if (match !== null && match !== placing) return nameExpr(match);
      return null;
    }
    if (argument.kind === "call") return placement(argument, placing);
    return null;
  };

  /** Whether `at` was given a place first, rather than a number. */
  const namesPlace = (argument: Expr): boolean => {
    if (argument.kind === "call") return isHelper(SYNONYMS.get(argument.function) ?? argument.function);
    if (argument.kind === "name") return !calculation.has(argument.name) && !CONSTANTS.has(argument.name);
    return false;
  };

  /** A placement with its helper and arguments checked and repaired. Null if it can't be read. */
  const placement = (expr: Expr, placing: string): Expr | null => {
    if (expr.kind === "name") return placeArgument(expr, placing);
    if (expr.kind !== "call") return null;
    const raw = expr.function;
    const args = expr.arguments;
    const fn = SYNONYMS.get(raw) ?? (isHelper(raw) ? raw : closestName(raw, new Set([...HELPERS.keys(), "at"])));
    if (fn === null) return null;
    if (fn === "at") {
      // From a place, or at numbers.
      const from = args[0] && namesPlace(args[0]) ? placeArgument(args[0], placing) : null;
      if (from) {
        const offsets = args.slice(1, 4).map((argument) => repairedExpr(argument, new Set()));
        return offsets.some((offset) => offset === null) ? null : call("at", [from, ...(offsets as Expr[])]);
      }
      const numbers = args.slice(0, 3).map((argument) => repairedExpr(argument, new Set()));
      if (!numbers.length || numbers.some((number) => number === null)) return null;
      return call("at", numbers as Expr[]);
    }
    const helper = HELPERS.get(fn);
    if (!helper || args.length < helper.required) return null;
    const checked: Expr[] = [];
    for (let index = 0; index < Math.min(args.length, helper.arguments.length); index++) {
      const fixedArgument = helper.arguments[index] === "place" ? placeArgument(args[index], placing) : repairedExpr(args[index], new Set());
      if (!fixedArgument) return null;
      checked.push(fixedArgument);
    }
    return call(fn, checked);
  };

  /** A position as written, read leniently: (1, 2, 3) and [1, 2, 3] as at(1, 2, 3). */
  const position = (raw: string, placing: string): string | null => {
    let source = trimAll(raw);
    if (source.startsWith("[") && source.endsWith("]")) source = "(" + dropLast(dropFirst(source)) + ")";
    if (source === "") return null;
    const expr = tryParse(source);
    if (expr && (expr.kind === "call" || expr.kind === "name")) {
      const fixedExpr = placement(expr, placing);
      return fixedExpr ? describe(fixedExpr) : null;
    }
    // Coordinates on their own.
    const inner = source.startsWith("(") && source.endsWith(")") ? dropLast(dropFirst(source)) : source;
    const wrapped = tryParse(`at(${inner})`);
    if (!wrapped) return null;
    const fixedExpr = placement(wrapped, placing);
    return fixedExpr ? describe(fixedExpr) : null;
  };

  scene.objects = scene.objects.flatMap((originalObject): SceneObject[] => {
    const object = { ...originalObject };
    const what = `the ${lower(words(object.kind))} '${object.name}'`;
    const drop = (why: string): SceneObject[] => {
      fixed(`In the scene '${scene.name}', dropped ${what}, ${why}.`);
      return [];
    };
    if (trim(object.position) === "") {
      object.position = "at(0, 0, 0)";
    } else {
      const place = position(object.position, object.name);
      if (place === null) return drop(`whose position can't be read: ${object.position}`);
      object.position = place;
    }
    if (isSpan(object.kind)) {
      const end = position(object.to, object.name);
      if (end === null) return drop("which needs somewhere to end");
      object.to = end;
    } else {
      object.to = "";
    }

    // Sizes, as many as the kind takes.
    const size = trim(object.size);
    if (size === "" || object.kind === "text") {
      object.size = "";
    } else {
      const expr = tryParse(`size(${size})`);
      if (!expr || expr.kind !== "call") return drop(`whose size can't be read: ${size}`);
      const fixedSizes = expr.arguments.slice(0, SIZE_NAMES[object.kind]).map((argument) => repairedExpr(argument, new Set()));
      if (fixedSizes.some((item) => item === null)) return drop(`whose size can't be read: ${size}`);
      object.size = (fixedSizes as Expr[]).map(describe).join(", ");
    }
    for (const key of ["turn", "tilt"] as const) {
      const raw = trim(object[key]);
      if (raw === "" || raw === "0") {
        object[key] = "";
        continue;
      }
      const angle = repaired(raw);
      if (angle === null) {
        fixed(`In the scene '${scene.name}', ${what} is drawn upright: its angle can't be read (${raw}).`);
        object[key] = "";
        continue;
      }
      object[key] = angle;
    }
    object.label = labelIn(object.label, surface);
    if (object.kind === "text" && object.label === "") return drop("with nothing to say");
    return [object];
  });

  // Plots run along their own x and y. Without a range they take their inputs', or -2 to 2.
  scene.plots = original.plots.flatMap((originalPlot): ScenePlot[] => {
    const plot = { ...originalPlot };
    const z = repaired(plot.z, new Set(["x", "y"]));
    if (z === null) {
      fixed(`In the scene '${scene.name}', dropped a plot whose formula can't be read: ${plot.z}`);
      return [];
    }
    plot.z = z;
    for (const [axis, from, to] of [["x", "xFrom", "xTo"], ["y", "yFrom", "yTo"]] as const) {
      const along = input(surface, axis);
      const range = along ? safeRange(along) : [-2, 2];
      plot[from] = repaired(plot[from]) ?? plain(range[0]);
      plot[to] = repaired(plot[to]) ?? plain(range[1]);
    }
    plot.label = labelIn(plot.label, surface);
    return [plot];
  });

  // The time it plays: an input that can be swept. A variable only the scene runs along is its
  // time even if the model didn't say so.
  const time = identifier(scene.time);
  const sweepable = new Set(surface.inputs.filter((item) => item.role !== "given" && isNumeric(item.format)).map((item) => item.name));
  const match = time === "" ? null : closestName(time, sweepable);
  if (sweepable.has(time)) {
    scene.time = time;
  } else if (match !== null) {
    scene.time = match;
  } else {
    const variables = [...sceneInputs(scene, surface)].filter((name) => input(surface, name)?.role === "variable" && !((name === "x" || name === "y") && scene.plots.length));
    scene.time = variables.length === 1 ? variables[0] : "";
  }

  // Last, what the formulas can't show until they're worked out.
  const drawn = drawing(scene, surface, evaluate(surface, initialValues(surface)).values);
  scene.objects = scene.objects.filter((object) => {
    if (drawn.placed.has(object.name)) return true;
    fixed(`In the scene '${scene.name}', dropped the ${lower(words(object.kind))} '${object.name}', which can't be placed at the starting values.`);
    return false;
  });
  scene.plots = scene.plots.filter((plot, index) => {
    if (drawn.plots.has(index)) return true;
    fixed(`In the scene '${scene.name}', dropped a plot (${plot.z}) that can't be drawn at the starting values.`);
    return false;
  });
  return scene;
}

/** A scene block, pointed at a scene that exists. Null if there's nothing to show. */
export function sceneBlock(original: Block, surface: Surface, fixed: (message: string) => void): Block | null {
  const block: Block = { ...original, over: "", text: "", items: [], children: [] };
  block.ref = trim(block.ref);
  const names = new Set((surface.scenes ?? []).map((scene) => scene.name));
  if (names.has(block.ref)) return block;
  const match = closestName(block.ref, names) ?? (names.size === 1 && block.ref === "" ? [...names][0] : null);
  if (match !== null) {
    block.ref = match;
    return block;
  }
  fixed(`Removed a scene of '${block.ref}', which isn't defined.`);
  return null;
}

function controls(block: Block): Set<string> {
  if (isControl(block.kind)) return new Set([block.ref]);
  const found = new Set<string>();
  for (const child of block.children) for (const name of controls(child)) found.add(name);
  return found;
}

/** A scene no block shows still gets shown: just before the controls that move it, or after the opening block. */
export function placeScenes(surface: Surface): Issue[] {
  const scenes = surface.scenes;
  if (!scenes) return [];
  const issues: Issue[] = [];
  const ids = (blocks: Block[]): string[] => blocks.flatMap((block) => [block.id, ...ids(block.children)]);
  const shown = (blocks: Block[], into = new Set<string>()): Set<string> => {
    for (const block of blocks) {
      if (block.kind === "scene") into.add(block.ref);
      shown(block.children, into);
    }
    return into;
  };
  const used = new Set(ids(surface.blocks));
  const showing = shown(surface.blocks);
  for (const scene of scenes) {
    if (showing.has(scene.name)) continue;
    let id = `scene-${scene.name}`;
    while (used.has(id)) id += "-2";
    used.add(id);
    const block = makeBlock(id, "scene", { ref: scene.name });
    const moving = sceneInputs(scene, surface);
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
    issues.push({ kind: "fixed", message: `Showed the scene '${scene.name}'.` });
  }
  return issues;
}
