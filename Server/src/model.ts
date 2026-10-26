// The model, through Dream's own server, so no provider key lives on a phone.
//
//   POST /api/model   an OpenAI-style chat completion  → xAI's answer, streamed as it comes
//
// The app's Dream provider (Dream/Generation/Providers/DreamModel.swift) sends what it would send
// xAI, with the user's session, proof that it's the app (attest.ts), and `X-Dream-Page` naming
// the page it's building. The request is checked and rebuilt from the fields Dream uses, so
// nothing else (other models, paid server-side tools, several answers at once) reaches xAI;
// `max_tokens` and the body's size are capped. The answer streams back byte for byte, reasoning
// included, so the app sees the model is working through a long think. The usage xAI reports at
// the end of the stream is counted against the account (usage.ts).
//
// Nothing that was asked or answered is logged or kept: only token counts and what they cost.

import { proveApp, type ProofEnv } from "./attest";
import { userFrom, signInNeeded, type AuthEnv } from "./auth";
import { allowed, bodyBytes, isJSON, problem } from "./reply";
import { accountOf, admitModel, recordModel, refusalResponse, type ModelUse, type UsageEnv } from "./usage";

export interface ModelEnv extends ProofEnv, UsageEnv, AuthEnv {
  /** Secret. Dream's xAI API key. */
  XAI_API_KEY?: string;
  /** Where xAI's API is. Only tests change it, to a stand-in on this Mac. */
  XAI_BASE_URL?: string;
  /** The models the app may ask for, separated by commas. The first is used when none is named. */
  MODELS?: string;
  /** The most a single answer may be, in tokens. */
  MAX_OUTPUT_TOKENS?: string;
  MODEL_LIMIT?: RateLimit;
}

/** A page's prompt is 60–120 KB, with a photo up to about 400 KB more. */
const MAX_BODY = 2_000_000;
const DEFAULT_MODELS = "grok-4.7";
const DEFAULT_MAX_OUTPUT = 32_000;
const EFFORTS = new Set(["low", "medium", "high"]);
const ROLES = new Set(["system", "developer", "user", "assistant", "tool"]);

/** Dollars per million tokens, from https://docs.x.ai/docs/models, for when xAI doesn't say what
 * a request cost (it usually does, as `cost_in_usd_ticks`). */
const PRICES: Record<string, { input: number; cached: number; output: number }> = {
  "grok-4.7": { input: 2, cached: 0.5, output: 6 },
};
const FALLBACK_PRICE = { input: 4, cached: 1, output: 12 };

class Invalid extends Error {}

const isObject = (value: unknown): value is Record<string, unknown> => value !== null && typeof value === "object" && !Array.isArray(value);

/** Only data: images, so the model provider never fetches an address on Dream's behalf. */
function checkContent(content: unknown): number {
  if (typeof content === "string" || content === null || content === undefined) return 0;
  if (!Array.isArray(content) || content.length > 50) throw new Invalid("message content");
  let images = 0;
  for (const part of content) {
    if (!isObject(part)) throw new Invalid("message content");
    if (part.type === "text" && typeof part.text === "string") continue;
    const url = isObject(part.image_url) ? part.image_url.url : undefined;
    if (part.type === "image_url" && typeof url === "string" && /^data:image\/(jpeg|png|webp|heic);base64,/.test(url)) {
      images++;
      continue;
    }
    throw new Invalid("message content");
  }
  return images;
}

/** What goes to xAI: the fields Dream uses, checked, and nothing else. */
export function upstreamBody(body: Record<string, unknown>, env: ModelEnv): Record<string, unknown> {
  const models = (env.MODELS ?? DEFAULT_MODELS).split(",").map((model) => model.trim()).filter(Boolean);
  const model = body.model ?? models[0];
  if (typeof model !== "string" || !models.includes(model)) throw new Invalid(`Dream doesn't offer that model. It offers ${models.join(", ")}.`);

  const messages = body.messages;
  if (!Array.isArray(messages) || messages.length < 1 || messages.length > 400) throw new Invalid("Send from 1 to 400 messages.");
  let images = 0;
  for (const message of messages) {
    if (!isObject(message) || typeof message.role !== "string" || !ROLES.has(message.role)) throw new Invalid("Each message needs a role.");
    images += checkContent(message.content);
    if (message.tool_calls !== undefined && (!Array.isArray(message.tool_calls) || message.tool_calls.length > 32)) throw new Invalid("Too many tool calls in one message.");
  }
  if (images > 4) throw new Invalid("Send at most 4 pictures.");

  const out: Record<string, unknown> = { model, messages };
  if (body.stream !== undefined) {
    if (typeof body.stream !== "boolean") throw new Invalid("stream is true or false.");
    out.stream = body.stream;
    // The last chunk then says what the request used, which is what's counted.
    if (body.stream) out.stream_options = { include_usage: true };
  }
  if (body.tools !== undefined) {
    if (!Array.isArray(body.tools) || body.tools.length > 32) throw new Invalid("Send at most 32 tools.");
    for (const tool of body.tools) {
      // Only the app's own functions: a provider's server-side tools (web search and the like) cost money.
      const fn = isObject(tool) ? tool.function : undefined;
      if (!isObject(tool) || tool.type !== "function" || !isObject(fn) || typeof fn.name !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(fn.name)) throw new Invalid("Tools must be functions.");
    }
    out.tools = body.tools;
  }
  if (body.tool_choice !== undefined) {
    if (!(["auto", "none", "required"].includes(body.tool_choice as string) || (isObject(body.tool_choice) && body.tool_choice.type === "function"))) throw new Invalid("tool_choice is auto, none, required or a function.");
    out.tool_choice = body.tool_choice;
  }
  if (body.parallel_tool_calls !== undefined) out.parallel_tool_calls = body.parallel_tool_calls === true;
  if (body.response_format !== undefined) {
    const format = body.response_format;
    if (!isObject(format) || !["text", "json_object", "json_schema"].includes(format.type as string)) throw new Invalid("response_format is text, json_object or json_schema.");
    if (format.type === "json_schema" && !isObject(format.json_schema)) throw new Invalid("json_schema needs a schema.");
    out.response_format = format;
  }
  if (body.reasoning_effort !== undefined) {
    if (!EFFORTS.has(body.reasoning_effort as string)) throw new Invalid("reasoning_effort is low, medium or high.");
    out.reasoning_effort = body.reasoning_effort;
  }
  for (const [name, low, high] of [["temperature", 0, 2], ["top_p", 0, 1], ["frequency_penalty", -2, 2], ["presence_penalty", -2, 2]] as const) {
    const value = body[name];
    if (value === undefined) continue;
    if (typeof value !== "number" || value < low || value > high) throw new Invalid(`${name} is a number from ${low} to ${high}.`);
    out[name] = value;
  }
  if (body.seed !== undefined && Number.isInteger(body.seed)) out.seed = body.seed;
  if (body.stop !== undefined) {
    const stop = body.stop;
    if (!(typeof stop === "string" || (Array.isArray(stop) && stop.length <= 4 && stop.every((item) => typeof item === "string")))) throw new Invalid("stop is a string, or up to 4.");
    out.stop = stop;
  }
  const cap = Number(env.MAX_OUTPUT_TOKENS) > 0 ? Number(env.MAX_OUTPUT_TOKENS) : DEFAULT_MAX_OUTPUT;
  const asked = body.max_completion_tokens ?? body.max_tokens;
  if (asked !== undefined && !(Number.isInteger(asked) && (asked as number) > 0)) throw new Invalid("max_tokens is a whole number.");
  out.max_tokens = Math.min((asked as number | undefined) ?? cap, cap);
  return out;
}

/** What a request used, from xAI's `usage`. Reasoning tokens are counted on their own there, and
 * billed as output. `cost_in_usd_ticks` is in ten-billionths of a dollar. */
export function useFrom(usage: unknown, model: string): ModelUse | null {
  if (!isObject(usage)) return null;
  const count = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 0);
  const tokensIn = count(usage.prompt_tokens);
  const tokensCached = Math.min(tokensIn, count(isObject(usage.prompt_tokens_details) ? usage.prompt_tokens_details.cached_tokens : 0));
  const tokensOut = count(usage.completion_tokens) + count(isObject(usage.completion_tokens_details) ? usage.completion_tokens_details.reasoning_tokens : 0);
  const ticks = usage.cost_in_usd_ticks;
  const cost = typeof ticks === "number" && Number.isFinite(ticks) && ticks >= 0 ? ticks / 10_000 : priced(model, tokensIn, tokensCached, tokensOut);
  return { tokensIn, tokensCached, tokensOut, cost };
}

function priced(model: string, tokensIn: number, tokensCached: number, tokensOut: number): number {
  const price = PRICES[model] ?? FALLBACK_PRICE;
  return (tokensIn - tokensCached) * price.input + tokensCached * price.cached + tokensOut * price.output;
}

/** Passes a server-sent event stream through untouched, watching for the usage chunk. If the
 * stream is cut short, what it used is estimated from its size. */
function metered(upstream: ReadableStream<Uint8Array>, model: string, requestBytes: number, finished: (use: ModelUse) => void): ReadableStream<Uint8Array> {
  const reader = upstream.getReader();
  const decoder = new TextDecoder();
  let pending = "";
  let lines = 0;
  let use: ModelUse | null = null;
  let done = false;
  const scan = (text: string) => {
    pending += text;
    let newline: number;
    while ((newline = pending.indexOf("\n")) >= 0) {
      const line = pending.slice(0, newline);
      pending = pending.slice(newline + 1);
      if (!line.startsWith("data:")) continue;
      lines++;
      // Only the usage chunk is parsed: inside answer text, quotes would be escaped.
      if (line.includes('"usage":{')) {
        try {
          use = useFrom((JSON.parse(line.slice(5)) as { usage?: unknown }).usage, model) ?? use;
        } catch {
          // Not the chunk it looked like.
        }
      }
    }
    if (pending.length > 1_000_000) pending = "";
  };
  const finish = () => {
    if (done) return;
    done = true;
    const tokensIn = Math.ceil(requestBytes / 4);
    finished(use ?? { tokensIn, tokensCached: 0, tokensOut: lines, cost: priced(model, tokensIn, 0, lines) });
  };
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        const { done: ended, value } = await reader.read();
        if (ended) {
          scan(decoder.decode());
          finish();
          controller.close();
          return;
        }
        scan(decoder.decode(value, { stream: true }));
        controller.enqueue(value);
      } catch (error) {
        finish();
        controller.error(error);
      }
    },
    async cancel(reason) {
      finish();
      await reader.cancel(reason);
    },
  });
}

/** What the app is told when xAI refuses or fails. xAI's own words only for a request it found
 * malformed, which helps when the app's schema or tools are at fault. */
async function upstreamProblem(response: Response): Promise<Response> {
  const text = await response.text().catch(() => "");
  console.error("Model provider failed", response.status);
  switch (response.status) {
    case 400:
    case 422: {
      let detail = "";
      try {
        const body = JSON.parse(text) as { error?: unknown; message?: unknown };
        detail = String((isObject(body.error) ? body.error.message : body.error) ?? body.message ?? "");
      } catch {
        detail = "";
      }
      return problem(400, `The model couldn't take that request${detail ? `: ${detail.slice(0, 300)}` : "."}`);
    }
    case 413:
      return problem(413, "That's too much for the model at once.");
    case 429:
      return problem(503, "The model is busy. Try again in a moment.", { "Retry-After": "20" });
    default:
      return problem(502, "The model didn't answer. Try again in a moment.");
  }
}

async function conversationID(userID: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`dream-conversation:${userID}`)));
  return [...digest.subarray(0, 16)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function model(request: Request, env: ModelEnv, ctx: ExecutionContext): Promise<Response> {
  const user = await userFrom(request, env);
  if (!user) return signInNeeded();
  if (!(await allowed(env.MODEL_LIMIT, `model:${user.id}`))) return problem(429, "Too many requests at once. Try again in a minute.", { "Retry-After": "60" });
  if (!isJSON(request)) return problem(415, "Send application/json.");
  const raw = await bodyBytes(request, MAX_BODY);
  if (!raw) return problem(413, "That's too much to send the model at once.");
  const refused = await proveApp(request, env, raw, "Dream's model");
  if (refused) return refused;
  const key = env.XAI_API_KEY?.trim();
  if (!key) return problem(503, "Dream's model isn't set up on this server yet.");

  let body: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(raw));
    if (!isObject(parsed)) return problem(400, "Expected a JSON object.");
    body = upstreamBody(parsed, env);
  } catch (error) {
    if (error instanceof Invalid) return problem(400, error.message);
    if (error instanceof SyntaxError || error instanceof TypeError) return problem(400, "That isn't JSON.");
    throw error;
  }

  const page = request.headers.get("X-Dream-Page");
  const pageID = page && /^[A-Za-z0-9-]{8,64}$/.test(page) ? page : null;
  const account = await accountOf(env, user.id);
  const refusal = await admitModel(env, user.id, pageID, account);
  if (refusal) return refusalResponse(refusal);

  const modelID = body.model as string;
  let upstream: Response;
  try {
    upstream = await fetch(`${(env.XAI_BASE_URL?.trim() || "https://api.x.ai").replace(/\/$/, "")}/v1/chat/completions`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json",
        Accept: body.stream ? "text/event-stream" : "application/json",
        // xAI keeps prompt caches per server, and sends requests with the same conversation id to
        // the same one. One per account means a page's tool rounds and repairs, and the next
        // page's long instructions, are read from the cache at a quarter of the price. It's a
        // hash, so xAI never sees Dream's id for anyone.
        "x-grok-conv-id": await conversationID(user.id),
      },
      body: JSON.stringify(body),
    });
  } catch {
    console.error("Model provider unreachable");
    return problem(502, "The model didn't answer. Try again in a moment.");
  }
  if (!upstream.ok) return upstreamProblem(upstream);
  const record = (use: ModelUse) => ctx.waitUntil(recordModel(env, user.id, pageID, use).catch((error) => console.error("Usage not recorded", error instanceof Error ? error.name : typeof error)));

  if (body.stream && upstream.body) {
    return new Response(metered(upstream.body, modelID, raw.length, record), {
      status: 200,
      headers: { "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" },
    });
  }
  const text = await upstream.text();
  let use: ModelUse | null = null;
  try {
    use = useFrom((JSON.parse(text) as { usage?: unknown }).usage, modelID);
  } catch {
    use = null;
  }
  const tokensIn = Math.ceil(raw.length / 4);
  record(use ?? { tokensIn, tokensCached: 0, tokensOut: Math.ceil(text.length / 4), cost: priced(modelID, tokensIn, 0, Math.ceil(text.length / 4)) });
  return new Response(text, { status: 200, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
}
