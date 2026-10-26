// Crash, hang and slow-launch reports from the app (Dream/Privacy/Diagnostics.swift), checked
// before they're stored (diagnostics.ts). The app sends them only when its user has turned on
// "Help improve Dream", and they're anonymous: the version of Dream and iOS, the kind of iPhone,
// and where in the code it happened, as MetricKit's call stack tree. Nothing here may carry who
// sent it or anything they wrote, so every field is bounded and anything unexpected is refused.
//
// No imports, so test/unit.mjs runs it in Node.

/** The largest upload read. A day's reports with whole stacks are usually 10 to 60 KB. */
export const MAX_DIAGNOSTICS_BODY = 256_000;
/** Reports in one upload. */
export const MAX_REPORTS = 20;
/** A stack bigger than this, as JSON, is dropped; the rest of its report is kept. */
export const MAX_STACK = 64_000;

export const KINDS = ["crash", "hang", "launch"] as const;
export type Kind = (typeof KINDS)[number];

/** One report, as stored. */
export interface DiagnosticReport {
  kind: Kind;
  app: string;
  build: string;
  os: string;
  device: string;
  testFlight: boolean;
  start: number | null;
  end: number | null;
  duration: number | null;
  exceptionType: number | null;
  exceptionCode: number | null;
  signal: number | null;
  exceptionName: string | null;
  exceptionClass: string | null;
  terminationReason: string | null;
  /** Where it happened, for grouping, like "EXC_BREAKPOINT SIGTRAP Dream+0x1a2b4". */
  signature: string;
  /** MetricKit's call stack tree, as JSON text; null if there was none or it was too big. */
  stack: string | null;
}

/** Why an upload was refused, said plainly; the status is always 400. */
export class ReportError extends Error {}

type Obj = Record<string, unknown>;
const isObject = (value: unknown): value is Obj => value !== null && typeof value === "object" && !Array.isArray(value);

/** Printable text without control characters, at most `max` long. */
const TEXT = /^[^\u0000-\u001f\u007f]*$/;

function text(report: Obj, key: string, max: number, required: boolean): string | null {
  const value = report[key];
  if (value === undefined || value === null) {
    if (required) throw new ReportError(`A report needs ${key}.`);
    return null;
  }
  if (typeof value !== "string" || value.length > max || !TEXT.test(value) || (required && !value.trim())) throw new ReportError(`${key} isn't usable.`);
  return value;
}

function number(report: Obj, key: string, { min, max, integer }: { min: number; max: number; integer: boolean }): number | null {
  const value = report[key];
  if (value === undefined || value === null) return null;
  if (typeof value !== "number" || !Number.isFinite(value) || value < min || value > max || (integer && !Number.isInteger(value))) {
    throw new ReportError(`${key} isn't usable.`);
  }
  return value;
}

/** Checks an upload, `{ format: 1, reports: [...] }`, and returns its reports, ready to store. */
export function parseReports(body: string): DiagnosticReport[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    throw new ReportError("That isn't JSON.");
  }
  if (!isObject(parsed) || parsed.format !== 1) throw new ReportError("Expected format 1.");
  const reports = parsed.reports;
  if (!Array.isArray(reports) || reports.length === 0) throw new ReportError("Expected reports.");
  if (reports.length > MAX_REPORTS) throw new ReportError(`At most ${MAX_REPORTS} reports at once.`);
  return reports.map(parseReport);
}

function parseReport(raw: unknown): DiagnosticReport {
  if (!isObject(raw)) throw new ReportError("Expected a report.");
  const kind = raw.kind;
  if (typeof kind !== "string" || !(KINDS as readonly string[]).includes(kind)) throw new ReportError("A report is a crash, a hang or a launch.");
  const testFlight = raw.testFlight ?? false;
  if (typeof testFlight !== "boolean") throw new ReportError("testFlight isn't usable.");
  const seconds = { min: 0, max: 4_102_444_800, integer: true };
  const code = { min: -(2 ** 53), max: 2 ** 53, integer: true };
  const report: DiagnosticReport = {
    kind: kind as Kind,
    app: text(raw, "app", 32, true)!,
    build: text(raw, "build", 32, true)!,
    os: text(raw, "os", 100, true)!,
    device: text(raw, "device", 40, true)!,
    testFlight,
    start: number(raw, "start", seconds),
    end: number(raw, "end", seconds),
    duration: number(raw, "duration", { min: 0, max: 86_400, integer: false }),
    exceptionType: number(raw, "exceptionType", code),
    exceptionCode: number(raw, "exceptionCode", code),
    signal: number(raw, "signal", { min: 0, max: 255, integer: true }),
    exceptionName: text(raw, "exceptionName", 120, false),
    exceptionClass: text(raw, "exceptionClass", 120, false),
    terminationReason: text(raw, "terminationReason", 200, false),
    signature: "",
    stack: null,
  };
  if (raw.stack !== undefined && raw.stack !== null) {
    if (!isObject(raw.stack)) throw new ReportError("stack isn't usable.");
    const stack = JSON.stringify(raw.stack);
    if (stack.length <= MAX_STACK) report.stack = stack;
  }
  report.signature = signatureOf(report, raw.stack);
  return report;
}

const EXCEPTIONS: Record<number, string> = {
  1: "EXC_BAD_ACCESS",
  2: "EXC_BAD_INSTRUCTION",
  3: "EXC_ARITHMETIC",
  5: "EXC_SOFTWARE",
  6: "EXC_BREAKPOINT",
  10: "EXC_CRASH",
  11: "EXC_RESOURCE",
  12: "EXC_GUARD",
};

const SIGNALS: Record<number, string> = {
  4: "SIGILL",
  5: "SIGTRAP",
  6: "SIGABRT",
  8: "SIGFPE",
  9: "SIGKILL",
  10: "SIGBUS",
  11: "SIGSEGV",
  15: "SIGTERM",
};

/** The frames of the thread that crashed or hung, innermost first: MetricKit's root frame is
 * where the thread was, and each frame's first sub-frame is what called it. */
export function framesOf(stack: unknown, limit = 200): Obj[] {
  if (!isObject(stack) || !Array.isArray(stack.callStacks)) return [];
  const threads = stack.callStacks.filter(isObject);
  const thread = threads.find((candidate) => candidate.threadAttributed === true) ?? threads[0];
  const frames: Obj[] = [];
  let frame: unknown = Array.isArray(thread?.callStackRootFrames) ? thread.callStackRootFrames[0] : undefined;
  while (isObject(frame) && frames.length < limit) {
    frames.push(frame);
    frame = Array.isArray(frame.subFrames) ? frame.subFrames[0] : undefined;
  }
  return frames;
}

function frameName(frame: Obj): string | null {
  const binary = typeof frame.binaryName === "string" ? frame.binaryName.replace(/[^A-Za-z0-9._+-]/g, "").slice(0, 60) : "";
  const offset = frame.offsetIntoBinaryTextSegment;
  if (!binary) return null;
  return typeof offset === "number" && Number.isInteger(offset) && offset >= 0 ? `${binary}+0x${offset.toString(16)}` : binary;
}

/** A short key that groups the same problem across reports: for a crash, what kind it was, then
 * the innermost frame in Dream's own code, or else the innermost frame. */
export function signatureOf(report: Pick<DiagnosticReport, "kind" | "exceptionType" | "signal" | "exceptionName">, stack: unknown): string {
  const parts: string[] = [];
  if (report.kind === "crash") {
    const name = report.exceptionName?.replace(/[^A-Za-z0-9._-]/g, "").slice(0, 60);
    if (name) parts.push(name);
    else if (report.exceptionType !== null) parts.push(EXCEPTIONS[report.exceptionType] ?? `EXC_${report.exceptionType}`);
    if (report.signal !== null) parts.push(SIGNALS[report.signal] ?? `SIG${report.signal}`);
  }
  const frames = framesOf(stack);
  const own = frames.find((frame) => frame.binaryName === "Dream") ?? frames[0];
  const where = own ? frameName(own) : null;
  parts.push(where ?? "unknown");
  return parts.join(" ").slice(0, 120);
}
