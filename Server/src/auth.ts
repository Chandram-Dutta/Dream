// Who's asking. Every route that keeps something for a person, or spends money on their behalf,
// asks `userFrom` first. The app signs in with Apple and gets a session token, which it sends as
// `Authorization: Bearer <token>`; only a hash of the token is stored (migrations/0003).
//
//   POST /api/dev/session    a session for a test user, only where DEV_LOGIN is "1" (.dev.vars)

export interface AuthEnv {
  DB: D1Database;
  /** "1" in local development only, never in production: lets tests sign in without Apple. */
  DEV_LOGIN?: string;
}

export interface User {
  id: string;
  email: string | null;
  name: string | null;
  createdAt: number;
}

/** How long a session lasts without being used. Each use pushes the end out again. */
const SESSION_SECONDS = 90 * 24 * 60 * 60;
/** Sessions are only touched once in this long, so reading them doesn't mean a write every time. */
const TOUCH_SECONDS = 60 * 60;

const now = () => Math.floor(Date.now() / 1000);

export async function hashToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** 32 random bytes, base64url: unguessable, and safe in a header. */
export function newToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A new id for a person, unrelated to anything Apple knows. */
export function newUserID(): string {
  return crypto.randomUUID();
}

/** Signs a user in on one device. The token is returned once and never stored. */
export async function startSession(env: AuthEnv, userID: string, device: string | null): Promise<{ token: string; expiresAt: number }> {
  const token = newToken();
  const at = now();
  const expiresAt = at + SESSION_SECONDS;
  await env.DB.prepare("INSERT INTO sessions (token_hash, user_id, created_at, last_used_at, expires_at, device) VALUES (?, ?, ?, ?, ?, ?)")
    .bind(await hashToken(token), userID, at, at, expiresAt, device?.slice(0, 60) ?? null)
    .run();
  return { token, expiresAt };
}

/** The signed-in user making this request, or null. */
export async function userFrom(request: Request, env: AuthEnv): Promise<User | null> {
  const token = /^Bearer\s+([A-Za-z0-9_-]{32,200})$/.exec(request.headers.get("Authorization") ?? "")?.[1];
  if (!token) return null;
  const hash = await hashToken(token);
  const at = now();
  const row = await env.DB.prepare(
    `SELECT users.id AS id, users.email AS email, users.name AS name, users.created_at AS created_at, sessions.last_used_at AS last_used_at
     FROM sessions JOIN users ON users.id = sessions.user_id
     WHERE sessions.token_hash = ? AND sessions.expires_at > ? AND users.deleted_at IS NULL`,
  ).bind(hash, at).first<{ id: string; email: string | null; name: string | null; created_at: number; last_used_at: number }>();
  if (!row) return null;
  if (at - row.last_used_at > TOUCH_SECONDS) {
    await env.DB.prepare("UPDATE sessions SET last_used_at = ?, expires_at = ? WHERE token_hash = ?").bind(at, at + SESSION_SECONDS, hash).run();
  }
  return { id: row.id, email: row.email, name: row.name, createdAt: row.created_at };
}

/** The answer to a request that needs someone signed in. */
export function signInNeeded(): Response {
  return new Response(JSON.stringify({ error: "Sign in to continue." }), {
    status: 401,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "WWW-Authenticate": "Bearer" },
  });
}

/** Local development only: a session for a test user, so features can be tried without Apple.
 * Null (so the route doesn't exist) unless DEV_LOGIN is "1". */
export async function devSession(request: Request, env: AuthEnv): Promise<Response | null> {
  if (env.DEV_LOGIN !== "1" || request.method !== "POST") return null;
  const name = new URL(request.url).searchParams.get("user") ?? "test";
  const sub = `dev:${name.slice(0, 40)}`;
  let id = (await env.DB.prepare("SELECT id FROM users WHERE apple_sub = ?").bind(sub).first<{ id: string }>())?.id;
  if (!id) {
    id = newUserID();
    await env.DB.prepare("INSERT INTO users (id, apple_sub, email, name, created_at) VALUES (?, ?, NULL, ?, ?)").bind(id, sub, name, now()).run();
  }
  const session = await startSession(env, id, "dev");
  return new Response(JSON.stringify({ user: id, ...session }), { status: 201, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" } });
}
