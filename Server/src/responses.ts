// xAI's Responses API, spoken for the app's chat completions. The app (ChatCompletions.swift)
// sends and reads OpenAI-style chat completions; model.ts sends xAI the same request as a
// Responses API call, and turns the answer back into chat completion chunks, so the app doesn't
// change.
//
// Why Responses: xAI only reuses a cached prompt (at about a third of the price) when requests
// carry a cache key. Chat completions take it as the `x-grok-conv-id` header, which Cloudflare's
// AI Gateway doesn't pass on reliably; the Responses API takes it in the body, as
// `prompt_cache_key`, which arrives untouched.
//
// What chat completions have and Responses don't (stop, seed and the penalties) is left out;
// Dream sends none of them. `store: false` keeps xAI from saving the conversation for later turns.
//
// No imports, so test/unit.mjs runs it in Node.

type JSONObject = Record<string, unknown>;

const isObject = (value: unknown): value is JSONObject => value !== null && typeof value === "object" && !Array.isArray(value);

/** A chat completions request, already checked (model.ts), as a Responses API request. */
export function toResponses(chat: JSONObject, cacheKey: string): JSONObject {
  const out: JSONObject = { model: chat.model, input: inputItems(Array.isArray(chat.messages) ? chat.messages : []), store: false, prompt_cache_key: cacheKey };
  if (chat.stream === true) out.stream = true;
  if (Array.isArray(chat.tools)) {
    out.tools = chat.tools.map((tool) => {
      const fn = isObject(tool) && isObject(tool.function) ? tool.function : {};
      return {
        type: "function",
        name: fn.name,
        ...(fn.description === undefined ? {} : { description: fn.description }),
        parameters: fn.parameters ?? { type: "object", properties: {} },
        ...(fn.strict === undefined ? {} : { strict: fn.strict }),
      };
    });
  }
  if (chat.tool_choice !== undefined) {
    const choice = chat.tool_choice;
    out.tool_choice = isObject(choice) ? { type: "function", name: isObject(choice.function) ? choice.function.name : choice.name } : choice;
  }
  if (chat.parallel_tool_calls !== undefined) out.parallel_tool_calls = chat.parallel_tool_calls;
  const format = chat.response_format;
  if (isObject(format) && format.type === "json_schema" && isObject(format.json_schema)) {
    const schema = format.json_schema;
    out.text = { format: { type: "json_schema", name: schema.name ?? "response", schema: schema.schema, ...(schema.strict === undefined ? {} : { strict: schema.strict }) } };
  } else if (isObject(format) && format.type === "json_object") {
    out.text = { format: { type: "json_object" } };
  }
  if (chat.reasoning_effort !== undefined) out.reasoning = { effort: chat.reasoning_effort };
  for (const name of ["temperature", "top_p"]) if (chat[name] !== undefined) out[name] = chat[name];
  if (chat.max_tokens !== undefined) out.max_output_tokens = chat.max_tokens;
  return out;
}

/** Chat messages as Responses input items: tool calls and their outputs become items of their own. */
function inputItems(messages: unknown[]): JSONObject[] {
  const items: JSONObject[] = [];
  for (const message of messages) {
    if (!isObject(message)) continue;
    if (message.role === "tool") {
      items.push({ type: "function_call_output", call_id: String(message.tool_call_id ?? ""), output: plainText(message.content) });
      continue;
    }
    if (message.role === "assistant") {
      const said = plainText(message.content);
      if (said) items.push({ role: "assistant", content: said });
      for (const call of Array.isArray(message.tool_calls) ? message.tool_calls : []) {
        if (!isObject(call)) continue;
        const fn = isObject(call.function) ? call.function : {};
        items.push({
          type: "function_call",
          call_id: String(call.id ?? ""),
          name: String(fn.name ?? ""),
          arguments: typeof fn.arguments === "string" ? fn.arguments : JSON.stringify(fn.arguments ?? {}),
        });
      }
      continue;
    }
    items.push({ role: message.role, content: contentParts(message.content) });
  }
  return items;
}

/** Text stays text; a message with a photo becomes input_text and input_image parts. */
function contentParts(content: unknown): string | JSONObject[] {
  if (!Array.isArray(content)) return plainText(content);
  return content.filter(isObject).map((part) => {
    if (part.type === "image_url" && isObject(part.image_url)) {
      return { type: "input_image", image_url: part.image_url.url, ...(part.image_url.detail ? { detail: part.image_url.detail } : {}) };
    }
    return { type: "input_text", text: String(part.text ?? "") };
  });
}

function plainText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.filter((part) => isObject(part) && typeof part.text === "string").map((part) => (part as JSONObject).text).join("\n");
  return "";
}

/** Responses usage, in chat completions' terms: reasoning is counted apart from completion
 * tokens, as xAI's chat completions count it, and xAI's own cost comes along. */
export function chatUsage(usage: unknown): JSONObject | null {
  if (!isObject(usage)) return null;
  const count = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 0);
  const input = count(usage.input_tokens);
  const output = count(usage.output_tokens);
  const reasoning = count(isObject(usage.output_tokens_details) ? usage.output_tokens_details.reasoning_tokens : 0);
  const out: JSONObject = {
    prompt_tokens: input,
    completion_tokens: Math.max(0, output - reasoning),
    total_tokens: count(usage.total_tokens) || input + output,
    prompt_tokens_details: { cached_tokens: count(isObject(usage.input_tokens_details) ? usage.input_tokens_details.cached_tokens : 0) },
    completion_tokens_details: { reasoning_tokens: reasoning },
  };
  if (typeof usage.cost_in_usd_ticks === "number") out.cost_in_usd_ticks = usage.cost_in_usd_ticks;
  return out;
}

/** A finished Responses answer as a chat completion. */
export function chatCompletion(response: unknown, model: string): JSONObject {
  const answer = isObject(response) ? response : {};
  let content = "";
  const toolCalls: JSONObject[] = [];
  for (const item of Array.isArray(answer.output) ? answer.output : []) {
    if (!isObject(item)) continue;
    if (item.type === "message") {
      for (const part of Array.isArray(item.content) ? item.content : []) if (isObject(part) && part.type === "output_text") content += String(part.text ?? "");
    } else if (item.type === "function_call") {
      toolCalls.push({ id: item.call_id, type: "function", function: { name: item.name, arguments: item.arguments } });
    }
  }
  return {
    id: answer.id ?? "chatcmpl-dream",
    object: "chat.completion",
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [
      {
        index: 0,
        message: { role: "assistant", content: content || (toolCalls.length ? null : ""), ...(toolCalls.length ? { tool_calls: toolCalls } : {}) },
        finish_reason: toolCalls.length ? "tool_calls" : answer.status === "incomplete" ? "length" : "stop",
      },
    ],
    usage: chatUsage(answer.usage),
  };
}

/** A streamed Responses answer, as chat completion chunks, as each event arrives. Text and
 * reasoning go on as deltas; a tool call goes whole, once its arguments are done, as xAI's chat
 * completions send them; the usage and `[DONE]` close it. Events with no chunk of their own go on
 * as comments, so the app still sees the model is working (ModelActivity). */
export function chatStream(upstream: ReadableStream<Uint8Array>, model: string): ReadableStream<Uint8Array> {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const created = Math.floor(Date.now() / 1000);
  let id = "chatcmpl-dream";
  let pending = "";
  let calls = 0;
  let closed = false;
  const chunk = (delta: JSONObject, finish: string | null = null) =>
    `data: ${JSON.stringify({ id, object: "chat.completion.chunk", created, model, choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
  const close = (finish: string, usage: JSONObject | null) => {
    closed = true;
    const end = usage ? `data: ${JSON.stringify({ id, object: "chat.completion.chunk", created, model, choices: [], usage })}\n\n` : "";
    return chunk({}, finish) + end + "data: [DONE]\n\n";
  };
  const translate = (event: JSONObject): string => {
    switch (event.type) {
      case "response.created":
        if (isObject(event.response) && typeof event.response.id === "string") id = event.response.id;
        return chunk({ role: "assistant" });
      case "response.output_text.delta":
        return typeof event.delta === "string" && event.delta ? chunk({ content: event.delta }) : "";
      case "response.reasoning_text.delta":
      case "response.reasoning_summary_text.delta":
        return typeof event.delta === "string" && event.delta ? chunk({ reasoning_content: event.delta }) : "";
      case "response.output_item.done": {
        const item = isObject(event.item) ? event.item : {};
        if (item.type !== "function_call") return ": item\n\n";
        return chunk({ tool_calls: [{ index: calls++, id: item.call_id, type: "function", function: { name: item.name, arguments: item.arguments ?? "" } }] });
      }
      case "response.completed":
      case "response.incomplete": {
        const response = isObject(event.response) ? event.response : {};
        return close(calls > 0 ? "tool_calls" : event.type === "response.incomplete" ? "length" : "stop", chatUsage(response.usage));
      }
      case "response.failed":
      case "error":
        // Ends the answer with nothing more; the app says the model didn't answer.
        return close("stop", null);
      default:
        return `: ${String(event.type ?? "event").replace(/[^\w.]/g, "")}\n\n`;
    }
  };
  const reader = upstream.getReader();
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) {
          if (!closed) controller.enqueue(encoder.encode(close("stop", null)));
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
          if (data === "[DONE]") continue;
          try {
            const event: unknown = JSON.parse(data);
            if (isObject(event)) out += translate(event);
          } catch {
            // Not an event this understands.
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
