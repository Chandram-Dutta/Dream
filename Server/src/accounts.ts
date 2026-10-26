// Accounts: signing in with Apple, who's signed in and where, everything kept for them, and
// deleting it all (App Store guideline 5.1.1(v)).
//
//   POST   /api/auth/apple        { identityToken, nonce, name?, device? }  → 201 { token, expiresAt, user, isNew }
//   GET    /api/me                → { id, name, email, isPrivateEmail, createdAt }
//   GET    /api/me/sessions       → { sessions: [{ id, device, createdAt, lastUsedAt, current }] }
//   DELETE /api/me/sessions/:id   signs one device out; "current" is the one asking
//   POST   /api/me/export         everything kept for the person, as a JSON file (userdata.ts)
//   DELETE /api/me                { authorizationCode? }  erases everything, then asks Apple to forget Dream
//
// The app makes a random nonce for each sign-in and puts its hash in the request to Apple, which
// writes it into the identity token; the app sends the nonce itself here. Each token signs in
// once (migrations/0004). Nothing personal is logged: no tokens, names, emails or ids, only why
// a sign-in was refused.

import { appleBase, appleKeys, audiences, AppleUnavailable, fetchAppleKeys, isPrivateRelay, revoke, storedKeys, TokenRefused, verifyIdentityToken } from "./apple";
import { hashToken, newUserID, signInNeeded, startSession, userFrom, type User } from "./auth";
import type { Env } from "./index";
import { readBody, Rejection } from "./payload";
import { eraseAll, exportAll } from "./userdata";

const HEADERS = { "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Cache-Control": "no-store" };

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...HEADERS, "Content-Type": "application/json; charset=utf-8", ...headers } });
}

function problem(status: number, message: string, headers: Record<string, string> = {}): Response {
  return json({ error: message }, status, headers);
}

const now = () => Math.floor(Date.now() / 1000);

/** Fetches Apple's keys into D1 on a schedule (index.ts), so sign-ins rarely need Apple at all. */
export async function refreshAppleKeys(env: Env): Promise<void> {
  const base = appleBase(env);
  try {
    await storedKeys(env.DB).write(`${base}/auth/keys`, await fetchAppleKeys(base), Date.now());
  } catch (error) {
    console.error("Apple's keys couldn't be refreshed:", error instanceof Error ? error.message : typeof error);
  }
}

/** The account routes, or null for any other path. */
export async function routeAccounts(request: Request, env: Env, url: URL): Promise<Response | null> {
  const path = url.pathname;
  const method = request.method;
  if (path === "/api/auth/apple") return method === "POST" ? signIn(request, env) : problem(405, "Only POST.", { Allow: "POST" });
  if (path === "/api/me") {
    if (method === "GET") return withUser(request, env, async (user) => json(profile(user)));
    if (method === "DELETE") return withUser(request, env, (user) => deleteAccount(request, env, user));
    return problem(405, "Only GET or DELETE.", { Allow: "GET, DELETE" });
  }
  if (path === "/api/me/sessions") {
    return method === "GET" ? withUser(request, env, (user) => sessions(request, env, user)) : problem(405, "Only GET.", { Allow: "GET" });
  }
  const one = path.match(/^\/api\/me\/sessions\/([^/]+)$/);
  if (one) {
    return method === "DELETE" ? withUser(request, env, (user) => signOut(request, env, user, one[1])) : problem(405, "Only DELETE.", { Allow: "DELETE" });
  }
  if (path === "/api/me/export") {
    return method === "POST" ? withUser(request, env, (user) => download(request, env, user)) : problem(405, "Only POST.", { Allow: "POST" });
  }
  return null;
}

async function withUser(request: Request, env: Env, answer: (user: User) => Promise<Response>): Promise<Response> {
  const user = await userFrom(request, env);
  return user ? answer(user) : signInNeeded();
}

/** Whether this key is still under its limit. Keys are addresses or account ids, never stored. */
async function allowed(limiter: RateLimit | undefined, key: string): Promise<boolean> {
  return limiter ? (await limiter.limit({ key })).success : true;
}

/** A small JSON object from the body; an empty body is an empty object. */
async function readJSON(request: Request): Promise<Record<string, unknown>> {
  let text = "";
  try {
    if (request.body) text = await readBody(request, 16_000);
  } catch (error) {
    if (error instanceof Rejection) throw new Rejection(error.status, error.status === 413 ? "That's too much to send." : error.message);
    throw error;
  }
  if (!text.trim()) return {};
  try {
    const value = JSON.parse(text);
    if (value && typeof value === "object" && !Array.isArray(value)) return value;
  } catch {
    // Falls through to the rejection.
  }
  throw new Rejection(400, "Send a JSON object.");
}

/** Text the app sent for people to read: no control characters, spaces tidied, and capped. */
function cleanText(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const text = value.replace(/[\p{Cc}\p{Cf}]/gu, " ").replace(/\s+/g, " ").trim().slice(0, max);
  return text || null;
}

function profile(user: User) {
  return { id: user.id, name: user.name, email: user.email, isPrivateEmail: isPrivateRelay(user.email), createdAt: user.createdAt };
}

// MARK: - Signing in

async function signIn(request: Request, env: Env): Promise<Response> {
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
  if (!(await allowed(env.CREATE_LIMIT, `signin:${address}`))) return problem(429, "Too many sign-ins at once. Try again in a minute.", { "Retry-After": "60" });
  if (!/^application\/json(\s*;|$)/i.test(request.headers.get("Content-Type") ?? "")) return problem(415, "Send application/json.");
  let body: Record<string, unknown>;
  try {
    body = await readJSON(request);
  } catch (error) {
    if (error instanceof Rejection) return problem(error.status, error.message);
    throw error;
  }
  const { identityToken, nonce } = body;
  if (typeof identityToken !== "string" || identityToken.length > 10_000) return problem(400, "Send the identity token from Sign in with Apple.");
  if (typeof nonce !== "string" || nonce.length < 16 || nonce.length > 200) return problem(400, "Send the nonce this sign-in was made with.");
  const clients = audiences(env);
  if (!clients.length) {
    console.error("Sign in with Apple isn't set up: APPLE_CLIENT_ID is empty");
    return problem(503, "Signing in isn't available right now.");
  }

  let identity;
  try {
    identity = await verifyIdentityToken(identityToken, { audiences: clients, nonce, key: appleKeys(appleBase(env), storedKeys(env.DB)) });
  } catch (error) {
    if (error instanceof TokenRefused) {
      console.warn("Sign in with Apple refused:", error.reason);
      return problem(401, "Sign in with Apple didn't go through. Try again.");
    }
    if (error instanceof AppleUnavailable) return problem(503, "Couldn't reach Apple. Try again in a moment.");
    throw error;
  }

  // Each token signs in once: its nonce is kept until it expires, and a second use is refused.
  const at = now();
  const [, used] = await env.DB.batch([
    env.DB.prepare("DELETE FROM apple_nonces WHERE expires_at < ?").bind(at),
    env.DB.prepare("INSERT INTO apple_nonces (nonce, expires_at) VALUES (?, ?) ON CONFLICT (nonce) DO NOTHING").bind(identity.nonce, identity.expiresAt + 120),
  ]);
  if (!used.meta.changes) {
    console.warn("Sign in with Apple refused:", "replayed");
    return problem(401, "Sign in with Apple didn't go through. Try again.");
  }

  // A deletion still going on, or one that stopped halfway (the Worker was cut off), which is
  // finished before a new account starts.
  const deleting = await env.DB.prepare("SELECT id, deleted_at FROM users WHERE apple_sub = ? AND deleted_at IS NOT NULL")
    .bind(identity.sub)
    .first<{ id: string; deleted_at: number }>();
  if (deleting) {
    if (at - deleting.deleted_at < 600) return problem(409, "This account is being deleted. Try again in a few minutes.");
    await eraseAll(env, deleting.id);
  }

  // Apple sends the name only to the app, and only the first time; the email comes in the token.
  const name = cleanText(body.name, 100);
  const created = await env.DB.prepare("INSERT INTO users (id, apple_sub, email, name, created_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT (apple_sub) DO NOTHING")
    .bind(newUserID(), identity.sub, identity.email, name, at)
    .run();
  const isNew = created.meta.changes > 0;
  if (!isNew) {
    await env.DB.prepare("UPDATE users SET name = COALESCE(name, ?), email = COALESCE(?, email) WHERE apple_sub = ?").bind(name, identity.email, identity.sub).run();
  }
  const row = await env.DB.prepare("SELECT id, name, email, created_at, deleted_at FROM users WHERE apple_sub = ?")
    .bind(identity.sub)
    .first<{ id: string; name: string | null; email: string | null; created_at: number; deleted_at: number | null }>();
  if (!row) throw new Error("The account wasn't saved");
  if (row.deleted_at) return problem(409, "This account is being deleted. Try again in a few minutes.");

  const session = await startSession(env, row.id, cleanText(body.device, 60));
  const user: User = { id: row.id, name: row.name, email: row.email, createdAt: row.created_at };
  return json({ ...session, user: profile(user), isNew }, 201);
}

// MARK: - Devices

/** The session the request came with, as stored. */
async function currentHash(request: Request): Promise<string | null> {
  const token = /^Bearer\s+([A-Za-z0-9_-]{32,200})$/.exec(request.headers.get("Authorization") ?? "")?.[1];
  return token ? hashToken(token) : null;
}

async function sessions(request: Request, env: Env, user: User): Promise<Response> {
  const current = await currentHash(request);
  const { results } = await env.DB.prepare(
    "SELECT token_hash, device, created_at, last_used_at FROM sessions WHERE user_id = ? AND expires_at > ? ORDER BY last_used_at DESC LIMIT 100",
  )
    .bind(user.id, now())
    .all<{ token_hash: string; device: string | null; created_at: number; last_used_at: number }>();
  return json({
    sessions: results.map((row) => ({
      // The stored hash names the session: it can't be turned back into the token, and only its
      // owner sees it.
      id: row.token_hash,
      device: row.device,
      createdAt: row.created_at,
      lastUsedAt: row.last_used_at,
      current: row.token_hash === current,
    })),
  });
}

async function signOut(request: Request, env: Env, user: User, id: string): Promise<Response> {
  const hash = id === "current" ? await currentHash(request) : id;
  if (!hash || !/^[0-9a-f]{64}$/.test(hash)) return problem(404, "That device isn't signed in.");
  const result = await env.DB.prepare("DELETE FROM sessions WHERE token_hash = ? AND user_id = ?").bind(hash, user.id).run();
  return result.meta.changes ? new Response(null, { status: 204, headers: HEADERS }) : problem(404, "That device isn't signed in.");
}

// MARK: - Your data

async function download(request: Request, env: Env, user: User): Promise<Response> {
  if (!(await allowed(env.CREATE_LIMIT, `export:${user.id}`))) return problem(429, "Too many exports at once. Try again in a minute.", { "Retry-After": "60" });
  const day = new Date().toISOString().slice(0, 10);
  return json(await exportAll(env, user.id), 200, { "Content-Disposition": `attachment; filename="dream-data-${day}.json"` });
}

/** Erases the account and everything kept for it, then asks Apple to forget Dream. The app sends
 * a fresh authorization code from Apple, which revoking needs; without one, or without Dream's
 * Sign in with Apple key on this server, everything is still erased and the revocation is logged
 * as pending. */
async function deleteAccount(request: Request, env: Env, user: User): Promise<Response> {
  let body: Record<string, unknown>;
  try {
    body = await readJSON(request);
  } catch (error) {
    if (error instanceof Rejection) return problem(error.status, error.message);
    throw error;
  }
  const code = typeof body.authorizationCode === "string" && body.authorizationCode.length <= 1_000 ? body.authorizationCode : null;
  const sub = (await env.DB.prepare("SELECT apple_sub FROM users WHERE id = ?").bind(user.id).first<{ apple_sub: string | null }>())?.apple_sub ?? null;

  // Every session stops working at once, so nothing new is kept while the rest is erased.
  await env.DB.prepare("UPDATE users SET deleted_at = ? WHERE id = ?").bind(now(), user.id).run();
  try {
    await eraseAll(env, user.id);
  } catch (error) {
    await env.DB.prepare("UPDATE users SET deleted_at = NULL WHERE id = ?").bind(user.id).run();
    console.error("Deleting an account failed", error instanceof Error ? error.name : typeof error);
    return problem(500, "Your account couldn't be deleted. Try again.");
  }

  const revocation = await revoke(env, code, sub);
  if (revocation !== "revoked") console.warn("Apple revocation pending:", revocation);
  return json({ deleted: true, appleRevoked: revocation === "revoked" });
}
