// Checks push notifications (src/push.ts). First on their own in Node, with an APNs key made for
// the test and a stand-in for fetch, so nothing reaches Apple: what registering a device takes,
// what a notification says and carries, the provider token (its shape, its signature checked with
// the key's public half, and kept for its half hour), which host each kind of build's tokens go
// to, and a token Apple says is gone. Then the job (compose/runner.ts), in memory, on the
// stand-in model: a page, a question or a call to the phone's tools nobody is watching notifies,
// one being watched doesn't. Then the routes end to end under `wrangler dev`, against a stand-in
// for APNs on this Mac (test/stub-apns.mjs): registering and forgetting devices, a session
// ending, deleting the account, the limits, and pages made on the server telling the account's
// iPhones, among them one that waits for the phone to be opened, and goes on once it answers.
//
//   node test/push.mjs
//
// The source imports without extensions, as the Worker's bundler takes them, so a resolve hook
// finds the .ts file (as test/compose.mjs does).

import { spawn, execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import { startAPNsStub } from "./stub-apns.mjs";

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (/^\.\.?\//.test(specifier) && !/\.(ts|mjs|js|json)$/.test(specifier)) {
      try {
        return nextResolve(`${specifier}.ts`, context);
      } catch {
        // Not a TypeScript file.
      }
    }
    return nextResolve(specifier, context);
  },
});

const { apnsConfig, apnsHost, deliver, MAX_DEVICES, notify, pageReady, phoneNeeded, providerToken, questionWaiting, readDevice, shortRequest, TOPIC } = await import("../src/push.ts");
const { Runner, memoryStore } = await import("../src/compose/runner.ts");
const { fakeModel } = await import("../src/compose/fake.ts");
const engine = await import("../src/engine/index.ts");

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const generation = JSON.parse(readFileSync(join(root, "src/generated/generation.json"), "utf8"));
let failures = 0;

function expect(condition, message) {
  console.log(`${condition ? "  ok  " : "  FAIL"}  ${message}`);
  if (!condition) failures++;
}

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const RUN = Date.now().toString(36);
const KEY_ID = "TESTKEY123";
const TEAM_ID = "TESTTEAM99";
const APP_KEY = "push-test-app-key-0123456789abcdef";
const locale = { language: "en", region: "IN", currency: "INR", measurementSystem: "metric" };
const uuid = () => crypto.randomUUID().toUpperCase();
/** A device token as iOS gives one: 32 random bytes, hex. */
const deviceToken = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("hex");

/** An APNs key as Apple's .p8 holds one, and its public half. */
async function apnsKey() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${der.match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----`, publicKey: pair.publicKey };
}

/** A provider token's header and claims, and whether the key's public half verifies it. */
async function readToken(token, publicKey) {
  const [header, claims, signature] = String(token).split(".");
  const verified = !!signature && (await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, Buffer.from(signature, "base64url"), new TextEncoder().encode(`${header}.${claims}`)));
  return { header: JSON.parse(Buffer.from(header, "base64url").toString()), claims: JSON.parse(Buffer.from(claims, "base64url").toString()), verified, signatureBytes: Buffer.from(signature ?? "", "base64url").length };
}

const key = await apnsKey();
const config = { key: key.pem, keyID: KEY_ID, teamID: TEAM_ID };
const JOB = { id: "a".repeat(64), pageID: "6F9619FF-8B86-D011-B42D-00C04FC964FF", deadline: Date.now() + 600_000 };

// MARK: - On their own

console.log("Registering a device");
{
  const token = deviceToken();
  const good = readDevice({ token: token.toUpperCase(), environment: "sandbox" });
  expect(good.token === token && good.environment === "sandbox", "a token as iOS gives it, in either case, kept as lowercase hex");
  expect(readDevice({ token, environment: "production" }).environment === "production", "production for App Store and TestFlight builds");
  const refused = [{ token: "xyz", environment: "sandbox" }, { token: token.slice(0, 40), environment: "sandbox" }, { token: `${token}a`, environment: "sandbox" }, { token: "ab".repeat(101), environment: "sandbox" }, { token: `${token.slice(2)}zz`, environment: "sandbox" }, { environment: "sandbox" }];
  expect(refused.every((body) => "error" in readDevice(body)), "not hex, too short, half a byte, too long, or missing: refused");
  expect("error" in readDevice({ token, environment: "development" }) && "error" in readDevice({ token }) && "error" in readDevice(null), "an environment other than sandbox or production, or none: refused");
}

console.log("What a notification says");
{
  expect(shortRequest("split a 2400 rupee dinner between 3 friends") === "split a 2400 rupee dinner between…", "a request's first six words");
  expect(shortRequest("  what's  the\nweather ") === "what's the weather", "a short one as it is, its spacing tidied");
  const long = shortRequest("Pneumonoultramicroscopicsilicovolcanoconiosis explained simply");
  expect(Array.from(long).length === 40 && long.endsWith("…"), "never more than 40 characters");
  expect(Array.from(shortRequest("東京から大阪までの新幹線の料金と所要時間を比べて、いちばん安い行き方と早い行き方を教えてください")).length === 40, "even in a language without spaces");
  expect(!shortRequest("🧑‍🍳".repeat(50)).includes("�"), "and never half a character");

  const now = Date.now();
  const ready = pageReady(JOB, "split a 2400 rupee dinner between 3 friends and me", { title: "Dinner, split  three ways", blocks: [{ text: "Each pays ₹800" }] }, now);
  expect(ready.title === "Your page is ready" && ready.body === "Dinner, split three ways", "a page is ready: its title, and nothing else from it");
  expect(ready.payload.page === JOB.pageID && ready.payload.job === JOB.id && ready.payload.kind === "done", "it carries the page, the job and what happened, for the app to open");
  expect(ready.expires === Math.floor(now / 1000) + 86_400, "and stops trying after a day, when the job is forgotten");
  expect(pageReady(JOB, "split a bill", {}, now).body === "“split a bill”", "a page with no title is named by its request");
  const asking = questionWaiting(JOB, "tell me about mercury and its orbit please", now);
  expect(!asking.title && asking.body === "Dream has a question about “tell me about mercury and its…”" && asking.payload.kind === "asking", "a question: the request's first few words");
  expect(asking.expires === Math.floor(JOB.deadline / 1000), "and it lasts as long as the question waits");
  const deadline = now + 600_000;
  const service = phoneNeeded(JOB, "file an issue about the login bug in Linear", { name: "linear_create_issue", service: "Linear" }, deadline);
  expect(!service.title && service.body === "Dream needs your iPhone to read Linear for “file an issue about the login…”" && service.payload.kind === "device" && service.payload.page === JOB.pageID && service.payload.job === JOB.id, "the phone's tool: the service it reads, and the request's first few words");
  expect(service.expires === Math.floor(deadline / 1000), "lasting as long as the call waits");
  expect(phoneNeeded(JOB, "how long to drive to the airport", { name: "travel" }, deadline).body === "Dream needs your iPhone to work out a journey for “how long to drive to the…”", "a travel time is a journey to work out");
  expect(phoneNeeded(JOB, "my notes", { name: "notes_search" }, deadline).body === "Dream needs your iPhone to read a connected service for “my notes”", "a service that didn't say its name is a connected service");
}

console.log("The provider token");
{
  const now = Date.UTC(2026, 9, 29, 10, 47, 12);
  const token = await providerToken(config, now);
  const { header, claims, verified, signatureBytes } = await readToken(token, key.publicKey);
  expect(header.alg === "ES256" && header.kid === KEY_ID && Object.keys(header).length === 2, "ES256, naming the key");
  expect(claims.iss === TEAM_ID && Object.keys(claims).sort().join() === "iat,iss", "issued by the team, with only iss and iat");
  expect(claims.iat === Date.UTC(2026, 9, 29, 10, 30) / 1000, "issued at the start of its half hour, so every copy of the Worker agrees");
  expect(verified && signatureBytes === 64, "signed with the key, as r ‖ s");
  expect((await providerToken(config, now + 10 * 60_000)) === token, "reused within its half hour");
  const next = await providerToken(config, now + 13 * 60_000);
  expect(next !== token && (await readToken(next, key.publicKey)).claims.iat === claims.iat + 1_800, "and made again after it, under an hour old");
  expect((await readToken(await providerToken({ ...config, key: key.pem.replace(/\n/g, "\\n") }, now), key.publicKey)).verified, "the key also reads with its line breaks written as \\n");
  expect((await readToken(await providerToken({ ...config, keyID: "OTHERKEY99" }, now), key.publicKey)).header.kid === "OTHERKEY99", "another key is never given this one's token");
}

console.log("Sending to APNs");
{
  const asked = [];
  let answer = () => new Response(null, { status: 200 });
  const send = async (url, init) => {
    asked.push({ url: new URL(url), init, body: JSON.parse(init.body) });
    return answer();
  };
  const sandbox = { token: deviceToken(), environment: "sandbox" };
  const production = { token: deviceToken(), environment: "production" };
  const ready = pageReady(JOB, "split a bill", { title: "Split a bill" });
  expect((await deliver(config, sandbox, ready, send)) === "sent", "a notification is sent");
  const [first] = asked;
  expect(first.url.origin === "https://api.sandbox.push.apple.com" && first.url.pathname === `/3/device/${sandbox.token}` && first.init.method === "POST", "a development build's token goes to the sandbox");
  await deliver(config, production, ready, send);
  expect(asked[1].url.origin === "https://api.push.apple.com" && apnsHost("production") === "https://api.push.apple.com", "an App Store or TestFlight build's to production");
  const headers = first.init.headers;
  expect(headers["apns-topic"] === TOPIC && TOPIC === "xyz.onlychan.Dream" && headers["apns-push-type"] === "alert" && headers["apns-priority"] === "10", "for Dream, as an alert, sent at once");
  expect(headers["apns-collapse-id"] === JOB.pageID && headers["apns-expiration"] === String(ready.expires), "one notification per page, which stops trying when it's stale");
  const bearer = /^bearer (.+)$/.exec(headers.authorization)?.[1];
  expect((await readToken(bearer, key.publicKey)).verified, "with the provider token");
  expect(first.body.aps.alert.title === "Your page is ready" && first.body.aps.alert.body === "Split a bill" && first.body.aps.sound === "default", "the alert");
  expect(first.body.page === JOB.pageID && first.body.job === JOB.id && first.body.kind === "done" && Object.keys(first.body).sort().join() === "aps,job,kind,page", "and the payload beside it, nothing more");
  const question = questionWaiting(JOB, "tell me about mercury");
  await deliver(config, sandbox, question, send);
  expect(asked.at(-1).body.aps.alert.title === undefined && asked.at(-1).body.kind === "asking", "a question has no title");
  await deliver(config, sandbox, phoneNeeded(JOB, "how long to drive to the airport", { name: "travel" }, Date.now() + 600_000), send);
  const needed = asked.at(-1);
  expect(needed.body.kind === "device" && needed.body.aps.alert.title === undefined && needed.init.headers["apns-collapse-id"] === JOB.pageID && needed.body.aps["thread-id"] === JOB.pageID, "nor does the phone's, which collapses with the page's others");

  answer = () => Response.json({ reason: "Unregistered" }, { status: 410 });
  expect((await deliver(config, sandbox, ready, send)) === "gone", "410: the app was deleted, so the token is gone");
  answer = () => Response.json({ reason: "BadDeviceToken" }, { status: 400 });
  expect((await deliver(config, sandbox, ready, send)) === "gone", "BadDeviceToken: gone too");
  answer = () => Response.json({ reason: "PayloadTooLarge" }, { status: 413 });
  expect((await deliver(config, sandbox, ready, send)) === "failed", "anything else only fails this one");
  const before = /^bearer (.+)$/.exec(asked.at(-1).init.headers.authorization)[1];
  answer = () => Response.json({ reason: "ExpiredProviderToken" }, { status: 403 });
  expect((await deliver(config, sandbox, ready, send)) === "failed", "an expired provider token fails this one");
  answer = () => new Response(null, { status: 200 });
  await deliver(config, sandbox, ready, send);
  expect(/^bearer (.+)$/.exec(asked.at(-1).init.headers.authorization)[1] !== before, "and the next is signed again");
  expect((await deliver(config, sandbox, ready, async () => { throw new TypeError("offline"); })) === "failed", "and APNs out of reach fails without throwing");

  expect(apnsConfig({}) === null && apnsConfig({ APNS_KEY: key.pem, APNS_KEY_ID: KEY_ID }) === null, "without all three secrets, there's no APNs");
  expect(apnsConfig({ APNS_KEY: key.pem, APNS_KEY_ID: ` ${KEY_ID} `, APNS_TEAM_ID: TEAM_ID }).keyID === KEY_ID, "with them, there is");
  expect(apnsConfig({ APNS_KEY: key.pem, APNS_KEY_ID: KEY_ID, APNS_TEAM_ID: TEAM_ID, APNS_BASE_URL: "http://127.0.0.1:1/" }).base === undefined, "a stand-in for Apple only counts in local development");
  expect(apnsConfig({ APNS_KEY: key.pem, APNS_KEY_ID: KEY_ID, APNS_TEAM_ID: TEAM_ID, APNS_BASE_URL: "http://127.0.0.1:1/", DEV_LOGIN: "1" }).base === "http://127.0.0.1:1", "where it does");

  const logged = [];
  const log = console.log;
  console.log = (...line) => logged.push(line.join(" "));
  let reached = 0;
  const nowhere = { DB: { prepare: () => { throw new Error("no database without APNs"); } } };
  await notify(nowhere, "user-1", ready, async () => (reached++, new Response(null)));
  await notify(nowhere, "user-1", ready, async () => (reached++, new Response(null)));
  console.log = log;
  expect(reached === 0 && logged.length === 1 && /APNS_KEY/.test(logged[0]), "without the secrets nothing is sent, and that's said once");
}

// MARK: - The job

const PICK = { model: "grok-4.7", effort: "low", name: "Grok 4.7", category: "other", difficulty: "easy", why: "Dream's default" };
const TIMING = { answerWait: 600_000, runLimit: 60_000, keep: 86_400_000, attempts: 3, keepAlive: 50 };

/** A job's services, on the stand-in model and the engine, which keep each notification asked for. */
function jobServices(notified) {
  return {
    loop: () => ({
      engine,
      generation,
      model: async (body) => fakeModel(body),
      route: async () => PICK,
      tools: { lookup: async () => null, related: async () => [], search: async () => ({ status: 0, body: null }), read: async () => ({ status: 0, body: null }), memory: async () => [], fetch: async () => new Response("", { status: 404 }), here: null },
      now: Date.now,
      sleep: (ms) => pause(ms),
    }),
    finish: async () => null,
    analytics: () => undefined,
    notify: (job, notice) => notified.push(notice),
    now: Date.now,
  };
}

/** Reads a watcher's events until `stop` says so, or the stream ends, then lets go of it. */
async function read(stream, stop = () => false) {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  const events = [];
  let text = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) return events;
    text += decoder.decode(value, { stream: true });
    let end;
    while ((end = text.indexOf("\n\n")) >= 0) {
      const part = text.slice(0, end);
      text = text.slice(end + 2);
      if (!part.startsWith("data: ")) continue;
      events.push(JSON.parse(part.slice(6)));
      if (stop(events.at(-1))) {
        await reader.cancel();
        return events;
      }
    }
  }
}

const job = () => ({ id: crypto.randomUUID().replace(/-/g, "").padEnd(64, "0"), owner: "user-1", counted: false, origin: "https://dream.example" });
const request = (text) => ({ request: text, locale, pageID: uuid() });
/** The phone's travel tool, as the app offers it (DeviceTools.swift's TravelTool). */
const TRAVEL = { name: "travel", description: "Fetches the distance and travel time between places now, from Apple Maps.", parameters: { type: "object", properties: { name: { type: "string" }, from: { type: "string" }, to: { type: "string" }, travel: { type: "string" } }, required: ["name", "from", "to", "travel"] } };
const JOURNEY = "how long to drive to the airport";
const journey = () => ({ ...request(JOURNEY), deviceTools: [TRAVEL] });

console.log("The job: nobody watching");
{
  const notified = [];
  const runner = new Runner(memoryStore(), jobServices(notified), TIMING);
  const asked = request("a page about tea");
  await runner.start(job(), asked);
  await runner.alarm();
  expect(runner.job.status === "done" && notified.length === 1, "a page finished with nobody watching asks for one notification");
  expect(notified[0].title === "Your page is ready" && notified[0].body === "A page about tea" && notified[0].payload.kind === "done" && notified[0].payload.page === asked.pageID && notified[0].payload.job === runner.job.id, "saying it's ready, with its title, for its page and job");

  const later = [];
  const asking = new Runner(memoryStore(), jobServices(later), TIMING);
  await asking.start(job(), request("tell me about mercury"));
  await asking.alarm();
  expect(asking.job.status === "asking" && later.length === 1 && later[0].body === "Dream has a question about “tell me about mercury”" && later[0].payload.kind === "asking", "questions with nobody to answer them: one notification");
  expect(later[0].expires === Math.floor(asking.job.deadline / 1000), "lasting as long as they wait");
  await asking.answer("user-1", { answers: [{ question: { text: "Which Mercury?" }, choice: "The planet" }] });
  await asking.alarm();
  expect(asking.job.status === "done" && later.length === 2 && later[1].payload.kind === "done", "then another when the page is made");

  const needed = [];
  const away = new Runner(memoryStore(), jobServices(needed), TIMING);
  await away.start(job(), journey());
  await away.alarm();
  expect(away.job.status === "device" && needed.length === 1 && needed[0].body === "Dream needs your iPhone to work out a journey for “how long to drive to the…”" && needed[0].payload.kind === "device" && needed[0].payload.job === away.job.id, "a journey only the phone can work out, with nobody there to run it: one notification, and the page waits for it");
}

// A page's own notices (ready, a question) go whether or not anyone watches: the phone hides
// them while it shows the page. Only the phone's tools wait on someone watching, which sets
// how long they wait.
console.log("The job: someone watching");
{
  const notified = [];
  const runner = new Runner(memoryStore(), jobServices(notified), TIMING);
  await runner.start(job(), request("a page about tea"));
  const watching = read(runner.watch("user-1", 0));
  await runner.alarm();
  const events = await watching;
  expect(events.at(-1)?.type === "done" && notified.length === 1 && notified[0].payload.kind === "done", "a page watched to the end still says it's ready, for the phone to hide");

  const asked = [];
  const asking = new Runner(memoryStore(), jobServices(asked), TIMING);
  await asking.start(job(), request("tell me about mercury"));
  const watcher = read(asking.watch("user-1", 0), (event) => event.type === "asking");
  await asking.alarm();
  const seen = await watcher;
  expect(seen.at(-1)?.type === "asking" && asked.length === 1 && asked[0].payload.kind === "asking", "questions someone sees still notify, for the phone to hide");
  // The watcher has let go: the app was left.
  await asking.answer("user-1", { answers: [] });
  await asking.alarm();
  expect(asking.job.status === "done" && asked.length === 2 && asked[1].payload.kind === "done", "and the page that's made says it's ready");

  const twice = [];
  const both = new Runner(memoryStore(), jobServices(twice), TIMING);
  await both.start(job(), request("a page about coffee"));
  const left = read(both.watch("user-1", 0), () => true);
  const stays = read(both.watch("user-1", 0));
  await both.alarm();
  await Promise.all([left, stays]);
  expect(both.job.status === "done" && twice.length === 1, "two watchers, one notice that it's ready");

  const open = [];
  const watched = new Runner(memoryStore(), jobServices(open), { ...TIMING, deviceWait: 300 });
  await watched.start(job(), journey());
  const following = read(watched.watch("user-1", 0));
  await watched.alarm();
  const all = await following;
  const call = all.find((event) => event.type === "deviceTool");
  expect(all.at(-1)?.type === "done" && !open.some((notice) => notice.payload.kind === "device") && call?.deadline <= Date.now(), "a call to the phone's tools someone sees: no notice for it, and the minute's wait (300 ms here), after which the page goes on without it");
}

// MARK: - End to end

/** One read of the local database while `wrangler dev` runs, straight from its SQLite file. */
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

async function startLocal(apns) {
  const env = { ...process.env, WRANGLER_SEND_METRICS: "false" };
  execFileSync("npx", ["wrangler", "d1", "migrations", "apply", "dream-share", "--local"], { cwd: root, env, stdio: "ignore" });
  const port = 22_000 + Math.floor(Math.random() * 2_000);
  // These take the place of anything in .dev.vars. The key goes with its line breaks written out.
  const vars = [
    "DEV_LOGIN:1",
    "MODEL_FAKE:1",
    `DREAM_APP_KEYS:${APP_KEY}`,
    "POSTHOG_KEY:",
    "MODELS:grok-4.7",
    `APNS_KEY:${key.pem.replace(/\n/g, "\\n")}`,
    `APNS_KEY_ID:${KEY_ID}`,
    `APNS_TEAM_ID:${TEAM_ID}`,
    `APNS_BASE_URL:${apns.base}`,
  ].flatMap((pair) => ["--var", pair]);
  const child = spawn("npx", ["wrangler", "dev", "--local", "--port", String(port), "--ip", "127.0.0.1", ...vars], { cwd: root, env, stdio: ["ignore", "pipe", "pipe"] });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("wrangler dev didn't start in 60 s")), 60_000);
    const watch = (chunk) => {
      if (String(chunk).includes("Ready on")) {
        clearTimeout(timer);
        resolve();
      }
    };
    child.stdout.on("data", watch);
    child.stderr.on("data", watch);    child.on("exit", (code) => reject(new Error(`wrangler dev exited with ${code}`)));
  });
  return { base: `http://127.0.0.1:${port}`, stop: () => child.kill("SIGTERM") };
}

/** Waits up to `ms` for `ready` to say so. */
async function until(ready, ms = 20_000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await ready()) return true;
    await pause(100);
  }
  return false;
}

async function endToEnd(base, apns) {
  const signIn = async (name) => {
    const { user, token } = await (await fetch(`${base}/api/dev/session?user=${encodeURIComponent(`push-${name}-${RUN}`)}`, { method: "POST" })).json();
    return { user, token };
  };
  const call = (who, path, { method = "GET", body, type = "application/json" } = {}) =>
    fetch(`${base}${path}`, {
      method,
      headers: { ...(who ? { Authorization: `Bearer ${who.token}` } : {}), ...(body !== undefined ? { "Content-Type": type } : {}) },
      body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
    });
  const register = (who, token, environment = "sandbox") => call(who, "/api/push/devices", { method: "POST", body: { token, environment } });
  const forget = (who, token) => call(who, `/api/push/devices/${token}`, { method: "DELETE" });
  const devices = (user) => query(`SELECT token, environment, session_hash FROM push_devices WHERE user_id = '${user}' ORDER BY updated_at, created_at`);
  const start = (who, text, fields = {}) =>
    fetch(`${base}/api/compose`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${who.token}`, "X-Dream-Key": APP_KEY },
      body: JSON.stringify({ request: text, locale, pageID: uuid(), model: "auto", ...fields }),
    }).then(async (response) => ({ status: response.status, ...(await response.json()) }));
  const watch = async (who, id) => {
    const response = await fetch(`${base}/api/compose/${id}/events?after=0`, { headers: { Authorization: `Bearer ${who.token}` } });
    return read(response.body, (event) => event.type === "done" || event.type === "failed");
  };
  const sentFor = (job) => apns.sent.filter((each) => each.body?.job === job);

  console.log("Registering devices, over HTTP");
  const alice = await signIn("alice");
  const token = deviceToken();
  let response = await register(null, token);
  expect(response.status === 401, "needs someone signed in");
  response = await call(alice, "/api/push/devices");
  expect(response.status === 405, "only POST");
  response = await call(alice, "/api/push/devices", { method: "POST", body: { token, environment: "sandbox" }, type: "text/plain" });
  expect(response.status === 415, "as JSON");
  response = await register(alice, "not-a-token");
  const said = await response.json();
  expect(response.status === 400 && /hex/.test(said.error), "a token that isn't one is refused");
  expect((await register(alice, token, "staging")).status === 400, "and an environment that isn't sandbox or production");
  response = await register(alice, token.toUpperCase());
  const [kept] = devices(alice.user);
  expect(response.status === 204 && kept?.token === token && kept.environment === "sandbox" && /^[0-9a-f]{64}$/.test(kept.session_hash), "a device is kept for the account, with the session that registered it");
  expect((await register(alice, token, "sandbox")).status === 204 && devices(alice.user).length === 1, "registering again changes nothing");

  const bob = await signIn("bob");
  const bobs = Array.from({ length: MAX_DEVICES + 1 }, deviceToken);
  for (const each of bobs) {
    await register(bob, each);
    await pause(1_100);
  }
  const left = devices(bob.user).map((row) => row.token);
  expect(left.length === MAX_DEVICES && !left.includes(bobs[0]) && left.includes(bobs.at(-1)), `at most ${MAX_DEVICES} for an account; the one registered longest ago goes`);

  expect((await forget(bob, token)).status === 404 && devices(alice.user).length === 1, "nobody else can forget someone's device");
  expect((await forget(alice, "zz")).status === 400, "forgetting needs a token");
  expect((await call(alice, `/api/push/devices/${token}`)).status === 405, "only DELETE");
  expect((await forget(alice, token)).status === 204 && devices(alice.user).length === 0, "its own account forgets it, as at sign-out");
  expect((await forget(alice, token)).status === 404, "once");

  const carol = await signIn("carol");
  const carl = await signIn("carl");
  const shared = deviceToken();
  await register(carol, shared);
  await register(carl, shared, "production");
  expect(devices(carol.user).length === 0 && devices(carl.user)[0]?.environment === "production", "an iPhone someone else signs in on moves to their account");

  const dave = await signIn("dave");
  await register(dave, deviceToken());
  expect((await call(dave, "/api/me/sessions/current", { method: "DELETE" })).status === 204 && devices(dave.user).length === 0, "signing a session out takes its device with it");

  const erin = await signIn("erin");
  const erins = deviceToken();
  await register(erin, erins);
  const exported = await (await call(erin, "/api/me/export", { method: "POST" })).text();
  expect(JSON.parse(exported).notifications?.[0]?.build === "development" && !exported.includes(erins), "the export says which builds get notifications, never the token");
  expect((await call(erin, "/api/me", { method: "DELETE", body: {} })).status === 200 && devices(erin.user).length === 0, "deleting the account erases its devices");

  const frank = await signIn("frank");
  let limited = false;
  for (let i = 0; i < 15 && !limited; i++) limited = (await register(frank, deviceToken())).status === 429;
  expect(limited, "registering is rate limited");

  console.log("Pages made on the server, notifying");
  const gina = await signIn("gina");
  const sandbox = deviceToken();
  const production = deviceToken();
  await register(gina, sandbox, "sandbox");
  await register(gina, production, "production");
  const ada = await start(gina, "look up Ada Lovelace");
  expect(ada.status === 200 && (await until(() => sentFor(ada.id).length === 2)), "a page nobody watches tells each of the account's iPhones it's ready");
  const [one] = sentFor(ada.id);
  expect(sentFor(ada.id).map((each) => each.token).sort().join() === [sandbox, production].sort().join(), "both of them");
  expect(one?.body.aps.alert.title === "Your page is ready" && one.body.aps.alert.body === "Look up Ada Lovelace" && one.body.kind === "done" && one.body.job === ada.id, "with its title, and what to open");
  expect(one?.headers["apns-topic"] === TOPIC && one.headers["apns-push-type"] === "alert" && /^[0-9A-F-]{36}$/.test(one.headers["apns-collapse-id"]), "for Dream, as an alert, one per page");
  const signed = await readToken(/^bearer (.+)$/.exec(one?.headers.authorization ?? "")?.[1], key.publicKey);
  expect(signed.verified && signed.header.kid === KEY_ID && signed.claims.iss === TEAM_ID, "signed with the APNs key from the secrets");

  const watched = await start(gina, "a page about tea");
  const seen = await watch(gina, watched.id);
  await pause(1_500);
  expect(seen.at(-1)?.type === "done" && (await until(() => sentFor(watched.id).length === 2)) && sentFor(watched.id).every((each) => each.body.kind === "done"), "a page watched as it's made still says it's ready, for the phone to hide");

  const glimpse = await start(gina, "a page about milk");
  const line = await fetch(`${base}/api/compose/${glimpse.id}/events?after=0`, { headers: { Authorization: `Bearer ${gina.token}` } });
  const first = await read(line.body, () => true);
  expect(first.length === 1 && (await until(() => sentFor(glimpse.id).length === 2)) && sentFor(glimpse.id)[0].body.kind === "done", "one the app watched for a moment, then left, still says when it's ready");

  const hank = await signIn("hank");
  await register(hank, deviceToken());
  const mercury = await start(hank, "tell me about mercury");
  expect(await until(() => sentFor(mercury.id).length === 1), "questions nobody is there to answer send one");
  const question = sentFor(mercury.id)[0]?.body;
  expect(question?.aps.alert.body === "Dream has a question about “tell me about mercury”" && question.kind === "asking" && !question.aps.alert.title, "saying what it's about");

  const jo = await signIn("jo");
  await register(jo, deviceToken());
  const trip = await start(jo, JOURNEY, { deviceTools: [TRAVEL] });
  expect(trip.status === 200 && (await until(() => sentFor(trip.id).length === 1)), "a journey only the phone can work out, with nobody there: one notification");
  const needed = sentFor(trip.id)[0];
  expect(needed?.body.aps.alert.body === "Dream needs your iPhone to work out a journey for “how long to drive to the…”" && needed.body.kind === "device" && !needed.body.aps.alert.title && needed.headers["apns-collapse-id"] === needed.body.page, "saying what for, and collapsing with the page's others");
  // Opened from it, the app reads the page's events from the first, and finds the call waiting.
  await pause(500);
  const opened = await fetch(`${base}/api/compose/${trip.id}/events?after=0`, { headers: { Authorization: `Bearer ${jo.token}` } });
  // The same line, read in two goes: up to the call, then on, as the app reads it.
  const reader = opened.body.getReader();
  const piece = () => new ReadableStream({ pull: async (controller) => { const { done, value } = await reader.read(); if (done) controller.close(); else controller.enqueue(value); } }, { highWaterMark: 0 });
  const within = (reading) => Promise.race([reading, pause(20_000).then(() => [])]);
  const caught = await within(read(piece(), (event) => event.type === "deviceTool"));
  const waiting = caught.at(-1);
  expect(waiting?.type === "deviceTool" && waiting.call.name === "travel" && waiting.deadline > Date.now() + 9 * 60_000, "its call is in the catch-up, with ten minutes to answer it");
  const answered = await call(jo, `/api/compose/${trip.id}/tools`, { method: "POST", body: { id: waiting?.call.id, output: "Live source trip: current location to Kempegowda Airport, driving\n- trip.minutes = 52" } });
  expect(answered.status === 200, "the phone's answer is taken");
  const rest = await within(read(piece(), (event) => event.type === "done" || event.type === "failed"));  const lines = [...caught, ...rest].filter((event) => event.type === "log").map((event) => event.line);
  expect(rest.at(-1)?.type === "done" && lines.some((each) => each.startsWith("The phone answered travel: ")) && lines.filter((each) => each === "Asked the phone to run travel").length === 1, "and the page goes on from there, and is made");
  expect((await until(() => sentFor(trip.id).length === 2)) && sentFor(trip.id)[1].body.kind === "done", "seen as it's made, it says it's ready, for the phone to hide");

  const ivan = await signIn("ivan");
  const deleted = deviceToken();
  apns.gone.add(deleted);
  await register(ivan, deleted);
  const lost = await start(ivan, "a page about cocoa");
  expect((await until(() => sentFor(lost.id).length === 1)) && (await until(() => devices(ivan.user).length === 0)), "a token APNs says is gone (410) is forgotten");
}

const apns = await startAPNsStub();
let server = null;
try {
  server = await startLocal(apns);
  await endToEnd(server.base, apns);
} catch (error) {
  console.log(`  FAIL  ${error.stack ?? error}`);
  failures++;
} finally {
  server?.stop();
  apns.stop();
}
console.log(failures ? `\n${failures} failed` : "\nAll passed");
process.exit(failures ? 1 : 0);
