// Shared surfaces in D1: one row per link, written once and never changed.

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

export interface Stored extends Shared {
  id: string;
  created: number;
}

export async function save(db: D1Database, shared: Shared): Promise<string> {
  const body = JSON.stringify(shared);
  const surface = shared.surface;
  for (let attempt = 0; attempt < 3; attempt++) {
    const id = newID();
    try {
      await db
        .prepare("INSERT INTO surfaces (id, created_at, format, title, summary, language, has_values, size, body) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
        .bind(id, Math.floor(Date.now() / 1000), shared.format, String(surface.title), String(surface.summary), languageOf(surface) ?? null, shared.values ? 1 : 0, body.length, body)
        .run();
      return id;
    } catch (error) {
      // Two links with the same id is all but impossible; anything else is a real failure.
      if (!String(error).includes("UNIQUE")) throw error;
    }
  }
  throw new Error("Couldn't find a free id.");
}

export async function load(db: D1Database, id: string): Promise<Stored | null> {
  const row = await db.prepare("SELECT created_at, body FROM surfaces WHERE id = ?").bind(id).first<{ created_at: number; body: string }>();
  if (!row) return null;
  return { ...(JSON.parse(row.body) as Shared), id, created: row.created_at };
}
