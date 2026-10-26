// A stand-in for xAI's Responses API on this Mac, so `npm test` checks the model proxy without
// paying for a request. It streams the way xAI does (reasoning, then the answer, then the usage
// in `response.completed`), slowly enough to show whether the Worker passes chunks on as they
// come, and remembers what it was sent, so the test can check what the Worker forwarded.

import { createServer } from "node:http";

export const STUB_XAI_KEY = "stub-xai-key";

/** What xAI reported for a real request (grok-4.7, 2026-10-26): output tokens include reasoning,
 * and the cost comes in ticks of 1e-10 dollars. */
export const USAGE = {
  input_tokens: 1261,
  input_tokens_details: { cached_tokens: 1152 },
  output_tokens: 65,
  output_tokens_details: { reasoning_tokens: 56 },
  total_tokens: 1326,
  num_sources_used: 0,
  num_server_side_tools_used: 0,
  cost_in_usd_ticks: 11_840_000,
};

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** The words of the last input item, wherever they are. */
function lastWords(body) {
  const last = body.input?.at(-1);
  if (typeof last?.content === "string") return last.content;
  if (Array.isArray(last?.content)) return last.content.map((part) => part.text ?? "").join(" ");
  return String(last?.output ?? "");
}

export async function startXAIStub() {
  const calls = { responses: [], headers: [], unauthorized: 0 };
  const server = createServer(async (request, response) => {
    let text = "";
    for await (const chunk of request) text += chunk;
    if (request.headers.authorization !== `Bearer ${STUB_XAI_KEY}`) {
      calls.unauthorized++;
      response.writeHead(401, { "Content-Type": "application/json" });
      return response.end(JSON.stringify({ error: "Incorrect API key provided" }));
    }
    if (request.method !== "POST" || request.url !== "/v1/responses") {
      response.writeHead(404);
      return response.end();
    }
    const body = JSON.parse(text || "{}");
    calls.responses.push(body);
    calls.headers.push(request.headers);
    const last = lastWords(body);
    if (last.includes("please fail")) {
      response.writeHead(429, { "Content-Type": "application/json" });
      return response.end(JSON.stringify({ error: "rate limited" }));
    }
    if (last.includes("bad schema")) {
      response.writeHead(400, { "Content-Type": "application/json" });
      return response.end(JSON.stringify({ code: "Client specified an invalid argument", error: "Invalid response_format schema" }));
    }
    const id = "resp-stub";
    const wantsTool = last.includes("use the tool") && body.tools?.length;
    const message = { type: "message", id: "msg-stub", role: "assistant", status: "completed", content: [{ type: "output_text", text: "Blue." }] };
    const call = { type: "function_call", id: "fc-stub", call_id: "call-stub-0", name: body.tools?.[0]?.name, arguments: '{"city":"Pune"}', status: "completed" };
    if (!body.stream) {
      response.writeHead(200, { "Content-Type": "application/json" });
      return response.end(JSON.stringify({ id, object: "response", model: body.model, status: "completed", output: [wantsTool ? call : message], usage: USAGE }));
    }
    response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" });
    let sequence = 0;
    const send = (event) => response.write(`event: ${event.type}\ndata: ${JSON.stringify({ ...event, sequence_number: sequence++ })}\n\n`);
    send({ type: "response.created", response: { id, status: "in_progress", model: body.model } });
    send({ type: "response.in_progress", response: { id, status: "in_progress" } });
    for (const piece of ["Thinking", " about", " the sky."]) {
      send({ type: "response.reasoning_text.delta", item_id: "rs-stub", output_index: 0, content_index: 0, delta: piece });
      await pause(250);
    }
    if (wantsTool) {
      send({ type: "response.output_item.added", output_index: 1, item: { ...call, arguments: "", status: "in_progress" } });
      send({ type: "response.function_call_arguments.delta", item_id: "fc-stub", output_index: 1, delta: '{"city":' });
      send({ type: "response.function_call_arguments.delta", item_id: "fc-stub", output_index: 1, delta: '"Pune"}' });
      send({ type: "response.function_call_arguments.done", item_id: "fc-stub", output_index: 1, arguments: call.arguments });
      send({ type: "response.output_item.done", output_index: 1, item: call });
    } else {
      send({ type: "response.output_item.added", output_index: 1, item: { ...message, content: [], status: "in_progress" } });
      // An answer that mentions "usage", to show only the real usage chunk is read as one.
      for (const piece of ['{"answer":"Blue', ' (see "usage":{ notes)', '"}']) {
        send({ type: "response.output_text.delta", item_id: "msg-stub", output_index: 1, content_index: 0, delta: piece });
        await pause(100);
      }
      send({ type: "response.output_item.done", output_index: 1, item: message });
    }
    send({ type: "response.completed", response: { id, status: "completed", model: body.model, usage: USAGE } });
    response.end();
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return { base: `http://127.0.0.1:${port}`, calls, stop: () => server.close() };
}
