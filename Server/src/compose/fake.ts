// A stand-in for every model, for `wrangler dev` with MODEL_FAKE=1 and DEV_LOGIN=1: a whole page
// can be made locally without a provider's key or a request that costs anything. Only the page
// loop asks for it (model.ts, `fake`); /api/model never does. It answers in chat completions, as
// the providers do once translated, slowly enough to watch: the gap check asks "Which Mercury?"
// about Mercury and nothing otherwise; the writing looks its subject up first when the request
// says "look up", and asks the phone for a journey first when it asks how long or how far and
// the phone offers its travel tool, then streams a small page, thinking a little before it starts.
//
// No imports, so test/compose.mjs runs it in Node.

type JSONObject = Record<string, unknown>;

const isObject = (value: unknown): value is JSONObject => value !== null && typeof value === "object" && !Array.isArray(value);

const textOf = (content: unknown): string =>
  typeof content === "string" ? content : Array.isArray(content) ? content.map((part) => (isObject(part) && typeof part.text === "string" ? part.text : "")).join("\n") : "";

/** The words of the request, from the first message that carries one. */
function requestOf(messages: JSONObject[]): string {
  for (const message of messages) {
    const match = /Request: (.*)/.exec(textOf(message.content));
    if (message.role === "user" && match) return match[1].trim();
  }
  return "";
}

const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** The page the stand-in writes: small, but every field the schema asks for. */
function page(request: string, answered: string[], looked: string | null): JSONObject {
  const title = request.split(/\s+/).slice(0, 4).join(" ").replace(/^./, (first) => first.toUpperCase()) || "A page";
  const block = (kind: string, fields: JSONObject = {}) => ({ kind, title: "", text: "", ref: "", over: "", items: [], children: [], ...fields });
  return {
    subject: "learning",
    mode: "read",
    title,
    summary: `A page about ${request}, made by Dream's stand-in model.`,
    symbol: "sparkles",
    collections: [],
    question: "",
    inputs: [],
    outputs: [],
    sounds: [],
    figures: [],
    diagrams: [],
    actions: [],
    scenes: [],
    blocks: [
      block("paragraph", { text: `This page was written by the stand-in model that local development uses, so nothing was paid for. It was asked for ${request}.` }),
      block("facts", {
        title: "How it was made",
        items: [
          { label: "Model", value: "Dream's stand-in" },
          ...(looked ? [{ label: "Looked up", value: looked }] : []),
          ...answered.map((line) => ({ label: "Answered", value: line })),
        ],
      }),
    ],
    related: ["How Dream makes a page", "Server-sent events"],
    citations: [],
  };
}

/** A chat completion stream, as model.ts passes one on. */
function stream(pieces: JSONObject[], usage: JSONObject, finish: string): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  const chunk = (delta: JSONObject, finishReason: string | null = null) => `data: ${JSON.stringify({ id: "chatcmpl-fake", object: "chat.completion.chunk", model: "fake", choices: [{ index: 0, delta, finish_reason: finishReason }] })}\n\n`;
  return new ReadableStream<Uint8Array>({
    async start(controller) {
      controller.enqueue(encoder.encode(chunk({ role: "assistant" })));
      for (const delta of pieces) {
        await pause(25);
        controller.enqueue(encoder.encode(chunk(delta)));
      }
      controller.enqueue(encoder.encode(chunk({}, finish)));
      controller.enqueue(encoder.encode(`data: ${JSON.stringify({ id: "chatcmpl-fake", object: "chat.completion.chunk", model: "fake", choices: [], usage })}\n\n`));
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  });
}

/** What the stand-in answers a checked chat completion request (model.ts, upstreamBody). */
export function fakeModel(body: JSONObject): Response {
  const messages = (Array.isArray(body.messages) ? body.messages : []).filter(isObject);
  const request = requestOf(messages);
  const format = isObject(body.response_format) && isObject(body.response_format.json_schema) ? body.response_format.json_schema : {};
  const schema = isObject(format.schema) ? format.schema : {};
  const usage = { prompt_tokens: Math.ceil(JSON.stringify(messages).length / 4), completion_tokens: 300 };
  const answer = (value: unknown) => {
    const text = JSON.stringify(value);
    const pieces: JSONObject[] = [{ reasoning_content: "Thinking it over." }];
    for (let at = 0; at < text.length; at += 40) pieces.push({ content: text.slice(at, at + 40) });
    return pieces;
  };

  let pieces: JSONObject[];
  let finish = "stop";
  if (schema.title === "WireGaps") {
    const asks = /\bmercury\b/i.test(request);
    pieces = answer({
      questions: asks ? [{ question: "Which Mercury?", topic: "Subject", options: ["The planet", "The element", "The god"], personal: false, typing: false, remembered: "" }] : [],
    });
  } else {
    // Each request carries the whole session, so what happened since the last request shows.
    const lastUser = messages.map((message) => message.role).lastIndexOf("user");
    const since = messages.slice(lastUser + 1);
    const looked = since.find((message) => message.role === "tool");
    const tools = Array.isArray(body.tools) ? body.tools.filter(isObject).map((tool) => (isObject(tool.function) ? tool.function.name : "")) : [];
    if (/\blook up\b/i.test(request) && tools.includes("lookup") && !looked) {
      const subject = request.replace(/.*\blook up\b/i, "").trim() || request;
      pieces = [{ tool_calls: [{ index: 0, id: "call-fake-0", type: "function", function: { name: "lookup", arguments: JSON.stringify({ subject, language: "en" }) } }] }];
      finish = "tool_calls";
    } else if (/\bhow (?:long|far)\b/i.test(request) && tools.includes("travel") && !messages.some((message) => message.role === "tool")) {
      // A journey is the phone's to work out (contract.ts), so it's asked, as a model would, once
      // for the page: a repair has the answer already.
      const to = /.*\bto (?:the )?(.+?)[?.!]*$/i.exec(request)?.[1] ?? "there";
      pieces = [{ tool_calls: [{ index: 0, id: "call-fake-travel", type: "function", function: { name: "travel", arguments: JSON.stringify({ name: "trip", from: "current location", to, travel: "driving" }) } }] }];
      finish = "tool_calls";
    } else {
      const asked = messages.filter((message) => message.role === "user").map((message) => textOf(message.content)).join("\n");
      const block = /Before building, the user answered:\n((?:- .*\n?)+)/.exec(asked)?.[1] ?? "";
      const answered = block.split("\n").filter(Boolean).map((line) => line.slice(2));
      const said = looked ? textOf(looked.content) : "";
      const title = looked ? (/Wikipedia, "([^"]+)"/.exec(said)?.[1] ?? (said.split("\n")[0].slice(0, 80) || "nothing found")) : null;
      pieces = answer(page(request, answered, title));
    }
  }
  if (body.stream !== true) {
    const content = pieces.map((piece) => (typeof piece.content === "string" ? piece.content : "")).join("");
    const calls = pieces.flatMap((piece) => (Array.isArray(piece.tool_calls) ? piece.tool_calls : []));
    return Response.json({ id: "chatcmpl-fake", object: "chat.completion", model: "fake", choices: [{ index: 0, message: { role: "assistant", content, ...(calls.length ? { tool_calls: calls } : {}) }, finish_reason: finish }], usage });
  }
  return new Response(stream(pieces, usage, finish), { status: 200, headers: { "Content-Type": "text/event-stream" } });
}
