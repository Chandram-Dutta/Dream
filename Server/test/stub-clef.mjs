// A stand-in for Cloudflare's Clef Flash on this Mac, so `npm test` checks Auto's route
// (src/route.ts) without asking Workers AI. It answers Clef's typed questions from words in the
// request, and remembers what it was sent, so the test can check what the Worker asked.
//
//   "please fail"   → 500, as if Workers AI were down
//   "nonsense"      → an answer missing its questions
//   "derive"        → maths, demanding
//   "right now"     → needs live facts
//   anything else   → money, simple

import { createServer } from "node:http";

export async function startClefStub() {
  const calls = [];
  const server = createServer(async (request, response) => {
    let text = "";
    for await (const chunk of request) text += chunk;
    if (request.method !== "POST" || request.url !== "/clef") {
      response.writeHead(404);
      return response.end();
    }
    const body = JSON.parse(text || "{}");
    calls.push(body);
    const state = String(body.state ?? "");
    if (state.includes("please fail")) {
      response.writeHead(500, { "Content-Type": "application/json" });
      return response.end(JSON.stringify({ errors: [{ message: "InferenceUpstreamError" }] }));
    }
    const usage = { input_tokens: 900, output_tokens: 0 };
    response.writeHead(200, { "Content-Type": "application/json" });
    if (state.includes("nonsense")) return response.end(JSON.stringify({ model: "clef-flash", answers: { topic: { type: "choice" } }, usage }));
    const topic = state.includes("derive") ? "science" : "money";
    const level = state.includes("derive") ? 2.6 : 0.4;
    const answers = {
      topic: { type: "choice", choice: topic, probabilities: { [topic]: 0.9 }, confidence: 0.8 },
      fresh: { type: "noul", noul: state.includes("right now") ? 0.93 : 0.04 },
      foreign: { type: "noul", noul: 0.02 },
      difficulty: { type: "score", score: level, legend: {}, probabilities: {}, confidence: 0.5 },
    };
    response.end(JSON.stringify({ model: "clef-flash", answers, usage }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return { url: `http://127.0.0.1:${port}/clef`, calls, stop: () => server.close() };
}
