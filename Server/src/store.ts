// Shared surfaces in D1: one row per link. A link belongs to the account that made it (links made
// before accounts have no owner, and stay read-only), can be updated to show its page's newest
// version, and can stop: its owner stops sharing it, it expires, an admin takes it down, or the
// account is deleted. A link that stops keeps its id, so it can say it's gone instead of 404.

import { languageOf, type Shared } from "./payload";

const ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
/** Ten characters from 62: about 60 bits, so links can't be guessed or walked through. */
export const ID_LENGTH = 10;
export const ID_PATTERN = new RegExp(`^[0-9A-Za-z]{${ID_LENGTH}}$`);

/** A random id, without the bias a plain modulo would give the first letters. */
export function newID(): string {
  let id = "";
  while (id.length < ID_LENGTH) {
    for (const byte of crypto.getRandomValues(new Uint8Array(16))) {
      if (byte < 248 && id.length < ID_LENGTH) id += ALPHABET[byte % 62];
    }
  }
  return id;
}

export const now = () => Math.floor(Date.now() / 1000);

export interface Stored extends Shared {
  id: string;
  created: number;
}

/** Whether a link shows its page: `stopped` by its owner (or their account's deletion),
 * `expired` at the time they chose, or `removed` by an admin. */
export type ShareState = "shared" | "stopped" | "expired" | "removed";

/** One link, without its content. */
export interface ShareRow {
  id: string;
  owner_id: string | null;
  page_id: string | null;
  created_at: number;
  updated_at: number | null;
  expires_at: number | null;
  revoked_at: number | null;
  revoked_by: string | null;
  views: number;
  has_values: number;
  title: string;
}

export function stateOf(row: ShareRow, at = now()): ShareState {
  if (row.revoked_at !== null) return row.revoked_by === "admin" ? "removed" : "stopped";
  if (row.expires_at !== null && row.expires_at <= at) return "expired";
  return "shared";
}

const ROW = "id, owner_id, page_id, created_at, updated_at, expires_at, revoked_at, revoked_by, views, has_values, title";

/** What a page's content sets in its row. */
function content(shared: Shared) {
  const body = JSON.stringify(shared);
  return { body, title: String(shared.surface.title), summary: String(shared.surface.summary), language: languageOf(shared.surface) ?? null, values: shared.values ? 1 : 0 };
}

/** Stores a new link and returns its id. */
export async function save(db: D1Database, shared: Shared, owner: { ownerID: string; pageID: string | null } | null = null): Promise<string> {
  const { body, title, summary, language, values } = content(shared);
  const at = now();
  for (let attempt = 0; attempt < 3; attempt++) {
    const id = newID();
    try {
      await db
        .prepare(
          `INSERT INTO surfaces (id, created_at, updated_at, format, title, summary, language, has_values, size, body, owner_id, page_id)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(id, at, at, shared.format, title, summary, language, values, body.length, body, owner?.ownerID ?? null, owner?.pageID ?? null)
        .run();
      return id;
    } catch (error) {
      // Two links with the same id is all but impossible; anything else is a real failure.
      if (!String(error).includes("UNIQUE")) throw error;
    }
  }
  throw new Error("Couldn't find a free id.");
}

/** Puts a page's newest version behind a link it already has. */
export async function replace(db: D1Database, id: string, shared: Shared): Promise<void> {
  const { body, title, summary, language, values } = content(shared);
  await db
    .prepare("UPDATE surfaces SET format = ?, title = ?, summary = ?, language = ?, has_values = ?, size = ?, body = ?, updated_at = ? WHERE id = ?")
    .bind(shared.format, title, summary, language, values, body.length, body, now(), id)
    .run();
}

/** A link the owner already has for this page, still working, with or without their numbers. */
export async function reusable(db: D1Database, ownerID: string, pageID: string, hasValues: boolean): Promise<string | null> {
  const row = await db
    .prepare(
      `SELECT id FROM surfaces WHERE owner_id = ? AND page_id = ? AND has_values = ? AND revoked_at IS NULL
       AND (expires_at IS NULL OR expires_at > ?) ORDER BY created_at DESC LIMIT 1`,
    )
    .bind(ownerID, pageID, hasValues ? 1 : 0, now())
    .first<{ id: string }>();
  return row?.id ?? null;
}

/** One link and, while it shows its page, the page. */
export async function find(db: D1Database, id: string): Promise<{ row: ShareRow; state: ShareState; stored: Stored | null } | null> {
  const row = await db.prepare(`SELECT ${ROW}, body FROM surfaces WHERE id = ?`).bind(id).first<ShareRow & { body: string }>();
  if (!row) return null;
  const { body, ...link } = row;
  const state = stateOf(link);
  const stored = state === "shared" && body ? { ...(JSON.parse(body) as Shared), id, created: row.created_at } : null;
  return { row: link, state, stored };
}

/** The page behind a link that's still shared, or null. */
export async function load(db: D1Database, id: string): Promise<Stored | null> {
  return (await find(db, id))?.stored ?? null;
}

/** A link's page whatever its state, for an admin reviewing a report: a takedown keeps it. */
export async function loadForReview(db: D1Database, id: string): Promise<Stored | null> {
  const row = await db.prepare("SELECT created_at, body FROM surfaces WHERE id = ?").bind(id).first<{ created_at: number; body: string }>();
  return row?.body ? { ...(JSON.parse(row.body) as Shared), id, created: row.created_at } : null;
}

export async function setExpiry(db: D1Database, id: string, expiresAt: number | null): Promise<void> {
  await db.prepare("UPDATE surfaces SET expires_at = ? WHERE id = ?").bind(expiresAt, id).run();
}

/** Stops a link. When its owner stops it, the page itself is erased and only the title stays,
 * for their list of links; a takedown keeps the page, unserved, for review. */
export async function revoke(db: D1Database, id: string, by: "owner" | "admin"): Promise<void> {
  const at = now();
  if (by === "admin") {
    await db.prepare("UPDATE surfaces SET revoked_at = COALESCE(revoked_at, ?), revoked_by = 'admin' WHERE id = ?").bind(at, id).run();
  } else {
    await db.prepare("UPDATE surfaces SET revoked_at = ?, revoked_by = 'owner', body = '', summary = '', size = 0 WHERE id = ? AND revoked_at IS NULL").bind(at, id).run();
  }
}

/** Takes down every link an account still shares, as an admin does when it blocks the account. */
export async function revokeAllOf(db: D1Database, ownerID: string): Promise<void> {
  await db.prepare("UPDATE surfaces SET revoked_at = ?, revoked_by = 'admin' WHERE owner_id = ? AND revoked_at IS NULL").bind(now(), ownerID).run();
}

/** A link as its owner's list shows it. Accent and symbol come from the page, so the app can
 * draw each in its colors; a stopped link's page is gone, so it has neither. */
export type ListedRow = ShareRow & { accent: string | null; symbol: string | null };

const LISTED = `SELECT ${ROW},
  CASE WHEN body = '' THEN NULL ELSE json_extract(body, '$.surface.accent') END AS accent,
  CASE WHEN body = '' THEN NULL ELSE json_extract(body, '$.surface.symbol') END AS symbol
  FROM surfaces`;

/** An account's links, newest first: those still shared, and those that stopped in the last 30 days. */
export async function owned(db: D1Database, ownerID: string): Promise<ListedRow[]> {
  const { results } = await db
    .prepare(`${LISTED} WHERE owner_id = ? AND (revoked_at IS NULL OR revoked_at > ?) ORDER BY created_at DESC LIMIT 200`)
    .bind(ownerID, now() - 30 * 86_400)
    .all<ListedRow>();
  return results;
}

export async function listed(db: D1Database, id: string): Promise<ListedRow | null> {
  return db.prepare(`${LISTED} WHERE id = ?`).bind(id).first<ListedRow>();
}

/** Links an account made in the last day, for its daily limit. */
export async function madeToday(db: D1Database, ownerID: string): Promise<number> {
  const row = await db.prepare("SELECT COUNT(*) AS count FROM surfaces WHERE owner_id = ? AND created_at > ?").bind(ownerID, now() - 86_400).first<{ count: number }>();
  return row?.count ?? 0;
}

/** One more view. A count only: nothing about who looked is kept. */
export async function countView(db: D1Database, id: string): Promise<void> {
  await db.prepare("UPDATE surfaces SET views = views + 1 WHERE id = ?").bind(id).run();
}
