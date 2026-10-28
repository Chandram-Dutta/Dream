// Chat completions, as the page loop speaks them to the model: the request it sends and the
// streamed answer it reads, ported from Dream/Generation/Providers/ChatCompletions.swift and
// DreamModel.swift so a page asks the model exactly as the app does. The model itself is called
// in-process (model.ts), so the answer arrives as the app's would: chat completion chunks, with
// ": thinking" comments while the model is quiet (stream.ts).
//
// No imports, so test/unit.mjs runs it in Node.

type JSONObject = Record<string, unknown>;

const isObject = (value: unknown): value is JSONObject => value !== null && typeof value === "object" && !Array.isArray(value);

export interface ToolCall {
  id: string;
  name: string;
  /** As the model wrote them: JSON, unchecked. */
  arguments: string;
}

/** One message of a session, as chat completions carry it. */
export interface Message {
  role: "system" | "user" | "assistant" | "tool";
  content: unknown;
  tool_calls?: { id: string; type: "function"; function: { name: string; arguments: string } }[];
  tool_call_id?: string;
}

/** A session's transcript: its instructions, then each request, tool round and answer. A
 * generation that fails or is stopped early is taken back out, request and all, as Foundation
 * Models does, so a repair knows whether the session still holds the page it's fixing. */
export class Transcript {
  readonly messages: Message[];

  constructor(instructions: string) {
    this.messages = [{ role: "system", content: instructions }];
  }

  /** Whether it ends with the model's answer, which a follow-up like a repair can point back to. */
  get endsWithAnswer(): boolean {
    const last = this.messages.at(-1);
    return last?.role === "assistant" && !last.tool_calls;
  }
}

/** Plain text, unless the request carries a photo (ChatCompletions.content). */
export function userContent(text: string, image?: string): unknown {
  return image ? [{ type: "text", text }, { type: "image_url", image_url: { url: `data:image/jpeg;base64,${image}` } }] : text;
}

/** Tokens of thinking to allow beside an answer's own budget, by level (ChatCompletions.thinkingRoom). */
export function thinkingRoom(level: string): number {
  switch (level) {
    case "medium":
      return 8_000;
    case "high":
      return 16_000;
    case "max":
      return 32_000;
    default:
      return 4_000;
  }
}

export interface RequestOptions {
  /** The catalogue id to ask for; empty for the server's default. */
  model: string;
  /** The thinking level Auto picked for the page, or the one the user picked. */
  effort: string;
  /** The user's own thinking level (ThinkingChoice.level), which sizes an answer's thinking room. */
  thinking: string;
  schema?: JSONObject;
  tools?: { name: string; description: string; parameters: JSONObject }[];
  temperature?: number;
  /** The answer's own budget, before thinking (GenerationOptions.maximumResponseTokens). */
  maximumResponseTokens?: number;
}

/** The request's JSON (ChatCompletions.body). */
export function requestBody(messages: Message[], options: RequestOptions): JSONObject {
  const body: JSONObject = { messages, stream: true };
  if (options.model) body.model = options.model;
  if (options.schema) body.response_format = { type: "json_schema", json_schema: { name: "response", schema: options.schema, strict: true } };
  if (options.tools?.length) {
    body.tools = options.tools.map((tool) => ({ type: "function", function: { name: tool.name, description: tool.description, parameters: tool.parameters } }));
  }
  body.reasoning_effort = options.effort;
  if (options.temperature !== undefined) body.temperature = options.temperature;
  // Providers count thinking against max_tokens, so the answer's budget gets room for it on top.
  if (options.maximumResponseTokens !== undefined) body.max_tokens = options.maximumResponseTokens + thinkingRoom(options.thinking);
  return body;
}

/** What the model's server said when it didn't answer, in its own plain words (DreamServiceError). */
export class ModelProblem extends Error {
  readonly status: number;
  /** Worth asking again in a moment: the model didn't answer (502), or was busy (503, with a
   * Retry-After). Not a used-up allowance, nor a server that isn't set up. */
  readonly transient: boolean;
  /** An allowance ran out, so Dream Plus might help. */
  readonly allowance: boolean;

  constructor(status: number, body: unknown, retryAfter: string | null) {
    const said = isObject(body) ? (typeof body.error === "string" ? body.error : isObject(body.error) && typeof body.error.message === "string" ? body.error.message : null) : null;
    const reason = isObject(body) ? body.reason : undefined;
    const allowance = status === 402 || (status === 429 && reason === "allowance");
    let message: string;
    if (allowance) message = said ?? "You've used today's allowance.";
    else if (status === 401) message = said ?? "Sign in to make pages.";
    else if (status === 429) message = said ?? "Too many requests at once. Try again in a minute.";
    else message = said ?? `Dream's server didn't answer (${status}). Try again in a moment.`;
    super(message);
    this.name = "ModelProblem";
    this.status = status;
    this.allowance = allowance;
    this.transient = status === 502 || (status === 503 && reason !== "allowance" && retryAfter !== null);
  }
}

/** How long to wait before asking again when the model was busy or didn't answer
 * (DreamExecutor.retryDelays). Some providers count requests per minute, so the waits grow. */
export const RETRY_DELAYS = [2_000, 6_000, 15_000];

/** The answer, or the signal's reason as soon as it stops; an answer that comes after is let go. */
function answered(sending: Promise<Response>, signal: AbortSignal): Promise<Response> {
  return new Promise((resolve, reject) => {
    const stop = () => {
      reject(signal.reason);
      sending.then((response) => response.body?.cancel()).catch(() => undefined);
    };
    if (signal.aborted) return stop();
    signal.addEventListener("abort", stop, { once: true });
    sending.then(
      (response) => {
        signal.removeEventListener("abort", stop);
        resolve(response);
      },
      (error) => {
        signal.removeEventListener("abort", stop);
        reject(error);
      },
    );
  });
}

/** One request, asked again after a busy or unreachable model: nothing has streamed yet, so it's
 * safe. The answer is the open stream. */
export async function ask(
  send: (body: JSONObject, signal: AbortSignal) => Promise<Response>,
  body: JSONObject,
  signal: AbortSignal,
  sleep: (ms: number, signal: AbortSignal) => Promise<void>,
  delays: number[] = RETRY_DELAYS,
): Promise<ReadableStream<Uint8Array>> {
  for (let attempt = 0; ; attempt++) {
    const response = await answered(send(body, signal), signal);
    if (response.ok && response.body) return response.body;
    const text = await response.text().catch(() => "");
    let parsed: unknown = null;
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = null;
    }
    const problem = new ModelProblem(response.ok ? 502 : response.status, parsed, response.headers.get("Retry-After"));
    if (!problem.transient || attempt >= delays.length) throw problem;
    await sleep(delays[attempt], signal);
  }
}

/** When the model last sent anything, heartbeats included, and when it last sent anything but a
 * heartbeat (ModelActivity). One per page: the gap check's stream counts for the writing's too,
 * as on the phone. */
export class Activity {
  seen: number;
  heard: number;

  constructor(now: number) {
    this.seen = now;
    this.heard = now;
  }
}

/** Spots an answer that has turned to padding (ChatCompletions.Padding): hundreds of blanks in a
 * row, a number dozens of digits long, a screen ten times longer than any on the bench, or a
 * model gone back to thinking long after its answer began. */
export class Padding {
  static readonly blankLimit = 400;
  static readonly digitLimit = 40;
  static readonly lengthLimit = 60_000;
  static readonly pieceLimit = 15_000;
  static readonly rethinkLimit = 20_000;
  private inString = false;
  private escaped = false;
  private blanks = 0;
  private digits = 0;
  private length = 0;
  private pieces = 0;
  private rethinking = 0;

  /** Reads thinking that comes after the answer began; what it has turned into, once it's lost. */
  rethink(text: string): string | null {
    this.rethinking += [...text].length;
    return this.rethinking > Padding.rethinkLimit ? `thinking again, ${this.rethinking} characters after the answer began` : null;
  }

  /** Reads the next piece of the answer; what it has turned into, once it's padding. */
  read(text: string): string | null {
    this.length += [...text].length;
    this.pieces += 1;
    if (this.length > Padding.lengthLimit || this.pieces > Padding.pieceLimit) return `${this.length} characters in ${this.pieces} pieces, longer than any screen`;
    for (const char of text) {
      if (char === " " || char === "\n" || char === "\r" || char === "\t") {
        this.blanks += 1;
        if (this.blanks >= Padding.blankLimit) return `${this.blanks} blank characters in a row`;
      } else {
        this.blanks = 0;
      }
      // Digits only count in numbers: a string may quote as many as it likes, like π's.
      if (this.inString) {
        if (this.escaped) this.escaped = false;
        else if (char === "\\") this.escaped = true;
        else if (char === '"') this.inString = false;
      } else if (char === '"') {
        this.inString = true;
        this.digits = 0;
      } else if (char >= "0" && char <= "9") {
        this.digits += 1;
        if (this.digits >= Padding.digitLimit) return `a number ${this.digits} digits long`;
      } else if (!".-+eE".includes(char)) {
        this.digits = 0;
      }
    }
    return null;
  }
}

/** Whether a piece of JSON changes what's been written so far: anything but blanks between
 * values. The page loop uses it, as the app uses a changed snapshot, to tell a model that's
 * writing from one that only keeps the line busy. */
export class Changes {
  private inString = false;
  private escaped = false;

  read(text: string): boolean {
    let changed = false;
    for (const char of text) {
      if (this.inString) {
        changed = true;
        if (this.escaped) this.escaped = false;
        else if (char === "\\") this.escaped = true;
        else if (char === '"') this.inString = false;
      } else if (char === '"') {
        this.inString = true;
        changed = true;
      } else if (char !== " " && char !== "\n" && char !== "\r" && char !== "\t") {
        changed = true;
      }
    }
    return changed;
  }
}

export interface Round {
  /** The answer's text, as far as it went. */
  text: string;
  toolCalls: ToolCall[];
  /** Why it ended: stop, tool_calls, or length when it ran out of room. */
  finish: string | null;
  /** What the answer turned into, when the padding guard ended it early. */
  padded: string | null;
}

/** Reads one streamed answer (ChatCompletions.stream): every line tells `activity` the model is
 * still working, reasoning and comments included, and heartbeats only that the line is open.
 * Text goes to `onText` as it comes. Padding goes no further: the answer ends there. A tool call's
 * pieces are put together by their index, though Dream's providers send each one whole. */
export async function readRound(stream: ReadableStream<Uint8Array>, activity: Activity, now: () => number, onText: (text: string) => void, signal: AbortSignal): Promise<Round> {
  const reader = stream.getReader();
  const stop = () => {
    reader.cancel().catch(() => undefined);
  };
  if (signal.aborted) stop();
  signal.addEventListener("abort", stop, { once: true });
  const decoder = new TextDecoder();
  const padding = new Padding();
  const calls: { id: string; name: string; arguments: string }[] = [];
  let pending = "";
  let text = "";
  let firstText = true;
  let finish: string | null = null;
  const done = (padded: string | null): Round => ({
    text,
    toolCalls: calls.filter((call) => call.name).map((call) => ({ ...call, id: call.id || crypto.randomUUID() })),
    finish,
    padded,
  });
  try {
    for (;;) {
      const { done: ended, value } = await reader.read();
      if (signal.aborted) throw signal.reason ?? new Error("Stopped");
      if (ended) break;
      pending += decoder.decode(value, { stream: true });
      let newline: number;
      while ((newline = pending.indexOf("\n")) >= 0) {
        const line = pending.slice(0, newline).replace(/\r$/, "");
        pending = pending.slice(newline + 1);
        // Blank lines only end events.
        if (!line) continue;
        const at = now();
        activity.seen = at;
        if (line !== ": thinking") activity.heard = at;
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (payload === "[DONE]") return done(null);
        let chunk: unknown;
        try {
          chunk = JSON.parse(payload);
        } catch {
          continue;
        }
        if (!isObject(chunk)) continue;
        const choice = Array.isArray(chunk.choices) && isObject(chunk.choices[0]) ? chunk.choices[0] : null;
        if (!choice) continue;
        if (typeof choice.finish_reason === "string") finish = choice.finish_reason;
        const delta = isObject(choice.delta) ? choice.delta : null;
        if (!delta) continue;
        if (typeof delta.reasoning_content === "string" && delta.reasoning_content && !firstText) {
          const lost = padding.rethink(delta.reasoning_content);
          if (lost) {
            stop();
            return done(lost);
          }
        }
        if (typeof delta.content === "string" && delta.content) {
          firstText = false;
          const padded = padding.read(delta.content);
          if (padded) {
            stop();
            return done(padded);
          }
          text += delta.content;
          onText(delta.content);
        }
        for (const piece of Array.isArray(delta.tool_calls) ? delta.tool_calls : []) {
          if (!isObject(piece)) continue;
          const fn = isObject(piece.function) ? piece.function : {};
          const index = typeof piece.index === "number" ? piece.index : calls.length;
          const call = (calls[index] ??= { id: "", name: "", arguments: "" });
          if (typeof piece.id === "string" && piece.id) call.id = piece.id;
          if (typeof fn.name === "string" && fn.name) call.name = fn.name;
          if (typeof fn.arguments === "string") call.arguments += fn.arguments;
        }
      }
      if (pending.length > 4_000_000) pending = "";
    }
    return done(null);
  } finally {
    signal.removeEventListener("abort", stop);
  }
}
