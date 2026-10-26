// A stand-in for xAI's chat completions API on this Mac, so `npm test` checks the model proxy
// without paying for a request. It streams the way xAI does (reasoning, then the answer, then a
// usage chunk), slowly enough to show whether the Worker passes chunks on as they come, and
// remembers what it was sent, so the test can check what the Worker forwarded.

import { createServer } from "node:http";

export const STUB_XAI_KEY = "stub-xai-key";

/** What xAI reported for a real request (grok-4.7, 2026-10-26): reasoning is counted apart from
 * completion_tokens, and the cost comes in ticks of 1e-10 dollars. */
export const USAGE = {
  prompt_tokens: 1261,
  completion_tokens: 9,
  total_tokens: 1326,
  prompt_tokens_details: { text_tokens: 1261, audio_tokens: 0, image_tokens: 0, cached_tokens: 1152 },
  completion_tokens_details: { reasoning_tokens: 56, audio_tokens: 0, accepted_prediction_tokens: 0, rejected_prediction_tokens: 0 },
  num_sources_used: 0,
  cost_in_usd_ticks: 11_840_000,
};

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export async function startXAIStub() {
  const calls = { completions: [], unauthorized: 0 };
  const server = createServer(async (request, response) => {
    let text = "";
    for await (const chunk of request) text += chunk;
    if (request.headers.authorization !== `Bearer ${STUB_XAI_KEY}`) {
      calls.unauthorized++;
      response.writeHead(401, { "Content-Type": "application/json" });
      return response.end(JSON.stringify({ error: "Incorrect API key provided" }));
    }
    if (request.method !== "POST" || request.url !== "/v1/chat/completions") {
      response.writeHead(404);
      return response.end();
    }
    const body = JSON.parse(text || "{}");
    calls.completions.push(body);
    const last = String(body.messages?.at(-1)?.content ?? "");
    if (last.includes("please fail")) {
      response.writeHead(429, { "Content-Type": "application/json" });
      return response.end(JSON.stringify({ error: "rate limited" }));
    }
    if (last.includes("bad schema")) {
      response.writeHead(400, { "Content-Type": "application/json" });
      return response.end(JSON.stringify({ code: "Client specified an invalid argument", error: "Invalid response_format schema" }));
    }
    const id = "chatcmpl-stub";
    if (!body.stream) {
      response.writeHead(200, { "Content-Type": "application/json" });
      return response.end(JSON.stringify({ id, object: "chat.completion", model: body.model, choices: [{ index: 0, message: { role: "assistant", content: "Blue." }, finish_reason: "stop" }], usage: USAGE }));
    }
    response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" });
    const send = (object) => response.write(`data: ${JSON.stringify(object)}\n\n`);
    for (const piece of ["Thinking", " about", " the sky."]) {
      send({ id, object: "chat.completion.chunk", model: body.model, choices: [{ index: 0, delta: { reasoning_content: piece } }] });
      await pause(250);
    }
    // An answer that mentions "usage", to show only the real usage chunk is read as one.
    for (const piece of ['{"answer":"Blue', ' (see "usage":{ notes)', '"}']) {
      send({ id, object: "chat.completion.chunk", model: body.model, choices: [{ index: 0, delta: { content: piece } }] });
      await pause(100);
    }
    if (body.stream_options?.include_usage) send({ id, object: "chat.completion.chunk", model: body.model, choices: [], usage: USAGE });
    response.write("data: [DONE]\n\n");
    response.end();
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return { base: `http://127.0.0.1:${port}`, calls, stop: () => server.close() };
}
