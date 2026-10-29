// One page's job, whatever keeps it (job.ts keeps it in a Durable Object): its record, its event
// log, the watchers, the answers, and when the loop runs (docs/ServerGeneration.md).
//
//   start     the request is kept and the loop is set to run at once, on the alarm
//   alarm     the loop runs; questions stop it, and the alarm wakes it again when they're
//             answered or in ten minutes, as if every answer were "You choose"; so does a call
//             to the phone's tools that nobody is there to run, which wakes it when the phone
//             answers or in ten minutes, as if it couldn't be read
//   watch     every event after a seq from the log, then new ones as they happen
//   answer    the user's answers to the questions it's waiting on
//   output    what one of the phone's tools returned, for a call the loop is waiting on
//
// Every event goes into the log with the next seq. A page shown so far is superseded by the next,
// so only the latest stays in the log: a watcher catching up gets the page as it stands, not
// every step of it. A call to one of the phone's tools stays only while it waits, so the phone
// never runs one twice. If the object is restarted mid-page, the alarm runs again and the page
// starts over, keeping only the model Auto picked and any answers. A day after it's done, it's
// forgotten. A page finished, questions asked, or the phone needed while nobody watches is a
// notification (push.ts).
//
// A call to the phone's tools waits a minute while someone watches the page: the app is open,
// and runs it. With nobody watching, the account's iPhones are told, and it waits ten minutes,
// without holding the alarm open: once nothing else is in flight, the loop stops, what it did so
// far is kept (journal.ts), and the alarm ends. The phone's answer, or the call's deadline, wakes
// it, and the loop starts again from the top, going over what it did from the journal, quietly,
// until it's back at the call, which is given the answer, and goes on from there.
//
// test/compose.mjs runs it in Node, with a store kept in memory.

import type { Surface } from "../engine/index";
import { pageReady, phoneNeeded, questionWaiting, type Notice } from "../push";
import type { ComposeEvent, ComposeRequest } from "./contract";
import { Journal } from "./journal";
import { sourceOf, type DeviceAnswer, type Here } from "./live";
import { Cancelled, leftToDream, PageLoop, Paused, TIMING, type LoopServices, type PagePick, type Start, type Timing } from "./loop";
import type { Answer, Question } from "./prompts";
import type { ToolServices } from "./tools";

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
  /** Drops one event: a call to the phone that's no longer waiting. */
  drop(seq: number): void;
  setAlarm(at: number): Promise<void>;
  getAlarm(): Promise<number | null>;
  /** Forgets the job and everything it kept. */
  clear(): Promise<void>;
}

/** `device`: stopped to wait on the phone, with nobody watching (Waiting). */
export type JobStatus = "queued" | "running" | "asking" | "device" | "done" | "failed";

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
  /** Where the request came from, as Cloudflare placed it, for the weather "here". */
  here?: Here | null;
  status: JobStatus;
  /** Starts of the page: more than one only when the object restarted mid-page. */
  attempts: number;
  createdAt: number;
  /** When this attempt began. */
  startedAt: number;
  /** The seq this attempt's log begins at, for the page's generation log. */
  logFrom: number;
  pick: PagePick | null;
  /** The questions waiting on the user: those Dream couldn't answer from what it remembers. */
  questions: Question[] | null;
  /** The answers Dream found in what it remembers, which come first. */
  remembered?: Answer[] | null;
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
  /** How long a call to one of the phone's tools waits for its answer, while someone watches the
   * page, before the model is told it couldn't be read: the app is open, and runs it at once. */
  deviceWait: number;
  /** How long one waits with nobody watching: the iPhone is told, and the app has to be opened. */
  deviceAwayWait: number;
}

export const JOB_TIMING: JobTiming = {
  answerWait: 10 * 60_000,
  runLimit: 14 * 60_000,
  keep: 24 * 3_600_000,
  attempts: 3,
  keepAlive: 15_000,
  deviceWait: 60_000,
  deviceAwayWait: 10 * 60_000,
};

/** Most of what a phone's tool may answer: a connected service's answer is cut to 8,000
 * characters on the phone (ConnectionTool.resultLimit), fenced and explained. */
const MAX_OUTPUT = 40_000;
/** Most of a journal kept while the page waits on the phone, in characters of JSON, inside what
 * a Durable Object keeps in one row. More than that, and the call waits with the alarm held. */
const MAX_JOURNAL = 1_500_000;

const finished = (status: JobStatus) => status === "done" || status === "failed";

/** A call to the phone's tools the page stopped to wait on, kept with the job while it waits. */
interface WaitingCall {
  id: string;
  name: string;
  arguments: string;
  /** Its place among the page's steps (journal.ts), by which the loop finds it again. */
  key: string;
  /** Its event, which leaves the log once it's answered or its time is up. */
  seq: number;
  deadline: number;
  /** What the phone returned; null once its time is up; absent while it waits. */
  answer?: DeviceAnswer | null;
}

/** What the page stopped for: the calls it waits on, and whether it was at its very start. */
interface Waiting {
  calls: WaitingCall[];
  first: boolean;
}

/** A call to the phone's tools waiting in this instance. */
interface Call {
  seq: number;
  key: string;
  name: string;
  arguments: string;
  deadline: number;
  /** Nobody was watching when it began: it waits ten minutes, and the page may stop for it. */
  away: boolean;
  /** What the phone returned, or null when its time is up: the loop goes on with it. */
  answer(answer: DeviceAnswer | null): void;
  /** The page stopped: nothing more waits on it here. */
  drop(): void;
  /** Lets go of it here, leaving it in the log: the page stopped to wait on it (Waiting). */
  release(): void;
}

/** One run of the loop in this instance. */
interface Running {
  job: JobRecord;
  request: ComposeRequest;
  limit: AbortController;
  journal: Journal;
  first: boolean;
  /** The calls the page stopped for last time, when this run picks up from there: each `reached`
   * once the loop calls it again, and held (`release`) until it's all the loop waits on. */
  resumed: (WaitingCall & { reached?: boolean; release?: () => void })[] | null;
  /** Stopped to wait on the phone: nothing more it says goes out. */
  paused: boolean;
}

/** When a page waiting on the phone goes on: at once when every call is answered or out of
 * time, otherwise at the soonest deadline still to come. */
function wakeAt(waiting: Waiting | null | undefined, now: number): number {
  const open = (waiting?.calls ?? []).filter((call) => call.answer === undefined && call.deadline > now);
  return open.length ? Math.min(...open.map((call) => call.deadline)) : now;
}

/** A wait in words, for the log. */
function span(ms: number): string {
  if (ms < 60_000) return `${Math.round(ms / 100) / 10} seconds`;
  const minutes = Math.round(ms / 60_000);
  return minutes === 1 ? "a minute" : `${minutes} minutes`;
}

/** The tools' services, with what they gave kept in the journal, and given again when the page
 * goes over it after waiting on the phone: search and read, so nothing is paid for twice, and
 * Wikipedia and what Dream remembers, so the page reads as it did. A live reading is read again,
 * whole while it's counted in flight; what the model was told of it is kept with its call
 * (loop.ts, runTool). Everything else the services carry, like where the user is, goes as it is. */
export function remembered(tools: ToolServices, journal: Journal): ToolServices {
  return {
    ...tools,
    lookup: (subject, language) => journal.remember("lookup", [subject, language], () => tools.lookup(subject, language)),
    related: (title, language) => journal.remember("related", [title, language], () => tools.related(title, language)),
    search: (query) => journal.remember("search", query, () => tools.search(query)),
    read: (query) => journal.remember("read", query, () => tools.read(query)),
    memory: () => journal.remember("memory", null, () => tools.memory()),
    fetch: (url, init) =>
      journal.working(async () => {
        const response = await tools.fetch(url, init);
        const empty = [101, 204, 205, 304].includes(response.status);
        const body = empty ? null : await response.arrayBuffer();
        return new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers });
      }),
  };
}

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
  /** Calls to the phone's tools waiting on their answers, by their id. */
  private readonly calls = new Map<string, Call>();
  /** The loop's run in this instance, while there is one. */
  private current: Running | null = null;
  /** A look, once what's in flight has settled, at whether the page waits on the phone alone. */
  private pausing: ReturnType<typeof setTimeout> | null = null;

  constructor(store: JobStore, services: JobServices, timing: Partial<JobTiming> = JOB_TIMING, loopTiming: Timing = TIMING) {
    this.store = store;
    this.services = services;
    this.timing = { ...JOB_TIMING, ...timing };
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
  async start(fields: Pick<JobRecord, "id" | "owner" | "counted" | "origin"> & { here?: Here | null }, request: ComposeRequest): Promise<void> {
    if (this.job) return;
    const now = this.now;
    this.store.put("request", request);
    this.save({ ...fields, pageID: request.pageID, status: "queued", attempts: 0, createdAt: now, startedAt: now, logFrom: 1, pick: null, questions: null, remembered: null, checkedAt: null, deadline: null, answers: null, finishedAt: null });
    await this.store.setAlarm(now);
  }

  /** A change to a page the user has, rather than a new page or one made again. */
  private static changes(request: ComposeRequest): boolean {
    return !!request.editing && !request.editing.again;
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
    let waiting: Waiting | null = null;
    if (job.status === "device") {
      waiting = this.store.get<Waiting>("waiting") ?? null;
      const at = wakeAt(waiting, this.now);
      if (at > this.now) {
        await this.store.setAlarm(at);
        return;
      }
      // Those the phone didn't answer in time: the model is told they couldn't be read.
      for (const call of waiting?.calls ?? []) {
        if (call.answer !== undefined) continue;
        call.answer = null;
        this.store.drop(call.seq);
      }
      if (waiting) this.store.put("waiting", waiting);
      start = { pick: job.pick, answers: job.answers, checkedAt: job.checkedAt, startedAt: job.startedAt, first: waiting?.first ?? false };
    } else if (job.status === "asking") {
      if (!job.answers) {
        if (job.deadline !== null && this.now < job.deadline) {
          await this.store.setAlarm(job.deadline);
          return;
        }
        // Nobody answered: every question is left to Dream, so building never waits on a screen that's gone.
        job.answers = [...(job.remembered ?? []), ...(job.questions ?? []).map(leftToDream)];
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
        // Nothing waits on the phone for the run that stopped, and nothing it kept carries over.
        this.store.forget("deviceTool", this.store.lastSeq() + 1);
        this.store.put("waiting", null);
        this.store.put("journal", null);
      } else {
        job.logFrom = this.store.lastSeq() + 1;
      }
      job.attempts += 1;
      job.startedAt = this.now;
      // A change isn't a page asked for, as on the phone.
      if (job.attempts === 1 && !Runner.changes(request)) this.services.analytics(job, "page_requested", { with_photo: !!request.image });
      start = { pick: job.pick, answers: job.answers, checkedAt: null, startedAt: job.startedAt, first: true };
    }
    job.status = "running";
    this.save(job);
    await this.run(job, request, start, waiting);
  }

  /** Runs the loop: from what it did before, when `waiting` says what it stopped for. */
  private async run(job: JobRecord, request: ComposeRequest, start: Start, waiting: Waiting | null = null): Promise<void> {
    this.active = true;
    const limit = new AbortController();
    const timer = setTimeout(() => limit.abort(new Cancelled("This page took too long to make. Try again.")), this.timing.runLimit);
    const journal = new Journal(waiting ? (this.store.get<[string, unknown][]>("journal") ?? []) : [], !!waiting);
    const running: Running = { job, request, limit, journal, first: start.first, resumed: waiting?.calls.map((call) => ({ ...call })) ?? null, paused: false };
    this.current = running;
    journal.onIdle = () => this.pauseSoon();
    // Going over what it did before, or stopped for the phone: it was said already, or it isn't so.
    const quiet = () => journal.replaying || running.paused;
    try {
      const given = this.services.loop(job, request);
      const services: LoopServices = { ...given, tools: remembered(given.tools, journal), device: (call, signal) => this.ask(call, signal), journal };
      const loop = new PageLoop(
        request,
        services,
        {
          phase: (phase) => {
            if (!quiet()) this.emit({ type: "phase", phase });
          },
          trace: (kind, text) => {
            if (!quiet()) this.emit({ type: "trace", kind, text });
          },
          surface: (surface) => {
            if (!quiet()) this.emit({ type: "surface", surface });
          },
          log: (line) => {
            if (!quiet()) this.emit({ type: "log", line });
          },
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
        case "paused": {
          // The alarm ends here: the phone's answer, or the soonest deadline, wakes it.
          job.status = "device";
          this.save(job);
          await this.store.setAlarm(wakeAt(this.store.get<Waiting>("waiting"), this.now));
          return;
        }
        case "asking": {
          job.status = "asking";
          job.questions = outcome.questions;
          job.remembered = outcome.remembered;
          job.checkedAt = outcome.checkedAt;
          job.answers = null;
          job.deadline = this.now + this.timing.answerWait;
          this.save(job);
          this.emit({ type: "asking", questions: outcome.questions });
          // Push: nobody is there to answer, so the account's iPhones are told.
          // Sent whether or not a line is open: the phone hides it while it shows the page
          // (Notifications.presents), and a line left open by a phone in the background once
          // swallowed every notification.
          this.services.notify?.(job, questionWaiting(job, request.request, this.now));
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
          // Sent whether or not a line is open, as questions are.
          this.services.notify?.(job, pageReady(job, request.request, outcome.surface, this.now));
          // As Composer.countFinished counts a page or a change.
          if (Runner.changes(request)) this.services.analytics(job, "page_changed", { ...pageShape(outcome.surface), pointed_at_block: !!request.editing?.focus, seconds: seconds(this.now - job.startedAt) });
          else this.services.analytics(job, "page_built", { ...pageShape(outcome.surface), model: outcome.model, seconds: seconds(this.now - job.startedAt) });
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
      if (this.pausing !== null) clearTimeout(this.pausing);
      this.pausing = null;
      this.active = false;
      this.current = null;
      // Nothing waits on the phone once the loop is over.
      for (const call of [...this.calls.values()]) call.drop();
      // What it kept to pick up from only lasts while it waits on the phone.
      if (!running.paused) {
        this.store.put("waiting", null);
        this.store.put("journal", null);
      }
    }
  }

  private fail(job: JobRecord, message: string, reason: string): void {
    job.status = "failed";
    job.finishedAt = this.now;
    this.save(job);
    this.emit({ type: "failed", message });
    const request = this.store.get<ComposeRequest>("request");
    this.services.analytics(job, "page_failed", { reason, changing: !!request && Runner.changes(request), seconds: seconds(this.now - job.startedAt) });
    this.store.setAlarm(job.finishedAt + this.timing.keep).catch(() => undefined);
  }

  // MARK: The phone's tools

  /** Asks the phone to run one of its tools: a `deviceTool` event, and the answer it posts, or
   * null when none comes by its deadline or the page stops. It waits `deviceWait` while someone
   * watches the page; with nobody watching, the account's iPhones are told, and it waits
   * `deviceAwayWait`, for which the page stops (`pause`). Once it's answered or given up on, the
   * call leaves the log, so a watcher catching up never runs it.
   *
   * Going over what it did before it stopped, a call answered then is answered the same way, and
   * the one it stopped for is given what the phone returned meanwhile, or null, once the loop is
   * back where it stopped: waiting on it alone, with everything it did before gone over, like a
   * gap check that decided beside it (`pause`). */
  private ask(call: { name: string; arguments: string }, signal: AbortSignal): Promise<DeviceAnswer | null> {
    const running = this.current;
    if (!running) return Promise.resolve(null);
    const { journal } = running;
    const step = journal.step<DeviceAnswer | null>("device", [call.name, call.arguments], { fresh: false });
    if (step.kept !== undefined) return Promise.resolve(step.kept);
    const resumed = running.resumed?.find((waited) => waited.key === step.key && !waited.reached);
    if (resumed) {
      resumed.reached = true;
      const answer = resumed.answer ?? null;
      journal.keep(step.key, answer);
      if (!journal.replaying) return Promise.resolve(answer);
      return new Promise((resolve) => {
        resumed.release = () => resolve(answer);
        this.pauseSoon();
      });
    }
    journal.replaying = false;
    if (signal.aborted) return Promise.resolve(null);
    const id = crypto.randomUUID();
    const away = this.watchers === 0;
    const wait = away ? this.timing.deviceAwayWait : this.timing.deviceWait;
    const deadline = this.now + wait;
    return new Promise((resolve) => {
      let timer: ReturnType<typeof setTimeout> | null = null;
      const finish = (answer: DeviceAnswer | null, leave: boolean) => {
        const waiting = this.calls.get(id);
        if (!waiting) return;
        this.calls.delete(id);
        if (timer !== null) clearTimeout(timer);
        signal.removeEventListener("abort", stop);
        if (leave) this.store.drop(waiting.seq);
        resolve(answer);
        // What's left may be calls the page could stop for.
        this.pauseSoon();
      };
      const stop = () => finish(null, true);
      // Push: nobody is there to run it, so the account's iPhones are told, once for the calls
      // the page stops for together.
      const told = [...this.calls.values()].some((other) => other.away);
      if (away && !told) {
        const tool = running.request.deviceTools?.find((tool) => tool.name === call.name) ?? { name: call.name };
        this.services.notify?.(running.job, phoneNeeded(running.job, running.request.request, tool, deadline));
        this.emit({ type: "log", line: `Nobody has this page open, so Dream sent a notification and waits up to ${span(wait)} for the phone to run ${call.name}.` });
      }
      const { seq } = this.emit({ type: "deviceTool", call: { id, name: call.name, arguments: call.arguments }, deadline });
      this.calls.set(id, {
        seq,
        key: step.key,
        name: call.name,
        arguments: call.arguments,
        deadline,
        away,
        answer: (answer) => {
          journal.keep(step.key, answer);
          finish(answer, true);
        },
        drop: () => finish(null, true),
        release: () => finish(null, false),
      });
      timer = setTimeout(() => this.calls.get(id)?.answer(null), wait);
      signal.addEventListener("abort", stop, { once: true });
      if (away) this.pauseSoon();
    });
  }

  /** Has a look at whether the page waits on the phone alone, once what's in flight now has had a
   * moment to settle: going over what it did, all of it is in hand at once, so by then it's back
   * where it stopped. */
  private pauseSoon(): void {
    if (this.pausing !== null || !this.current || this.current.paused) return;
    this.pausing = setTimeout(() => {
      this.pausing = null;
      this.pause();
    }, 0);
  }

  /** Stops the page when all it waits on is the phone, with nobody watching: what it did so far
   * is kept, the calls stay in the log, and the alarm ends (`run`). Nothing else may be in
   * flight, so the journal holds everything up to the calls, and a gap check still deciding
   * decides first.
   *
   * Picking up again, it's where the calls it stopped for are answered: the loop is back at
   * them, with nothing else to go over, so from here what it says is new. One that went another
   * way meanwhile (something it hadn't done before) has them answered at once. */
  private pause(): void {
    const running = this.current;
    if (!running || running.paused || !running.journal.idle) return;
    const held = running.resumed?.filter((call) => call.release) ?? [];
    if (held.length && (!running.journal.replaying || running.resumed!.every((call) => call.reached))) {
      running.journal.replaying = false;
      for (const call of held) {
        const release = call.release!;
        call.release = undefined;
        release();
      }
      return;
    }
    const waiting = [...this.calls.entries()];
    if (!waiting.length || !waiting.every(([, call]) => call.away)) return;
    const entries = running.journal.entries();
    // Too much to keep in one row: the calls wait here, holding the alarm, as they always may.
    if (JSON.stringify(entries).length > MAX_JOURNAL) return;
    this.store.put("journal", entries);
    const kept: Waiting = { calls: waiting.map(([id, call]) => ({ id, name: call.name, arguments: call.arguments, key: call.key, seq: call.seq, deadline: call.deadline })), first: running.first };
    this.store.put("waiting", kept);
    running.paused = true;
    // Let go of here before the loop stops, so stopping doesn't take them out of the log.
    for (const [, call] of waiting) call.release();
    running.limit.abort(new Paused());
  }

  /** What one of the phone's tools returned, for a call the page is waiting on: here, or kept
   * while the page stopped for it, which wakes it once every call it stopped for is answered. */
  async output(owner: string, body: unknown): Promise<{ status: number; body: JSONObject }> {
    const job = this.job;
    if (!job || job.owner !== owner) return { status: 404, body: { error: "There's no page being made with that id." } };
    if (!isObject(body) || typeof body.id !== "string" || typeof body.output !== "string") return { status: 400, body: { error: "Send { id, output }: the call's id, and what the tool returned." } };
    const call = this.calls.get(body.id);
    const waiting = call ? null : this.store.get<Waiting>("waiting");
    const kept = waiting?.calls.find((each) => each.id === body.id && each.answer === undefined && each.deadline > this.now);
    if (!call && !kept) return { status: 409, body: { error: "This page isn't waiting on that call." } };
    const source = body.source === undefined || body.source === null ? null : sourceOf(body.source);
    if (body.source !== undefined && body.source !== null && !source) return { status: 400, body: { error: "source is a live source, as the app's Source encodes it." } };
    const service = typeof body.service === "string" && body.service.trim() ? body.service.trim().slice(0, 100) : undefined;
    const output = [...body.output].length > MAX_OUTPUT ? `${[...body.output].slice(0, MAX_OUTPUT).join("")}\n[Cut off here.]` : body.output;
    const answer: DeviceAnswer = { output, ...(source ? { source } : {}), ...(service ? { service } : {}) };
    if (call) {
      call.answer(answer);
      return { status: 200, body: { ok: true } };
    }
    kept!.answer = answer;
    this.store.drop(kept!.seq);
    this.store.put("waiting", waiting);
    if (wakeAt(waiting, this.now) <= this.now) await this.store.setAlarm(this.now);
    return { status: 200, body: { ok: true } };
  }

  /** A page that was being made when this instance began, or waits on the phone, with no alarm
   * to start it again: one is set, so a watcher never waits on a page nothing is making. */
  private async heal(): Promise<void> {
    const status = this.job?.status;
    if ((await this.store.getAlarm()) === null && (status === "running" || status === "device") && !this.active) await this.store.setAlarm(this.now);
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
    if ((job.status === "running" || job.status === "device") && !this.active) this.heal().catch(() => undefined);
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
    // What Dream remembered first, then the user's, as Asking keeps them.
    job.answers = [
      ...(job.remembered ?? []),
      ...questions.map((question, index) => {
        const match =
          given.find((answer) => isObject(answer) && isObject(answer.question) && answer.question.text === question.text) ??
          (given.length === questions.length ? given[index] : undefined);
        const choice = isObject(match) && typeof match.choice === "string" ? match.choice.trim().slice(0, 300) : "";
        return { question, choice, isRemembered: false };
      }),
    ];
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
    drop(seq: number) {
      events = events.filter((event) => event.seq !== seq);
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
