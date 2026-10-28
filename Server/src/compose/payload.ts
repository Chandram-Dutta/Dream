// A page the server made, as the account's sync keeps it: a `surface` item whose body is the
// app's SurfacePayload (Dream/Sync/SyncPayloads.swift), written as the app's SyncCoding writes it
// (Dream/Sync/SyncItem.swift): keys sorted at every level, dates as ISO 8601 with milliseconds,
// nothing for a field that's nil. So the phone reads it the next time it syncs as if another
// iPhone had made the page, and the item it saves for a page it watched has the same id.
//
// No imports, so test/unit.mjs runs it in Node.

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
  for (const lines of [Infinity, 200, 40, 0]) {
    const body = surfacePayload(page, lines);
    if (bytes(body) <= MAX_ITEM) return { kind: "surface", id: pageID, parent: null, format: FORMAT, updatedAt: page.at, deleted: false, body };
  }
  return null;
}
