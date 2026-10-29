// The page loop on the server, ported from Dream/Generation/Composer.swift and GapCheck.swift
// (docs/ServerGeneration.md): Auto picks the model once, a quick check looks for what only the
// user can tell while the page starts to stream out of sight, the page is written with its tools
// (lookup, recall, live data, search and read, and the phone's own), the checker fixes what it
// can and sends real mistakes back for repair, recordings and molecules are found, and what's
// finished is checked once more. A change to a page (Composer.edit, and Composer.rebuild for a
// different answer) goes through the same writing, from the page as it is. Everything it does is
// an event: the phase, each step of the work as it starts, the page so far, the log.
//
// Where the app waits on the user's answers, the loop stops instead and says what it would ask
// (`asking`); the job (runner.ts) starts it again with the answers, so a page never holds the
// object for the ten minutes it may wait. A question about something Dream remembers is
// answered from the account's synced facts, as on the phone. A call to the phone's tools that
// waits on an app nobody has open stops it too (`paused`), and it starts again from the top,
// going over what it did before from the job's journal (journal.ts) until it's back at the call.
//
// test/compose.mjs runs it in Node, with a fake model and a fake engine.

import type * as EngineModule from "../engine/index";
import type { EngineLocale, MoleculeStructure, Recording, Surface, Issue, Reference } from "../engine/index";
import type { ComposeEditing, ComposePhase, ComposeRequest } from "./contract";
import { Activity, ask, Changes, ModelProblem, readRound, requestBody, RETRY_DELAYS, Transcript, userContent, type Message, type RequestOptions, type Round } from "./chat";
import type { Journal } from "./journal";
import { LiveLog, type DeviceAnswer } from "./live";
import { findMolecule, findRecording } from "./media";
import { Memory, recallKey } from "./memory";
import { partialObject } from "./partial";
import {
  answersContext, changeOf, describeBlock, editPrompt, gapRequest, isMemoryLine, memoryContext, repairPrompt, sameQuestion, surfaceRequest, writing,
  type Answer, type Generation, type Pointed, type Question,
} from "./prompts";
import { citationKey, ReferenceLog, ServiceLog, toolBox, WebLog, type Citation, type ToolBox, type ToolServices } from "./tools";
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
  /** Asks the phone to run one of its tools (the job sets it): what it answered, or null when no
   * answer came in time, or the page stopped. */
  device?(call: { name: string; arguments: string }, signal: AbortSignal): Promise<DeviceAnswer | null>;
  /** What the page did before it stopped to wait on the phone, which it's given again, and where
   * what it does now is kept (journal.ts). The job sets it. */
  journal?: Journal;
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
  /** `remembered` answers the questions Dream could answer itself; `questions` are the rest. */
  | { kind: "asking"; questions: Question[]; remembered: Answer[]; checkedAt: number }
  | { kind: "failed"; message: string; reason: "empty" | "other" }
  /** Stopped to wait on the phone with nobody watching (Paused): the job starts it again. */
  | { kind: "paused" };

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

/** The job stopped the page to wait on the phone without holding its alarm open: it starts again
 * from the top once the phone answers, or its time is up (runner.ts). */
export class Paused extends Error {
  constructor() {
    super("Waiting on the phone.");
    this.name = "Paused";
  }
}

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

/** The answers as the log says them. */
const answerWords = (answers: Answer[]) => answers.map((answer) => (!answer.choice ? "You choose" : answer.isRemembered ? `${answer.choice} (remembered)` : answer.choice)).join("; ");

/** The same surface, carrying the answers it was built from (Surface.answered). */
function answered(surface: Surface, answers: Answer[]): Surface {
  const out: Surface = { ...surface };
  if (answers.length) out.answers = answers;
  else delete out.answers;
  return out;
}

const text = (value: unknown) => (typeof value === "string" ? value : "");

/** Surface.credits: the article it looked up and the pages it cites, each once, which a change
 * may cite again without reading them again. */
function credits(surface: Surface): Citation[] {
  const all: Citation[] = [...(surface.reference ? [{ title: surface.reference.title, site: "Wikipedia", url: surface.reference.url }] : []), ...(surface.citations ?? [])];
  const seen = new Set<string>();
  return all.filter((credit) => {
    const key = citationKey(credit.url);
    if (key === null || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/** The block with an id, wherever it is on the page. */
function blockWithID(blocks: unknown, id: string): Pointed | null {
  for (const block of list(blocks)) {
    if (!isObject(block)) continue;
    if (block.id === id) return { id, kind: text(block.kind), title: text(block.title), ref: text(block.ref), over: text(block.over) };
    const inside = blockWithID(block.children, id);
    if (inside) return inside;
  }
  return null;
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
  /** What Dream remembers about the user, read when first asked. */
  private readonly memory: Memory;
  /** The page a change starts from; null for a new page, or one made again. */
  private readonly current: Surface | null;
  /** The live data fetched while writing, which the page's live inputs bind to. */
  private readonly live: LiveLog;
  /** The connected services read while writing, and the buttons for theirs it had. */
  private readonly serviceLog: ServiceLog;
  /** The pages a change's page already credits. */
  private readonly kept: Citation[];
  /** The language lookups read first: the page's own for a change. */
  private readonly language: string;

  constructor(request: ComposeRequest, services: LoopServices, events: LoopEvents, signal: AbortSignal, timing: Timing = TIMING) {
    this.request = request;
    this.services = services;
    this.events = events;
    this.timing = timing;
    this.signal = signal;
    this.engine = services.engine;
    this.generation = services.generation;
    this.activity = new Activity(services.now());
    this.memory = new Memory(() => services.tools.memory());
    const editing = request.editing;
    this.current = editing && !editing.again && isObject(editing.surface) ? (editing.surface as unknown as Surface) : null;
    this.live = new LiveLog(this.current?.sources ?? []);
    this.serviceLog = new ServiceLog(this.current);
    this.kept = this.current ? credits(this.current) : [];
    this.language = this.current?.locale?.language || request.locale.language;
  }

  /** The reader the checker works for, as the phone's locale would have it. */
  private get reader(): EngineLocale {
    return this.request.locale;
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
      const change = this.change();
      if (start.first) {
        if (change) this.note(`Change: ${change.instruction}${change.focus ? ` (pointing at #${change.focus.id})` : ""}`);
        else this.note(`Request: ${this.request.request}${image ? " (with photo)" : ""}`);
      }
      // Auto (route.ts): the model and thinking for this page, picked once, up front. A change is
      // picked for like a new page, from the request and the change together.
      this.pick = start.pick;
      if (this.onAuto && !this.pick) await (change ? this.route(`${this.request.request}. ${change.instruction}`, undefined) : this.route(this.request.request, image));
      this.modelName = this.pick ? `Auto → ${this.pick.name} · ${this.pick.effort}` : `Dream (${this.request.model || "default"})`;
      if (start.first) this.note(`Model: ${this.modelName}`);
      if (start.answers && start.checkedAt !== null && !start.first) {
        this.note(`Answered: ${answerWords(start.answers)} after ${elapsed(start.checkedAt, this.now)}`);
      }
      if (change) {
        await this.writeChange(change);
      } else {
        const asking = await this.writeRequest(start.answers ?? []);
        if (asking) return { kind: "asking", ...asking };
      }
      const surface = this.surface;
      if (!surface || this.engine.isEmpty(surface)) throw new ComposeError("Nothing came out of this. Try asking another way.");
      const done = this.recordLocale(surface, change?.current.locale);
      this.note(`Done in ${elapsed(start.startedAt, this.now)}`);
      return { kind: "done", surface: done, model: this.modelName };
    } catch (error) {
      const stopped = this.signal.aborted ? this.signal.reason : error;
      if (stopped instanceof Paused) return { kind: "paused" };
      const message = describe(stopped);
      if (!(stopped instanceof Cancelled) && describe(stopped) === describe(null)) console.error("Page failed", stopped instanceof Error ? stopped.name : typeof stopped);
      this.note(`Failed: ${message}`);
      return { kind: "failed", message, reason: stopped instanceof ComposeError ? "empty" : "other" };
    } finally {
      this.dispose();
    }
  }

  private async route(text: string, photo: string | undefined): Promise<void> {
    const started = this.now;
    const image = photo ? `data:image/jpeg;base64,${photo}` : undefined;
    let pick: PagePick;
    try {
      pick = await abortable(this.services.route(text.slice(0, 4_000), image), this.signal);
    } catch (error) {
      if (this.signal.aborted) throw this.signal.reason;
      // Auto shouldn't stop a page from being made: the server's default, as if Auto weren't on.
      pick = { model: "", effort: "low", name: "Dream's default", category: "other", difficulty: "easy", why: "" };
      this.pick = pick;
      this.events.picked(pick);
      this.note(`Auto → ${pick.name} · ${pick.effort} (the router didn't answer: ${describe(error)})`);
      return;
    }
    this.pick = pick;
    this.events.picked(pick);
    this.note(`Auto → ${pick.name} · ${pick.effort} (${pick.category}, ${pick.difficulty}: ${pick.why}; ${elapsed(started, this.now)})`);
  }

  // MARK: Context

  /** Prompts.context: what's said beside the request. The phone sends its lines (the language,
   * the region, the time, its connected services); what Dream remembers comes from the account's
   * synced facts, which recall reads, in place of the phone's own line. A line saying the web
   * can't be searched doesn't hold here, where it can. */
  private async contextLines(): Promise<string[]> {
    const phone = (this.request.context ?? []).filter((line) => !isMemoryLine(this.generation, line) && line !== this.generation.context.webUnavailable);
    return [...memoryContext(this.generation, await this.memory.topics()), ...phone];
  }

  // MARK: Changes

  /** The change to make, when the request is one (Composer.edit): the page as it is, what the
   * user said about it, and the block they point at. A different answer (Composer.rebuild) is a
   * change in their words, from the page with that answer in place of the old one. Null for a
   * new page, or one made again. */
  private change(): { current: Surface; instruction: string; focus: Pointed | null; pointing: string | null } | null {
    const editing: ComposeEditing | undefined = this.request.editing;
    if (!editing || editing.again || !this.current) return null;
    let current = this.current;
    const { instruction, answers } = changeOf(this.generation, editing, current.answers);
    if (answers) current = answered(current, answers);
    const focus = !editing.answer && editing.focus ? blockWithID(current.blocks, editing.focus) : null;
    const page = current;
    const pointing = focus
      ? describeBlock(this.generation, focus, {
          label: (name) => this.engine.label(page, name),
          sound: (name) => page.sounds?.find((sound) => sound.name === name),
          action: (name) => page.actions?.find((action) => action.name === name),
        })
      : null;
    return { current, instruction, focus: pointing ? focus : null, pointing };
  }

  /** Writes the change: the page as it is, and what to change, with the context. Not streamed:
   * the page stays as it is on screen until the change is whole. */
  private async writeChange(change: { current: Surface; instruction: string; pointing: string | null }): Promise<void> {
    const current = change.current;
    this.answers = list(current.answers) as Answer[];
    this.display(current);
    const asked = editPrompt(this.generation, {
      intent: this.request.request,
      outline: this.engine.outline(current),
      logic: this.engine.hasLogic(current) ? this.engine.logicSummary(current) : null,
      instruction: change.instruction,
      pointing: change.pointing,
      context: await this.contextLines(),
    });
    await this.write(asked, asked, current.reference ?? null, false, this.signal);
  }

  // MARK: Asking

  /** Writes the page for the request while a quick check, in its own session, looks for what the
   * request leaves out that only the user can tell. If it finds nothing, the writing carries on
   * untouched. If it has questions, the writing stops; those Dream remembers the answer to are
   * answered at once, and the rest are returned, to ask. */
  private async writeRequest(answers: Answer[]): Promise<{ questions: Question[]; remembered: Answer[]; checkedAt: number } | null> {
    const context = await this.contextLines();
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
      for (const answer of gaps.remembered) this.note(`Remembered: ${answer.question.topic}`);
      await written.catch(() => undefined);
      const open = gaps.questions.filter((question) => !gaps.remembered.some((answer) => sameQuestion(answer.question, question)));
      if (open.length) return { questions: open, remembered: gaps.remembered, checkedAt: started };
      // Dream remembers every answer, so nobody is asked: the page is written for them at once.
      this.note(`Answered: ${answerWords(gaps.remembered)} after ${elapsed(started, this.now)}`);
      this.isChecking = false;
      this.held = null;
      this.quiet = false;
      this.surface = null;
      this.answers = gaps.remembered;
      await this.write(prompt(gaps.remembered), asked(gaps.remembered), null, true, this.signal);
      return null;
    } finally {
      this.isChecking = false;
      this.held = null;
    }
  }

  /** The gap check, on the model this page runs on, told the topics Dream remembers. If it fails,
   * nothing is asked. */
  private async gaps(intent: string): Promise<{ questions: Question[]; remembered: Answer[]; seconds: number }> {
    const started = this.now;
    const limit = linked(this.signal);
    const timer = setTimeout(() => limit.abort(new ComposeError("The check took too long.")), this.timing.gapPatience);
    try {
      const topics = await abortable(this.memory.topics(), limit.signal);
      const transcript = new Transcript(this.generation.prompts.gapCheck);
      const round = await this.respond({ transcript, tools: null, web: new WebLog() }, gapRequest(this.generation, intent, topics), { schema: this.generation.schemas.gaps, temperature: 0.2, maximumResponseTokens: 600 }, () => undefined, () => undefined, limit.signal);
      const wire = wholeObject(round.text);
      if (!wire) throw new ParsingError();
      const resolved = await abortable(this.resolve(list(wire.questions).slice(0, 3), topics), limit.signal);
      return { ...resolved, seconds: (this.now - started) / 1000 };
    } catch (error) {
      if (!this.signal.aborted) this.note(`Check failed after ${elapsed(started, this.now)} (${describe(limit.signal.aborted ? limit.signal.reason : error)}); building without asking.`);
      return { questions: [], remembered: [], seconds: (this.now - started) / 1000 };
    } finally {
      clearTimeout(timer);
    }
  }

  /** GapCheck.resolve: the questions, with those Dream can answer itself answered. The model names
   * the topic that answers one, and a question about a remembered topic is answered even if it
   * didn't. */
  private async resolve(items: unknown[], topics: string[]): Promise<{ questions: Question[]; remembered: Answer[] }> {
    const questions: Question[] = [];
    const remembered: Answer[] = [];
    for (const item of items) {
      const question = questionFrom(item);
      if (!question) continue;
      questions.push(question);
      const named = isObject(item) && typeof item.remembered === "string" ? item.remembered.trim() : "";
      const topic = named || topics.find((known) => recallKey(known) === recallKey(question.topic));
      if (!topic) continue;
      const facts = await this.memory.facts([topic]);
      if (facts.length) remembered.push({ question, choice: facts.map((fact) => fact.detail).join(", "), isRemembered: true });
    }
    return { questions, remembered };
  }

  // MARK: Writing

  /** A new session's tools and the instructions that describe them, which always agree
   * (prompts.ts, `writing`). */
  private session(found: ReferenceLog, signal: AbortSignal): Session {
    const web = new WebLog(this.kept);
    const phone = this.request.deviceTools?.length && this.services.device ? this.request.deviceTools : null;
    const box = toolBox(
      this.generation,
      this.services.tools,
      {
        trace: (kind, text) => this.events.trace(kind, text),
        use: (line) => this.researching(line),
        note: (line) => this.note(line),
      },
      {
        found,
        web,
        live: this.live,
        memory: this.memory,
        services: this.serviceLog,
        language: this.language,
        reader: this.request.locale,
        device: phone ? { tools: phone, run: (call) => this.onPhone(call, signal) } : null,
        now: () => this.now,
      },
    );
    const { instructions, tools } = writing(this.generation, this.request.locale.currency, box.definitions, box);
    return { transcript: new Transcript(instructions), tools: { ...box, definitions: tools }, web };
  }

  /** Asks the phone to run one of its tools. Waiting on the phone isn't a stalled model: the line
   * counts as busy until it answers, or its time is up. */
  private async onPhone(call: { name: string; arguments: string }, signal: AbortSignal): Promise<DeviceAnswer | null> {
    const device = this.services.device;
    if (!device) return null;
    const touch = () => {
      const now = this.now;
      this.activity.seen = now;
      this.activity.heard = now;
    };
    touch();
    const beat = setInterval(touch, this.timing.watch);
    try {
      return await device(call, signal);
    } finally {
      clearInterval(beat);
      touch();
    }
  }

  /** Surface.fetched(live).connected(…): with the sources fetched while it was written, for the
   * checker to bind its live inputs to, and the connected services it read. */
  private prepared(surface: Surface): Surface {
    const out: Surface = { ...surface };
    const sources = this.live.sources;
    if (sources.length) out.sources = sources;
    else delete out.sources;
    return this.serviceLog.connected(out);
  }

  /** Surface.findRecordings and findMolecules: a recording for every sound that asks for one,
   * and the structure of every molecule a scene names, all at once. One that finds nothing is
   * left without, and the checker drops it. */
  private async findMedia(surface: Surface, signal: AbortSignal): Promise<Surface> {
    const searches = [...new Set(this.engine.recordingSearches(surface))];
    const names = [...new Set(this.engine.moleculeNames(surface))];
    if (!searches.length && !names.length) return surface;
    const fetcher = this.services.tools.fetch;
    const [recordings, molecules] = await abortable(
      Promise.all([
        Promise.all(searches.map(async (search) => [search, await findRecording(search, fetcher).catch(() => null)] as const)),
        Promise.all(names.map(async (name) => [name, await findMolecule(name, fetcher).catch(() => null)] as const)),
      ]),
      signal,
    );
    const found = <T>(pairs: readonly (readonly [string, T | null])[]) => new Map(pairs.flatMap(([key, value]) => (value ? [[key, value] as [string, T]] : [])));
    return this.engine.addMolecules(this.engine.addRecordings(surface, found<Recording>(recordings)), found<MoleculeStructure>(molecules));
  }

  /** Writes a whole surface, then has the checker fix what it can and sends real mistakes back
   * in the same session, so the model sees what it wrote. `asked` is the prompt's text, for a
   * repair to repeat when the session no longer holds it. */
  private async write(prompt: unknown, asked: string, fallback: Reference | null, streaming: boolean, signal: AbortSignal): Promise<void> {
    this.setPhase("composing");
    const found = new ReferenceLog();
    let session = this.session(found, signal);
    let surface: Surface;
    // A page Auto's router knows is about the world (an explainer, or something current) looks it
    // up before it writes: cheap models skipped it, and sending the page back for it doubled the
    // wait. Other pages, like a bill split, may write straight away.
    const mustLook = this.pick?.category === "science" || this.pick?.category === "live";
    try {
      surface = await this.generateSurface(session, "Surface", prompt, found, fallback, streaming, signal, { requireTool: mustLook });
      // A title and a sentence with nothing under them is as empty as nothing at all: a cheap
      // model once answered a whole EV comparison with just that.
      if (!surface.blocks.length && !this.engine.hasLogic(surface)) throw new EmptyScreen();
    } catch (error) {
      if (!worthAnotherTry(error) || signal.aborted) throw error;
      // Nothing usable came out. Another go in a new session usually works, and costs less than
      // a page that fails.
      this.note(`Writing again in a new session, after: ${describe(error)}`);
      session = this.session(found, signal);
      surface = await this.generateSurface(session, "Surface", prompt, found, fallback, streaming, signal);
    }
    surface = this.prepared(surface);
    for (let round = 0; round <= 2; round++) {
      const checked = this.engine.checkLogic(surface, this.reader);
      surface = checked.surface;
      // A request to act whose changing tool was never called goes back, as on the phone.
      let issues = checked.issues.concat(this.serviceLog.problems());
      // Once: a page about the world that looked nothing up goes back to look it up, and this
      // time it must: asked nicely, a model cited Wikipedia pages it never read instead.
      const unsourced = round === 0 ? this.engine.checkSourcing(surface, session.web.reading(found.all)) : [];
      issues = issues.concat(unsourced);
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
      const before = surface;
      try {
        surface = this.prepared(await this.generateSurface(session, `Repair ${round + 1}`, repair, found, fallback, false, signal, { repairing: true, requireTool: unsourced.length > 0 }));
        // A repair fixes the page; one that lost most of it isn't worth having.
        if (list(surface.blocks).length * 2 < list(before.blocks).length) {
          this.note(`Kept the screen as it was: repair ${round + 1} left ${list(surface.blocks).length} of its ${list(before.blocks).length} blocks.`);
          surface = before;
          break;
        }
      } catch (error) {
        if (signal.aborted) throw signal.reason;
        // A repair that fails leaves the page as it was, which beats no page.
        this.note(`Kept the screen as it was: repair ${round + 1} didn't finish (${describe(error)}).`);
        break;
      }
    }
    surface = await this.findMedia(surface, signal);
    const reading = session.web.reading(found.all);
    const cited = this.engine.checkCitations(surface, reading);
    this.report(cited.issues);
    const blocks = this.engine.checkBlocks(cited.surface, this.reader);
    this.report(blocks.issues);
    surface = answered(blocks.surface, this.answers);
    if (signal.aborted) throw signal.reason;
    this.surface = surface;
    this.queueSurface(surface);
    this.note(this.engine.outline(surface));
  }

  /** A whole surface from one request, keeping the finished blocks if the model stops early. Not
   * a repair: one that stops early leaves the page it was repairing, which is whole, instead of a
   * few blocks of its rewrite (a page about vaccines once came down to one block that way). */
  private async generateSurface(session: Session, step: string, prompt: unknown, found: ReferenceLog, fallback: Reference | null, streaming: boolean, signal: AbortSignal, { repairing = false, requireTool = false } = {}): Promise<Surface> {
    const reference = () => found.first ?? fallback;
    const onPartial = streaming ? (partial: JSONObject) => this.show(answered(this.engine.surfaceFromPartial(partial, reference()), this.answers)) : null;
    try {
      const wire = await this.generate(session, step, prompt, onPartial, (partial) => this.engine.isRepeatingItself(this.engine.surfaceFromPartial(partial, null)), signal, requireTool);
      const surface = this.engine.surfaceFromWire(wire, reference());
      // The whole answer at once, not the last update before it, while the checks run.
      if (streaming) this.show(answered(surface, this.answers));
      return surface;
    } catch (error) {
      if (!(error instanceof Unfinished) || repairing) throw error;
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
  private async generate(session: Session, step: string, prompt: unknown, onPartial: ((partial: JSONObject) => void) | null, isRunaway: (partial: JSONObject) => boolean, signal: AbortSignal, requireTool = false): Promise<JSONObject> {
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
      await this.respond(session, prompt, { schema, temperature: 0.4, requireTool }, onText, () => {
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
      // Something the loop didn't expect: where in the code, for the Worker's log. Never the
      // message, which can quote the page.
      if (describe(failure) === describe(null)) console.error("Step failed", step, failure instanceof Error ? `${failure.name}\n${failure.stack ?? ""}` : typeof failure);
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
  private async respond(session: Session, prompt: unknown, options: Pick<RequestOptions, "schema" | "temperature" | "maximumResponseTokens" | "requireTool">, onText: (text: string) => void, onToolRound: () => void, signal: AbortSignal): Promise<Round> {
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
          // Only the first round: once it has looked, it writes.
          requireTool: round === 0 && options.requireTool === true,
        });
        const result = await this.round(body, onText, signal);
        if (result.toolCalls.length && !result.padded && tools) {
          if (round >= this.timing.toolRounds) throw new ComposeError("The model kept looking things up without writing the page.");
          onToolRound();
          const calls: Message["tool_calls"] = result.toolCalls.map((call) => ({ id: call.id, type: "function", function: { name: call.name, arguments: call.arguments } }));
          transcript.messages.push({ role: "assistant", content: "", tool_calls: calls });
          const outputs = await Promise.all(result.toolCalls.map((call) => abortable(this.runTool(tools, call), signal)));
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

  /** One answer from the model, or the one it gave here before the page stopped to wait on the
   * phone (journal.ts), given again whole. One the padding guard ended isn't kept: asked again,
   * it may go better. */
  private async round(body: JSONObject, onText: (text: string) => void, signal: AbortSignal): Promise<Round> {
    const journal = this.services.journal;
    const step = journal?.step<Round>("model", body);
    if (step?.kept) {
      this.activity.seen = this.activity.heard = this.now;
      if (step.kept.text) onText(step.kept.text);
      return step.kept;
    }
    const answer = async () => readRound(await ask(this.services.model, body, signal, this.services.sleep, this.timing.retries), this.activity, () => this.now, onText, signal);
    const result = journal ? await journal.working(answer) : await answer();
    if (step && !result.padded) journal!.keep(step.key, result);
    return result;
  }

  /** What a tool call returns. Gone over again after the page stopped for the phone, the tool
   * runs again for what it notes (the pages read, the sources declared), on what its services
   * gave before, and the model is given what it was given then, so its transcript stays the
   * same even where a live reading has moved on since. */
  private async runTool(tools: ToolBox, call: { id: string; name: string; arguments: string }): Promise<string> {
    const output = await tools.run(call.name, call.arguments);
    const journal = this.services.journal;
    if (!journal) return output;
    const step = journal.step<string>("output", call.id);
    if (step.kept !== undefined) return step.kept;
    journal.keep(step.key, output);
    return output;
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
   * the page's own text; the server has no recognizer, so it's the one the page had before a
   * change, or the user's, as the app falls back to when it can't tell. A change keeps the units
   * of the page it changed (SurfaceLocale(written:editing:)). */
  private recordLocale(surface: Surface, earlier?: { language: string; measurementSystem: string }): Surface {
    const locale = { language: earlier?.language || this.request.locale.language, measurementSystem: earlier?.measurementSystem || this.request.locale.measurementSystem };
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
