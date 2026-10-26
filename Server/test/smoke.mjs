// Checks the Worker end to end over HTTP: creating, fetching, the web viewer, the associated
// domains file, and the protections. With no address given, it applies the migrations to a local
// database and starts `wrangler dev` itself.
//
//   npm test                                  local, on a free port
//   DREAM_SHARE_URL=http://127.0.0.1:8787 npm test   against a server that's already running

import { spawn, execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const fixture = readFileSync(join(root, "test/fixtures/split-bill.json"), "utf8");
let failures = 0;

function expect(condition, message) {
  console.log(`${condition ? "  ok  " : "  FAIL"}  ${message}`);
  if (!condition) failures++;
}

async function startLocal() {
  const env = { ...process.env, WRANGLER_SEND_METRICS: "false" };
  execFileSync("npx", ["wrangler", "d1", "migrations", "apply", "dream-share", "--local"], { cwd: root, env, stdio: "ignore" });
  const port = 18_000 + Math.floor(Math.random() * 2_000);
  const child = spawn("npx", ["wrangler", "dev", "--port", String(port), "--ip", "127.0.0.1"], { cwd: root, env, stdio: ["ignore", "pipe", "pipe"] });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("wrangler dev didn't start in 60 s")), 60_000);
    const watch = (chunk) => {
      if (String(chunk).includes("Ready on")) {
        clearTimeout(timer);
        resolve();
      }
    };
    child.stdout.on("data", watch);
    child.stderr.on("data", watch);
    child.on("exit", (code) => reject(new Error(`wrangler dev exited with ${code}`)));
  });
  return { base: `http://127.0.0.1:${port}`, stop: () => child.kill("SIGTERM") };
}

const create = (base, body, type = "application/json") => fetch(`${base}/api/surfaces`, { method: "POST", headers: { "Content-Type": type }, body });

async function run(base) {
  console.log("Associated domains");
  let response = await fetch(`${base}/.well-known/apple-app-site-association`);
  const association = await response.json();
  expect(response.status === 200 && response.headers.get("content-type")?.startsWith("application/json"), "served as JSON");
  // The app ID comes from APP_IDS in wrangler.jsonc.
  const appID = process.env.DREAM_APP_ID ?? "DR99P625RR.xyz.onlychan.Dream";
  expect(association.applinks?.details?.[0]?.appIDs?.includes(appID), `names Dream's app ID, ${appID}`);
  expect(association.applinks?.details?.[0]?.components?.[0]?.["/"] === "/s/*", "claims /s/ links");

  console.log("Creating");
  response = await create(base, fixture);
  const created = await response.json();
  expect(response.status === 201, `201 Created (got ${response.status})`);
  expect(/^[0-9A-Za-z]{10}$/.test(created.id ?? ""), "a ten-character id");
  expect(created.url === `${base}/s/${created.id}`, "a link to the web viewer");
  const second = await (await create(base, fixture)).json();
  expect(second.id && second.id !== created.id, "each share gets its own id");

  console.log("Fetching for the app");
  response = await fetch(`${base}/api/surfaces/${created.id}`);
  const stored = await response.json();
  expect(response.status === 200, "200");
  expect(stored.surface?.title === "Split a bill", "the surface comes back");
  expect(stored.surface && !("answers" in stored.surface), "personal answers are never stored, even when sent");
  expect(stored.values?.bill === 240, "the sharer's numbers, when they chose to share them");
  expect(stored.currency === "USD" && stored.format === 1, "currency and format");
  expect(!("preview" in stored), "the web viewer's working stays on the server");
  expect(!JSON.stringify(stored).includes("Pune"), "the answer's text appears nowhere");

  console.log("Web viewer");
  response = await fetch(`${base}/s/${created.id}`);
  const page = await response.text();
  expect(response.status === 200 && response.headers.get("content-type")?.startsWith("text/html"), "an HTML page");
  expect(response.headers.get("content-security-policy")?.includes("default-src 'none'"), "a strict content security policy, with no scripts");
  expect(page.includes("<h1>Split a bill</h1>"), "the title");
  expect(page.includes('class="katex"'), "maths typeset by KaTeX");
  expect(!page.includes("<script"), "no script tags, even ones written into the surface");
  expect(page.includes("&lt;script&gt;alert(1)&lt;/script&gt;"), "text is escaped");
  expect(page.includes(`href="dream://s/${created.id}"`), "an Open in Dream link");
  expect(page.includes("$69"), "values worked out by the app");
  expect(page.includes("<svg") && page.includes('class="bars"'), "a curve and a bar chart");
  expect(page.includes("Shared with their numbers"), "says when the numbers are the sharer's");
  expect(!page.includes("Pune"), "no personal answers on the page");
  expect(page.includes('property="og:title" content="Split a bill"'), "a link preview title");
  response = await fetch(`${base}/katex/katex.min.css`);
  expect(response.status === 200 && response.headers.get("content-type")?.includes("css"), "KaTeX's stylesheet is served by the Worker");

  console.log("Missing and malformed");
  response = await fetch(`${base}/api/surfaces/ABCDEFGHIJ`);
  expect(response.status === 404, "an unknown id is 404");
  response = await fetch(`${base}/s/not-an-id`);
  expect(response.status === 404 && (await response.text()).includes("The link may be incomplete"), "a malformed link shows a page saying so");
  response = await fetch(`${base}/api/surfaces`);
  expect(response.status === 405, "listing isn't allowed");
  response = await create(base, fixture, "text/plain");
  expect(response.status === 415, "only application/json is read");
  response = await create(base, "{not json");
  expect(response.status === 400, "malformed JSON is refused");
  response = await create(base, JSON.stringify({ format: 1, surface: { summary: "", blocks: [], inputs: [], outputs: [], accent: "blue", symbol: "x" } }));
  expect(response.status === 400, "a surface without a title is refused");
  response = await create(base, JSON.stringify({ format: 1, surface: { title: "x".repeat(250_000) } }));
  expect(response.status === 413, "a body over the size limit is refused");
  let nested = "1";
  for (let i = 0; i < 40; i++) nested = `[${nested}]`;
  response = await create(base, `{"format":1,"surface":{"title":"Deep","summary":"","blocks":${nested},"inputs":[],"outputs":[],"accent":"blue","symbol":"x"}}`);
  expect(response.status === 413, "deep nesting is refused");
  response = await create(base, JSON.stringify({ ...JSON.parse(fixture), values: { "bad name": 1 } }));
  expect(response.status === 400, "values must be numbers by name");

  console.log("Rate limiting");
  let limited = false;
  for (let i = 0; i < 15 && !limited; i++) limited = (await create(base, fixture)).status === 429;
  expect(limited, "too many shares from one address are refused for a while");
}

const server = process.env.DREAM_SHARE_URL ? { base: process.env.DREAM_SHARE_URL.replace(/\/$/, ""), stop() {} } : await startLocal();
try {
  await run(server.base);
} catch (error) {
  console.log(`  FAIL  ${error.stack ?? error}`);
  failures++;
} finally {
  server.stop();
}
console.log(failures ? `\n${failures} failed` : "\nAll passed");
process.exit(failures ? 1 : 0);
