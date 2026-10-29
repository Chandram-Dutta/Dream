// A page as the app's Swift types encode it (Dream/Engine/Surface.swift and the types it holds),
// field for field, so what the server sends the app decodes as it would have made it itself.
// Optional fields are left out rather than null, as Swift's Codable leaves out a nil.

export type Accent = "blue" | "teal" | "green" | "mint" | "orange" | "pink" | "purple" | "indigo" | "red" | "yellow" | "cyan" | "brown";
export type Mode = "use" | "decide" | "learn" | "read";
export type Subject = "money" | "health" | "food" | "places" | "nature" | "science" | "tech" | "home" | "learning" | "sport";
export type Format = "number" | "integer" | "currency" | "percent" | "toggle" | "choice";
export type InputRole = "adjustable" | "given" | "variable" | "live";
export type BlockKind =
  | "hero" | "metric" | "slider" | "stepper" | "field" | "toggle" | "picker" | "chart"
  | "paragraph" | "facts" | "bullets" | "steps" | "timeline" | "stat" | "equation" | "data"
  | "section" | "row"
  | "sound"
  | "list" | "add"
  | "figure" | "diagram"
  | "action"
  | "scene";

export interface Item {
  label: string;
  value: string;
}

export interface Block {
  id: string;
  kind: BlockKind;
  title: string;
  text: string;
  ref: string;
  over: string;
  items: Item[];
  children: Block[];
}

export interface Input {
  name: string;
  label: string;
  format: Format;
  initial: number;
  min: number;
  max: number;
  step: number;
  options: string[];
  role: InputRole;
  symbol: string;
  unit: string;
  source: string;
}

export interface Output {
  name: string;
  label: string;
  formula: string;
  format: Format;
  symbol: string;
  unit: string;
}

/** Wikipedia's article for the page. */
export interface Reference {
  title: string;
  extract: string;
  url: string;
  imageURL?: string;
}

/** A page the surface credits (Citation.swift). */
export interface Citation {
  title: string;
  site: string;
  url: string;
  date?: string;
}

// MARK: - Sounds

export type Waveform = "sine" | "square" | "triangle" | "sawtooth";

export interface Tone {
  frequency: string;
  amplitude: string;
  waveform: Waveform;
}

export interface Recording {
  title: string;
  audioURL: string;
  pageURL: string;
  credit: string;
  licence: string;
  duration?: number;
}

export interface Sound {
  name: string;
  label: string;
  tones: Tone[];
  search: string;
  recording?: Recording;
}

// MARK: - Lists

export type FieldType = "text" | "number" | "currency" | "date" | "done" | "choice" | "rating";

/** A number (amounts, dates as seconds since 1970, done as 1 or 0) or text. */
export type RecordValue = number | string;

export interface RecordField {
  name: string;
  label: string;
  type: FieldType;
  options: string[];
}

export interface RecordCollection {
  name: string;
  label: string;
  entry: string;
  fields: RecordField[];
  starters: Record<string, RecordValue>[];
  source?: string;
}

/** One of the user's entries, as the engine sees it. */
export interface Entry {
  values: Map<string, RecordValue>;
  order: number;
  /** Seconds since 1970. */
  created: number;
}

// MARK: - Figures and diagrams

export type ShapeKind = "segment" | "arrow" | "polygon" | "square" | "circle" | "arc" | "angle" | "rightAngle" | "text" | "path";
export type ShapeTone = "main" | "contrast" | "plain" | "guide";

export interface FigurePoint {
  name: string;
  x: string;
  y: string;
  label: string;
}

export interface FigureShape {
  kind: ShapeKind;
  points: string[];
  radius: string;
  from: string;
  to: string;
  over: string;
  x: string;
  y: string;
  label: string;
  tone: ShapeTone;
}

export interface Figure {
  name: string;
  points: FigurePoint[];
  shapes: FigureShape[];
}

export type DiagramShape = "flow" | "cycle" | "tree" | "hub";

export interface DiagramNode {
  id: string;
  label: string;
  detail: string;
}

export interface DiagramEdge {
  from: string;
  to: string;
  label: string;
}

export interface Diagram {
  name: string;
  shape: DiagramShape;
  nodes: DiagramNode[];
  edges: DiagramEdge[];
}

// MARK: - Scenes

export type SolidKind = "sphere" | "box" | "cylinder" | "cone" | "tube" | "arrow" | "ring" | "plane" | "axes" | "text";
export type SolidTone = "main" | "contrast" | "plain" | "guide" | "glow";

export interface SceneObject {
  name: string;
  kind: SolidKind;
  position: string;
  to: string;
  size: string;
  turn: string;
  tilt: string;
  label: string;
  tone: SolidTone;
}

export interface ScenePlot {
  z: string;
  xFrom: string;
  xTo: string;
  yFrom: string;
  yTo: string;
  label: string;
}

export interface MoleculeStructure {
  cid: number;
  title: string;
  formula: string;
  atoms: { element: number; x: number; y: number; z: number }[];
  bonds: { from: number; to: number; order: number }[];
}

export interface Molecule {
  name: string;
  structure?: MoleculeStructure;
}

export interface Scene3D {
  name: string;
  objects: SceneObject[];
  plots: ScenePlot[];
  molecule?: Molecule;
  time: string;
}

// MARK: - Live

export interface SourceField {
  name: string;
  value: number;
  unit: string;
  format: Format;
  meaning: string;
}

export interface SourceList {
  name: string;
  keys: string[];
  count: number;
}

export interface Source {
  name: string;
  kind: string;
  parameters: Record<string, string>;
  fields: SourceField[];
  lists?: SourceList[];
}

export interface Action {
  name: string;
  kind: string;
  fields: Record<string, string>;
}

// MARK: - The page

export interface Answer {
  [key: string]: unknown;
}

export interface SurfaceLocale {
  language: string;
  measurementSystem: string;
}

export interface Surface {
  title: string;
  summary: string;
  symbol: string;
  accent: Accent;
  inputs: Input[];
  outputs: Output[];
  blocks: Block[];
  related: string[];
  reference?: Reference;
  citations?: Citation[];
  question?: string;
  sounds?: Sound[];
  answers?: Answer[];
  collections?: RecordCollection[];
  figures?: Figure[];
  diagrams?: Diagram[];
  scenes?: Scene3D[];
  locale?: SurfaceLocale;
  sources?: Source[];
  actions?: Action[];
  services?: string[];
  mode?: Mode;
}

export interface Issue {
  kind: "fixed" | "needsModel" | "warning";
  message: string;
}

/** The reader the checker works for: the money and units it shows (Locale.current in the app). */
export interface EngineLocale {
  /** An ISO 4217 code, like INR. */
  currency: string;
  /** How the reader writes it, like ₹. Worked out from `currency` and `language` if not given. */
  currencySymbol?: string;
  /** metric, ussystem or uksystem, as Locale.MeasurementSystem names them; us and uk work too. */
  measurementSystem: string;
  language?: string;
  region?: string;
}
