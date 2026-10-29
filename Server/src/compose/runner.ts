// One page's job, whatever keeps it (job.ts keeps it in a Durable Object): its record, its event
// log, the watchers, the answers, and when the loop runs (docs/ServerGeneration.md).
//
//   start     the request is kept and the loop is set to run at once, on the alarm
//   alarm     the loop runs; questions stop it, and the alarm wakes it again when they're
//             answered or in ten minutes, as if every answer were "You choose"
//   watch     every event after a seq from the log, then new ones as they happen
//   answer    the user's answers to the questions it's waiting on
//
// Every event goes into the log with the next seq. A page shown so far is superseded by the next,
// so only the latest stays in the log: a watcher catching up gets the page as it stands, not
// every step of it. If the object is restarted mid-page, the alarm runs again and the page starts
// over, keeping only the model Auto picked and any answers. A day after it's done, it's forgotten.
// A page finished, or questions asked, while nobody watches is a notification (push.ts).
//
// test/compose.mjs runs it in Node, with a store kept in memory.

import type { Surface } from "../engine/index";
import { pageReady, questionWaiting, type Notice } from "../push";
import type { ComposeEvent, ComposeRequest } from "./contract";
import { Cancelled, leftToDream, PageLoop, TIMING, type LoopServices, type PagePick, type Start, type Timing } from "./loop";
import type { Answer, Question } from "./prompts";

type JSONObject = Record<string, unknown>;

const isObject = (value: unknown): value is JSONObject => value !== null && typeof value === "object" && !Array.isArray(value);

type Without<T, K extends keyof T> = T extends unknown ? Omit<T, K> : never;
/** An event before it has its place in the log. */
export type EventBody = Without<ComposeEvent, "seq">;

/** Where a job keeps itself. Reads and writes are synchronous, as a Durable Object's SQL is. */
export interface JobStore {
  get<T>(key: string): T | undefined;
  put(key: string, value: unknown): void;
  /** Adds an event to the log with the next seq. */
  append(event: EventBody): ComposeEvent;
  /** Every event after `seq`, in order. */
  after(seq: number): ComposeEvent[];
  /** The last seq given, or 0. */
  lastSeq(): number;
  /** Drops events of a type from before a seq: pages since superseded. */
  forget(type: ComposeEvent["type"], before: number): void;
  setAlarm(at: number): Promise<void>;
  getAlarm(): Promise<number | null>;
  /** Forgets the job and everything it kept. */
  clear(): Promise<void>;
}

export type JobStatus = "queued" | "running" | "asking" | "done" | "failed";

/** What a job keeps about itself, apart from its request. */
export interface JobRecord {
  id: string;
  /** The account it's for: the only one that may watch it or answer it. */
  owner: string;
  pageID: string;
  /** The person lets Dream count what's used (analytics.ts). */
  counted: boolean;
  /** Where the request came to, for the reader's User-Agent (web.ts). */
  origin: string;
  status: JobStatus;
  /** Starts of the page: more than one only when the object restarted mid-page. */
  attempts: number;
  createdAt: number;
  /** When this attempt began. */
  startedAt: number;
  /** The seq this attempt's log begins at, for the page's generation log. */
  logFrom: number;
  pick: PagePick | null;
  questions: Question[] | null;
  checkedAt: number | null;
  /** When questions go unanswered as "You choose". */
  deadline: number | null;
  answers: Answer[] | null;
  finishedAt: number | null;
}

export interface JobServices {
  /** What the loop calls, for this job: the model in-process, its tools, the engine. */
  loop(job: JobRecord, request: ComposeRequest): LoopServices;
  /** Keeps the finished page in the account's sync. Says what went wrong, or null. */
  finish(job: JobRecord, request: ComposeRequest, surface: Surface, log: string[], model: string): Promise<string | null>;
  /** An analytics event, for someone who lets Dream count what's used. */
  analytics(job: JobRecord, event: string, properties: Record<string, string | number | boolean | null | string[]>): void;
  /** Tells the account's iPhones what they'd come back for (push.ts). Absent where nothing is
   * sent, as in tests. */
  notify?(job: JobRecord, notice: Notice): void;
  now(): number;
}

export interface JobTiming {
  /** How long questions wait before the page is made as if every answer were "You choose". */
  answerWait: number;
  /** How long one run of the loop may take, inside an alarm's fifteen minutes. */
  runLimit: number;
  /** How long a finished job is kept, for a watcher to find it by its id. */
  keep: number;
  /** Starts of a page before it's given up on. */
  attempts: number;
  /** A comment this often while nothing happens, so the line stays open. */
  keepAlive: number;
}

export const JOB_TIMING: JobTiming = {
  answerWait: 10 * 60_000,
  runLimit: 14 * 60_000,
  keep: 24 * 3_600_000,
  attempts: 3,
  keepAlive: 15_000,
};

const finished = (status: JobStatus) => status === "done" || status === "failed";

/** What a page is made of, for analytics: never its words (Analytics.Shape). */
export function pageShape(surface: Surface): Record<string, number | boolean | string | string[]> {
  const blocks: JSONObject[] = [];
  const walk = (items: unknown) => {
    for (const block of Array.isArray(items) ? items : []) {
      if (!isObject(block)) continue;
      blocks.push(block);
      walk(block.children);
    }
  };
  walk(surface.blocks);
  const count = (value: unknown) => (Array.isArray(value) ? value.length : 0);
  const wikipedia = (url: unknown) => {
    try {
      return new URL(String(url)).hostname.toLowerCase().endsWith(".wikipedia.org");
    } catch {
      return false;
    }
  };
  return {
    blocks: blocks.length,
    block_kinds: [...new Set(blocks.map((block) => String(block.kind ?? "")))].sort(),
    inputs: count(surface.inputs),
    outputs: count(surface.outputs),
    lists: count(surface.collections),
    live_sources: count(surface.sources),
    used_web: (Array.isArray(surface.citations) ? surface.citations : []).some((citation) => isObject(citation) && !wikipedia(citation.url)),
    used_connections: count(surface.services) > 0,
    asked_questions: count(surface.answers) > 0,
    mode: typeof surface.mode === "string" ? surface.mode : "unknown",
  };
}

const seconds = (ms: number) => Math.round(ms / 100) / 10;

export class Runner {
  private readonly store: JobStore;
  private readonly services: JobServices;
  private readonly timing: JobTiming;
  private readonly loopTiming: Timing;
  /** Watchers waiting for the next event. */
  private readonly waiters = new Set<() => void>();
  /** The loop is running in this instance. */
  private active = false;
  /** Event streams open now: someone is watching, and needs no notification. */
  private watchers = 0;

  constructor(store: JobStore, services: JobServices, timing: JobTiming = JOB_TIMING, loopTiming: Timing = TIMING) {
    this.store = store;
    this.services = services;
    this.timing = timing;
    this.loopTiming = loopTiming;
  }

  private get now(): number {
    return this.services.now();
  }

  get job(): JobRecord | undefined {
    return this.store.get<JobRecord>("job");
  }

  private save(job: JobRecord): void {
    this.store.put("job", job);
  }

  private emit(event: EventBody): ComposeEvent {
    const logged = this.store.append(event);
    if (event.type === "surface") this.store.forget("surface", logged.seq);
    for (const wake of [...this.waiters]) wake();
    return logged;
  }

  /** Keeps a new page's request and starts it on the alarm. Asking again changes nothing. */
  async start(fields: Pick<JobRecord, "id" | "owner" | "counted" | "origin">, request: ComposeRequest): Promise<void> {
    if (this.job) return;
    const now = this.now;
    this.store.put("request", request);
    this.save({ ...fields, pageID: request.pageID, status: "queued", attempts: 0, createdAt: now, startedAt: now, logFrom: 1, pick: null, questions: null, checkedAt: null, deadline: null, answers: null, finishedAt: null });
    await this.store.setAlarm(now);
  }

  /** Runs whatever the job is waiting to do. Never throws, so the alarm isn't tried again for a
   * page that failed; only a restart of the object, mid-run, runs it again. */
  async alarm(): Promise<void> {
    const job = this.job;
    const request = this.store.get<ComposeRequest>("request");
    if (!job || !request) {
      await this.store.clear();
      return;
    }
    if (finished(job.status)) {
      const forgetAt = (job.finishedAt ?? job.createdAt) + this.timing.keep;
      if (this.now >= forgetAt) await this.store.clear();
      else await this.store.setAlarm(forgetAt);
      return;
    }
    if (this.active) return;
    let start: Start;
    if (job.status === "asking") {
      if (!job.answers) {
        if (job.deadline !== null && this.now < job.deadline) {
          await this.store.setAlarm(job.deadline);
          return;
        }
        // Nobody answered: every question is left to Dream, so building never waits on a screen that's gone.
        job.answers = (job.questions ?? []).map(leftToDream);
      }
      start = { pick: job.pick, answers: job.answers, checkedAt: job.checkedAt, startedAt: job.startedAt, first: false };
    } else {
      if (job.status === "running") {
        // The object restarted while it was making the page: it starts over.
        if (job.attempts >= this.timing.attempts) {
          this.fail(job, "Dream couldn't finish this page. Try again.", "other");
          return;
        }
        job.logFrom = this.emit({ type: "log", line: "Started again: Dream's server restarted while it was making this page." }).seq;
      } else {
        job.logFrom = this.store.lastSeq() + 1;
      }
      job.attempts += 1;
      job.startedAt = this.now;
      if (job.attempts === 1) this.services.analytics(job, "page_requested", { with_photo: !!request.image });
      start = { pick: job.pick, answers: job.answers, checkedAt: null, startedAt: job.startedAt, first: true };
    }
    job.status = "running";
    this.save(job);
    await this.run(job, request, start);
  }

  private async run(job: JobRecord, request: ComposeRequest, start: Start): Promise<void> {
    this.active = true;
    const limit = new AbortController();
    const timer = setTimeout(() => limit.abort(new Cancelled("This page took too long to make. Try again.")), this.timing.runLimit);
    try {
      const loop = new PageLoop(
        request,
        this.services.loop(job, request),
        {
          phase: (phase) => this.emit({ type: "phase", phase }),
          trace: (kind, text) => this.emit({ type: "trace", kind, text }),
          surface: (surface) => this.emit({ type: "surface", surface }),
          log: (line) => this.emit({ type: "log", line }),
          picked: (pick) => {
            job.pick = pick;
            this.save(job);
          },
        },
        limit.signal,
        this.loopTiming,
      );
      const outcome = await loop.run(start);
      clearTimeout(timer);
      switch (outcome.kind) {
        case "asking": {
          job.status = "asking";
          job.questions = outcome.questions;
          job.checkedAt = outcome.checkedAt;
          job.answers = null;
          job.deadline = this.now + this.timing.answerWait;
          this.save(job);
          this.emit({ type: "asking", questions: outcome.questions });
          // Push: nobody is there to answer, so the account's iPhones are told.
          if (!this.watchers) this.services.notify?.(job, questionWaiting(job, request.request, this.now));
          await this.store.setAlarm(job.deadline);
          return;
        }
        case "failed":
          this.fail(job, outcome.message, outcome.reason);
          return;
        case "done": {
          const log = this.store.after(job.logFrom - 1).flatMap((event) => (event.type === "log" ? [event.line] : []));
          let problem: string | null;
          try {
            problem = await this.services.finish(job, request, outcome.surface, log, outcome.model);
          } catch (error) {
            console.error("Page not synced", error instanceof Error ? error.name : typeof error);
            problem = "Dream's server couldn't keep it just now.";
          }
          if (problem) this.emit({ type: "log", line: `Not kept in sync: ${problem}` });
          job.status = "done";
          job.finishedAt = this.now;
          this.save(job);
          this.emit({ type: "done", surface: outcome.surface, model: outcome.model, pageID: job.pageID });
          // Push: nobody saw it finish, so the account's iPhones are told it's ready.
          if (!this.watchers) this.services.notify?.(job, pageReady(job, request.request, outcome.surface, this.now));
          this.services.analytics(job, "page_built", { ...pageShape(outcome.surface), model: outcome.model, seconds: seconds(this.now - job.startedAt) });
          await this.store.setAlarm(job.finishedAt + this.timing.keep);
          return;
        }
      }
    } catch (error) {
      // The loop catches its own failures; this is anything else, which still ends the page.
      console.error("Page job failed", error instanceof Error ? error.name : typeof error);
      this.fail(job, "Something went wrong. Try again in a moment.", "other");
    } finally {
      clearTimeout(timer);
      this.active = false;
    }
  }

  private fail(job: JobRecord, message: string, reason: string): void {
    job.status = "failed";
    job.finishedAt = this.now;
    this.save(job);
    this.emit({ type: "failed", message });
    this.services.analytics(job, "page_failed", { reason, changing: false, seconds: seconds(this.now - job.startedAt) });
    this.store.setAlarm(job.finishedAt + this.timing.keep).catch(() => undefined);
  }

  /** A page that was being made when this instance began, with no alarm to start it again: one
   * is set, so a watcher never waits on a page nothing is making. */
  private async heal(): Promise<void> {
    if ((await this.store.getAlarm()) === null && this.job?.status === "running" && !this.active) await this.store.setAlarm(this.now);
  }

  /** Resolves true at the next event, or false after `ms` without one. */
  private next(ms: number): Promise<boolean> {
    return new Promise((resolve) => {
      const wake = () => {
        clearTimeout(timer);
        this.waiters.delete(wake);
        resolve(true);
      };
      const timer = setTimeout(() => {
        this.waiters.delete(wake);
        resolve(false);
      }, ms);
      this.waiters.add(wake);
    });
  }

  /** The job's events after `after`, as server-sent events: first from the log, then as they
   * happen, with a comment while it's quiet. It ends after `done` or `failed`. Null when there's
   * no such job, or it isn't the watcher's. */
  watch(owner: string, after: number): ReadableStream<Uint8Array> | null {
    const job = this.job;
    if (!job || job.owner !== owner) return null;
    if (job.status === "running" && !this.active) this.heal().catch(() => undefined);
    const encoder = new TextEncoder();
    let cursor = after;
    let cancelled = false;
    // Push: counted while it's open, so a page nobody watches notifies instead.
    let open = true;
    this.watchers += 1;
    const leave = () => {
      if (open) this.watchers -= 1;
      open = false;
    };
    return new ReadableStream<Uint8Array>(
      {
        pull: async (controller) => {
          for (;;) {
            if (cancelled) return;
            const events = this.store.after(cursor);
            if (events.length) {
              let out = "";
              let ended = false;
              for (const event of events) {
                out += `data: ${JSON.stringify(event)}\n\n`;
                cursor = event.seq;
                if (event.type === "done" || event.type === "failed") ended = true;
              }
              controller.enqueue(encoder.encode(out));
              if (ended) {
                leave();
                controller.close();
              }
              return;
            }
            const now = this.job;
            if (!now || finished(now.status)) {
              leave();
              controller.close();
              return;
            }
            if (!(await this.next(this.timing.keepAlive))) {
              if (!cancelled) controller.enqueue(encoder.encode(": keep-alive\n\n"));
              return;
            }
          }
        },
        cancel: () => {
          cancelled = true;
          leave();
        },
      },
      { highWaterMark: 0 },
    );
  }

  /** The answers to the questions the job is waiting on, matched to them by their words. A
   * question with no answer is left to Dream. */
  async answer(owner: string, body: unknown): Promise<{ status: number; body: JSONObject }> {
    const job = this.job;
    if (!job || job.owner !== owner) return { status: 404, body: { error: "There's no page being made with that id." } };
    if (job.status !== "asking" || job.answers || !job.questions) return { status: 409, body: { error: "This page isn't waiting on answers." } };
    const given = isObject(body) && Array.isArray(body.answers) ? body.answers : null;
    if (!given || given.length > 10) return { status: 400, body: { error: "Send { answers: [...] }, one for each question." } };
    const questions = job.questions;
    job.answers = questions.map((question, index) => {
      const match =
        given.find((answer) => isObject(answer) && isObject(answer.question) && answer.question.text === question.text) ??
        (given.length === questions.length ? given[index] : undefined);
      const choice = isObject(match) && typeof match.choice === "string" ? match.choice.trim().slice(0, 300) : "";
      return { question, choice, isRemembered: false };
    });
    this.save(job);
    await this.store.setAlarm(this.now);
    return { status: 200, body: { ok: true } };
  }
}

/** A store kept in memory, for tests and for anything that doesn't need to outlive itself. */
export function memoryStore(clock: () => number = Date.now): JobStore & { alarm: number | null; cleared: boolean } {
  const values = new Map<string, string>();
  let events: ComposeEvent[] = [];
  let seq = 0;
  const store = {
    alarm: null as number | null,
    cleared: false,
    get<T>(key: string): T | undefined {
      const value = values.get(key);
      return value === undefined ? undefined : (JSON.parse(value) as T);
    },
    put(key: string, value: unknown) {
      values.set(key, JSON.stringify(value));
    },
    append(event: EventBody): ComposeEvent {
      const logged = { ...event, seq: ++seq } as ComposeEvent;
      events.push(JSON.parse(JSON.stringify(logged)) as ComposeEvent);
      return logged;
    },
    after(after: number) {
      return events.filter((event) => event.seq > after).map((event) => JSON.parse(JSON.stringify(event)) as ComposeEvent);
    },
    lastSeq: () => seq,
    forget(type: ComposeEvent["type"], before: number) {
      events = events.filter((event) => event.type !== type || event.seq >= before);
    },
    async setAlarm(at: number) {
      store.alarm = Math.max(at, clock());
    },
    async getAlarm() {
      return store.alarm;
    },
    async clear() {
      values.clear();
      events = [];
      store.alarm = null;
      store.cleared = true;
    },
  };
  return store;
}
