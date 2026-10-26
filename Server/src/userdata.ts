// Everything Dream keeps for a person, in one list, so "Export my data" and "Delete my account"
// (accounts.ts) can't miss any of it. App Store guideline 5.1.1(v) asks for deletion in the app;
// GDPR and India's DPDP Act ask for both.
//
// A table that holds someone's data gets one entry in HOLDINGS, added beside the others:
//
//   {
//     name: "pages",       // its key in the export
//     export: (env, user) => rows(env, "SELECT id, title, updated_at AS updatedAt FROM pages WHERE user_id = ?", user),
//     erase: async (env, user) => [env.DB.prepare("DELETE FROM pages WHERE user_id = ?").bind(user)],
//   },
//
// - `export` returns plain JSON, as the person would recognise it as theirs. Leave out secrets and
//   hashes (session tokens, OAuth tokens) and anything only Dream could make sense of.
// - `erase` returns the D1 statements that remove it. Every holding's statements run in one
//   batch, so a deletion is all or nothing, and a failed one can be tried again. Anything outside
//   D1 (photos in R2) is removed inside `erase` before it returns; make that safe to repeat.
// - Holdings run first to last, and the account itself (sessions, then the user) always goes
//   last, so tables that refer to `users(id)` are emptied before it.

import type { Env } from "./index";
import { sharingErasure } from "./sharing";

export interface Holding {
  name: string;
  export(env: Env, userID: string): Promise<unknown>;
  erase(env: Env, userID: string): Promise<D1PreparedStatement[]>;
}

/** Every workstream's tables. The account's own come after these, in `ACCOUNT`. */
const HOLDINGS: Holding[] = [
  {
    name: "sharedLinks",
    // What was shared and how it went; the pages themselves are in the export's pages.
    export: async (env, user) =>
      (await rows(env, "SELECT id, title, created_at, updated_at, expires_at, revoked_at, views, has_values FROM surfaces WHERE owner_id = ? ORDER BY created_at", user)).map((row) => ({
        id: row.id,
        title: row.title,
        sharedAt: date(row.created_at),
        updatedAt: date(row.updated_at),
        expiresAt: date(row.expires_at),
        stoppedAt: date(row.revoked_at),
        views: row.views,
        withNumbers: row.has_values === 1,
      })),
    erase: async (env, user) => sharingErasure(env, user),
  },
];

/** Who the person is, and where they're signed in. Always last. */
const ACCOUNT: Holding[] = [
  {
    name: "sessions",
    // Devices and dates only: never the token's hash.
    export: async (env, user) =>
      (await rows(env, "SELECT device, created_at, last_used_at, expires_at FROM sessions WHERE user_id = ? ORDER BY created_at", user)).map((row) => ({
        device: row.device,
        signedInAt: date(row.created_at),
        lastUsedAt: date(row.last_used_at),
        expiresAt: date(row.expires_at),
      })),
    erase: async (env, user) => [env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(user)],
  },
  {
    name: "account",
    export: async (env, user) => {
      const row = (await rows(env, "SELECT id, name, email, created_at FROM users WHERE id = ?", user))[0];
      return row ? { id: row.id, name: row.name, email: row.email, createdAt: date(row.created_at), signIn: "Sign in with Apple" } : null;
    },
    erase: async (env, user) => [env.DB.prepare("DELETE FROM users WHERE id = ?").bind(user)],
  },
];

/** Everything kept for this person, by holding, account first. */
export async function exportAll(env: Env, userID: string): Promise<Record<string, unknown>> {
  const all = [...ACCOUNT].reverse().concat(HOLDINGS);
  const parts = await Promise.all(all.map(async (holding) => [holding.name, await holding.export(env, userID)] as const));
  return { format: 1, exportedAt: new Date().toISOString(), ...Object.fromEntries(parts) };
}

/** Erases everything kept for this person, in one batch. Throws, having changed nothing in D1,
 * when any part fails. */
export async function eraseAll(env: Env, userID: string): Promise<void> {
  const statements: D1PreparedStatement[] = [];
  for (const holding of [...HOLDINGS, ...ACCOUNT]) statements.push(...(await holding.erase(env, userID)));
  await env.DB.batch(statements);
}

// MARK: - Helpers for holdings

/** The rows a query finds for one person, as plain objects. */
export async function rows(env: Env, sql: string, userID: string): Promise<Record<string, any>[]> {
  return (await env.DB.prepare(sql).bind(userID).all<Record<string, any>>()).results;
}

/** A stored time (seconds since 1970) as an ISO 8601 date, for people to read. */
export function date(seconds: unknown): string | null {
  return typeof seconds === "number" ? new Date(seconds * 1000).toISOString() : null;
}
