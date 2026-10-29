// A page the server made, as the account's sync keeps it: a `surface` item whose body is the
// app's SurfacePayload (Dream/Sync/SyncPayloads.swift), written as the app's SyncCoding writes it
// (Dream/Sync/SyncItem.swift): keys sorted at every level, dates as ISO 8601 with milliseconds,
// nothing for a field that's nil. So the phone reads it the next time it syncs as if another
// iPhone had made the page, and the item it saves for a page it watched has the same id.
//
// No imports, so test/compose.mjs runs it in Node.

type JSONObject = Record<string, unknown>;

/** The app's sync format for every kind (SyncFormat.current). */
export const FORMAT = 1;
/** Just under the server's limit for one item (Sync.maxItem). */
export const MAX_ITEM = 250_000;

const isObject = (value: unknown): value is JSONObject => value !== null && typeof value === "object" && !Array.isArray(value);

/** A value with its objects' keys in order, as JSONEncoder's .sortedKeys writes them. */
export function sortedKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortedKeys);
  if (!isObject(value)) return value;
  const out: JSONObject = {};
  for (const key of Object.keys(value).sort()) if (value[key] !== undefined) out[key] = sortedKeys(value[key]);
  return out;
}

export interface MadePage {
  /** What the user asked for, in their words. */
  intent: string;
  /** The page, as the app's Surface encodes it. */
  surface: JSONObject;
  modelName: string;
  /** What Under the hood shows: the generation log. */
  log: string[];
  /** The photo it started from, by its id on the server (/api/photos/:id). */
  photo?: string;
  /** When it was finished, in milliseconds. */
  at: number;
}

/** SurfacePayload for a page just made, as the app's screen saves one (SurfaceScreen.start): the
 * request is its first turn, with the answers it was built from, and none of the user's own
 * numbers yet. */
export function surfacePayload(page: MadePage, keepingLog = Infinity): JSONObject {
  const at = new Date(page.at).toISOString();
  return sortedKeys({
    intent: page.intent,
    createdAt: at,
    updatedAt: at,
    openCount: 0,
    modelName: page.modelName,
    history: [{ kind: "asked", text: page.intent, at, answers: Array.isArray(page.surface.answers) ? page.surface.answers : [] }],
    editRequests: [],
    generationLog: Number.isFinite(keepingLog) ? page.log.slice(Math.max(0, page.log.length - keepingLog)) : page.log,
    template: page.surface,
    values: {},
    ...(page.photo ? { photo: page.photo } : {}),
    seeded: [],
  }) as JSONObject;
}

/** The sync item for a page, as POST /api/sync takes it. */
export interface SurfaceItem {
  kind: "surface";
  id: string;
  parent: null;
  format: number;
  updatedAt: number;
  deleted: false;
  body: JSONObject;
}

const bytes = (value: unknown) => new TextEncoder().encode(JSON.stringify(value)).length;

/** The item for a page under its id, with less of its log if it's grown past what an item may
 * carry (Sync.outgoing): the log is how it was built, not the user's words, so it goes first.
 * Null if even without it the page is too big. */
export function surfaceItem(pageID: string, page: MadePage): SurfaceItem | null {
  return fitted(pageID, page.at, (lines) => surfacePayload(page, lines));
}

function fitted(pageID: string, at: number, body: (keepingLog: number) => JSONObject): SurfaceItem | null {
  for (const lines of [Infinity, 200, 40, 0]) {
    const payload = body(lines);
    if (bytes(payload) <= MAX_ITEM) return { kind: "surface", id: pageID, parent: null, format: FORMAT, updatedAt: at, deleted: false, body: payload };
  }
  return null;
}

// MARK: - Changes

/** A change to a page the account keeps, as the app's screen saves one (SurfaceScreen's
 * submitChange, changeAnswer and runAgain). */
export interface MadeChange {
  /** The turn it adds to the page's conversation (PageTurn.Kind). */
  kind: "changed" | "answered" | "rebuilt";
  /** What the turn says: the instruction, the new choice, or the request made again. */
  text: string;
  /** What's added to editRequests: the instruction, or the different answer in the user's
   * words (Prompts.changedAnswer). Null when it was made again. */
  request: string | null;
  /** The turn's answers: for a different answer, the page's answer to that question now; made
   * again, all the page's answers. */
  answers: unknown[];
  /** The page as it was when the change began, and as it is now. */
  before: JSONObject;
  surface: JSONObject;
  modelName: string;
  /** Under the hood's lines for this change, added to the page's. */
  log: string[];
  /** Whether the user's numbers stay only where their input starts where it did (a change, or
   * a different answer), rather than all of them (made again). */
  narrowsValues: boolean;
  at: number;
}

const inputs = (surface: unknown) => (isObject(surface) && Array.isArray(surface.inputs) ? surface.inputs.filter(isObject) : []);

/** The user's numbers after a change: kept only where an input of that name is on the page
 * before and after, starting where it did, "unless the change was about that number". */
export function keptValues(values: unknown, before: JSONObject, after: JSONObject): Record<string, number> {
  const kept: Record<string, number> = {};
  if (!isObject(values)) return kept;
  const start = (surface: JSONObject, name: string) => inputs(surface).find((input) => input.name === name)?.initial;
  for (const [name, value] of Object.entries(values)) {
    if (typeof value !== "number") continue;
    const was = start(before, name);
    const now = start(after, name);
    if (was !== undefined && now !== undefined && was === now) kept[name] = value;
  }
  return kept;
}

/** SavedSurface.history: the page's conversation, or for a page saved before turns were kept,
 * its request and the changes asked for since, dated when the page last changed. A page someone
 * shared has none until the user says something to it. */
function history(stored: JSONObject): unknown[] {
  if (Array.isArray(stored.history) && stored.history.length) return stored.history;
  const intent = typeof stored.intent === "string" ? stored.intent : "";
  if (typeof stored.sharedFrom === "string" || !intent) return [];
  const template = isObject(stored.template) ? stored.template : {};
  const updated = stored.updatedAt ?? stored.createdAt;
  return [
    { kind: "asked", text: intent, at: stored.createdAt, answers: Array.isArray(template.answers) ? template.answers : [] },
    ...(Array.isArray(stored.editRequests) ? stored.editRequests : []).map((text) => ({ kind: "changed", text, at: updated, answers: [] })),
  ];
}

/** The page's SurfacePayload after a change, from what the account keeps of it: the new page,
 * the turn and the change asked for added, the log added to, the model that made it, and the
 * user's numbers kept as the app keeps them. Everything else, the photo, the dates it was made
 * and opened, the lists already seeded, stays as it was. */
export function changedPayload(stored: JSONObject, change: MadeChange, keepingLog = Infinity): JSONObject {
  const at = new Date(change.at).toISOString();
  const log = [...(Array.isArray(stored.generationLog) ? stored.generationLog : []), ...change.log];
  const payload: JSONObject = {
    ...stored,
    template: change.surface,
    updatedAt: at,
    modelName: change.modelName,
    history: [...history(stored), { kind: change.kind, text: change.text, at, answers: change.answers }],
    generationLog: Number.isFinite(keepingLog) ? log.slice(Math.max(0, log.length - keepingLog)) : log,
  };
  if (change.request !== null) payload.editRequests = [...(Array.isArray(stored.editRequests) ? stored.editRequests : []), change.request];
  if (change.narrowsValues) payload.values = keptValues(stored.values, change.before, change.surface);
  return sortedKeys(payload) as JSONObject;
}

/** The item for a change to a page, stamped after what's stored so it's the latest. */
export function changedItem(pageID: string, stored: { updatedAt: number; body: JSONObject }, change: MadeChange): SurfaceItem | null {
  const at = Math.max(change.at, stored.updatedAt + 1);
  return fitted(pageID, at, (lines) => changedPayload(stored.body, { ...change, at }, lines));
}
