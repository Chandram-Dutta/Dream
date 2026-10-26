// Workers AI's chat completions, as the app reads them. Workers AI already answers in OpenAI's
// chunk format, with three differences this smooths over:
//
// - A tool call arrives in pieces across chunks (its name, then its arguments a bit at a time).
//   The app takes each call whole, as xAI sends them, so the pieces are joined and the call goes
//   on whole when the answer finishes.
// - Usage comes on several chunks, the last with the totals. Only that goes on, once, at the end.
// - What a request cost comes in neurons. It goes on as `cost_in_usd_ticks`, like xAI's, so
//   usage.ts counts it the same way.
//
// No imports, so test/unit.mjs runs it in Node.

type JSONObject = Record<string, unknown>;

const isObject = (value: unknown): value is JSONObject => value !== null && typeof value === "object" && !Array.isArray(value);

/** Workers AI bills $0.011 per 1,000 neurons: 110,000 ticks of 1e-10 dollars each (models.ts). */
const TICKS_PER_NEURON = 110_000;

/** Workers AI usage in the shape usage.ts reads, with neurons as dollars. */
export function workersUsage(usage: unknown): JSONObject | null {
  if (!isObject(usage)) return null;
  const count = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 0);
  const prompt = count(usage.prompt_tokens);
  const completion = count(usage.completion_tokens);
  const out: JSONObject = {
    prompt_tokens: prompt,
    completion_tokens: completion,
    total_tokens: count(usage.total_tokens) || prompt + completion,
    prompt_tokens_details: { cached_tokens: count(isObject(usage.prompt_tokens_details) ? usage.prompt_tokens_details.cached_tokens : 0) },
  };
  if (typeof usage.neurons === "number" && Number.isFinite(usage.neurons) && usage.neurons >= 0) out.cost_in_usd_ticks = Math.round(usage.neurons * TICKS_PER_NEURON);
  return out;
}

/** A finished Workers AI answer, with its usage in Dream's terms. */
export function workersCompletion(answer: unknown, model: string): JSONObject {
  const result = isObject(answer) ? { ...answer } : {};
  result.model = model;
  result.usage = workersUsage(result.usage);
  return result;
}

interface ToolCall {
  id: string;
  name: string;
  arguments: string;
}

/** A streamed Workers AI answer, as the app reads one. */
export function workersStream(upstream: ReadableStream<Uint8Array>, model: string): ReadableStream<Uint8Array> {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const created = Math.floor(Date.now() / 1000);
  let id = "chatcmpl-dream";
  let pending = "";
  let usage: JSONObject | null = null;
  let finish: string | null = null;
  let closed = false;
  const calls: ToolCall[] = [];
  const chunk = (delta: JSONObject, finishReason: string | null = null) =>
    `data: ${JSON.stringify({ id, object: "chat.completion.chunk", created, model, choices: [{ index: 0, delta, finish_reason: finishReason }] })}\n\n`;
  const close = () => {
    closed = true;
    let out = "";
    if (calls.length) {
      out += chunk({ tool_calls: calls.map((call, index) => ({ index, id: call.id, type: "function", function: { name: call.name, arguments: call.arguments } })) });
    }
    out += chunk({}, calls.length ? "tool_calls" : finish ?? "stop");
    const counted = workersUsage(usage);
    if (counted) out += `data: ${JSON.stringify({ id, object: "chat.completion.chunk", created, model, choices: [], usage: counted })}\n\n`;
    return out + "data: [DONE]\n\n";
  };
  const translate = (event: JSONObject): string => {
    if (isObject(event.usage)) {
      // The last usage with anything in it is the total.
      const total = event.usage.total_tokens;
      if (typeof total === "number" && total > 0) usage = event.usage;
    }
    if (typeof event.id === "string" && event.id) id = event.id;
    const choice = Array.isArray(event.choices) && isObject(event.choices[0]) ? event.choices[0] : null;
    if (!choice) return "";
    if (typeof choice.finish_reason === "string" && choice.finish_reason) finish = choice.finish_reason === "tool_calls" ? "tool_calls" : choice.finish_reason;
    const delta = isObject(choice.delta) ? choice.delta : {};
    for (const piece of Array.isArray(delta.tool_calls) ? delta.tool_calls : []) {
      if (!isObject(piece)) continue;
      const index = typeof piece.index === "number" ? piece.index : calls.length;
      const call = (calls[index] ??= { id: "", name: "", arguments: "" });
      if (typeof piece.id === "string" && piece.id) call.id = piece.id;
      const fn = isObject(piece.function) ? piece.function : {};
      if (typeof fn.name === "string" && fn.name) call.name = fn.name;
      if (typeof fn.arguments === "string") call.arguments += fn.arguments;
    }
    const out: JSONObject = {};
    if (typeof delta.role === "string") out.role = delta.role;
    if (typeof delta.content === "string" && delta.content) out.content = delta.content;
    if (typeof delta.reasoning_content === "string" && delta.reasoning_content) out.reasoning_content = delta.reasoning_content;
    // Pieces of a tool call go on as comments, so the app still sees the model working.
    if (!Object.keys(out).length) return Array.isArray(delta.tool_calls) ? ": tool\n\n" : "";
    return chunk(out);
  };
  const reader = upstream.getReader();
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) {
          if (!closed) controller.enqueue(encoder.encode(close()));
          controller.close();
          return;
        }
        pending += decoder.decode(value, { stream: true });
        let out = "";
        let newline: number;
        while ((newline = pending.indexOf("\n")) >= 0) {
          const line = pending.slice(0, newline).trim();
          pending = pending.slice(newline + 1);
          if (!line.startsWith("data:") || closed) continue;
          const data = line.slice(5).trim();
          if (data === "[DONE]") {
            out += close();
            continue;
          }
          try {
            const event: unknown = JSON.parse(data);
            if (isObject(event)) out += translate(event);
          } catch {
            // Not a chunk this understands.
          }
        }
        if (pending.length > 4_000_000) pending = "";
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
