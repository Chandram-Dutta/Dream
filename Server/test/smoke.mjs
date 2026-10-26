// Checks the Worker end to end over HTTP: creating, fetching, the web viewer, the associated
// domains file, web search and reading, the policy pages, crash reports, the model proxy,
// allowances, Dream Plus, App Attest, and the protections. With no address given, it applies the migrations to a local database and
// starts `wrangler dev` itself, with web search pointed at a stand-in for Parallel and the model
// at a stand-in for xAI on this Mac (test/stub-parallel.mjs, test/stub-xai.mjs), so nothing is
// paid for, and with test roots for the App Store and App Attest (test/vectors.mjs). Reading
// fetches example.com and example.org, and asks Cloudflare's resolver about names, so it needs
// the network.
//
//   npm test                                  local, on a free port
//   DREAM_SHARE_URL=http://127.0.0.1:8787 npm test   against a server that's already running
//
// Against a server that's already running, the web and model checks need its app key in
// DREAM_WEB_KEY and a session in DREAM_SESSION, and only the ones refused before anything is
// paid for run. Crash reports are only stored locally, and the diagnostics summary is only read
// there, with a key made for the test.

import { spawn, execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import { runSharing } from "./sharing.mjs";
import { STUB_KEY, startStub } from "./stub-parallel.mjs";
import { runSync } from "./sync.mjs";
import { STUB_XAI_KEY, startXAIStub } from "./stub-xai.mjs";
import { appStoreChain, assertion, attest, attestRoot, jws, requestData, transaction } from "./vectors.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const fixture = readFileSync(join(root, "test/fixtures/split-bill.json"), "utf8");
const diagnostics = readFileSync(join(root, "test/fixtures/diagnostics.json"), "utf8");
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
/** What one person may keep in sync, small enough to fill in a test. */
const LOCAL_SYNC_QUOTA = 3_000_000;
/** Allowances low enough to reach in a test. */
const LOCAL_ALLOWANCES = { free: { pagesPerDay: 2, searchesPerDay: 10 } };
/** The roots the local server trusts besides Apple's, made for this run. */
const appStore = appStoreChain();
const attestCA = attestRoot();
/** Everything the test writes, cleared before and after so runs don't affect each other. */
const CLEAR = ["web_cache", "web_usage", "usage", "usage_pages", "spend", "subscriptions", "appstore_notifications", "attest_keys", "attest_challenges", "diagnostics"].map((table) => `DELETE FROM ${table};`).join(" ");

async function startLocal(stub, xai) {
  const env = { ...process.env, WRANGLER_SEND_METRICS: "false" };
  execFileSync("npx", ["wrangler", "d1", "migrations", "apply", "dream-share", "--local"], { cwd: root, env, stdio: "ignore" });
  // Each run starts with nothing cached and nothing spent today.
  execFileSync("npx", ["wrangler", "d1", "execute", "dream-share", "--local", "--command", CLEAR], { cwd: root, env, stdio: "ignore" });
  const { answers: _, ...surface } = JSON.parse(fixture).surface;
  const legacy = JSON.stringify({ format: 1, surface }).replace(/'/g, "''");
  execFileSync("npx", ["wrangler", "d1", "execute", "dream-share", "--local", "--command",
    `INSERT INTO surfaces (id, created_at, format, title, summary, has_values, size, body) VALUES ('${LEGACY_ID}', 1767225600, 1, 'Split a bill', '', 0, ${legacy.length}, '${legacy}')`], { cwd: root, env, stdio: "ignore" });
  const port = 18_000 + Math.floor(Math.random() * 2_000);
  // These take the place of anything in .dev.vars, so the real Parallel and xAI keys are never used here.
  const vars = [
    `PARALLEL_BASE_URL:${stub.base}`,
    `PARALLEL_API_KEY:${STUB_KEY}`,
    `DREAM_APP_KEYS:an-older-key-being-rotated-out,${LOCAL_APP_KEY}`,
    `WEB_DAILY_LIMIT:${LOCAL_DAILY_LIMIT}`,
    // Test users sign in without Apple (auth.ts), and an admin can review reports.
    "DEV_LOGIN:1",
    `ADMIN_KEY:${LOCAL_ADMIN_KEY}`,
    `SYNC_QUOTA_BYTES:${LOCAL_SYNC_QUOTA}`,
    `XAI_BASE_URL:${xai.base}`,
    `XAI_API_KEY:${STUB_XAI_KEY}`,
    "MAX_OUTPUT_TOKENS:4000",
    `ALLOWANCES:${JSON.stringify(LOCAL_ALLOWANCES)}`,
    `APPSTORE_TEST_ROOT:${appStore.rootBase64}`,
    `ATTEST_TEST_ROOT:${attestCA.rootBase64}`,
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
      execFileSync("npx", ["wrangler", "d1", "execute", "dream-share", "--local", "--command", CLEAR], { cwd: root, env, stdio: "ignore" });
    },
  };
}

/** One read of the local database while `wrangler dev` runs, straight from its SQLite file:
 * `wrangler d1 execute` at the same time can upset the running server. */
function query(sql) {
  const folder = join(root, ".wrangler/state/v3/d1/miniflare-D1DatabaseObject");
  const file = readdirSync(folder).find((name) => name.endsWith(".sqlite") && name !== "metadata.sqlite");
  const db = new DatabaseSync(join(folder, file), { readOnly: true });
  try {
    return db.prepare(sql).all();
  } finally {
    db.close();
  }
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
async function runWeb(base, key, session, stub) {
  const local = stub !== null;
  const post = (path, body, { auth = key, signedIn = session, type = "application/json" } = {}) =>
    fetch(`${base}${path}`, {
      method: "POST",
      headers: { "Content-Type": type, ...(auth ? { "X-Dream-Key": auth } : {}), ...(signedIn ? { Authorization: `Bearer ${signedIn}` } : {}) },
      body: typeof body === "string" ? body : JSON.stringify(body),
    });

  console.log("Web search: who may ask, and what");
  let response = await post("/api/search", { query: "budget phones" }, { signedIn: null });
  expect(response.status === 401 && response.headers.get("www-authenticate") === "Bearer", "no session is refused");
  response = await fetch(`${base}/api/search`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` }, body: "{}" });
  expect(response.status === 401, "the app key in Authorization, where it used to go, isn't a session");
  response = await post("/api/search", { query: "budget phones" }, { auth: null });
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

  console.log("Web allowance per account");
  const other = await signIn(base, "web-allowance");
  let refusal = null;
  for (let i = 0; i < LOCAL_ALLOWANCES.free.searchesPerDay + 2 && !refusal; i++) {
    const answer = await post("/api/search", { query: `allowance check ${i}` }, { signedIn: other.token });
    if (answer.status === 402) refusal = { at: i, body: await answer.json() };
  }
  expect(refusal?.at === LOCAL_ALLOWANCES.free.searchesPerDay, `a free account's searches stop at its daily allowance (after ${refusal?.at})`);
  expect(refusal?.body.upgrade === true && /free web searches/.test(refusal?.body.error ?? ""), "saying so plainly, with Dream Plus as the way to more");
  expect(query(`SELECT searches FROM usage WHERE user_id = '${other.user}' AND period = '${new Date().toISOString().slice(0, 10)}'`)[0]?.searches === LOCAL_ALLOWANCES.free.searchesPerDay, "searches are counted per account, by day");

  console.log("Rate limiting");
  let limited = false;
  for (let i = 0; i < 40 && !limited; i++) limited = (await post("/api/search", { query: "budget phones" })).status === 429;
  expect(limited, "too many searches from one address are refused for a while");
  limited = false;
  for (let i = 0; i < 40 && !limited; i++) limited = (await post("/api/read", { url: "http://localhost/" })).status === 429;
  expect(limited, "and too many reads");
}

/** The model proxy, allowances, Dream Plus and App Attest, against the local server and the
 * stand-in for xAI. */
async function runPlan(base, xai) {
  const me = await signIn(base, "plan");
  const today = new Date().toISOString().slice(0, 10);
  const ask = (body, { session = me.token, key = LOCAL_APP_KEY, page, headers = {} } = {}) =>
    fetch(`${base}/api/model`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(session ? { Authorization: `Bearer ${session}` } : {}),
        ...(key ? { "X-Dream-Key": key } : {}),
        ...(page ? { "X-Dream-Page": page } : {}),
        ...headers,
      },
      body: typeof body === "string" ? body : JSON.stringify(body),
    });
  const hello = (extra = {}) => ({ model: "grok-4.7", messages: [{ role: "system", content: "Answer briefly." }, { role: "user", content: "What colour is the sky?" }], ...extra });
  const usage = async (token = me.token) => (await fetch(`${base}/api/usage`, { headers: { Authorization: `Bearer ${token}` } })).json();
  const settle = () => new Promise((resolve) => setTimeout(resolve, 400));

  console.log("Model: who may ask, and what");
  let response = await ask(hello(), { session: null });
  expect(response.status === 401, "no session is refused");
  response = await ask(hello(), { key: null });
  expect(response.status === 401 && (await response.json()).error === "This is for the Dream app.", "a session without the app's proof is refused");
  response = await fetch(`${base}/api/model`, { headers: { Authorization: `Bearer ${me.token}` } });
  expect(response.status === 405, "only POST");
  response = await ask(JSON.stringify(hello()), { headers: { "Content-Type": "text/plain" } });
  expect(response.status === 415, "only application/json");
  response = await ask(hello({ model: "grok-5-heavy" }));
  expect(response.status === 400 && /doesn't offer that model/.test((await response.json()).error), "a model that isn't on the list is refused");
  response = await ask(hello({ tools: [{ type: "web_search" }] }));
  expect(response.status === 400, "a provider's paid server-side tools are refused");
  response = await ask(hello({ messages: [{ role: "user", content: "x".repeat(2_100_000) }] }));
  expect(response.status === 413, "a body over 2 MB is refused");
  expect(xai.calls.completions.length === 0 && xai.calls.unauthorized === 0, "nothing refused reached xAI");

  console.log("Model: streaming through");
  const started = Date.now();
  response = await ask(hello({ stream: true, max_tokens: 90_000, n: 3, search_parameters: { mode: "on" }, reasoning_effort: "low" }), { page: "page-a-0001" });
  expect(response.status === 200 && response.headers.get("content-type")?.startsWith("text/event-stream"), "200, as server-sent events");
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let streamed = "";
  let firstAt = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!firstAt) firstAt = Date.now() - started;
    streamed += decoder.decode(value, { stream: true });
  }
  const total = Date.now() - started;
  expect(firstAt > 0 && total - firstAt >= 600, `chunks arrive as xAI sends them, not all at the end (first after ${firstAt} ms of ${total} ms)`);
  expect(streamed.includes('"reasoning_content":"Thinking"') && streamed.indexOf("Thinking") < streamed.indexOf("Blue"), "reasoning comes through first, so the app sees the model working");
  expect(streamed.includes('"usage":{') && streamed.trimEnd().endsWith("data: [DONE]"), "then the answer, the usage and [DONE], byte for byte");
  const sent = xai.calls.completions.at(-1);
  expect(sent?.max_tokens === 4000 && sent?.stream_options?.include_usage === true && sent?.reasoning_effort === "low", "xAI got max_tokens capped, a request for usage, and the reasoning effort");
  expect(sent && !("n" in sent) && !("search_parameters" in sent), "and nothing Dream doesn't use");

  console.log("Model: errors");
  response = await ask(hello({ messages: [{ role: "user", content: "please fail" }] }));
  expect(response.status === 503 && response.headers.get("retry-after") === "20", "xAI's rate limit is a 503 to try again shortly");
  response = await ask(hello({ messages: [{ role: "user", content: "bad schema" }] }));
  expect(response.status === 400 && /Invalid response_format schema/.test((await response.json()).error), "a request xAI calls malformed says why");

  console.log("Allowance: pages");
  response = await ask(hello({ stream: true }), { page: "page-a-0001" });
  await response.text();
  response = await ask(hello());
  const plain = await response.json();
  expect(response.status === 200 && plain.choices?.[0]?.message?.content === "Blue." && plain.usage?.prompt_tokens === 1261, "a small job that isn't a page goes through, not streamed");
  await settle();
  let status = await usage();
  expect(status.plan === "free" && status.pages.today === 1 && status.pages.perDay === LOCAL_ALLOWANCES.free.pagesPerDay, `two requests for the same page count as one page (${status.pages?.today})`);
  expect(status.accountToken === me.user && status.subscription === null && status.plans?.plus?.pagesPerDay > status.plans?.free?.pagesPerDay, "with the account's purchase token, and what Dream Plus adds");
  const [row] = query(`SELECT tokens_in, tokens_cached, tokens_out, cost_micros FROM usage WHERE user_id = '${me.user}' AND period = '${today}'`);
  // Three requests reached xAI and were answered: two streamed for page a, and one plain. Errors cost nothing.
  expect(row?.tokens_in === 3 * 1261 && row?.tokens_cached === 3 * 1152 && row?.tokens_out === 3 * 65, `tokens are counted from xAI's usage, reasoning as output (${JSON.stringify(row)})`);
  expect(row?.cost_micros === 3 * 1184, "and what they cost, from xAI's own figure");
  expect(query(`SELECT cost_micros FROM usage WHERE user_id = '${me.user}' AND period = '${today.slice(0, 7)}'`)[0]?.cost_micros === 3 * 1184, "by month too");
  expect(query(`SELECT cost_micros FROM usage_pages WHERE user_id = '${me.user}' AND page = 'page-a-0001'`)[0]?.cost_micros === 2 * 1184, "and by page");
  response = await ask(hello(), { page: "page-b-0001" });
  expect(response.status === 200, "a second page is allowed");
  response = await ask(hello(), { page: "page-c-0001" });
  const refused = await response.json();
  expect(response.status === 402 && refused.upgrade === true && refused.reason === "allowance", "a third, past the free allowance, is 402 with a way to Dream Plus");
  expect(refused.error === `You've made today's ${LOCAL_ALLOWANCES.free.pagesPerDay} free pages. You can make more tomorrow, or now with Dream Plus.`, "saying so plainly");
  expect(Number(response.headers.get("retry-after")) > 0 && refused.resetsAt > Date.now() / 1000, "and when more come");
  response = await ask(hello(), { page: "page-b-0001" });
  expect(response.status === 200, "a page already started can finish");
  response = await ask(hello());
  expect(response.status === 200, "small jobs that aren't pages still go");

  console.log("Dream Plus: purchases from the app");
  const bought = transaction({ appAccountToken: me.user.toUpperCase(), originalTransactionId: "7000000000000001", transactionId: "7000000000000001" });
  response = await fetch(`${base}/api/appstore/transactions`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${me.token}` }, body: JSON.stringify({ signedTransactions: [jws(appStore, bought)] }) });
  status = await response.json();
  expect(response.status === 200 && status.plan === "plus" && status.subscription?.product === "xyz.onlychan.dream.plus.monthly", "a signed purchase makes the account Dream Plus");
  response = await ask(hello(), { page: "page-c-0001" });
  expect(response.status === 200, "and the next page goes through");
  const theirs = await signIn(base, "plan-other");
  response = await fetch(`${base}/api/appstore/transactions`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${theirs.token}` }, body: JSON.stringify({ signedTransactions: [jws(appStore, bought)] }) });
  expect(response.status === 409, "someone else can't claim it");
  response = await fetch(`${base}/api/appstore/transactions`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${theirs.token}` }, body: JSON.stringify({ signedTransactions: [jws(appStore, transaction({ originalTransactionId: "7000000000000001" }))] }) });
  expect(response.status === 409, "even without an account token");
  response = await fetch(`${base}/api/appstore/transactions`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${theirs.token}` }, body: JSON.stringify({ signedTransactions: [jws(appStoreChain(), transaction({ appAccountToken: theirs.user }))] }) });
  expect(response.status === 400, "a purchase not signed by the App Store is refused");
  response = await fetch(`${base}/api/appstore/transactions`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${theirs.token}` }, body: JSON.stringify({ signedTransactions: [jws(appStore, transaction({ appAccountToken: theirs.user, bundleId: "com.example.other", originalTransactionId: "7000000000000009" }))] }) });
  expect(response.status === 400, "so is one for another app");
  response = await fetch(`${base}/api/appstore/transactions`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
  expect(response.status === 401, "purchases need a session");

  console.log("Dream Plus: App Store Server Notifications");
  const notify = (payload) => fetch(`${base}/api/appstore/notifications`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ signedPayload: jws(appStore, payload) }) });
  const notification = (type, signedTransaction, extra = {}) => ({
    notificationType: type,
    notificationUUID: randomUUID(),
    data: { bundleId: "xyz.onlychan.Dream", bundleVersion: "1", environment: "Sandbox", signedTransactionInfo: signedTransaction, status: 1 },
    version: "2.0",
    signedDate: Date.now(),
    ...extra,
  });
  const refund = notification("REFUND", jws(appStore, { ...bought, revocationDate: Date.now(), revocationReason: 0, signedDate: Date.now() + 1_000 }));
  response = await notify(refund);
  expect(response.status === 200 && (await usage()).plan === "free", "a refund ends Dream Plus");
  response = await notify(refund);
  expect(response.status === 200, "the same notification again is fine");
  response = await notify(notification("DID_RENEW", jws(appStore, { ...bought, signedDate: Date.now() - 60_000 })));
  expect(response.status === 200 && (await usage()).plan === "free", "an older state arriving late doesn't undo the refund");
  response = await notify({ ...notification("SUBSCRIBED", jws(appStore, transaction({ appAccountToken: theirs.user, originalTransactionId: "7000000000000002", transactionId: "7000000000000002", productId: "xyz.onlychan.dream.plus.yearly" }))), subtype: "INITIAL_BUY" });
  const subscribed = await usage(theirs.token);
  expect(response.status === 200 && subscribed.plan === "plus" && subscribed.subscription?.product === "xyz.onlychan.dream.plus.yearly", "a purchase the server hears of first is tied to the account the app named");
  const lapsed = transaction({ appAccountToken: theirs.user, originalTransactionId: "7000000000000002", transactionId: "7000000000000003", expiresDate: Date.now() - 1_000, signedDate: Date.now() + 2_000 });
  const graceful = notification("DID_FAIL_TO_RENEW", jws(appStore, lapsed), { subtype: "GRACE_PERIOD" });
  graceful.data.signedRenewalInfo = jws(appStore, { originalTransactionId: "7000000000000002", autoRenewStatus: 1, isInBillingRetryPeriod: true, gracePeriodExpiresDate: Date.now() + 6 * 86_400_000, environment: "Sandbox", signedDate: Date.now() + 2_000 });
  response = await notify(graceful);
  expect(response.status === 200 && (await usage(theirs.token)).plan === "plus", "a billing grace period keeps Dream Plus going");
  response = await notify(notification("EXPIRED", jws(appStore, { ...lapsed, signedDate: Date.now() + 3_000 }), { subtype: "BILLING_RETRY" }));
  expect(response.status === 200 && (await usage(theirs.token)).plan === "free", "and when it expires, it ends");
  response = await notify(notification("SUBSCRIBED", jws(appStore, transaction({ appAccountToken: randomUUID(), originalTransactionId: "7000000000000004" }))));
  expect(response.status === 200, "a purchase for no one Dream knows is acknowledged and left alone");
  response = await notify({ notificationType: "TEST", notificationUUID: randomUUID(), data: { bundleId: "xyz.onlychan.Dream", environment: "Sandbox" }, version: "2.0", signedDate: Date.now() });
  expect(response.status === 200, "a test notification is acknowledged");
  response = await fetch(`${base}/api/appstore/notifications`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ signedPayload: jws(appStoreChain(), notification("REFUND", jws(appStore, bought))) }) });
  expect(response.status === 400, "a notification not signed by the App Store is refused");
  response = await notify({ ...notification("DID_RENEW", jws(appStore, bought)), data: { bundleId: "com.example.other", environment: "Sandbox", signedTransactionInfo: jws(appStore, bought) } });
  expect(response.status === 400, "as is one for another app");

  console.log("App Attest");
  const attestFor = (token) => fetch(`${base}/api/attest/challenge`, { method: "POST", headers: { Authorization: `Bearer ${token}` } });
  response = await fetch(`${base}/api/attest/challenge`, { method: "POST" });
  expect(response.status === 401, "attesting needs a session");
  const { challenge } = await (await attestFor(me.token)).json();
  const device = attest(attestCA, { challenge: Buffer.from(challenge, "base64"), category: 3 });
  const register = (body) => fetch(`${base}/api/attest/key`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${me.token}` }, body: JSON.stringify(body) });
  response = await register({ keyId: device.keyID, attestation: device.attestation.toString("base64"), challenge });
  expect(response.status === 201 && (await response.json()).environment === "development", "a key attested for a fresh challenge is kept");
  response = await register({ keyId: device.keyID, attestation: device.attestation.toString("base64"), challenge });
  expect(response.status === 400, "a challenge works once");
  const asserted = (body, counter, { time = String(Math.floor(Date.now() / 1000)), keyID = device.keyID, signer = device.device } = {}) => ({
    "X-Dream-Attest-Key": keyID,
    "X-Dream-Attest-Time": time,
    "X-Dream-Assertion": assertion(signer, requestData("POST", "/api/model", time, Buffer.from(body)), counter).toString("base64"),
  });
  const body = JSON.stringify(hello());
  const headers = asserted(body, 1);
  response = await ask(body, { key: null, headers });
  expect(response.status === 200, "a request with an assertion, and no app key, goes through");
  response = await ask(body, { key: null, headers });
  expect(response.status === 401, "the same assertion again is refused");
  response = await ask(JSON.stringify(hello({ temperature: 1 })), { key: null, headers: asserted(body, 2) });
  expect(response.status === 401, "an assertion for another body is refused");
  const [late, later] = [asserted(body, 4), asserted(body, 3)];
  expect((await ask(body, { key: null, headers: late })).status === 200 && (await ask(body, { key: null, headers: later })).status === 200, "counters arriving a little out of order are fine");
  response = await ask(body, { key: null, headers: asserted(body, 5, { time: String(Math.floor(Date.now() / 1000) - 600) }) });
  expect(response.status === 401, "an assertion from ten minutes ago is refused");
  const stranger = attest(attestCA, { challenge: Buffer.from("never asked for") });
  response = await ask(body, { key: null, headers: asserted(body, 1, { keyID: stranger.keyID, signer: stranger.device }) });
  expect(response.status === 401 && response.headers.get("x-dream-attest") === "again", "a key the server doesn't know asks the app to attest again");
}

/** The policy pages, crash reports and their summary. Reports are only stored by a local
 * server, and the summary only read there. */
async function runRelease(base, local) {
  console.log("Privacy policy, terms and support");
  for (const [path, title] of [["/privacy", "Privacy policy"], ["/terms", "Terms of use"], ["/support", "Support"]]) {
    const response = await fetch(`${base}${path}`);
    const page = await response.text();
    expect(response.status === 200 && response.headers.get("content-type")?.startsWith("text/html"), `${path} is a page`);
    expect(page.includes(`<h1>${title}</h1>`) && page.includes("Draft, needs legal review"), `${path} says it's a draft`);
    expect(response.headers.get("content-security-policy")?.includes("default-src 'none'") && !page.includes("<script"), `${path} has no scripts`);
  }
  let response = await fetch(`${base}/privacy/`);
  expect(response.status === 200, "a trailing slash works too");
  const policy = await (await fetch(`${base}/privacy`)).text();
  expect(["Cloudflare", "xAI", "Parallel", "Apple", "Wikimedia", "PostHog"].every((name) => policy.includes(name)), "the policy names every company that handles data");
  expect(policy.includes("Digital Personal Data Protection Act") && policy.includes("GDPR"), "and rights under the GDPR and India's DPDP Act");
  response = await fetch(`${base}/terms`, { method: "POST" });
  expect(response.status === 405, "the pages are read-only");

  console.log("Crash and hang reports");
  const report = (body, type = "application/json") => fetch(`${base}/api/diagnostics`, { method: "POST", headers: { "Content-Type": type }, body });
  if (local) {
    response = await report(diagnostics);
    expect(response.status === 202 && (await response.json()).accepted === 3, "a day's reports are accepted");
  }
  response = await fetch(`${base}/api/diagnostics`);
  expect(response.status === 405, "only POST");
  response = await report(diagnostics, "text/plain");
  expect(response.status === 415, "only application/json");
  const one = JSON.parse(diagnostics);
  response = await report(JSON.stringify({ ...one, reports: [{ ...one.reports[2], kind: "freeze" }] }));
  expect(response.status === 400, "a report of another kind is refused");
  response = await report(JSON.stringify({ ...one, padding: "x".repeat(300_000) }));
  expect(response.status === 413, "a body over 256 KB is refused");

  console.log("The diagnostics summary");
  const summary = (key) => fetch(`${base}/api/admin/diagnostics?days=7`, { headers: key ? { "X-Admin-Key": key } : {} });
  response = await summary();
  expect(local ? response.status === 403 : [403, 404].includes(response.status), "not without the operator's key");
  if (local) {
    response = await summary("a-wrong-admin-key-of-good-length");
    expect(response.status === 403, "not with a wrong key");
    response = await summary(LOCAL_ADMIN_KEY);
    const seen = await response.json();
    expect(response.status === 200 && response.headers.get("cache-control") === "no-store", "200 with the key, and never cached");
    expect(seen.total === 3 && seen.byKind?.crash === 1 && seen.byKind?.hang === 1 && seen.byKind?.launch === 1, "counts by kind");
    expect(seen.byVersion?.[0]?.app === "1.0" && seen.byVersion?.[0]?.build === "7" && seen.perDay?.length === 1, "by version and by day");
    expect(seen.topSignatures?.some((item) => item.signature === "EXC_BREAKPOINT SIGTRAP Dream+0x1a2b4" && item.count === 1 && item.latest === "1.0 (7)"), "grouped by where they happened");
    expect(seen.durations?.hang?.max === 2.5 && seen.durations?.launch?.average === 4.25, "how long hangs and launches took");
    response = await fetch(`${base}/api/admin/diagnostics?days=900`, { headers: { "X-Admin-Key": LOCAL_ADMIN_KEY } });
    expect(response.status === 400, "at most 90 days");

    let limited = false;
    for (let i = 0; i < 15 && !limited; i++) limited = (await report("{nope")).status === 429;
    expect(limited, "too many reports from one address are refused for a while");
  }
}

const remote = process.env.DREAM_SHARE_URL;
const stub = remote ? null : await startStub();
const xai = remote ? null : await startXAIStub();
const server = remote ? { base: remote.replace(/\/$/, ""), stop() {} } : await startLocal(stub, xai);
try {
  await run(server.base);
  // Owners, reports, blocks and the admin need several test users, so only run locally.
  if (!remote) await runSharing(server.base, { expect, signIn: (name) => signIn(server.base, name), fixture, adminKey: LOCAL_ADMIN_KEY, legacyID: LEGACY_ID });
  await runRelease(server.base, !remote);
  const key = remote ? process.env.DREAM_WEB_KEY : LOCAL_APP_KEY;
  const session = remote ? process.env.DREAM_SESSION : (await signIn(server.base, "smoke"))?.token;
  if (key && session) await runWeb(server.base, key, session, stub);
  else console.log("\nWeb search and reading: skipped, since DREAM_WEB_KEY or DREAM_SESSION isn't set for this server.");
  await runSync(server.base, expect, { quota: LOCAL_SYNC_QUOTA });
  if (!remote) await runPlan(server.base, xai);
} catch (error) {
  console.log(`  FAIL  ${error.stack ?? error}`);
  failures++;
} finally {
  server.stop();
  stub?.stop();
  xai?.stop();
}
console.log(failures ? `\n${failures} failed` : "\nAll passed");
process.exit(failures ? 1 : 0);
