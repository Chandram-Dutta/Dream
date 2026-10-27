// Tools before the schema, for models that can't have both at once. A page's requests carry the
// app's tools (lookup, search, read…) and the JSON schema the answer must fill
// (ChatCompletions.swift). Grok takes both: it calls tools, then writes the JSON. The models
// Workers AI and Sarvam serve follow a schema by holding every token they write to it, so with
// one they can never start a tool call: they write facts from memory instead (benched
// 2026-10-27: asked who won the 2026 World Cup, DeepSeek V4.1 Flash wrote "I'll look this up."
// as the page and Gemma 4 that the final hadn't been played; without the schema, both called
// lookup).
//
// So for those models (`toolsFirst` in models.ts) a round with tools goes first without the
// schema. If the model calls a tool, that round is the answer, and the app runs the tool and asks
// again. Once it starts to write an answer instead, that answer is dropped unread and the same
// round is asked again with the schema, which shapes what it writes. The price is thinking twice
// on the last round. Reasoning and keep-alive comments pass on as they come, so the app sees the
// model working throughout, and the app sees one answer either way. After a few rounds of tools
// the schema holds the model to answering. The tool calls themselves, which no schema held, are
// fitted to their tools' schemas (workersai.ts).
//
// No imports, so test/unit.mjs runs it in Node.

type JSONObject = Record<string, unknown>;

const isObject = (value: unknown): value is JSONObject => value !== null && typeof value === "object" && !Array.isArray(value);

/** Rounds of tool calls a request may already have had and still go first without the schema.
 * After that the schema holds the model to answering: unheld, DeepSeek once looked things up 18
 * times for a bill split and never wrote it. Grok's pages take at most three: search, read, and
 * read again. */
export const TOOL_ROUNDS = 3;

/** Whether a request has tools a model could call and a schema that would stop it: streamed, so
 * an answer can be dropped as soon as it starts, and short of its tool rounds since the request. */
export function asksToolsFirst(chat: JSONObject): boolean {
  const format = chat.response_format;
  if (!(chat.stream === true && Array.isArray(chat.tools) && chat.tools.length > 0 && isObject(format) && format.type === "json_schema")) return false;
  const messages = Array.isArray(chat.messages) ? chat.messages : [];
  let rounds = 0;
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index];
    if (!isObject(message) || message.role === "user") break;
    if (message.role === "assistant" && Array.isArray(message.tool_calls) && message.tool_calls.length) rounds++;
  }
  return rounds < TOOL_ROUNDS;
}

/** The request without its schema, for the round that may call tools. */
export function withoutSchema(chat: JSONObject): JSONObject {
  const { response_format: _format, ...free } = chat;
  return free;
}

/** What one event of a chat completions stream (as workersStream sends it) says about the round:
 * a tool call starting, an answer starting, blank text, the end, or something else. */
function kind(event: string): "tool" | "answer" | "blank" | "end" | "other" {
  const line = event.trim();
  if (line.startsWith(": tool")) return "tool";
  if (!line.startsWith("data:")) return "other";
  const data = line.slice(5).trim();
  if (data === "[DONE]") return "end";
  try {
    const chunk = JSON.parse(data) as JSONObject;
    const choice = Array.isArray(chunk.choices) && isObject(chunk.choices[0]) ? chunk.choices[0] : null;
    const delta = choice && isObject(choice.delta) ? choice.delta : {};
    if (Array.isArray(delta.tool_calls) && delta.tool_calls.length) return "tool";
    if (typeof delta.content === "string" && delta.content.trim()) return "answer";
    if (choice && typeof choice.finish_reason === "string" && choice.finish_reason !== "tool_calls") return "end";
    if (typeof delta.content === "string") return "blank";
  } catch {
    // Not a chunk this understands; it passes on.
  }
  return "other";
}

/** How long to wait before asking again for the answer with the schema, when the model is busy or
 * didn't answer (`shaped` failing outright counts too). By then the round's answer has begun, so
 * the app can't ask again itself, as it does when a round is turned away at the start
 * (DreamModel.swift): it would only see an empty answer. Sarvam turns away a second request in
 * quick succession. */
export const SHAPED_WAITS = [2_000, 6_000];

const AGAIN = new Set([429, 500, 502, 503]);

/** A round's answer: `free` as it is if the model calls a tool there, otherwise the answer
 * `shaped` asks for with the schema. `dropped` hears how many events of a dropped answer came
 * before it was dropped, to count what it cost. */
export function toolsFirst(free: ReadableStream<Uint8Array>, shaped: () => Promise<Response>, dropped: (events: number) => void, waits = SHAPED_WAITS): ReadableStream<Uint8Array> {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  let reader = free.getReader();
  // Deciding while the model thinks; then the round is either a tool call, passed on as it is,
  // or an answer, asked again with the schema and passed on from there.
  let state: "deciding" | "tools" | "shaped" = "deciding";
  let pending = "";
  let events = 0;

  const switchToShaped = async (): Promise<void> => {
    state = "shaped";
    pending = "";
    dropped(events);
    await reader.cancel().catch(() => {});
    let response = await shaped().catch(() => null);
    for (const wait of waits) {
      if (response && (response.ok || !AGAIN.has(response.status))) break;
      await new Promise((resolve) => setTimeout(resolve, wait));
      response = await shaped().catch(() => null);
    }
    // With nothing to pass on, the answer just ends, and the app says the model didn't answer.
    reader = (response?.ok && response.body ? response.body : new Blob(["data: [DONE]\n\n"]).stream()).getReader();
  };

  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      for (;;) {
        const { done, value } = await reader.read();
        if (state === "shaped") {
          if (done) controller.close();
          else controller.enqueue(value);
          return;
        }
        if (done) {
          if (state === "tools") {
            controller.close();
            return;
          }
          // It ended without calling a tool or answering: ask with the schema.
          await switchToShaped();
          continue;
        }
        // The free round's text goes through the one decoder, so a character split between
        // chunks stays whole.
        pending += decoder.decode(value, { stream: true });
        if (state === "tools") {
          const out = pending;
          pending = "";
          if (out) {
            controller.enqueue(encoder.encode(out));
            return;
          }
          continue;
        }
        let out = "";
        let end: number;
        while (state === "deciding" && (end = pending.indexOf("\n\n")) >= 0) {
          const event = pending.slice(0, end + 2);
          pending = pending.slice(end + 2);
          events++;
          const said = kind(event);
          if (said === "tool") {
            // The round is a tool call: everything from here on passes on untouched.
            state = "tools";
            out += event + pending;
            pending = "";
          } else if (said === "answer" || said === "end") {
            await switchToShaped();
          } else if (said === "other") {
            // Reasoning, the role, usage and comments pass on. Blank text before a tool call
            // doesn't, so the app's answer stays clean.
            out += event;
          }
        }
        if (out) {
          controller.enqueue(encoder.encode(out));
          return;
        }
      }
    },
    async cancel(reason) {
      await reader.cancel(reason);
    },
  });
}
