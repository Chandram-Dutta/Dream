// What the model writes, turned into a page (Dream/Generation/Wire*.swift's conversions): a whole
// answer as Surface.init(_ wire:reference:) reads it, and one still streaming as
// Surface.init(partial:reference:) does, keeping whatever has arrived. Block ids are positions, so
// blocks keep their identity while they stream in.
//
// `wireIsWhole` says whether the app would read an answer as whole (WireSurface decoding it): every
// field there, of the right type, every choice one the schema allows. Anything else is read as an
// answer cut short.

import { parseValue } from "./records.ts";
import { isWhitespace, max, min, splitWhere, trim, trimAll } from "./swift.ts";
import type {
  Accent, Action, Block, BlockKind, Citation, Diagram, DiagramShape, FieldType, Figure, FigureShape, Format, Input, InputRole,
  RecordCollection, RecordField, RecordValue, Reference, Scene3D, SceneObject, ScenePlot, ShapeKind, ShapeTone, SolidKind, SolidTone,
  Sound, Subject, Surface, Tone, Waveform,
} from "./types.ts";

type Wire = Record<string, unknown>;

const SUBJECT_ACCENTS: Record<Subject, Accent> = {
  money: "green", health: "pink", food: "orange", places: "blue", nature: "teal", science: "indigo",
  tech: "cyan", home: "yellow", learning: "purple", sport: "red",
};

const ENUMS = {
  format: ["number", "integer", "currency", "percent", "toggle", "choice"],
  mode: ["use", "decide", "learn", "read"],
  subject: ["money", "health", "food", "places", "nature", "science", "tech", "home", "learning", "sport"],
  role: ["adjustable", "given", "variable", "live"],
  blockKind: [
    "hero", "metric", "slider", "stepper", "field", "toggle", "picker", "chart", "paragraph", "facts", "bullets", "steps", "timeline", "stat",
    "equation", "data", "section", "row", "sound", "list", "add", "figure", "diagram", "action", "scene",
  ],
  fieldType: ["text", "number", "currency", "date", "done", "choice", "rating"],
  waveform: ["sine", "square", "triangle", "sawtooth"],
  soundKind: ["tones", "recording"],
  shapeKind: ["segment", "arrow", "polygon", "square", "circle", "arc", "angle", "rightAngle", "text", "path"],
  shapeTone: ["main", "contrast", "plain", "guide"],
  diagramShape: ["flow", "cycle", "tree", "hub"],
  actionKind: ["calendarEvent", "reminder", "directions"],
  travel: ["driving", "walking", "transit"],
  solidKind: ["sphere", "box", "cylinder", "cone", "tube", "arrow", "ring", "plane", "axes", "text"],
  solidTone: ["main", "contrast", "plain", "guide", "glow"],
} as const;

// MARK: - Reading what arrived

const object = (value: unknown): Wire | undefined =>
  value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Wire) : undefined;
const text = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);
const numeric = (value: unknown): number | undefined => (typeof value === "number" && Number.isFinite(value) ? value : undefined);
const list = (value: unknown): unknown[] | undefined => (Array.isArray(value) ? value : undefined);
const objects = (value: unknown): Wire[] => (list(value) ?? []).map(object).filter((item): item is Wire => item !== undefined);
const strings = (value: unknown): string[] => (list(value) ?? []).filter((item): item is string => typeof item === "string");
function choice<T extends string>(value: unknown, allowed: readonly T[]): T | undefined {
  return typeof value === "string" && (allowed as readonly string[]).includes(value) ? (value as T) : undefined;
}

// MARK: - Whole answers

/** Surface.init(_ wire:reference:): a finished answer as a page. */
export function fromWire(raw: unknown, reference: Reference | null): Surface {
  const wire = object(raw) ?? {};
  const surface: Surface = {
    title: text(wire.title) ?? "",
    summary: text(wire.summary) ?? "",
    symbol: text(wire.symbol) ?? "",
    accent: SUBJECT_ACCENTS[choice(wire.subject, ENUMS.subject) ?? "home"],
    inputs: objects(wire.inputs).map((item) => inputFrom(item, false)!),
    outputs: objects(wire.outputs).map((item) => outputFrom(item, false)!),
    blocks: blocksFrom(objects(wire.blocks), "block", false),
    related: strings(wire.related),
  };
  if (reference) surface.reference = reference;
  const question = text(wire.question) ?? "";
  if (question !== "") surface.question = question;
  const collections = objects(wire.collections).map((item) => collectionFrom(item, false)!);
  if (collections.length) surface.collections = collections;
  const sounds = objects(wire.sounds).map((item) => soundFrom(item, false)!);
  if (sounds.length) surface.sounds = sounds;
  takeVisuals(surface, objects(wire.figures).map((item) => figureFrom(item, false)!), objects(wire.diagrams).map((item) => diagramFrom(item, false)!));
  const actions = objects(wire.actions).map((item) => actionFrom(item, false)!);
  if (actions.length) surface.actions = actions;
  takeScenes(surface, objects(wire.scenes).map((item) => sceneFrom(item, false)!));
  const citations = strings(wire.citations);
  if (citations.length) surface.citations = citations.map(named);
  surface.mode = choice(wire.mode, ENUMS.mode) ?? "use";
  return surface;
}

/** Surface.init(partial:reference:): the answer so far, while it streams. */
export function fromPartial(raw: unknown, reference: Reference | null): Surface {
  const wire = object(raw) ?? {};
  const subject = choice(wire.subject, ENUMS.subject);
  const surface: Surface = {
    title: text(wire.title) ?? "",
    summary: text(wire.summary) ?? "",
    symbol: text(wire.symbol) ?? "sparkles",
    accent: subject ? SUBJECT_ACCENTS[subject] : "blue",
    inputs: objects(wire.inputs).map((item) => inputFrom(item, true)).filter((item) => item !== null),
    outputs: objects(wire.outputs).map((item) => outputFrom(item, true)).filter((item) => item !== null),
    blocks: blocksFrom(objects(wire.blocks), "block", true),
    related: strings(wire.related),
  };
  if (reference) surface.reference = reference;
  const question = text(wire.question);
  if (question) surface.question = question;
  const collections = objects(wire.collections).map((item) => collectionFrom(item, true)).filter((item) => item !== null);
  if (collections.length) surface.collections = collections;
  const sounds = objects(wire.sounds).map((item) => soundFrom(item, true)).filter((item) => item !== null);
  if (sounds.length) surface.sounds = sounds;
  const mode = choice(wire.mode, ENUMS.mode);
  if (mode) surface.mode = mode;
  takeVisuals(
    surface,
    objects(wire.figures).map((item) => figureFrom(item, true)).filter((item) => item !== null),
    objects(wire.diagrams).map((item) => diagramFrom(item, true)).filter((item) => item !== null),
  );
  const actions = objects(wire.actions).map((item) => actionFrom(item, true)).filter((item) => item !== null);
  if (actions.length) surface.actions = actions;
  takeScenes(surface, objects(wire.scenes).map((item) => sceneFrom(item, true)).filter((item) => item !== null));
  return surface;
}

/** An address as the model wrote it, before the checker finds the page it means. */
export function named(url: string): Citation {
  return { title: "", site: "", url: trimAll(url) };
}

function takeVisuals(surface: Surface, figures: Figure[], diagrams: Diagram[]) {
  if (figures.length) surface.figures = figures;
  else delete surface.figures;
  if (diagrams.length) surface.diagrams = diagrams;
  else delete surface.diagrams;
}

function takeScenes(surface: Surface, scenes: Scene3D[]) {
  if (scenes.length) surface.scenes = scenes;
  else delete surface.scenes;
}

// MARK: - The calculation

function inputFrom(wire: Wire, partial: boolean): Input | null {
  const name = text(wire.name);
  if (partial && !name) return null;
  const initial = numeric(wire.initial) ?? 0;
  const lowest = numeric(wire.min) ?? (partial ? min(0, initial) : 0);
  return {
    name: name ?? "",
    label: text(wire.label) ?? "",
    format: choice<Format>(wire.format, ENUMS.format) ?? "number",
    initial,
    min: lowest,
    max: numeric(wire.max) ?? (partial ? max(lowest + 1, initial * 2) : 0),
    step: numeric(wire.step) ?? 0,
    options: strings(wire.options),
    role: choice<InputRole>(wire.role, ENUMS.role) ?? "adjustable",
    symbol: text(wire.symbol) ?? "",
    unit: text(wire.unit) ?? "",
    source: text(wire.source) ?? "",
  };
}

function outputFrom(wire: Wire, partial: boolean) {
  const name = text(wire.name);
  if (partial && !name) return null;
  return {
    name: name ?? "",
    label: text(wire.label) ?? "",
    formula: text(wire.formula) ?? "",
    format: choice<Format>(wire.format, ENUMS.format) ?? "number",
    symbol: text(wire.symbol) ?? "",
    unit: text(wire.unit) ?? "",
  };
}

function blocksFrom(wires: Wire[], prefix: string, partial: boolean): Block[] {
  const blocks: Block[] = [];
  wires.forEach((wire, index) => {
    const kind = choice<BlockKind>(wire.kind, ENUMS.blockKind);
    if (partial && !kind) return;
    const id = `${prefix}-${index}`;
    blocks.push({
      id,
      kind: kind ?? "paragraph",
      title: text(wire.title) ?? "",
      text: text(wire.text) ?? "",
      ref: text(wire.ref) ?? "",
      over: text(wire.over) ?? "",
      items: objects(wire.items).map((item) => ({ label: text(item.label) ?? "", value: text(item.value) ?? "" })),
      children: blocksFrom(objects(wire.children), id, partial),
    });
  });
  return blocks;
}

// MARK: - Lists

function fieldFrom(wire: Wire, partial: boolean): RecordField | null {
  const name = text(wire.name);
  if (partial && !name) return null;
  return {
    name: name ?? "",
    label: text(wire.label) ?? "",
    type: choice<FieldType>(wire.type, ENUMS.fieldType) ?? "text",
    options: strings(wire.options),
  };
}

function collectionFrom(wire: Wire, partial: boolean): RecordCollection | null {
  const name = text(wire.name);
  if (partial && !name) return null;
  const fields = objects(wire.fields).map((item) => fieldFrom(item, partial)).filter((item) => item !== null);
  const collection: RecordCollection = {
    name: name ?? "",
    label: text(wire.label) ?? "",
    entry: text(wire.entry) ?? "",
    fields,
    starters: objects(wire.starters).map((starter) => starterFrom(strings(starter.values), fields)),
  };
  const source = trimAll(text(wire.source) ?? "");
  if (source !== "") collection.source = source;
  return collection;
}

/** A starter's values, written in field order, by field name. */
function starterFrom(values: string[], fields: RecordField[]): Record<string, RecordValue> {
  const result: Record<string, RecordValue> = {};
  for (let index = 0; index < Math.min(values.length, fields.length); index++) {
    const value = parseValue(fields[index], values[index]);
    if (value !== null) result[fields[index].name] = value;
  }
  return result;
}

// MARK: - Sounds

function toneFrom(wire: Wire, partial: boolean): Tone | null {
  const frequency = text(wire.frequency);
  if (partial && !frequency) return null;
  return { frequency: frequency ?? "", amplitude: text(wire.amplitude) ?? "", waveform: choice<Waveform>(wire.waveform, ENUMS.waveform) ?? "sine" };
}

function soundFrom(wire: Wire, partial: boolean): Sound | null {
  const name = text(wire.name);
  if (partial && !name) return null;
  const isRecording = choice(wire.kind, ENUMS.soundKind) === "recording";
  return {
    name: name ?? "",
    label: text(wire.label) ?? "",
    tones: isRecording ? [] : objects(wire.tones).map((item) => toneFrom(item, partial)).filter((item) => item !== null),
    search: isRecording ? text(wire.search) ?? "" : "",
  };
}

// MARK: - Figures and diagrams

/** "A, B, C" → [A, B, C]. */
export function pointNames(written: string): string[] {
  return splitWhere(written, (character) => character === "," || isWhitespace(character));
}

function figureFrom(wire: Wire, partial: boolean): Figure | null {
  const name = text(wire.name);
  if (partial && !name) return null;
  const points = objects(wire.points).flatMap((point) => {
    const [pointName, x, y] = [text(point.name), text(point.x), text(point.y)];
    if (partial && (pointName === undefined || x === undefined || y === undefined)) return [];
    return [{ name: pointName ?? "", x: x ?? "", y: y ?? "", label: text(point.label) ?? "" }];
  });
  const shapes = objects(wire.shapes).flatMap((shape): FigureShape[] => {
    const kind = choice<ShapeKind>(shape.kind, ENUMS.shapeKind);
    if (partial && !kind) return [];
    return [{
      kind: kind ?? "segment",
      points: pointNames(text(shape.points) ?? ""),
      radius: text(shape.radius) ?? "",
      from: text(shape.from) ?? "",
      to: text(shape.to) ?? "",
      over: text(shape.over) ?? "",
      x: text(shape.x) ?? "",
      y: text(shape.y) ?? "",
      label: text(shape.label) ?? "",
      tone: choice<ShapeTone>(shape.tone, ENUMS.shapeTone) ?? "plain",
    }];
  });
  return { name: name ?? "", points, shapes };
}

function diagramFrom(wire: Wire, partial: boolean): Diagram | null {
  const name = text(wire.name);
  if (partial && !name) return null;
  return {
    name: name ?? "",
    shape: choice<DiagramShape>(wire.shape, ENUMS.diagramShape) ?? "flow",
    nodes: objects(wire.nodes).flatMap((node) => {
      const [id, label] = [text(node.id), text(node.label)];
      if (partial && (id === undefined || label === undefined)) return [];
      return [{ id: id ?? "", label: label ?? "", detail: text(node.detail) ?? "" }];
    }),
    edges: objects(wire.edges).flatMap((edge) => {
      const [from, to] = [text(edge.from), text(edge.to)];
      if (partial && (from === undefined || to === undefined)) return [];
      return [{ from: from ?? "", to: to ?? "", label: text(edge.label) ?? "" }];
    }),
  };
}

// MARK: - Actions

function actionFrom(wire: Wire, partial: boolean): Action | null {
  const name = text(wire.name);
  const kind = choice(wire.kind, ENUMS.actionKind);
  if (partial && (!name || !kind)) return null;
  const travel = choice(wire.travel, ENUMS.travel);
  const value = (key: string) => text(wire[key]) ?? "";
  let all: Record<string, string>;
  switch (kind ?? "calendarEvent") {
    case "calendarEvent":
      all = { title: value("title"), day: value("day"), time: value("time"), duration: value("duration"), place: value("place"), notes: value("notes") };
      break;
    case "reminder":
      all = { title: value("title"), day: value("day"), time: value("time"), notes: value("notes") };
      break;
    default:
      all = { title: value("title"), place: value("place"), from: value("from"), travel: travel ?? (partial ? "" : "driving") };
  }
  const fields: Record<string, string> = {};
  for (const [key, written] of Object.entries(all)) if (trim(written) !== "") fields[key] = written;
  return { name: name ?? "", kind: kind ?? "calendarEvent", fields };
}

// MARK: - Scenes

function sceneFrom(wire: Wire, partial: boolean): Scene3D | null {
  const name = text(wire.name);
  if (partial && !name) return null;
  const objectsIn = objects(wire.objects).flatMap((item): SceneObject[] => {
    const [objectName, kind, position] = [text(item.name), choice<SolidKind>(item.kind, ENUMS.solidKind), text(item.position)];
    if (partial && (objectName === undefined || kind === undefined || position === undefined)) return [];
    return [{
      name: objectName ?? "",
      kind: kind ?? "sphere",
      position: position ?? "",
      to: text(item.to) ?? "",
      size: text(item.size) ?? "",
      turn: text(item.turn) ?? "",
      tilt: text(item.tilt) ?? "",
      label: text(item.label) ?? "",
      tone: choice<SolidTone>(item.tone, ENUMS.solidTone) ?? "plain",
    }];
  });
  const plots = objects(wire.plots).flatMap((plot): ScenePlot[] => {
    const values = [text(plot.z), text(plot.xFrom), text(plot.xTo), text(plot.yFrom), text(plot.yTo)];
    if (partial && values.some((value) => value === undefined)) return [];
    const [z, xFrom, xTo, yFrom, yTo] = values.map((value) => value ?? "");
    return [{ z, xFrom, xTo, yFrom, yTo, label: text(plot.label) ?? "" }];
  });
  const scene: Scene3D = { name: name ?? "", objects: objectsIn, plots, time: text(wire.time) ?? "" };
  // A whole answer's molecule is trimmed; one still streaming is taken as it is.
  const molecule = partial ? text(wire.molecule) ?? "" : trimAll(text(wire.molecule) ?? "");
  if (molecule !== "") scene.molecule = { name: molecule };
  return scene;
}


// MARK: - Whether it's whole

/** What the schema asks for: a string, a number, a list of strings, one of some words, an object
 * with these properties, or a list of such objects. */
type Shape = "string" | "number" | "strings" | { oneOf: readonly string[] } | { properties: Record<string, Shape> } | { each: Record<string, Shape> };

const oneOf = (words: readonly string[]): Shape => ({ oneOf: words });
const each = (properties: Record<string, Shape>): Shape => ({ each: properties });

const INPUT: Record<string, Shape> = {
  name: "string", label: "string", role: oneOf(ENUMS.role), source: "string", symbol: "string", unit: "string", format: oneOf(ENUMS.format),
  initial: "number", min: "number", max: "number", step: "number", options: "strings",
};
const OUTPUT: Record<string, Shape> = { name: "string", label: "string", symbol: "string", unit: "string", formula: "string", format: oneOf(ENUMS.format) };
const BLOCK: Record<string, Shape> = {
  kind: oneOf(ENUMS.blockKind), title: "string", text: "string", ref: "string", over: "string", items: each({ label: "string", value: "string" }),
};
BLOCK.children = each(BLOCK);
const COLLECTION: Record<string, Shape> = {
  name: "string", label: "string", entry: "string",
  fields: each({ name: "string", label: "string", type: oneOf(ENUMS.fieldType), options: "strings" }),
  starters: each({ values: "strings" }), source: "string",
};
const SOUND: Record<string, Shape> = {
  name: "string", label: "string", kind: oneOf(ENUMS.soundKind),
  tones: each({ frequency: "string", amplitude: "string", waveform: oneOf(ENUMS.waveform) }), search: "string",
};
const FIGURE: Record<string, Shape> = {
  name: "string",
  points: each({ name: "string", x: "string", y: "string", label: "string" }),
  shapes: each({
    kind: oneOf(ENUMS.shapeKind), points: "string", radius: "string", from: "string", to: "string", over: "string", x: "string", y: "string",
    label: "string", tone: oneOf(ENUMS.shapeTone),
  }),
};
const DIAGRAM: Record<string, Shape> = {
  name: "string", shape: oneOf(ENUMS.diagramShape),
  nodes: each({ id: "string", label: "string", detail: "string" }), edges: each({ from: "string", to: "string", label: "string" }),
};
const ACTION: Record<string, Shape> = {
  name: "string", kind: oneOf(ENUMS.actionKind), title: "string", day: "string", time: "string", duration: "string", place: "string",
  from: "string", travel: oneOf(ENUMS.travel), notes: "string",
};
const SCENE: Record<string, Shape> = {
  name: "string", molecule: "string",
  objects: each({
    name: "string", kind: oneOf(ENUMS.solidKind), position: "string", to: "string", size: "string", turn: "string", tilt: "string",
    label: "string", tone: oneOf(ENUMS.solidTone),
  }),
  plots: each({ z: "string", xFrom: "string", xTo: "string", yFrom: "string", yTo: "string", label: "string" }),
  time: "string",
};
const SURFACE: Record<string, Shape> = {
  subject: oneOf(ENUMS.subject), mode: oneOf(ENUMS.mode), title: "string", summary: "string", symbol: "string", collections: each(COLLECTION),
  question: "string", inputs: each(INPUT), outputs: each(OUTPUT), sounds: each(SOUND), figures: each(FIGURE), diagrams: each(DIAGRAM),
  actions: each(ACTION), scenes: each(SCENE), blocks: each(BLOCK), related: "strings", citations: "strings",
};

function has(value: unknown, properties: Record<string, Shape>): boolean {
  const wire = object(value);
  return wire !== undefined && Object.entries(properties).every(([key, shape]) => key in wire && matches(wire[key], shape));
}

function matches(value: unknown, shape: Shape): boolean {
  if (shape === "string") return typeof value === "string";
  if (shape === "number") return typeof value === "number" && Number.isFinite(value);
  if (shape === "strings") return Array.isArray(value) && value.every((item) => typeof item === "string");
  if ("oneOf" in shape) return typeof value === "string" && shape.oneOf.includes(value);
  if ("each" in shape) return Array.isArray(value) && value.every((item) => has(item, shape.each));
  return has(value, shape.properties);
}

/** Whether the app reads this answer as whole (WireSurface decodes it), rather than as one cut short. */
export function wireIsWhole(raw: unknown): boolean {
  return has(raw, SURFACE);
}
