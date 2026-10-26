// What sync keeps for each person (migrations/0005), the checks every change passes, and the
// account-wide jobs: deleting and exporting someone's data. The routes are in sync.ts.
//
// No imports, so `npm test` checks these directly in Node.

/** What syncs. Anything else is refused, so a typo can't make a new kind of row. */
export const KINDS = ["surface", "record", "fact", "connection", "setting"] as const;
export type Kind = (typeof KINDS)[number];

export const LIMITS = {
  /** One request's body. */
  request: 2_000_000,
  /** Changes in one request. */
  items: 200,
  /** One item's JSON. A page with its template, history and log is usually 5 to 60 KB. */
  item: 262_144,
  /** Everything one person keeps, photos aside. Tests set less with SYNC_QUOTA_BYTES. */
  stored: 50_000_000,
  /** Changes in one page of reading, by default and at most. */
  page: 200,
  maxPage: 500,
  /** About as much as one page of reading carries; it stops after the item that passes this. */
  pageBytes: 2_000_000,
  /** One photo, and all of one person's. Tests set less with SYNC_PHOTO_QUOTA_BYTES. */
  photo: 4_000_000,
  photos: 500_000_000,
  /** How far ahead of the server's clock a change may say it was made. Later is pulled back. */
  ahead: 10 * 60 * 1000,
};

const ID = /^[A-Za-z0-9._-]{1,64}$/;
export const PHOTO_ID = /^[A-Za-z0-9-]{8,64}$/;
/** Before 2017: no Dream phone made it, so it's a mistake. */
const EARLIEST = 1_500_000_000_000;

/** A request refused as a whole, with what to tell the app. */
export class SyncRejection extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

/** One change, checked and ready to store. */
export interface Change {
  kind: Kind;
  id: string;
  parent: string | null;
  format: number;
  updatedAt: number;
  deleted: boolean;
  /** The item's JSON, as stored; null for a deletion. */
  body: string | null;
  /** Bytes of body. */
  size: number;
  /** A page's photo id, so the server can let go of one the page no longer has. */
  photo: string | null;
}

/** A change that wasn't stored, and why: the app keeps the item, and stops sending it. */
export interface Refused {
  kind: string;
  id: string;
  reason: "kind" | "id" | "parent" | "format" | "updatedAt" | "body" | "size";
}

const isObject = (value: unknown): value is Record<string, unknown> => value !== null && typeof value === "object" && !Array.isArray(value);

/** Whether parsed JSON stays within sane nesting, so storing and reading it back is safe. */
function bounded(value: unknown, depth = 0): boolean {
  if (depth > 40) return false;
  if (Array.isArray(value)) return value.every((item) => bounded(item, depth + 1));
  if (isObject(value)) return Object.values(value).every((item) => bounded(item, depth + 1));
  return typeof value !== "number" || Number.isFinite(value);
}

const encoder = new TextEncoder();

/** Checks a batch of changes. Malformed requests are refused whole; a malformed change is
 * refused alone, so one bad item never holds up the rest. Of two changes to one item, the later
 * is kept. Times ahead of the server's clock are pulled back to `now` plus a little. */
export function parseChanges(text: string, now: number): { changes: Change[]; refused: Refused[] } {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new SyncRejection(400, "That isn't JSON.");
  }
  if (!isObject(parsed) || !Array.isArray(parsed.items)) throw new SyncRejection(400, "Expected { items: [...] }.");
  if (parsed.items.length > LIMITS.items) throw new SyncRejection(413, `Send at most ${LIMITS.items} changes at once.`);

  const refused: Refused[] = [];
  const latest = new Map<string, Change>();
  for (const item of parsed.items) {
    const kind = isObject(item) && typeof item.kind === "string" ? item.kind : "";
    const id = isObject(item) && typeof item.id === "string" ? item.id : "";
    const refuse = (reason: Refused["reason"]) => refused.push({ kind: kind.slice(0, 20), id: id.slice(0, 64), reason });
    if (!isObject(item) || !(KINDS as readonly string[]).includes(kind)) {
      refuse("kind");
      continue;
    }
    if (!ID.test(id)) {
      refuse("id");
      continue;
    }
    const parent = item.parent ?? null;
    if (parent !== null && (typeof parent !== "string" || !ID.test(parent))) {
      refuse("parent");
      continue;
    }
    // A list entry belongs to a page, and goes when the page does.
    if (kind === "record" && parent === null) {
      refuse("parent");
      continue;
    }
    if (!Number.isInteger(item.format) || (item.format as number) < 1 || (item.format as number) > 1000) {
      refuse("format");
      continue;
    }
    if (!Number.isSafeInteger(item.updatedAt) || (item.updatedAt as number) < EARLIEST) {
      refuse("updatedAt");
      continue;
    }
    const deleted = item.deleted === true;
    let body: string | null = null;
    let photo: string | null = null;
    if (!deleted) {
      if (!isObject(item.body) || !bounded(item.body)) {
        refuse("body");
        continue;
      }
      body = JSON.stringify(item.body);
      if (encoder.encode(body).length > LIMITS.item) {
        refuse("size");
        continue;
      }
      if (kind === "surface" && typeof item.body.photo === "string" && PHOTO_ID.test(item.body.photo)) photo = item.body.photo;
    }
    const change: Change = {
      kind: kind as Kind,
      id,
      parent,
      format: item.format as number,
      updatedAt: Math.min(item.updatedAt as number, now + LIMITS.ahead),
      deleted,
      body,
      size: body === null ? 0 : encoder.encode(body).length,
      photo,
    };
    const key = `${kind}/${id}`;
    const earlier = latest.get(key);
    if (!earlier || change.updatedAt > earlier.updatedAt) latest.set(key, change);
  }
  return { changes: [...latest.values()], refused };
}

// MARK: - Cursors

/** Where a device left off reading: the last change it was given. */
export interface Cursor {
  change: number;
  kind: string;
  id: string;
}

export const START: Cursor = { change: 0, kind: "", id: "" };

const base64url = (text: string) => btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** Opaque to the app. It names the account it was given to, so one carried into another account
 * starts again instead of skipping that account's changes. */
export function encodeCursor(cursor: Cursor, user: string): string {
  return base64url(JSON.stringify([cursor.change, cursor.kind, cursor.id, user.slice(0, 8)]));
}

/** The cursor a device sent: the start when there's none, and also when it was made for another
 * account ("elsewhere"). Null when it's malformed. */
export function decodeCursor(text: string | null, user: string): { cursor: Cursor; elsewhere: boolean } | null {
  if (text === null || text === "") return { cursor: START, elsewhere: false };
  if (text.length > 400 || !/^[A-Za-z0-9_-]+$/.test(text)) return null;
  let parts: unknown;
  try {
    parts = JSON.parse(atob(text.replace(/-/g, "+").replace(/_/g, "/")));
  } catch {
    return null;
  }
  if (!Array.isArray(parts) || parts.length !== 4) return null;
  const [change, kind, id, tag] = parts;
  if (!Number.isSafeInteger(change) || change < 0 || typeof kind !== "string" || typeof id !== "string" || typeof tag !== "string") return null;
  if (tag !== user.slice(0, 8)) return { cursor: START, elsewhere: true };
  return { cursor: { change, kind, id }, elsewhere: false };
}

// MARK: - Photos

/** What a photo is, from its first bytes; null for anything that isn't one. */
export function imageType(bytes: Uint8Array): string | null {
  const ascii = (from: number, to: number) => String.fromCharCode(...bytes.subarray(from, to));
  if (bytes.length < 12) return null;
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
  if (ascii(0, 8) === "\x89PNG\r\n\x1a\n") return "image/png";
  if (ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP") return "image/webp";
  if (ascii(4, 8) === "ftyp" && ["heic", "heix", "mif1", "msf1", "hevc"].includes(ascii(8, 12))) return "image/heic";
  return null;
}

/** Where a person's photo is kept in the bucket. */
export const photoKey = (userID: string, id: string) => `${userID}/${id}`;

// MARK: - The whole account

interface DataEnv {
  DB: D1Database;
  PHOTOS?: R2Bucket;
}

/** Erases everything sync keeps for a person: their photos, then their rows. For deleting an
 * account (workstream A). Safe to run again if it stops part way. */
export async function deleteUserData(env: DataEnv, userID: string): Promise<void> {
  if (env.PHOTOS) {
    let cursor: string | undefined;
    do {
      const listed = await env.PHOTOS.list({ prefix: `${userID}/`, cursor, limit: 1000 });
      if (listed.objects.length) await env.PHOTOS.delete(listed.objects.map((object) => object.key));
      cursor = listed.truncated ? listed.cursor : undefined;
    } while (cursor);
  }
  await env.DB.batch([
    env.DB.prepare("DELETE FROM sync_items WHERE user_id = ?").bind(userID),
    env.DB.prepare("DELETE FROM sync_photos WHERE user_id = ?").bind(userID),
    env.DB.prepare("DELETE FROM sync_state WHERE user_id = ?").bind(userID),
  ]);
}

/** Everything sync keeps for a person that still exists, for "Export my data" (workstream A):
 * each item's JSON as stored, and the photos by id, which /api/photos/:id serves. */
export async function exportUserData(env: DataEnv, userID: string): Promise<{ items: unknown[]; photos: unknown[] }> {
  const [items, photos] = await env.DB.batch([
    env.DB.prepare("SELECT kind, id, parent, format, updated_at, body FROM sync_items WHERE user_id = ? AND deleted = 0 ORDER BY kind, id").bind(userID),
    env.DB.prepare("SELECT id, size, content_type, created_at FROM sync_photos WHERE user_id = ? ORDER BY created_at").bind(userID),
  ]);
  return {
    items: (items.results as { kind: string; id: string; parent: string | null; format: number; updated_at: number; body: string }[]).map((row) => ({
      kind: row.kind,
      id: row.id,
      parent: row.parent,
      format: row.format,
      updatedAt: new Date(row.updated_at).toISOString(),
      body: JSON.parse(row.body),
    })),
    photos: (photos.results as { id: string; size: number; content_type: string; created_at: number }[]).map((row) => ({
      id: row.id,
      size: row.size,
      contentType: row.content_type,
      createdAt: new Date(row.created_at * 1000).toISOString(),
    })),
  };
}
