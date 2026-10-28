// PageJob, a Durable Object: one per page being made on the server (docs/ServerGeneration.md).
// The runner (runner.ts) decides what happens; this keeps it in the object's SQLite storage, runs
// it on the object's alarm, and gives the loop what it calls in-process: the model through
// model.ts's checks, routing, metering and translation, Auto's pick (route.ts), web search and
// reading (web.ts), Wikipedia, the engine, and the finished page kept in sync (sync.ts).
//
// The Worker talks to it over fetch, only ever for a signed-in user, whose id it sends:
//
//   POST /start      { counted, origin, request }   keeps the request and starts the page
//   GET  /events?after=<seq>                         the events, as server-sent events
//   POST /answers    { answers }                     the answers to its questions

import { capture, type AnalyticsEnv } from "../analytics";
import * as engine from "../engine";
import generation from "../generated/generation.json";
import { askModel } from "../model";
import { routePage, type RouteEnv } from "../route";
import { keepItems, keepPhoto, type SyncEnv } from "../sync";
import { SyncRejection } from "../syncdata";
import { readFor, searchFor, type WebEnv } from "../web";
import type { ComposeEvent, ComposeRequest } from "./contract";
import type { LoopServices } from "./loop";
import { find, related } from "./lookup";
import { surfaceItem } from "./payload";
import type { Generation } from "./prompts";
import { Runner, type EventBody, type JobRecord, type JobStore } from "./runner";
import type { WebAnswer } from "./tools";

export interface ComposeEnv extends RouteEnv, WebEnv, SyncEnv, AnalyticsEnv {
  /** The PageJob Durable Objects (wrangler.jsonc). */
  PAGE_JOBS?: DurableObjectNamespace;
}

/** The job's record and its event log, in the object's own SQLite. */
function sqlStore(state: DurableObjectState): JobStore {
  const sql = state.storage.sql;
  sql.exec("CREATE TABLE IF NOT EXISTS job (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
  sql.exec("CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY, type TEXT NOT NULL, body TEXT NOT NULL)");
  const lastSeq = () => Number(sql.exec<{ seq: number | null }>("SELECT MAX(seq) AS seq FROM events").one().seq ?? 0);
  return {
    get<T>(key: string): T | undefined {
      const row = sql.exec<{ value: string }>("SELECT value FROM job WHERE key = ?", key).toArray()[0];
      return row ? (JSON.parse(row.value) as T) : undefined;
    },
    put(key, value) {
      sql.exec("INSERT INTO job (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", key, JSON.stringify(value));
    },
    append(event: EventBody): ComposeEvent {
      const logged = { seq: lastSeq() + 1, ...event } as ComposeEvent;
      sql.exec("INSERT INTO events (seq, type, body) VALUES (?, ?, ?)", logged.seq, event.type, JSON.stringify(logged));
      return logged;
    },
    after(seq) {
      return sql.exec<{ body: string }>("SELECT body FROM events WHERE seq > ? ORDER BY seq", seq).toArray().map((row) => JSON.parse(row.body) as ComposeEvent);
    },
    lastSeq,
    forget(type, before) {
      sql.exec("DELETE FROM events WHERE type = ? AND seq < ?", type, before);
    },
    setAlarm: (at) => state.storage.setAlarm(at),
    getAlarm: () => state.storage.getAlarm(),
    async clear() {
      await state.storage.deleteAlarm();
      await state.storage.deleteAll();
    },
  };
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" } });

/** What web.ts answered, as the tools read it; a failure to answer at all is status 0. */
async function webAnswer(answering: Promise<Response>): Promise<WebAnswer> {
  try {
    const response = await answering;
    return { status: response.status, body: await response.json().catch(() => null) };
  } catch (error) {
    console.error("Web tool failed", error instanceof Error ? error.name : typeof error);
    return { status: 0, body: null };
  }
}

function bytesOf(base64: string): Uint8Array {
  const text = atob(base64);
  const bytes = new Uint8Array(text.length);
  for (let index = 0; index < text.length; index++) bytes[index] = text.charCodeAt(index);
  return bytes;
}

export class PageJob implements DurableObject {
  private readonly state: DurableObjectState;
  private readonly env: ComposeEnv;
  private readonly runner: Runner;
  /** Usage and analytics still being sent, which an alarm waits for before it ends. */
  private readonly pending = new Set<Promise<unknown>>();
  private readonly context = {
    waitUntil: (promise: Promise<unknown>) => {
      const tracked = promise.catch(() => undefined).finally(() => this.pending.delete(tracked));
      this.pending.add(tracked);
    },
  };

  constructor(state: DurableObjectState, env: ComposeEnv) {
    this.state = state;
    this.env = env;
    this.runner = new Runner(sqlStore(state), {
      loop: (job, request) => this.services(job, request),
      finish: (job, request, surface, log, model) => this.keep(job, request, surface, log, model),
      analytics: (job, event, properties) => {
        if (job.counted) capture(this.env, this.context, job.owner, event, properties);
      },
      now: Date.now,
    });
  }

  /** Local development's stand-in model, only ever with DEV_LOGIN (model.ts, compose/fake.ts). */
  private get fake(): boolean {
    return this.env.MODEL_FAKE === "1" && this.env.DEV_LOGIN === "1";
  }

  private services(job: JobRecord, _request: ComposeRequest): LoopServices {
    const env = this.env;
    return {
      engine,
      generation: generation as unknown as Generation,
      model: (body) => askModel(env, this.context, body, { userID: job.owner, pageID: job.id, counted: job.counted, fake: this.fake }),
      route: async (text, image) => {
        const { signals: _signals, ...pick } = await routePage(env, this.context, job.owner, text, image !== undefined, image, this.fake);
        return pick;
      },
      tools: {
        lookup: (subject, language) => find(subject, language),
        related: (title, language) => related(title, language),
        search: (query) => webAnswer(searchFor(env, job.owner, query)),
        read: (query) => webAnswer(readFor(env, this.context, job.owner, query, job.origin)),
      },
      now: Date.now,
      sleep: (ms, signal) =>
        new Promise((resolve, reject) => {
          if (signal.aborted) return reject(signal.reason);
          const timer = setTimeout(resolve, ms);
          signal.addEventListener("abort", () => {
            clearTimeout(timer);
            reject(signal.reason);
          }, { once: true });
        }),
    };
  }

  /** The finished page into the account's sync, with its photo, as the phone would keep it. */
  private async keep(job: JobRecord, request: ComposeRequest, surface: engine.Surface, log: string[], model: string): Promise<string | null> {
    let photo: string | undefined;
    let problem: string | null = null;
    if (request.image && this.env.PHOTOS) {
      const id = crypto.randomUUID().toUpperCase();
      const kept = await keepPhoto(this.env, this.env.PHOTOS, job.owner, id, bytesOf(request.image));
      if (kept === "kept") photo = id;
      else problem = kept === "full" ? "There's no room for its photo." : "Its photo isn't one Dream keeps.";
    }
    const item = surfaceItem(job.pageID, { intent: request.request, surface, modelName: model, log, photo, at: Date.now() });
    if (!item) return "It's too big to keep.";
    try {
      const { applied, refused } = await keepItems(this.env, job.owner, [item]);
      // Not applied and not refused: the phone kept a newer copy of it already.
      if (!applied && refused) return "Sync didn't take it.";
    } catch (error) {
      if (error instanceof SyncRejection) return error.message;
      throw error;
    }
    return problem;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const owner = request.headers.get("X-Dream-User") ?? "";
    if (!owner) return json({ error: "Sign in to continue." }, 401);
    switch (url.pathname) {
      case "/start": {
        const body = (await request.json()) as { counted: boolean; origin: string; request: ComposeRequest };
        await this.runner.start({ id: this.state.id.toString(), owner, counted: body.counted === true, origin: body.origin }, body.request);
        return json({ id: this.state.id.toString() });
      }
      case "/events": {
        const after = Number(url.searchParams.get("after") ?? "0");
        const stream = this.runner.watch(owner, Number.isSafeInteger(after) && after >= 0 ? after : 0);
        if (!stream) return json({ error: "There's no page being made with that id." }, 404);
        return new Response(stream, { headers: { "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
      }
      case "/answers": {
        const answered = await this.runner.answer(owner, await request.json().catch(() => null));
        return json(answered.body, answered.status);
      }
      default:
        return json({ error: "Not found." }, 404);
    }
  }

  async alarm(): Promise<void> {
    await this.runner.alarm();
    await Promise.allSettled([...this.pending]);
  }
}
