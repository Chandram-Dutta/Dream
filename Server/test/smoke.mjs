// Checks the Worker end to end over HTTP: creating, fetching, the web viewer, the associated
// domains file, web search and reading, and the protections. With no address given, it applies
// the migrations to a local database and starts `wrangler dev` itself, with web search pointed at
// a stand-in for Parallel on this Mac (test/stub-parallel.mjs), so no search is paid for. Reading
// fetches example.com and example.org, and asks Cloudflare's resolver about names, so it needs
// the network.
//
//   npm test                                  local, on a free port
//   DREAM_SHARE_URL=http://127.0.0.1:8787 npm test   against a server that's already running
//
// Against a server that's already running, the web checks need its app key in DREAM_WEB_KEY, and
// only the ones refused before anything is paid for run.

import { spawn, execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { runSharing } from "./sharing.mjs";
import { STUB_KEY, startStub } from "./stub-parallel.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const fixture = readFileSync(join(root, "test/fixtures/split-bill.json"), "utf8");
let failures = 0;

function expect(condition, message) {
  console.log(`${condition ? "  ok  " : "  FAIL"}  ${message}`);
  if (!condition) failures++;
}

/** The app key the local server is started with, beside another to show keys can be rotated. */
const LOCAL_APP_KEY = "test-app-key-0123456789abcdef";
/** Provider calls a day, low enough to reach in a test. */
const LOCAL_DAILY_LIMIT = 4;
/** The admin key the local server is started with (safety.ts). */
const LOCAL_ADMIN_KEY = "test-admin-key-0123456789abcdef-0123456789";
/** A link from before accounts, with no owner, stored straight into the local database. */
const LEGACY_ID = `Old${Math.random().toString(36).slice(2, 9).padEnd(7, "0")}`.slice(0, 10);

async function startLocal(stub) {
  const env = { ...process.env, WRANGLER_SEND_METRICS: "false" };
  execFileSync("npx", ["wrangler", "d1", "migrations", "apply", "dream-share", "--local"], { cwd: root, env, stdio: "ignore" });
  // Each run starts with nothing cached and nothing spent today.
  execFileSync("npx", ["wrangler", "d1", "execute", "dream-share", "--local", "--command", "DELETE FROM web_cache; DELETE FROM web_usage;"], { cwd: root, env, stdio: "ignore" });
  const { answers: _, ...surface } = JSON.parse(fixture).surface;
  const legacy = JSON.stringify({ format: 1, surface }).replace(/'/g, "''");
  execFileSync("npx", ["wrangler", "d1", "execute", "dream-share", "--local", "--command",
    `INSERT INTO surfaces (id, created_at, format, title, summary, has_values, size, body) VALUES ('${LEGACY_ID}', 1767225600, 1, 'Split a bill', '', 0, ${legacy.length}, '${legacy}')`], { cwd: root, env, stdio: "ignore" });
  const port = 18_000 + Math.floor(Math.random() * 2_000);
  // These take the place of anything in .dev.vars, so the real Parallel key is never used here.
  const vars = [
    `PARALLEL_BASE_URL:${stub.base}`,
    `PARALLEL_API_KEY:${STUB_KEY}`,
    `DREAM_APP_KEYS:an-older-key-being-rotated-out,${LOCAL_APP_KEY}`,
    `WEB_DAILY_LIMIT:${LOCAL_DAILY_LIMIT}`,
    // Test users sign in without Apple (auth.ts), and an admin can review reports.
    "DEV_LOGIN:1",
    `ADMIN_KEY:${LOCAL_ADMIN_KEY}`,
  ].flatMap((pair) => ["--var", pair]);
  const child = spawn("npx", ["wrangler", "dev", "--port", String(port), "--ip", "127.0.0.1", ...vars], { cwd: root, env, stdio: ["ignore", "pipe", "pipe"] });
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
  return {
    base: `http://127.0.0.1:${port}`,
    stop() {
      child.kill("SIGTERM");
      // What the test spent and cached would otherwise hold back a `wrangler dev` run afterwards.
      execFileSync("npx", ["wrangler", "d1", "execute", "dream-share", "--local", "--command", "DELETE FROM web_cache; DELETE FROM web_usage;"], { cwd: root, env, stdio: "ignore" });
    },
  };
}

/** Test users' names carry this run's time, so links made in earlier runs don't count against
 * today's limit. */
const RUN = Date.now().toString(36);

/** A session for a test user: from the server's dev sign-in (auth.ts), or DREAM_SESSION for a
 * server without one. */
async function signIn(base, name) {
  const response = await fetch(`${base}/api/dev/session?user=${encodeURIComponent(`${name}-${RUN}`)}`, { method: "POST" });
  if (response.status === 201) {
    const { user, token } = await response.json();
    return { user, token, auth: { Authorization: `Bearer ${token}` } };
  }
  const token = process.env.DREAM_SESSION;
  return token ? { user: null, token, auth: { Authorization: `Bearer ${token}` } } : null;
}

/** Making links needs a signed-in user; this one makes the links `run` checks. */
let sharer = null;
const create = (base, body, type = "application/json") => fetch(`${base}/api/surfaces`, { method: "POST", headers: { "Content-Type": type, ...sharer?.auth }, body });

async function run(base) {
  console.log("Associated domains");
  let response = await fetch(`${base}/.well-known/apple-app-site-association`);
  const association = await response.json();
  expect(response.status === 200 && response.headers.get("content-type")?.startsWith("application/json"), "served as JSON");
  // The app ID comes from APP_IDS in wrangler.jsonc.
  const appID = process.env.DREAM_APP_ID ?? "DR99P625RR.xyz.onlychan.Dream";
  expect(association.applinks?.details?.[0]?.appIDs?.includes(appID), `names Dream's app ID, ${appID}`);
  expect(association.applinks?.details?.[0]?.components?.[0]?.["/"] === "/s/*", "claims /s/ links");

  sharer = await signIn(base, "smoke");
  if (!sharer) {
    console.log("\nSharing: skipped, since this server has no dev sign-in and DREAM_SESSION isn't set.");
    return;
  }
  console.log("Creating");
  response = await create(base, fixture);
  const created = await response.json();
  expect(response.status === 201, `201 Created (got ${response.status})`);
  expect(/^[0-9A-Za-z]{10}$/.test(created.id ?? ""), "a ten-character id");
  // Under `wrangler dev` with the custom domain configured, links name the production host.
  expect(typeof created.url === "string" && new URL(created.url).pathname === `/s/${created.id}`, "a link to the web viewer");
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

  console.log("Credits in the web viewer");
  const cited = JSON.parse(fixture);
  cited.surface.blocks.push({ id: "about", kind: "paragraph", title: "", text: "Tipping customs vary.", ref: "", over: "", items: [], children: [] });
  cited.surface.reference = { title: "Gratuity", extract: "", url: "https://en.wikipedia.org/wiki/Gratuity", imageURL: "https://evil.example/a.png" };
  cited.surface.citations = [
    { title: "Tipping in restaurants, 2026", site: "Etiquette Weekly", url: "https://www.etiquette.example/tipping", date: "2026-10-01" },
    { title: "Bad", site: "Bad", url: "javascript:alert(1)" },
    { title: "Also bad", site: "Bad", url: "https://user:pw@evil.example/" },
    { title: "Quoted\" onmouseover=\"x", site: "<b>Loud</b>", url: "https://loud.example/a?b=1&c=2" },
  ];
  const citedID = (await (await create(base, JSON.stringify(cited))).json()).id;
  const citedPage = await (await fetch(`${base}/s/${citedID}`)).text();
  const footer = citedPage.slice(citedPage.indexOf('<footer class="source">'));
  expect(footer.includes('href="https://en.wikipedia.org/wiki/Gratuity"') && footer.includes('href="https://www.etiquette.example/tipping"'), "every source is linked, Wikipedia first");
  expect(footer.includes(">Wikipedia</a>, ") && footer.includes(">Etiquette Weekly</a>") && footer.includes("CC BY-SA 4.0"), "by site name, with Wikipedia's licence");
  expect(!footer.includes("javascript:") && !footer.includes("user:pw") && !citedPage.includes("evil.example/a.png"), "only http(s) pages, and no pictures from elsewhere");
  expect(footer.includes("&lt;b&gt;Loud&lt;/b&gt;") && !footer.includes('" onmouseover') && footer.includes("b=1&amp;c=2"), "names, titles and addresses are escaped");
  expect(footer.includes('rel="nofollow noopener noreferrer"'), "links don't vouch for the pages or tell them who sent the reader");

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

  console.log("Directory of MCP servers (reads the real registry)");
  response = await fetch(`${base}/api/mcp/featured`);
  const featured = (await response.json()).servers ?? [];
  const named = Object.fromEntries(featured.map((server) => [server.name, server]));
  expect(response.status === 200 && featured.length >= 6, `featured servers (${featured.length})`);
  expect(named.DeepWiki?.signIn === false && named.Linear?.signIn === true, "each says whether it needs a sign-in");
  expect(featured.every((server) => server.url.startsWith("https://") && server.featured), "every one is https, and marked featured");
  expect(!named.Figma, "Figma, which wouldn't register Dream, isn't featured");
  expect(named.Atlassian?.aliases?.includes("Jira"), "other names for a service, for noticing it in a request");
  response = await fetch(`${base}/api/mcp/servers?search=linear`);
  const found = (await response.json()).servers ?? [];
  expect(response.status === 200 && found.some((server) => server.url === "https://mcp.linear.app/mcp" && server.name === "Linear"), `searching the registry finds Linear (${found.length} found)`);
  expect(found.length > 0 && found.every((server) => server.url.startsWith("https://") && !server.url.includes("{")), "only servers the app can use");
  expect(found.every((server) => !server.icon || /\.(png|jpe?g|webp)(\?|$)/i.test(server.icon)), "icons are bitmaps, never SVG");
  expect(response.headers.get("cache-control")?.includes("max-age=3600"), "kept for an hour");
  response = await fetch(`${base}/api/mcp/servers?search=Linear`);
  expect((await response.json()).servers?.length === found.length, "the same search, in other letters, is the same answer");
  response = await fetch(`${base}/api/mcp/servers?search=${"x".repeat(100)}`);
  expect(response.status === 400, "a search that's too long is refused");
  response = await fetch(`${base}/api/mcp/featured`, { method: "POST" });
  expect(response.status === 405, "the directory is read-only");
  response = await fetch(`${base}/api/mcp/elsewhere`);
  expect(response.status === 404, "nothing else under /api/mcp/");

  console.log("Rate limiting");
  let limited = false;
  for (let i = 0; i < 15 && !limited; i++) limited = (await create(base, fixture)).status === 429;
  expect(limited, "too many shares from one account are refused for a while");
}

/** Web search and reading. With the stand-in (`stub`), everything; against a running server,
 * only what's refused before anything is paid for. */
async function runWeb(base, key, stub) {
  const local = stub !== null;
  const post = (path, body, { auth = key, type = "application/json" } = {}) =>
    fetch(`${base}${path}`, {
      method: "POST",
      headers: { "Content-Type": type, ...(auth ? { Authorization: `Bearer ${auth}` } : {}) },
      body: typeof body === "string" ? body : JSON.stringify(body),
    });

  console.log("Web search: who may ask, and what");
  let response = await post("/api/search", { query: "budget phones" }, { auth: null });
  expect(response.status === 401, "no app key is refused");
  response = await post("/api/search", { query: "budget phones" }, { auth: "a-wrong-key-of-a-good-length" });
  expect(response.status === 401, "a wrong key is refused");
  response = await fetch(`${base}/api/search`);
  expect(response.status === 405, "only POST");
  response = await post("/api/search", "query=phones", { type: "text/plain" });
  expect(response.status === 415, "only application/json");
  response = await post("/api/search", { query: "  " });
  expect(response.status === 400, "an empty query is refused");
  response = await post("/api/search", { query: "phones ".repeat(60) });
  expect(response.status === 400, "a query over 300 characters is refused");
  response = await post("/api/search", { query: "phones", count: "lots" });
  expect(response.status === 400, "count is a number");
  response = await post("/api/search", { query: "phones", freshness: "hourly" });
  expect(response.status === 400, "freshness is day, week, month or year");
  response = await post("/api/search", { query: "x".repeat(5_000) });
  expect(response.status === 413, "a large body is refused before it's read");
  if (local) expect(stub.calls.search.length === 0 && stub.calls.unauthorized === 0, "nothing refused reached the provider");

  console.log("Reading: addresses it refuses");
  const refused = [
    "file:///etc/passwd",
    "ftp://example.com/",
    "javascript:alert(1)",
    "http://127.0.0.1:8787/api/surfaces",
    "http://localhost/",
    "http://[::1]/",
    "http://10.0.0.5/",
    "http://192.168.1.1/",
    "http://169.254.169.254/latest/meta-data/",
    "http://2130706433/",
    "http://0x7f000001/",
    "http://[::ffff:127.0.0.1]/",
    "http://user:pw@example.com/",
    "https://example.com:22/",
    "http://printer.local/",
    "http://metadata.google.internal/",
    // A public-looking name that resolves to this machine.
    "http://127.0.0.1.nip.io/",
  ];
  for (const url of refused) {
    response = await post("/api/read", { url });
    expect(response.status === 400, `${url} is refused`);
  }
  if (local) expect(stub.calls.extract.length === 0, "none of them reached the provider");
  response = await fetch(`${base}/reader`);
  expect(response.status === 200 && (await response.text()).includes("User-agent: DreamReader"), "the reader explains itself to site owners");
  if (!local) return;

  console.log("Web search");
  response = await post("/api/search", { query: "best budget phones India", objective: "Which budget phones are best in India now?", count: 3, freshness: "week", region: "IN" });
  const found = await response.json();
  expect(response.status === 200 && found.cached === false && found.provider === "parallel", "200, from the provider");
  const sent = stub.calls.search.at(-1);
  expect(sent?.search_queries?.[0] === "best budget phones India" && sent?.objective === "Which budget phones are best in India now?", "the query and objective, as Parallel takes them");
  expect(sent?.mode === "fast" && sent?.advanced_settings?.max_results === 3 && sent?.advanced_settings?.location === "in", "fast mode, the count and the region");
  const week = new Date(Date.now() - 7 * 86_400_000).toISOString().slice(0, 10);
  expect(sent?.advanced_settings?.source_policy?.after_date === week, "freshness as the first day to look from");
  const [first, second] = found.results ?? [];
  expect(first?.title === "Best budget phones, October 2026" && first?.site === "gsmarena.com" && first?.date === "2026-10-20", "title, site and date");
  expect(first?.snippet?.startsWith("Top picks The Redmi 15 costs ₹12,999") && !first.snippet.includes("]("), "the snippet as plain text");
  const text = JSON.stringify(found);
  expect(!text.includes("javascript:") && !text.includes("secret@") && found.results.every((result) => /^https?:\/\//.test(result.url)), "only http(s) addresses, without credentials");
  expect(found.results.length === 2 && second?.url === "https://www.91mobiles.com/list/phones-under-15000" && second?.title === "91mobiles.com", "repeats dropped, and a missing title filled with the site");
  response = await post("/api/search", { query: "Best budget phones   india", objective: "Which budget phones are best in India now?", count: 3, freshness: "week", region: "in" });
  expect((await response.json()).cached === true && stub.calls.search.length === 1, "asked again, it comes from the cache");

  console.log("Reading a page");
  response = await post("/api/read", { url: "https://example.com/#top", focus: "what the domain is for" });
  const page = await response.json();
  expect(response.status === 200 && page.via === "parallel" && page.cached === false, `read through the provider (got ${response.status} ${page.error ?? page.via})`);
  expect(page.text?.includes("STUB EXCERPT") && page.excerpted === true, "the parts about the focus");
  expect(page.title === "Example Domain" && page.site === "example.com", "the title from the page itself, and the site");
  expect(page.canonical?.startsWith("https://example.com/"), "a canonical address");
  const asked = stub.calls.extract.at(-1);
  expect(asked?.urls?.[0] === "https://example.com/" && asked?.objective === "what the domain is for" && asked?.advanced_settings?.full_content, "the address without its fragment, the focus, and the page from the top too");
  response = await post("/api/read", { url: "https://example.com/", focus: "what the domain is for" });
  expect((await response.json()).cached === true && stub.calls.extract.length === 1, "read again, it comes from the cache");
  response = await post("/api/read", { url: "https://example.org/", maxChars: 500 });
  const own = await response.json();
  expect(response.status === 200 && own.via === "fetch" && own.title === "Example Domain" && /this domain is for use/i.test(own.text ?? ""), `when the provider can't read a page, Dream's own fetch does (got ${response.status} ${own.error ?? own.via})`);
  expect(!/<|s\.js|color-scheme/.test(own.text), "only the page's words: no markup, styles or scripts");
  expect(own.text.length <= 502 && own.excerpted === false, "text is capped");

  console.log("Daily budget");
  // Spent so far: one search, and two reads. Each kind has its own budget.
  let stopped = -1;
  for (let i = 0; i < 6 && stopped < 0; i++) {
    if ((await post("/api/search", { query: `budget check ${i}` })).status === 503) stopped = i;
  }
  expect(stopped === LOCAL_DAILY_LIMIT - 1, `searches stop for the day at the limit (after ${stopped} more)`);
  expect(stub.calls.search.length === LOCAL_DAILY_LIMIT, "and the provider isn't asked past it");

  console.log("Rate limiting");
  let limited = false;
  for (let i = 0; i < 40 && !limited; i++) limited = (await post("/api/search", { query: "budget phones" })).status === 429;
  expect(limited, "too many searches from one address are refused for a while");
  limited = false;
  for (let i = 0; i < 40 && !limited; i++) limited = (await post("/api/read", { url: "http://localhost/" })).status === 429;
  expect(limited, "and too many reads");
}

const remote = process.env.DREAM_SHARE_URL;
const stub = remote ? null : await startStub();
const server = remote ? { base: remote.replace(/\/$/, ""), stop() {} } : await startLocal(stub);
try {
  await run(server.base);
  // Owners, reports, blocks and the admin need several test users, so only run locally.
  if (!remote) await runSharing(server.base, { expect, signIn: (name) => signIn(server.base, name), fixture, adminKey: LOCAL_ADMIN_KEY, legacyID: LEGACY_ID });
  const key = remote ? process.env.DREAM_WEB_KEY : LOCAL_APP_KEY;
  if (key) await runWeb(server.base, key, stub);
  else console.log("\nWeb search and reading: skipped, since DREAM_WEB_KEY isn't set for this server.");
} catch (error) {
  console.log(`  FAIL  ${error.stack ?? error}`);
  failures++;
} finally {
  server.stop();
  stub?.stop();
}
console.log(failures ? `\n${failures} failed` : "\nAll passed");
process.exit(failures ? 1 : 0);
