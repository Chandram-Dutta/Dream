// What Dream remembers about the user, as a page made on the server reads it: the account's
// synced facts (sync kind `fact`, the app's FactPayload in Dream/Sync/SyncPayloads.swift), as the
// app's Memory reads its own store (Dream/Memory/Memory.swift). Only facts the user confirmed,
// most recent first. The model is told the topics and fetches a detail with the recall tool
// (Dream/Generation/Recall.swift), and the gap check answers a question about a remembered topic
// itself (GapCheck.resolve).
//
// No imports, so test/compose.mjs runs it in Node.

type JSONObject = Record<string, unknown>;

const isObject = (value: unknown): value is JSONObject => value !== null && typeof value === "object" && !Array.isArray(value);

/** One thing Dream remembers about the user, like Home city: Pune (Remembered). */
export interface Remembered {
  topic: string;
  detail: string;
}

/** Recall.key: topics compare without case or extra spaces, since the model copies them back. */
export function recallKey(topic: string): string {
  return topic.toLowerCase().split(/[^\p{L}\p{M}\p{N}]+/u).filter(Boolean).join(" ");
}

/** A date as SyncCoding writes it (ISO 8601) or as it also reads it (milliseconds). */
function time(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return -Infinity;
}

/** The confirmed facts among synced fact bodies, most recently changed first, as Memory.confirmed
 * sorts them. Bodies that aren't facts are passed over. */
export function confirmedFacts(bodies: unknown[]): Remembered[] {
  return bodies
    .filter(isObject)
    .filter((body) => body.confirmed === true && typeof body.topic === "string" && typeof body.text === "string" && body.topic.trim() !== "")
    .map((body) => ({ topic: body.topic as string, detail: body.text as string, at: time(body.updatedAt ?? body.createdAt) }))
    .sort((a, b) => b.at - a.at)
    .map(({ topic, detail }) => ({ topic, detail }));
}

/** What a page reads of the user's memory (Recall.Source): read once, when first asked. */
export class Memory {
  private reading: Promise<Remembered[]> | null = null;
  private readonly read: () => Promise<Remembered[]>;

  constructor(read: () => Promise<Remembered[]>) {
    this.read = read;
  }

  private all(): Promise<Remembered[]> {
    // A memory that can't be read is an empty one: the page is made without it.
    this.reading ??= this.read().catch(() => []);
    return this.reading;
  }

  /** Memory.topics: confirmed topics, most recent first, each once. */
  async topics(): Promise<string[]> {
    const seen = new Set<string>();
    return (await this.all()).map((fact) => fact.topic).filter((topic) => {
      const key = recallKey(topic);
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  }

  /** Memory.facts(about:): the confirmed facts on some topics. */
  async facts(topics: string[]): Promise<Remembered[]> {
    const wanted = new Set(topics.map(recallKey));
    return (await this.all()).filter((fact) => wanted.has(recallKey(fact.topic)));
  }
}
