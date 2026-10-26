// What the app uploads, and the checks it passes before it's stored. The app checks a shared
// surface again when it opens one, so these checks protect the server and the web viewer: they
// bound the size and shape of what's stored, and drop anything personal that slipped through.

/** The largest body the Worker reads. Real surfaces are 5 to 40 KB. */
export const MAX_BODY = 200_000;

/** The newest format this Worker understands. */
export const FORMAT = 1;

const LIMITS = { depth: 20, nodes: 25_000, string: 4_000, array: 400, keys: 200 };

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type JsonObject = { [key: string]: Json };

/** A shared surface, as stored. `surface` is the template; `values` are the sharer's own
 * numbers, present only when they chose to share them. `preview` is what the app's engine
 * worked out for the web viewer: values as shown, equations, and chart lines. */
export interface Shared {
  format: number;
  surface: JsonObject;
  values?: Record<string, number>;
  currency?: string;
  preview?: JsonObject;
}

export class Rejection extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

/** Reads at most `max` bytes of the body as UTF-8, or rejects it as too large. */
export async function readBody(request: Request, max = MAX_BODY): Promise<string> {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > max) throw new Rejection(413, "That screen is too big to share.");
  if (!request.body) throw new Rejection(400, "Nothing was sent.");
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      await reader.cancel();
      throw new Rejection(413, "That screen is too big to share.");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
  } catch {
    throw new Rejection(400, "That isn't text.");
  }
}

/** Whether a parsed JSON value stays inside the limits: nesting, count, string and array sizes. */
export function withinLimits(value: unknown): boolean {
  let nodes = 0;
  const visit = (node: unknown, depth: number): boolean => {
    if (++nodes > LIMITS.nodes || depth > LIMITS.depth) return false;
    if (typeof node === "string") return node.length <= LIMITS.string;
    if (Array.isArray(node)) return node.length <= LIMITS.array && node.every((item) => visit(item, depth + 1));
    if (node !== null && typeof node === "object") {
      const entries = Object.entries(node);
      return entries.length <= LIMITS.keys && entries.every(([key, item]) => key.length <= 200 && visit(item, depth + 1));
    }
    return node === null || typeof node === "boolean" || (typeof node === "number" && Number.isFinite(node));
  };
  return visit(value, 0);
}

export const isObject = (value: unknown): value is JsonObject => value !== null && typeof value === "object" && !Array.isArray(value);
const NAME = /^[A-Za-z_][A-Za-z0-9_]{0,63}$/;

/** Checks an upload and returns what's stored. Personal answers are dropped even though the
 * app never sends them. */
export function parseShared(text: string): Shared {
  return checkShared(parseJSON(text));
}

/** Parses an upload, or rejects it as malformed. */
export function parseJSON(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    throw new Rejection(400, "That isn't JSON.");
  }
}

/** Checks an upload that's already parsed, as `parseShared` does. */
export function checkShared(parsed: unknown): Shared {
  if (!withinLimits(parsed)) throw new Rejection(413, "That screen is too big or too deeply nested to share.");
  if (!isObject(parsed)) throw new Rejection(400, "Expected a shared surface.");
  if (parsed.format !== FORMAT) throw new Rejection(400, `Expected format ${FORMAT}.`);

  const surface = parsed.surface;
  if (!isObject(surface)) throw new Rejection(400, "Expected a surface.");
  if (typeof surface.title !== "string" || !surface.title.trim() || surface.title.length > 300) throw new Rejection(400, "A surface needs a title.");
  if (typeof surface.summary !== "string") throw new Rejection(400, "A surface needs a summary.");
  for (const key of ["blocks", "inputs", "outputs"]) {
    if (!Array.isArray(surface[key])) throw new Rejection(400, `A surface needs ${key}.`);
  }
  if (typeof surface.accent !== "string" || typeof surface.symbol !== "string") throw new Rejection(400, "A surface needs an accent and a symbol.");
  // What the user answered before it was built stays on their phone.
  delete surface.answers;

  const shared: Shared = { format: FORMAT, surface };
  if (parsed.values !== undefined) {
    if (!isObject(parsed.values)) throw new Rejection(400, "Values must be numbers by name.");
    const values: Record<string, number> = {};
    for (const [name, value] of Object.entries(parsed.values)) {
      if (!NAME.test(name) || typeof value !== "number") throw new Rejection(400, "Values must be numbers by name.");
      values[name] = value;
    }
    if (Object.keys(values).length) shared.values = values;
  }
  if (typeof parsed.currency === "string" && /^[A-Z]{3}$/.test(parsed.currency)) shared.currency = parsed.currency;
  if (isObject(parsed.preview)) shared.preview = parsed.preview;
  return shared;
}

/** The language a surface is written in, if it says, as a safe BCP 47 tag. */
export function languageOf(surface: JsonObject): string | undefined {
  const locale = surface.locale;
  if (!isObject(locale) || typeof locale.language !== "string") return undefined;
  return /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,3}$/.test(locale.language) ? locale.language : undefined;
}
