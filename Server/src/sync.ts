// Cloud sync (PRODUCTION.md, workstream B): a signed-in person's pages, list entries, memory,
// connections and settings, so they follow them to another iPhone. Each phone works on its own
// copy and sends what changed. The server keeps the latest version of each item, and the latest
// change wins, by when it was made. Every batch it takes gets the next number of the person's
// change counter, so a device asks only for what's new since it last looked.
//
//   GET    /api/sync?since=<cursor>&limit=<n>   changes since the cursor, in order, a page at a time
//   POST   /api/sync                            a batch of changes: { items: [...] }
//   PUT    /api/photos/:id                      a page's photo (JPEG, PNG, HEIC or WebP), at most 4 MB
//   GET    /api/photos/:id
//   DELETE /api/photos/:id
//
// Every route needs someone signed in (auth.ts), and only ever reads or writes their own rows
// and photos. What's stored is readable by the server (PRODUCTION.md) but never logged.
//
// A page the server made (compose/) is kept the same way, as if a phone had sent it
// (`keepItems`, `keepPhoto`).

import { signInNeeded, userFrom, type AuthEnv, type User } from "./auth";
import { decodeCursor, encodeCursor, imageType, LIMITS, parseChanges, PHOTO_ID, photoKey, SyncRejection, type Change, type Cursor } from "./syncdata";

export { deleteUserData, exportUserData } from "./syncdata";

export interface SyncEnv extends AuthEnv {
  DB: D1Database;
  /** Photos from synced pages: the dream-photos bucket. */
  PHOTOS?: R2Bucket;
  /** Requests a minute for each person, sync and photos together. */
  SYNC_LIMIT?: RateLimit;
  /** Tests only: smaller allowances, in bytes, than LIMITS.stored and LIMITS.photos. */
  SYNC_QUOTA_BYTES?: string;
  SYNC_PHOTO_QUOTA_BYTES?: string;
}

const HEADERS = { "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Cache-Control": "no-store" };

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(typeof body === "string" ? body : JSON.stringify(body), { status, headers: { ...HEADERS, "Content-Type": "application/json; charset=utf-8", ...headers } });
}

function problem(status: number, message: string, headers: Record<string, string> = {}): Response {
  return json({ error: message }, status, headers);
}

/** The sync and photo routes; null for any other path. */
export async function routeSync(request: Request, env: SyncEnv, url: URL): Promise<Response | null> {
  const photo = url.pathname.match(/^\/api\/photos\/([^/]+)$/);
  if (url.pathname !== "/api/sync" && !photo) return null;
  const user = await userFrom(request, env);
  if (!user) return signInNeeded();
  if (env.SYNC_LIMIT && !(await env.SYNC_LIMIT.limit({ key: `sync:${user.id}` })).success) {
    return problem(429, "Too many requests. Try again in a minute.", { "Retry-After": "60" });
  }
  try {
    if (photo) {
      if (!env.PHOTOS) return problem(503, "Photos aren't set up on this server.");
      const id = photo[1];
      if (!PHOTO_ID.test(id)) return problem(400, "That isn't a photo id.");
      switch (request.method) {
        case "GET":
        case "HEAD":
          return await getPhoto(env.PHOTOS, user, id);
        case "PUT":
          return await putPhoto(request, env, env.PHOTOS, user, id);
        case "DELETE":
          await removePhoto(env, user.id, id);
          return new Response(null, { status: 204, headers: HEADERS });
        default:
          return problem(405, "Only GET, PUT and DELETE.", { Allow: "GET, HEAD, PUT, DELETE" });
      }
    }
    switch (request.method) {
      case "GET":
        return await pull(env, user, url);
      case "POST":
        return await push(request, env, user);
      default:
        return problem(405, "Only GET and POST.", { Allow: "GET, POST" });
    }
  } catch (error) {
    if (error instanceof SyncRejection) return problem(error.status, error.message);
    throw error;
  }
}

// MARK: - Reading changes

interface Row {
  kind: string;
  id: string;
  parent: string | null;
  format: number;
  updated_at: number;
  deleted: number;
  body: string | null;
  size: number;
  change: number;
}

/** One item as the app reads it. Bodies were checked and written by this Worker, so they're
 * spliced in as they are rather than parsed and written out again. */
function itemJSON(row: Row): string {
  const body = row.deleted || row.body === null ? "null" : row.body;
  return `{"kind":${JSON.stringify(row.kind)},"id":${JSON.stringify(row.id)},"parent":${JSON.stringify(row.parent)},"format":${row.format},"updatedAt":${row.updated_at},"deleted":${row.deleted ? "true" : "false"},"body":${body}}`;
}

const COLUMNS = "kind, id, parent, format, updated_at, deleted, body, size, change";

async function pull(env: SyncEnv, user: User, url: URL): Promise<Response> {
  const since = decodeCursor(url.searchParams.get("since"), user.id);
  if (!since) return problem(400, "That isn't a cursor this server made.");
  const asked = Number(url.searchParams.get("limit") ?? LIMITS.page);
  const limit = Number.isInteger(asked) ? Math.min(Math.max(asked, 1), LIMITS.maxPage) : LIMITS.page;
  const { cursor } = since;
  const { results } = await env.DB.prepare(
    `SELECT ${COLUMNS} FROM sync_items WHERE user_id = ?1 AND (change, kind, id) > (?2, ?3, ?4) ORDER BY change, kind, id LIMIT ?5`,
  )
    .bind(user.id, cursor.change, cursor.kind, cursor.id, limit + 1)
    .all<Row>();
  // A page ends at the limit, or soon after it carries about LIMITS.pageBytes.
  const page: Row[] = [];
  let bytes = 0;
  for (const row of results.slice(0, limit)) {
    page.push(row);
    bytes += row.size;
    if (bytes > LIMITS.pageBytes) break;
  }
  const more = page.length < results.length;
  const last = page.at(-1);
  const next: Cursor = last ? { change: last.change, kind: last.kind, id: last.id } : cursor;
  return json(
    `{"user":${JSON.stringify(user.id)},"items":[${page.map(itemJSON).join(",")}],"cursor":${JSON.stringify(encodeCursor(next, user.id))},"more":${more},"reset":${since.elsewhere},"now":${Date.now()}}`,
  );
}

// MARK: - Taking changes

/** Reads at most `max` bytes of a body, or refuses it. */
async function readLimited(request: Request, max: number, tooBig: string): Promise<Uint8Array> {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > max) throw new SyncRejection(413, tooBig);
  if (!request.body) throw new SyncRejection(400, "Nothing was sent.");
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      await reader.cancel();
      throw new SyncRejection(413, tooBig);
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

const allowance = (setting: string | undefined, fallback: number) => {
  const value = Number(setting);
  return Number.isFinite(value) && value > 0 ? value : fallback;
};

async function push(request: Request, env: SyncEnv, user: User): Promise<Response> {
  if (!/^application\/json(\s*;|$)/i.test(request.headers.get("Content-Type") ?? "")) return problem(415, "Send changes as application/json.");
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(await readLimited(request, LIMITS.request, "That's more than one sync can send."));
  } catch (error) {
    if (error instanceof SyncRejection) throw error;
    throw new SyncRejection(400, "That isn't text.");
  }
  const now = Date.now();
  const { changes, refused } = parseChanges(text, now);
  if (!changes.length) return json({ applied: 0, stale: [], refused, now });
  const { applied, staleItems } = await store(env, user.id, changes);
  return json(`{"applied":${applied},"stale":[${staleItems.join(",")}],"refused":${JSON.stringify(refused)},"now":${now}}`);
}

/** Items for someone's account, from the server itself rather than a phone: checked as a sync
 * from a phone is, and kept the same way. Throws SyncRejection when the account is full. */
export async function keepItems(env: SyncEnv, userID: string, items: unknown[]): Promise<{ applied: number; refused: number }> {
  const { changes, refused } = parseChanges(JSON.stringify({ items }), Date.now());
  if (!changes.length) return { applied: 0, refused: refused.length };
  const { applied } = await store(env, userID, changes);
  return { applied, refused: refused.length };
}

/** Writes checked changes: each one only if it's newer than what's stored, within the account's
 * allowance. Returns how many were applied, and for those older than what's stored, what is. */
async function store(env: SyncEnv, userID: string, changes: Change[]): Promise<{ applied: number; staleItems: string[] }> {
  // What's stored now for these items: for the allowance, and for photos a page lets go of.
  const keyOf = (item: { kind: string; id: string }) => `${item.kind}/${item.id}`;
  const { results: before } = await env.DB.prepare(
    `SELECT kind, id, updated_at, size, CASE WHEN kind = 'surface' AND deleted = 0 THEN json_extract(body, '$.photo') END AS photo
     FROM sync_items WHERE user_id = ?1 AND kind || '/' || id IN (SELECT value FROM json_each(?2))`,
  )
    .bind(userID, JSON.stringify(changes.map(keyOf)))
    .all<{ kind: string; id: string; updated_at: number; size: number; photo: string | null }>();
  const stored = new Map(before.map((row) => [keyOf(row), row]));

  // The allowance counts only changes that would win. Deleting always fits.
  let growth = 0;
  for (const change of changes) {
    const old = stored.get(keyOf(change));
    if (old && change.updatedAt <= old.updated_at) continue;
    growth += change.size - (old?.size ?? 0);
  }
  if (growth > 0) {
    const total = (await env.DB.prepare("SELECT COALESCE(SUM(size), 0) AS total FROM sync_items WHERE user_id = ?").bind(userID).first<{ total: number }>())?.total ?? 0;
    if (total + growth > allowance(env.SYNC_QUOTA_BYTES, LIMITS.stored)) throw new SyncRejection(507, "Your account is full.");
  }

  // One transaction: the batch takes the next change number, and each change is written only if
  // it's newer than what's stored. A tie keeps what's stored, as the app does.
  const counter = "(SELECT change FROM sync_state WHERE user_id = ?1)";
  const statements = [env.DB.prepare("INSERT INTO sync_state (user_id, change) VALUES (?1, 1) ON CONFLICT (user_id) DO UPDATE SET change = change + 1").bind(userID)];
  for (const change of changes) {
    statements.push(
      env.DB.prepare(
        `INSERT INTO sync_items (user_id, kind, id, parent, format, updated_at, deleted, body, size, change)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ${counter})
         ON CONFLICT (user_id, kind, id) DO UPDATE SET parent = excluded.parent, format = excluded.format, updated_at = excluded.updated_at,
           deleted = excluded.deleted, body = excluded.body, size = excluded.size, change = excluded.change
         WHERE excluded.updated_at > sync_items.updated_at`,
      ).bind(userID, change.kind, change.id, change.parent, change.format, change.updatedAt, change.deleted ? 1 : 0, change.body, change.size),
    );
  }
  // A deleted page takes its entries with it, unless one changed after it was deleted.
  const cascades = changes.filter((change) => change.kind === "surface" && change.deleted);
  for (const page of cascades) {
    statements.push(
      env.DB.prepare(
        `UPDATE sync_items SET deleted = 1, body = NULL, size = 0, updated_at = ?3, change = ${counter}
         WHERE user_id = ?1 AND kind = 'record' AND parent = ?2 AND deleted = 0 AND updated_at < ?3
           AND EXISTS (SELECT 1 FROM sync_items WHERE user_id = ?1 AND kind = 'surface' AND id = ?2 AND deleted = 1 AND updated_at = ?3)`,
      ).bind(userID, page.id, page.updatedAt),
    );
  }
  const results = await env.DB.batch(statements);
  const applied: Change[] = [];
  const stale: Change[] = [];
  changes.forEach((change, index) => ((results[index + 1].meta.changes ?? 0) > 0 ? applied : stale).push(change));

  // Photos a page no longer has, or a deleted page had.
  for (const change of applied) {
    const old = stored.get(keyOf(change))?.photo;
    if (old && old !== change.photo) await removePhoto(env, userID, old);
  }

  // For changes older than what's stored, what is stored, so the app can take it.
  let staleItems: string[] = [];
  if (stale.length) {
    const { results: rows } = await env.DB.prepare(`SELECT ${COLUMNS} FROM sync_items WHERE user_id = ?1 AND kind || '/' || id IN (SELECT value FROM json_each(?2))`)
      .bind(userID, JSON.stringify(stale.map(keyOf)))
      .all<Row>();
    staleItems = rows.map(itemJSON);
  }
  return { applied: applied.length, staleItems };
}

// MARK: - Photos

async function getPhoto(bucket: R2Bucket, user: User, id: string): Promise<Response> {
  const object = await bucket.get(photoKey(user.id, id));
  if (!object) return problem(404, "There's no photo here.");
  return new Response(object.body, {
    headers: { ...HEADERS, "Content-Type": object.httpMetadata?.contentType ?? "application/octet-stream", "Content-Length": String(object.size) },
  });
}

async function putPhoto(request: Request, env: SyncEnv, bucket: R2Bucket, user: User, id: string): Promise<Response> {
  const bytes = await readLimited(request, LIMITS.photo, "That photo is too big.");
  switch (await keepPhoto(env, bucket, user.id, id, bytes)) {
    case "unsupported":
      return problem(415, "Send a JPEG, PNG, HEIC or WebP photo.");
    case "full":
      return problem(507, "Your account is full.");
    case "kept":
      return json({ id, size: bytes.length }, 201);
  }
}

/** Keeps a page's photo under its id, within the account's allowance for photos. */
export async function keepPhoto(env: SyncEnv, bucket: R2Bucket, userID: string, id: string, bytes: Uint8Array): Promise<"kept" | "full" | "unsupported"> {
  const type = imageType(bytes);
  if (!type || bytes.length > LIMITS.photo) return "unsupported";
  const others = await env.DB.prepare("SELECT COALESCE(SUM(size), 0) AS total FROM sync_photos WHERE user_id = ? AND id != ?").bind(userID, id).first<{ total: number }>();
  if ((others?.total ?? 0) + bytes.length > allowance(env.SYNC_PHOTO_QUOTA_BYTES, LIMITS.photos)) return "full";
  await bucket.put(photoKey(userID, id), bytes, { httpMetadata: { contentType: type } });
  await env.DB.prepare(
    "INSERT INTO sync_photos (user_id, id, size, content_type, created_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT (user_id, id) DO UPDATE SET size = excluded.size, content_type = excluded.content_type",
  )
    .bind(userID, id, bytes.length, type, Math.floor(Date.now() / 1000))
    .run();
  return "kept";
}

async function removePhoto(env: SyncEnv, userID: string, id: string): Promise<void> {
  await env.PHOTOS?.delete(photoKey(userID, id));
  await env.DB.prepare("DELETE FROM sync_photos WHERE user_id = ? AND id = ?").bind(userID, id).run();
}
