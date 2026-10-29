// A stand-in for Apple's Push Notification service, on this Mac, for test/push.mjs: it takes
// POST /3/device/<token> as APNs does, keeps every notification it's sent, and answers a token
// marked gone with 410 Unregistered, as Apple does for an app that was deleted.

import { createServer } from "node:http";

export async function startAPNsStub() {
  const sent = [];
  const gone = new Set();
  const server = createServer(async (request, response) => {
    let text = "";
    for await (const chunk of request) text += chunk;
    const token = /^\/3\/device\/([0-9a-f]+)$/.exec(request.url ?? "")?.[1];
    if (request.method !== "POST" || !token) {
      response.writeHead(404, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ reason: "BadPath" }));
      return;
    }
    let body = null;
    try {
      body = JSON.parse(text);
    } catch {
      // Kept as null: the test says what it expected.
    }
    sent.push({ token, headers: request.headers, body });
    if (gone.has(token)) {
      response.writeHead(410, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ reason: "Unregistered", timestamp: Date.now() }));
      return;
    }
    response.writeHead(200, { "apns-id": crypto.randomUUID().toUpperCase() });
    response.end();
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return { base: `http://127.0.0.1:${port}`, sent, gone, stop: () => server.close() };
}
