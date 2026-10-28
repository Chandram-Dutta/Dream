// The page loop on the server, ported from Dream/Generation/Composer.swift and GapCheck.swift
// (docs/ServerGeneration.md): Auto picks the model once, a quick check looks for what only the
// user can tell while the page starts to stream out of sight, the page is written with lookup,
// search and read, the checker fixes what it can and sends real mistakes back for repair, and
// what's finished is checked once more. Everything it does is an event: the phase, each step of
// the work as it starts, the page so far, the log.
//
// Where the app waits on the user's answers, the loop stops instead and says what it would ask
// (`asking`); the job (runner.ts) starts it again with the answers, so a page never holds the
// object for the ten minutes it may wait. Memory recall, live data, connected services,
// recordings and molecules are Stage 2.
//
// test/compose.mjs runs it in Node, with a fake model and a fake engine.

import type * as EngineModule from "../engine/index";
import type { Surface, Issue, Reference } from "../engine/index";
import type { ComposePhase, ComposeRequest } from "./contract";
import { Activity, ask, Changes, ModelProblem, readRound, requestBody, RETRY_DELAYS, Transcript, userContent, type Message, type RequestOptions, type Round } from "./chat";
import { partialObject } from "./partial";
import { answersContext, gapRequest, repairPrompt, surfaceInstructions, surfaceRequest, type Answer, type Generation, type Question } from "./prompts";
import { ReferenceLog, toolBox, WebLog, type ToolBox, type ToolServices } from "./tools";
import { languageOf } from "./lookup";

type JSONObject = Record<string, unknown>;
type Engine = typeof EngineModule;

const isObject = (value: unknown): value is JSONObject => value !== null && typeof value === "object" && !Array.isArray(value);

/** Auto's pick for a page (route.ts), as the app's Route.Pick. */
export interface PagePick {
  model: string;
  effort: string;
  name: string;
  category: string;
  difficulty: string;
  why: string;
}

export interface LoopServices {
  engine: Engine;
  generation: Generation;
  /** The model, in-process (model.ts): a chat completions request, answered as /api/model would. */
  model(body: JSONObject, signal: AbortSignal): Promise<Response>;
  /** Auto's pick for the page: asked once, at its start. */
  route(request: string, image: string | undefined): Promise<PagePick>;
  tools: ToolServices;
  now(): number;
  sleep(ms: number, signal: AbortSignal): Promise<void>;
}

export interface LoopEvents {
  phase(phase: ComposePhase): void;
  trace(kind: "search" | "read" | "lookup", text: string): void;
  /** The page so far, at most once every `surfaceEvery`. */
  surface(surface: Surface): void;
  log(line: string): void;
  /** Auto picked the page's model, which every later start keeps. */
  picked(pick: PagePick): void;
}

/** How long things may take, as the app has them. Tests shorten them. */
export interface Timing {
  /** Silence, heartbeats included, before a generation counts as stalled. */
  patience: number;
  /** Time without the model doing anything but keeping the line open. */
  ceiling: number;
  /** How often the watchdog looks. */
  watch: number;
  /** The gap check, past which it's dropped (GapCheck.patience). */
  gapPatience: number;
  /** How long the page may stream out of sight while the check decides (GapCheck.hold). */
  hold: number;
  /** The least time between two `surface` events: at most five a second. */
  surfaceEvery: number;
  /** How often the page so far is read and shown while it streams (Composer's Pace, 0.15 s):
   * reading it whole on every token is the costly part. */
  partialEvery: number;
  /** How often the runaway check looks at it (0.25 s). */
  runawayEvery: number;
  /** Waits before asking a busy model again (DreamExecutor.retryDelays). */
  retries: number[];
  /** Rounds of tool calls in one generation before it's given up as going in circles. */
  toolRounds: number;
}

export const TIMING: Timing = {
  patience: 45_000,
  ceiling: 150_000,
  watch: 500,
  gapPatience: 25_000,
  hold: 6_000,
  surfaceEvery: 200,
  partialEvery: 150,
  runawayEvery: 250,
  retries: RETRY_DELAYS,
  toolRounds: 12,
};

/** Where a page stands as the loop starts on it. */
export interface Start {
  /** Auto's pick, if it was made already; asked otherwise (when the page is on Auto). */
  pick: PagePick | null;
  /** The answers to the gap check's questions, when it asked already. */
  answers: Answer[] | null;
  /** When the gap check began, which the answers' line counts from. */
  checkedAt: number | null;
  /** When the page began, which "Done in" counts from. */
  startedAt: number;
  /** The very start of the page, or a restart: the request and the model go in the log. Not when
   * it carries on after questions. */
  first: boolean;
}

export type Outcome =
  | { kind: "done"; surface: Surface; model: string }
  | { kind: "asking"; questions: Question[]; checkedAt: number }
  | { kind: "failed"; message: string; reason: "empty" | "other" };

// MARK: - Errors

/** Something the loop says went wrong, in words for the user (ComposeError). */
export class ComposeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ComposeError";
  }
}

/** The page was stopped from outside: its time ran out, or it gave way to questions. */
export class Cancelled extends Error {
  constructor(message = "Stopped.") {
    super(message);
    this.name = "Cancelled";
  }
}

type StopReason = "stalled" | "repeating" | "cutOff";

/** The model stopped before finishing, with what it had written by then. */
class Unfinished extends Error {
  readonly partial: JSONObject;
  readonly reason: StopReason;

  constructor(partial: JSONObject, reason: StopReason) {
    super("The model stopped before finishing.");
    this.partial = partial;
    this.reason = reason;
  }
}

/** The model answered with a screen that has nothing in it, not even a title. */
class EmptyScreen extends Error {
  constructor() {
    super("The model wrote an empty screen.");
  }
}

/** A whole answer that isn't the JSON object it was asked for (GeneratedContent.ParsingError). */
class ParsingError extends Error {
  constructor() {
    super("The model's answer wasn't what was asked for.");
  }
}

/** Whether writing the screen again might work where this failed: the model looped, padded or
 * broke its answer with nothing worth keeping, or left it empty. */
const worthAnotherTry = (error: unknown) => error instanceof Unfinished || error instanceof EmptyScreen || error instanceof ParsingError;

/** An error in words for the log and the user. Anything unexpected says nothing of itself. */
export function describe(error: unknown): string {
  if (error instanceof ModelProblem || error instanceof ComposeError || error instanceof Cancelled || error instanceof Unfinished || error instanceof EmptyScreen || error instanceof ParsingError) return error.message;
  return "Something went wrong. Try again in a moment.";
}

// MARK: - Helpers

const elapsed = (from: number, now: number) => `${((now - from) / 1000).toFixed(1)}s`;

/** An object, when the whole text is one. */
function wholeObject(text: string): JSONObject | null {
  try {
    const value: unknown = JSON.parse(text);
    return isObject(value) ? value : null;
  } catch {
    return null;
  }
}

/** A signal that stops when `parent` does, or when it's told to itself. */
function linked(parent: AbortSignal): AbortController {
  const controller = new AbortController();
  if (parent.aborted) controller.abort(parent.reason);
  else parent.addEventListener("abort", () => controller.abort(parent.reason), { once: true });
  return controller;
}

/** The work's result, or the signal's reason as soon as it stops. */
function abortable<T>(work: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(signal.reason);
  return new Promise<T>((resolve, reject) => {
    const stop = () => reject(signal.reason);
    signal.addEventListener("abort", stop, { once: true });
    work.then(
      (value) => {
        signal.removeEventListener("abort", stop);
        resolve(value);
      },
      (error) => {
        signal.removeEventListener("abort", stop);
        reject(error);
      },
    );
  });
}

const list = (value: unknown): unknown[] => (Array.isArray(value) ? value : []);

/** Question.init?(wire): what the model wrote, tidied. Options it shouldn't have offered go, and
 * a question left with too few to tap takes a typed answer instead. */
export function questionFrom(wire: unknown): Question | null {
  if (!isObject(wire)) return null;
  const text = typeof wire.question === "string" ? wire.question.trim() : "";
  if (!text) return null;
  const seen = new Set<string>();
  const youChoose = new Set(["youchoose", "youdecide", "surpriseme", "dontmind", "anything", "either"]);
  const options = list(wire.options)
    .map((option) => (typeof option === "string" ? option.trim() : ""))
    .filter((option) => {
      if (!option || youChoose.has(option.toLowerCase().replace(/[^\p{L}]/gu, ""))) return false;
      const key = option.toLowerCase();
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  const topic = typeof wire.topic === "string" ? wire.topic.trim() : "";
  return { text, topic: topic || text, options: options.slice(0, 4), allowsTyping: wire.typing === true || options.length < 2, isPersonal: wire.personal === true };
}

/** Every question left to Dream: "You choose". */
export const leftToDream = (question: Question): Answer => ({ question, choice: "", isRemembered: false });

/** The same surface, carrying the answers it was built from (Surface.answered). */
function answered(surface: Surface, answers: Answer[]): Surface {
  const out: Surface = { ...surface };
  if (answers.length) out.answers = answers;
  else delete out.answers;
  return out;
}

/** A language's name in English, for the log (Languages.name). */
function languageName(code: string): string {
  try {
    return new Intl.DisplayNames(["en"], { type: "language" }).of(code) ?? code;
  } catch {
    return code;
  }
}

/** One session of writing a page: its transcript, its tools, and what it read. */
interface Session {
  transcript: Transcript;
  tools: ToolBox | null;
  web: WebLog;
}

// MARK: - The loop

export class PageLoop {
  private readonly request: ComposeRequest;
  private readonly services: LoopServices;
  private readonly events: LoopEvents;
  private readonly timing: Timing;
  private readonly signal: AbortSignal;
  private readonly engine: Engine;
  private readonly generation: Generation;
  private readonly activity: Activity;
  private phase: ComposePhase | null = null;
  /** The page as it stands on screen, including while it streams in. */
  private surface: Surface | null = null;
  private answers: Answer[] = [];
  private pick: PagePick | null = null;
  private modelName = "";
  /** While the gap check decides, the page streams in out of sight for a few seconds, so it
   * rarely appears only to give way to questions. */
  private isChecking = false;
  private held: Surface | null = null;
  private holdUntil = 0;
  /** The writing gave way to questions: nothing more of it shows. */
  private quiet = false;
  private pending: Surface | null = null;
  private lastSurfaceAt = -Infinity;
  private surfaceTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(request: ComposeRequest, services: LoopServices, events: LoopEvents, signal: AbortSignal, timing: Timing = TIMING) {
    this.request = request;
    this.services = services;
    this.events = events;
    this.timing = timing;
    this.signal = signal;
    this.engine = services.engine;
    this.generation = services.generation;
    this.activity = new Activity(services.now());
  }

  private get now(): number {
    return this.services.now();
  }

  private get onAuto(): boolean {
    return !this.request.model || this.request.model === "auto";
  }

  /** The user's own thinking level, which sizes an answer's thinking room. */
  private get thinking(): string {
    return this.request.thinking ?? "low";
  }

  /** Makes the page, or says what to ask first, or why it couldn't. */
  async run(start: Start): Promise<Outcome> {
    try {
      const image = this.request.image;
      if (start.first) this.note(`Request: ${this.request.request}${image ? " (with photo)" : ""}`);
      // Auto (route.ts): the model and thinking for this page, picked once, up front.
      this.pick = start.pick;
      if (this.onAuto && !this.pick) await this.route();
      this.modelName = this.pick ? `Auto → ${this.pick.name} · ${this.pick.effort}` : `Dream (${this.request.model || "default"})`;
      if (start.first) this.note(`Model: ${this.modelName}`);
      if (start.answers && start.checkedAt !== null && !start.first) {
        this.note(`Answered: ${start.answers.map((answer) => (!answer.choice ? "You choose" : answer.isRemembered ? `${answer.choice} (remembered)` : answer.choice)).join("; ")} after ${elapsed(start.checkedAt, this.now)}`);
      }
      const asking = await this.writeRequest(start.answers ?? []);
      if (asking) return { kind: "asking", ...asking };
      const surface = this.surface;
      if (!surface || this.engine.isEmpty(surface)) throw new ComposeError("Nothing came out of this. Try asking another way.");
      const done = this.recordLocale(surface);
      this.note(`Done in ${elapsed(start.startedAt, this.now)}`);
      return { kind: "done", surface: done, model: this.modelName };
    } catch (error) {
      const stopped = this.signal.aborted ? this.signal.reason : error;
      const message = describe(stopped);
      if (!(stopped instanceof Cancelled) && describe(stopped) === describe(null)) console.error("Page failed", stopped instanceof Error ? stopped.name : typeof stopped);
      this.note(`Failed: ${message}`);
      return { kind: "failed", message, reason: stopped instanceof ComposeError ? "empty" : "other" };
    } finally {
      this.dispose();
    }
  }

  private async route(): Promise<void> {
    const started = this.now;
    const image = this.request.image ? `data:image/jpeg;base64,${this.request.image}` : undefined;
    const pick = await abortable(this.services.route(this.request.request.slice(0, 4_000), image), this.signal);
    this.pick = pick;
    this.events.picked(pick);
    this.note(`Auto → ${pick.name} · ${pick.effort} (${pick.category}, ${pick.difficulty}: ${pick.why}; ${elapsed(started, this.now)})`);
  }

  // MARK: Asking

  /** Writes the page for the request while a quick check, in its own session, looks for what the
   * request leaves out that only the user can tell. If it finds nothing, the writing carries on
   * untouched. If it has questions, the writing stops and they're returned, to ask. */
  private async writeRequest(answers: Answer[]): Promise<{ questions: Question[]; checkedAt: number } | null> {
    const context = this.request.context ?? [];
    const image = this.request.image;
    const asked = (given: Answer[]) => surfaceRequest(this.generation, this.request.request, !!image, [...context, ...answersContext(this.generation, given)]);
    const prompt = (given: Answer[]) => userContent(asked(given), image);
    this.answers = answers;
    // A photo usually settles what it's about; and once asked, the answers are in.
    if (image || answers.length) {
      await this.write(prompt(answers), asked(answers), null, true, this.signal);
      return null;
    }
    const started = this.now;
    this.isChecking = true;
    this.held = null;
    this.holdUntil = started + this.timing.hold;
    const writing = linked(this.signal);
    const checking = this.gaps(this.request.request);
    const written = this.write(prompt([]), asked([]), null, true, writing.signal);
    written.catch(() => undefined);
    try {
      const gaps = await checking;
      if (this.signal.aborted) throw this.signal.reason;
      if (!gaps.questions.length) {
        this.note(`Check: nothing to ask (${gaps.seconds.toFixed(1)}s${this.held === null ? "" : ", while the page was held back"})`);
        this.isChecking = false;
        if (this.surface === null && this.held) this.display(this.held);
        await written;
        return null;
      }
      writing.abort(new Cancelled("The page gave way to questions."));
      this.quiet = true;
      const where = this.surface !== null ? "after it showed" : this.held !== null ? "before it showed" : "before it began";
      this.note(
        `Check: ${gaps.questions.length} to ask after ${gaps.seconds.toFixed(1)}s, so the screen stopped ${where}: ` +
          gaps.questions.map((question) => `${question.text} (${question.options.join(" / ")}${question.allowsTyping ? ", or typed" : ""})`).join("; "),
      );
      await written.catch(() => undefined);
      return { questions: gaps.questions, checkedAt: started };
    } finally {
      this.isChecking = false;
      this.held = null;
    }
  }

  /** The gap check, on the model this page runs on. If it fails, nothing is asked. */
  private async gaps(intent: string): Promise<{ questions: Question[]; seconds: number }> {
    const started = this.now;
    const limit = linked(this.signal);
    const timer = setTimeout(() => limit.abort(new ComposeError("The check took too long.")), this.timing.gapPatience);
    try {
      const transcript = new Transcript(this.generation.prompts.gapCheck);
      const round = await this.respond({ transcript, tools: null, web: new WebLog() }, gapRequest(this.generation, intent), { schema: this.generation.schemas.gaps, temperature: 0.2, maximumResponseTokens: 600 }, () => undefined, () => undefined, limit.signal);
      const wire = wholeObject(round.text);
      if (!wire) throw new ParsingError();
      const questions = list(wire.questions).slice(0, 3).map(questionFrom).filter((question): question is Question => question !== null);
      return { questions, seconds: (this.now - started) / 1000 };
    } catch (error) {
      if (!this.signal.aborted) this.note(`Check failed after ${elapsed(started, this.now)} (${describe(limit.signal.aborted ? limit.signal.reason : error)}); building without asking.`);
      return { questions: [], seconds: (this.now - started) / 1000 };
    } finally {
      clearTimeout(timer);
    }
  }

  // MARK: Writing

  private session(found: ReferenceLog): Session {
    const web = new WebLog();
    const tools = toolBox(
      this.generation,
      this.services.tools,
      {
        trace: (kind, text) => this.events.trace(kind, text),
        use: (line) => this.researching(line),
      },
      found,
      web,
      this.request.locale.language,
    );
    return { transcript: new Transcript(surfaceInstructions(this.generation, this.request.locale.currency)), tools, web };
  }

  /** Writes a whole surface, then has the checker fix what it can and sends real mistakes back
   * in the same session, so the model sees what it wrote. `asked` is the prompt's text, for a
   * repair to repeat when the session no longer holds it. */
  private async write(prompt: unknown, asked: string, fallback: Reference | null, streaming: boolean, signal: AbortSignal): Promise<void> {
    this.setPhase("composing");
    const found = new ReferenceLog();
    let session = this.session(found);
    let surface: Surface;
    try {
      surface = await this.generateSurface(session, "Surface", prompt, found, fallback, streaming, signal);
      // A title and a sentence with nothing under them is as empty as nothing at all: a cheap
      // model once answered a whole EV comparison with just that.
      if (!surface.blocks.length && !this.engine.hasLogic(surface)) throw new EmptyScreen();
    } catch (error) {
      if (!worthAnotherTry(error) || signal.aborted) throw error;
      // Nothing usable came out. Another go in a new session usually works, and costs less than
      // a page that fails.
      this.note(`Writing again in a new session, after: ${describe(error)}`);
      session = this.session(found);
      surface = await this.generateSurface(session, "Surface", prompt, found, fallback, streaming, signal);
    }
    for (let round = 0; round <= 2; round++) {
      const checked = this.engine.checkLogic(surface);
      surface = checked.surface;
      let issues = checked.issues;
      // Once: a page about the world that looked nothing up goes back to look it up.
      if (round === 0) issues = issues.concat(this.engine.checkSourcing(surface, session.web.reading(found.all)));
      this.report(issues);
      const problems = issues.filter((issue) => issue.kind === "needsModel");
      if (!problems.length || round === 2) break;
      this.setPhase("fixing");
      // A screen that stopped early left the session without the request or the screen, so the
      // repair repeats both.
      const messages = problems.map((problem) => problem.message);
      const repair = session.transcript.endsWithAnswer
        ? repairPrompt(this.generation, messages)
        : repairPrompt(this.generation, messages, { asked, outline: this.engine.outline(surface), logic: this.engine.hasLogic(surface) ? this.engine.logicSummary(surface) : null });
      try {
        surface = await this.generateSurface(session, `Repair ${round + 1}`, repair, found, fallback, false, signal);
      } catch (error) {
        if (signal.aborted) throw signal.reason;
        // A repair that fails leaves the page as it was, which beats no page.
        this.note(`Kept the screen as it was: repair ${round + 1} didn't finish (${describe(error)}).`);
        break;
      }
    }
    const reading = session.web.reading(found.all);
    const cited = this.engine.checkCitations(surface, reading);
    this.report(cited.issues);
    const blocks = this.engine.checkBlocks(cited.surface);
    this.report(blocks.issues);
    surface = answered(blocks.surface, this.answers);
    if (signal.aborted) throw signal.reason;
    this.surface = surface;
    this.queueSurface(surface);
    this.note(this.engine.outline(surface));
  }

  /** A whole surface from one request, keeping the finished blocks if the model stops early. A
   * repair is one too, and keeps what it finished the same way. */
  private async generateSurface(session: Session, step: string, prompt: unknown, found: ReferenceLog, fallback: Reference | null, streaming: boolean, signal: AbortSignal): Promise<Surface> {
    const reference = () => found.first ?? fallback;
    const onPartial = streaming ? (partial: JSONObject) => this.show(answered(this.engine.surfaceFromPartial(partial, reference()), this.answers)) : null;
    try {
      const wire = await this.generate(session, step, prompt, onPartial, (partial) => this.engine.isRepeatingItself(this.engine.surfaceFromPartial(partial, null)), signal);
      const surface = this.engine.surfaceFromWire(wire, reference());
      // The whole answer at once, not the last update before it, while the checks run.
      if (streaming) this.show(answered(surface, this.answers));
      return surface;
    } catch (error) {
      if (!(error instanceof Unfinished)) throw error;
      const kept = await this.salvaged(this.engine.surfaceFromPartial(error.partial, reference()), error.reason, "related" in error.partial);
      // Finished blocks are worth keeping, and so is a calculation with none, if it has results:
      // the checker gives it its controls and results. Inputs alone were kept once, and every
      // repair stopped early too: a page of one slider.
      if (!(kept.blocks.length || (list(kept.inputs).length && list(kept.outputs).length && kept.title))) throw error;
      this.note(kept.blocks.length ? `Kept the ${kept.blocks.length} finished blocks.` : "Kept the calculation; no block was finished.");
      return kept;
    }
  }

  /** What's usable from a surface that stopped early: every finished block. A block that was
   * looping or cut off is dropped; after a stall, everything there is as finished as it gets.
   * Related topics come from Wikipedia if they're missing. */
  private async salvaged(partial: Surface, reason: StopReason, blocksFinished: boolean): Promise<Surface> {
    const blocks = [...partial.blocks];
    let related = list(partial.related).filter((topic): topic is string => typeof topic === "string");
    if (reason === "stalled") {
      // Keep it all.
    } else if ((reason === "repeating" || !blocksFinished) && blocks.length) {
      blocks.pop();
    } else if (related.length) {
      // It stopped while listing topics, so the last one may be cut off mid-word.
      related = related.slice(0, -1);
    }
    const reference = isObject(partial.reference) ? (partial.reference as unknown as Reference) : null;
    if (related.length < 3 && reference) related = related.concat(await this.services.tools.related(reference.title, languageOf(reference)).catch(() => []));
    return { ...partial, blocks, related };
  }

  // MARK: Generation

  /** One generation, with the watchdog the app has: a model can stall, sending nothing new, or
   * keep sending without anything changing. Models report activity while they think, so only
   * real silence counts. The server's heartbeat says the line is open, not that the model is
   * working: it buys a long think, up to `ceiling`, never a hang. */
  private async generate(session: Session, step: string, prompt: unknown, onPartial: ((partial: JSONObject) => void) | null, isRunaway: (partial: JSONObject) => boolean, signal: AbortSignal): Promise<JSONObject> {
    const started = this.now;
    const schema = this.generation.schemas.surface;
    const watch = { text: "", partial: null as JSONObject | null, lastChange: started, lastRead: -Infinity, lastChecked: -Infinity, stop: null as "repeating" | "stalled" | null };
    const changes = new Changes();
    const stopper = linked(signal);
    // The page so far, about six times a second rather than on every token, and the runaway
    // check at its own pace: reading the page whole is the costly part.
    const look = (force: boolean) => {
      const now = this.now;
      const shown = force || now - watch.lastRead >= this.timing.partialEvery;
      const checked = now - watch.lastChecked >= this.timing.runawayEvery;
      if (!shown && !checked) return;
      const partial = partialObject(watch.text, schema);
      if (!partial) return;
      watch.partial = partial;
      if (shown) {
        watch.lastRead = now;
        onPartial?.(partial);
      }
      if (checked && !watch.stop) {
        watch.lastChecked = now;
        if (isRunaway(partial)) {
          watch.stop = "repeating";
          stopper.abort(new Cancelled());
        }
      }
    };
    const onText = (text: string) => {
      watch.text += text;
      if (changes.read(text)) {
        watch.lastChange = this.now;
        if (this.phase === "researching") this.setPhase("composing");
      }
      look(false);
    };
    const watchdog = setInterval(() => {
      const now = this.now;
      const latest = Math.max(watch.lastChange, this.activity.seen);
      const heard = Math.max(watch.lastChange, this.activity.heard);
      if (now - latest > this.timing.patience || now - heard > this.timing.ceiling) {
        watch.stop ??= "stalled";
        stopper.abort(new Cancelled());
      }
    }, this.timing.watch);
    let failure: unknown = null;
    try {
      await this.respond(session, prompt, { schema, temperature: 0.4 }, onText, () => {
        watch.text = "";
      }, stopper.signal);
    } catch (error) {
      failure = error;
    } finally {
      clearInterval(watchdog);
    }
    if (watch.text) look(true);
    // Stopped from outside, like writing that gives way to the gap check's questions.
    if (signal.aborted) throw signal.reason;
    if (failure !== null && watch.stop === null) {
      this.note(`${step} stopped after ${elapsed(started, this.now)} (${describe(failure)}).`);
      if (watch.partial) throw new Unfinished(watch.partial, "cutOff");
      throw failure;
    }
    switch (watch.stop) {
      case "repeating":
        this.note(`${step} started repeating itself after ${elapsed(started, this.now)}; stopped it there.`);
        if (watch.partial) throw new Unfinished(watch.partial, "repeating");
        break;
      case "stalled": {
        // It may have stalled right at the end, in which case the answer is whole.
        const whole = wholeObject(watch.text);
        if (whole) {
          this.note(`${step}: ${elapsed(started, this.now)} on ${this.modelName}`);
          return whole;
        }
        this.note(`${step} stopped making progress after ${elapsed(started, this.now)}; stopped it there.`);
        if (watch.partial) throw new Unfinished(watch.partial, "stalled");
        throw new ComposeError("The model stopped making progress.");
      }
      default:
        break;
    }
    if (!watch.text.trim()) throw new ComposeError("The model returned nothing.");
    this.note(`${step}: ${elapsed(started, this.now)} on ${this.modelName}`);
    const whole = wholeObject(watch.text);
    if (whole) return whole;
    // The answer filled its room before it was done, or turned to padding and was cut off.
    this.note(`${step} ended before it was finished.`);
    if (watch.partial) throw new Unfinished(watch.partial, "cutOff");
    throw new ParsingError();
  }

  /** One request in a session, through as many rounds of tool calls as the model makes, then its
   * answer. The transcript keeps it only when the answer is whole: a generation that failed or
   * was stopped early is taken back out, request and all. */
  private async respond(session: Session, prompt: unknown, options: Pick<RequestOptions, "schema" | "temperature" | "maximumResponseTokens">, onText: (text: string) => void, onToolRound: () => void, signal: AbortSignal): Promise<Round> {
    const { transcript, tools } = session;
    const mark = transcript.messages.length;
    let kept = false;
    transcript.messages.push({ role: "user", content: prompt });
    try {
      for (let round = 0; ; round++) {
        const body = requestBody(transcript.messages, {
          model: this.pick ? this.pick.model : this.onAuto ? "" : this.request.model ?? "",
          effort: this.pick ? this.pick.effort : this.thinking,
          thinking: this.thinking,
          tools: tools?.definitions,
          ...options,
        });
        const stream = await ask(this.services.model, body, signal, this.services.sleep, this.timing.retries);
        const result = await readRound(stream, this.activity, () => this.now, onText, signal);
        if (result.toolCalls.length && !result.padded && tools) {
          if (round >= this.timing.toolRounds) throw new ComposeError("The model kept looking things up without writing the page.");
          onToolRound();
          const calls: Message["tool_calls"] = result.toolCalls.map((call) => ({ id: call.id, type: "function", function: { name: call.name, arguments: call.arguments } }));
          transcript.messages.push({ role: "assistant", content: "", tool_calls: calls });
          const outputs = await Promise.all(result.toolCalls.map((call) => abortable(tools.run(call.name, call.arguments), signal)));
          result.toolCalls.forEach((call, index) => transcript.messages.push({ role: "tool", tool_call_id: call.id, content: outputs[index] }));
          continue;
        }
        if (!result.padded && wholeObject(result.text)) {
          transcript.messages.push({ role: "assistant", content: result.text });
          kept = true;
        }
        return result;
      }
    } finally {
      if (!kept) transcript.messages.length = mark;
    }
  }

  // MARK: Showing

  /** A partial surface goes on screen, unless the gap check has only just started deciding. */
  private show(partial: Surface): void {
    if (this.quiet) return;
    if (this.isChecking && this.now < this.holdUntil) {
      this.held = partial;
      return;
    }
    this.display(partial);
  }

  private display(surface: Surface): void {
    this.surface = surface;
    this.queueSurface(surface);
  }

  /** At most one `surface` event every `surfaceEvery`; the latest waits for its turn. */
  private queueSurface(surface: Surface): void {
    if (this.quiet) return;
    this.pending = surface;
    const wait = this.lastSurfaceAt + this.timing.surfaceEvery - this.now;
    if (wait <= 0) this.flushSurface();
    else this.surfaceTimer ??= setTimeout(() => this.flushSurface(), wait);
  }

  private flushSurface(): void {
    if (this.surfaceTimer !== null) clearTimeout(this.surfaceTimer);
    this.surfaceTimer = null;
    const surface = this.pending;
    this.pending = null;
    if (!surface || this.quiet) return;
    this.lastSurfaceAt = this.now;
    this.events.surface(surface);
  }

  /** Nothing more goes out once the loop is over: `done` carries the page. */
  private dispose(): void {
    this.quiet = true;
    this.pending = null;
    if (this.surfaceTimer !== null) clearTimeout(this.surfaceTimer);
    this.surfaceTimer = null;
  }

  // MARK: Reporting

  /** The language and units a finished surface is written in. The app tells the language from
   * the page's own text; the server has no recognizer, so it's the user's, as the app falls back
   * to when it can't tell. */
  private recordLocale(surface: Surface): Surface {
    const locale = { language: this.request.locale.language, measurementSystem: this.request.locale.measurementSystem };
    this.note(`Written in ${languageName(locale.language)}, for ${locale.measurementSystem} units`);
    return { ...surface, locale };
  }

  private setPhase(phase: ComposePhase): void {
    if (this.phase === phase) return;
    this.phase = phase;
    this.events.phase(phase);
  }

  private researching(line: string): void {
    this.setPhase("researching");
    this.note(line);
  }

  private report(issues: Issue[]): void {
    for (const issue of issues) {
      this.note(`${issue.kind === "fixed" ? "Fixed" : issue.kind === "needsModel" ? "Problem" : "Warning"}: ${issue.message}`);
    }
  }

  private note(line: string): void {
    this.events.log(line);
  }
}
