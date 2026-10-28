// Checks the Worker's pure parts in Node, without a Worker: which addresses the reader may fetch,
// robots.txt, how web text is tidied, the publish check, sync's rules with deleting someone's
// data, crash reports, the operator's key, and the server's own analytics events. Node runs the
// TypeScript files directly.
//
//   node test/unit.mjs

import { readFileSync } from "node:fs";
import { checkURL, isPublicIP, parseIP } from "../src/address.ts";
import { checkPublish, words } from "../src/moderation.ts";
import { adminAccess } from "../src/adminkey.ts";
import { AppleUnavailable, appleKeys } from "../src/apple.ts";
import { chatCompletion, chatStream, chatUsage, toResponses } from "../src/responses.ts";
import { CATALOG, allowedEffort, choose, fitEffort, offered } from "../src/models.ts";
import { CLEF, DEFAULT_PICK, HARD_FROM, QUESTIONS, READS_PHOTOS, TABLE, TOPICS, classify, clefCost, clefInput, firstUsable, guess, nonLatin, readAnswers } from "../src/router.ts";
import { withHeartbeat } from "../src/stream.ts";
import { workersCompletion, workersStream, workersUsage } from "../src/workersai.ts";
import { aiGeneration, capture, countsAllowed, limitReached } from "../src/analytics.ts";
import { MAX_REPORTS, MAX_STACK, parseReports, ReportError, signatureOf } from "../src/metrickit.ts";
import { robotsAllows } from "../src/robots.ts";
import { decodeCursor, deleteUserData, encodeCursor, imageType, parseChanges } from "../src/syncdata.ts";
import { capText, clip, dayOf, decodeEntities, delink, flatten, siteOf, tidy } from "../src/webtext.ts";

let failures = 0;
function expect(condition, message) {
  console.log(`${condition ? "  ok  " : "  FAIL"}  ${message}`);
  if (!condition) failures++;
}

console.log("Addresses the reader refuses");
const refused = {
  "file:///etc/passwd": "scheme",
  "ftp://example.com/": "scheme",
  "javascript:alert(1)": "scheme",
  "data:text/html,hi": "scheme",
  "http://localhost/": "host",
  "http://LOCALHOST./admin": "host",
  "http://api.localhost/": "host",
  "http://printer.local/": "host",
  "http://metadata.google.internal/computeMetadata/v1/": "host",
  "http://intranet/": "host",
  "http://127.0.0.1:8787/api/surfaces": "port",
  "http://127.0.0.1/": "private",
  "http://127.1/": "private",
  "http://2130706433/": "private",
  "http://0x7f000001/": "private",
  "http://0177.0.0.1/": "private",
  "http://0.0.0.0/": "private",
  "http://10.1.2.3/": "private",
  "http://172.20.0.1/": "private",
  "http://192.168.1.1/": "private",
  "http://100.64.0.1/": "private",
  "http://169.254.169.254/latest/meta-data/": "private",
  "http://[::1]/": "private",
  "http://[::]/": "private",
  "http://[::ffff:127.0.0.1]/": "private",
  "http://[::ffff:a9fe:a9fe]/": "private",
  "http://[64:ff9b::a00:1]/": "private",
  "http://[fd00::1]/": "private",
  "http://[fe80::1]/": "private",
  "http://[2001:db8::1]/": "private",
  "http://user:pass@example.com/": "credentials",
  "https://example.com:22/": "port",
  "https://example.com:8443/": "port",
  "not a url": "malformed",
  "": "length",
};
for (const [url, reason] of Object.entries(refused)) {
  const result = checkURL(url);
  expect("refused" in result && result.refused === reason, `${url || "(empty)"} → ${reason}${"refused" in result && result.refused !== reason ? ` (got ${result.refused})` : ""}`);
}
expect("refused" in checkURL(`https://example.com/${"a".repeat(2_100)}`), "addresses over 2,000 characters");

console.log("Addresses it reads");
for (const url of ["https://example.com/", "http://www.gsmarena.com/a?b=1", "https://xn--bcher-kva.example.com.au/", "https://8.8.8.8/", "https://[2606:4700:4700::1111]/", "https://example.com:443/x"]) {
  expect("url" in checkURL(url), url);
}
const kept = checkURL("https://example.com/page#section");
expect("url" in kept && kept.url.href === "https://example.com/page", "the fragment is dropped");
expect(isPublicIP(parseIP("1.1.1.1")) && !isPublicIP(parseIP("198.18.0.1")) && !isPublicIP(parseIP("224.0.0.1")), "IPv4 ranges");
expect(parseIP("::ffff:7f00:1")?.version === 6 && !isPublicIP(parseIP("::ffff:7f00:1")), "IPv6 written by the URL parser");

console.log("robots.txt");
const robots = `
# Comments are ignored
User-agent: *
Disallow: /private/
Allow: /private/open
Disallow: /*.pdf$

User-agent: Googlebot
Disallow: /

User-agent: DreamReader
User-agent: OtherBot
Disallow: /drafts
`;
expect(robotsAllows(robots, "/drafts/1") === false, "a group naming DreamReader applies to it");
expect(robotsAllows(robots, "/private/x") === true, "and only that group: the * rules don't apply then");
const general = robots.replace(/User-agent: DreamReader\n/, "");
expect(robotsAllows(general, "/private/x") === false, "without one, the * group applies");
expect(robotsAllows(general, "/private/open/page") === true, "the longest match wins: Allow");
expect(robotsAllows(general, "/files/report.pdf") === false && robotsAllows(general, "/files/report.pdf?x") === true, "* and $ in patterns");
expect(robotsAllows("", "/anything") === true, "an empty file allows everything");
expect(robotsAllows("User-agent: *\nDisallow:", "/") === true, "an empty Disallow allows everything");
expect(robotsAllows("User-agent: *\nDisallow: /", "/") === false, "Disallow: / refuses everything");
expect(robotsAllows("user-agent: dreamreader\ndisallow: /", "/a") === false, "field names and agents ignore case");
expect(robotsAllows("User-agent: *\nDisallow: /a\nAllow: /a", "/a") === true, "a tie goes to Allow");

console.log("Web text");
expect(decodeEntities("Fish &amp; chips &#8377;12&nbsp;999 &#x2014; &rsquo;s &bogus;") === "Fish & chips ₹12 999 — ’s &bogus;", "entities");
expect(flatten("## Top\nThe [Redmi 15](https://x.y) is **good** ![pic](a.png)") === "Top The Redmi 15 is good", "Markdown flattened for snippets");
expect(flatten("_Most iPhones get it._ macOS\\* and snake_case_name stay") === "Most iPhones get it. macOS* and snake_case_name stay", "emphasis and escapes, but not words with underscores");
expect(delink("See [the notes](https://a.b/c) and <https://d.e/f>. ![x](y.png)") === "See the notes and https://d.e/f. ", "links in page text become words");
expect(clip("one two three four", 10) === "one two…", "clipped on a word");
expect(tidy("Home\n\n\n\nA real line of text.\nHome\n|  |\n---\nEnd") === "Home\n\nA real line of text.\nEnd", "tidied: blank runs, repeats and separators");
const capped = capText(`${"First paragraph sentence. ".repeat(10)}\n\n${"Second paragraph. ".repeat(20)}`, 300);
expect(capped.truncated && capped.text.length <= 302 && capped.text.endsWith("\n…"), "long text is cut, and says so");
expect(siteOf("www.gsmarena.com") === "gsmarena.com" && siteOf("m.example.co.uk") === "example.co.uk", "site names from hosts");
expect(dayOf("2026-10-20T08:00:00+05:30") === "2026-10-20" && dayOf("Tue, 20 Oct 2026 10:00:00 GMT") === "2026-10-20" && dayOf("soon") === undefined, "dates");

console.log("The publish check (with each list's made-up test word)");
const page = (text, extra = {}) => ({ format: 1, surface: { title: "A page", summary: "", blocks: [{ id: "p", kind: "paragraph", title: "", text }], inputs: [], outputs: [], accent: "blue", symbol: "x", ...extra } });
const reason = (text, extra) => checkPublish(page(text, extra))?.reason ?? null;
expect(words("Ünïcödé L33T sp3ll1ng, stretchhhhed, s p e l l e d").join(" ") === "unicode leet spelling stretchhed spelled", "words are folded: accents, l33t, stretched and spelled-out letters");
expect(reason("Some dreamslurcheck here.") === "slur" && reason("DREAMSLURCHECKS!") === "slur", "a listed word, in any case, or plural");
expect(reason("notdreamslurcheck") === null, "only as a whole word");
expect(reason("Fine text", { related: ["dreamslurcheck"] }) === "slur", "anywhere a reader sees text");
expect(reason("Fine text", { inputs: [{ name: "dreamslurcheck", formula: "dreamslurcheck * 2" }] }) === null, "but not in names and formulas");
expect(reason("The toddlers dreamexplicitcheck.") === "minors" && reason("A 12 yrs old and dreamexplicitcheck") === "minors", "an explicit word in a sentence with a child, or a young age");
expect(reason("Kids are here. Elsewhere, dreamexplicitcheck.") === null && reason("A 30-year-old and dreamexplicitcheck") === null, "not in another sentence, or with an adult's age");
expect(reason("kiddie dreamporncheck") === "minors" && reason("dreamporncheck for kids") === null, "slang for pornography right after a word for a child");
expect(reason("Talk to children about sexual abuse and how to stay safe.") === null, "clinical words about keeping children safe aren't refused");
expect(reason("SSN 512-44-3321") === "private" && reason("SSN 666-44-3321") === null && reason("e.g. 123-45-6789") === null, "Social Security numbers, but not impossible or example ones");
expect(reason("Aadhaar 4991 1866 5246") === "private" && reason("4991 1866 5247") === null, "Aadhaar numbers that pass their check digit");
expect(reason("4539 1488 0343 6467") === "private" && reason("4539 1488 0343 6468") === null && reason("4242 4242 4242 4242") === null, "card numbers that pass Luhn, apart from test cards");
expect(reason("Her home address is 14 Elm Road. Her phone number is +44 20 7946 0958.") === "private", "a person's home address with their phone number");
expect(reason("The President lives at 1600 Pennsylvania Avenue. Call the office on 202-456-1111.") === null, "but not a famous address, or a public phone");
console.log("Sync rules");
const someone = "1f0c2a9e-0000-4000-8000-000000000001";
const cursor = encodeCursor({ change: 42, kind: "record", id: "ABC" }, someone);
expect(/^[A-Za-z0-9_-]+$/.test(cursor), "a cursor is safe in a query string");
const back = decodeCursor(cursor, someone);
expect(back?.cursor.change === 42 && back.cursor.kind === "record" && back.cursor.id === "ABC" && !back.elsewhere, "and reads back");
expect(decodeCursor(cursor, "7a7a7a7a-0000-4000-8000-000000000002")?.elsewhere === true, "one made for another account starts from the beginning");
expect(decodeCursor(null, someone)?.cursor.change === 0 && decodeCursor("%%%", someone) === null && decodeCursor("e30", someone) === null, "none is the start; malformed ones are refused");
const at = 1_793_000_000_000;
const parsed = parseChanges(
  JSON.stringify({
    items: [
      { kind: "fact", id: "A", format: 1, updatedAt: at, deleted: false, body: { text: "one" } },
      { kind: "fact", id: "A", format: 1, updatedAt: at + 5, deleted: false, body: { text: "two" } },
      { kind: "surface", id: "P", format: 1, updatedAt: at, deleted: false, body: { photo: "0A1B2C3D-photo" } },
      { kind: "surface", id: "Q", format: 1, updatedAt: at, deleted: true, body: { secret: "dropped" } },
      { kind: "fact", id: "B", format: 1, updatedAt: at, deleted: false, body: { deep: JSON.parse("[".repeat(60) + "]".repeat(60)) } },
    ],
  }),
  at,
);
const changed = (id) => parsed.changes.find((change) => change.id === id);
expect(parsed.changes.length === 3 && changed("A")?.body === '{"text":"two"}', "of two changes to one item, the later is kept");
expect(changed("P")?.photo === "0A1B2C3D-photo", "a page's photo is noticed, so it can be let go later");
expect(changed("Q")?.body === null && changed("Q")?.size === 0, "a deletion keeps no content, even when some is sent");
expect(parsed.refused.length === 1 && parsed.refused[0].reason === "body", "deep nesting is refused");
const ahead = parseChanges(JSON.stringify({ items: [{ kind: "fact", id: "C", format: 1, updatedAt: at + 86_400_000, deleted: true }] }), at).changes[0];
expect(ahead.updatedAt === at + 600_000, "a time far ahead is pulled back to ten minutes ahead");
const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0]);
expect(imageType(jpeg) === "image/jpeg" && imageType(new TextEncoder().encode("<svg onload=x>      ")) === null, "photos are known by their bytes");

// Deleting an account's data: every photo under the person's prefix, a page at a time, then the rows.
const deletedKeys = [];
const statements = [];
const listings = [
  { objects: [{ key: "u1/a" }, { key: "u1/b" }], truncated: true, cursor: "next" },
  { objects: [{ key: "u1/c" }], truncated: false },
];
const listed = [];
const fakeEnv = {
  PHOTOS: {
    async list(options) {
      listed.push(options);
      return listings.shift();
    },
    async delete(keys) {
      deletedKeys.push(...keys);
    },
  },
  DB: {
    prepare: (sql) => ({ bind: (...values) => ({ sql, values }) }),
    async batch(list) {
      statements.push(...list);
      return [];
    },
  },
};
await deleteUserData(fakeEnv, "u1");
expect(deletedKeys.join() === "u1/a,u1/b,u1/c" && listed.every((options) => options.prefix === "u1/") && listed[1]?.cursor === "next", "deleting an account removes every one of its photos, and only its own");
expect(
  ["sync_items", "sync_photos", "sync_state"].every((table) => statements.some((statement) => statement.sql === `DELETE FROM ${table} WHERE user_id = ?` && statement.values[0] === "u1")),
  "and its rows in every sync table",
);
console.log("Crash and hang reports");
const upload = JSON.parse(readFileSync(new URL("./fixtures/diagnostics.json", import.meta.url), "utf8"));
const refusedWith = (body) => {
  try {
    parseReports(typeof body === "string" ? body : JSON.stringify(body));
    return null;
  } catch (error) {
    return error instanceof ReportError ? error.message : `not a ReportError: ${error}`;
  }
};
const [crash, hang, launch] = parseReports(JSON.stringify(upload));
expect(crash?.kind === "crash" && hang?.kind === "hang" && launch?.kind === "launch", "a crash, a hang and a launch");
expect(crash.signature === "EXC_BREAKPOINT SIGTRAP Dream+0x1a2b4", `a crash is grouped by its kind and the innermost frame in Dream (got ${crash.signature})`);
expect(hang.signature === "Dream+0xbeef" && launch.signature === "unknown", `hangs by their frame alone, and no stack is "unknown" (got ${hang.signature}, ${launch.signature})`);
expect(crash.testFlight === true && crash.exceptionType === 6 && crash.signal === 5 && hang.duration === 2.5 && launch.stack === null, "fields as sent");
expect(JSON.parse(crash.stack).callStacks.length === 2, "the stack is kept as JSON");
const [withMessage] = parseReports(JSON.stringify({ format: 1, reports: [{ ...upload.reports[2], kind: "crash", exceptionName: "NSRangeException", composedMessage: "index 3 beyond bounds in Milk, Eggs" }] }));
expect(withMessage.exceptionName === "NSRangeException" && !JSON.stringify(withMessage).includes("Milk"), "an exception's name is kept, never anything else that's sent");
const named = signatureOf({ kind: "crash", exceptionType: 5, signal: 6, exceptionName: "NSRangeException" }, upload.reports[0].stack);
expect(named === "NSRangeException SIGABRT Dream+0x1a2b4", `an Objective-C exception is named (got ${named})`);
const elsewhere = signatureOf({ kind: "hang", exceptionType: null, signal: null, exceptionName: null }, { callStacks: [upload.reports[0].stack.callStacks[0]] });
expect(elsewhere === "libsystem_kernel.dylib+0x1000", `with no frame in Dream, the innermost frame (got ${elsewhere})`);
const huge = structuredClone(upload.reports[1]);
huge.stack.callStacks[0].callStackRootFrames[0].binaryUUID = "x".repeat(MAX_STACK);
const [trimmed] = parseReports(JSON.stringify({ format: 1, reports: [huge] }));
expect(trimmed.stack === null && trimmed.signature === "Dream+0xbeef", "a stack that's too big is dropped, after grouping");
const report = upload.reports[2];
const refusals = {
  "a newer format": { format: 2, reports: [report] },
  "no reports": { format: 1, reports: [] },
  [`more than ${MAX_REPORTS}`]: { format: 1, reports: Array(MAX_REPORTS + 1).fill(report) },
  "another kind": { format: 1, reports: [{ ...report, kind: "freeze" }] },
  "a missing version": { format: 1, reports: [{ ...report, app: undefined }] },
  "a long device": { format: 1, reports: [{ ...report, device: "i".repeat(41) }] },
  "control characters": { format: 1, reports: [{ ...report, os: "iOS\n27" }] },
  "a negative duration": { format: 1, reports: [{ ...report, duration: -1 }] },
  "a fractional signal": { format: 1, reports: [{ ...report, signal: 5.5 }] },
  "a stack that isn't an object": { format: 1, reports: [{ ...report, stack: "frames" }] },
  "testFlight as text": { format: 1, reports: [{ ...report, testFlight: "yes" }] },
};
for (const [what, body] of Object.entries(refusals)) {
  const message = refusedWith(body);
  expect(message !== null && !message.startsWith("not a"), `refuses ${what}${message ? ` (“${message}”)` : ""}`);
}
expect(refusedWith("{nope") === "That isn't JSON.", "refuses what isn't JSON");

console.log("The operator's key");
const asking = (key) => new Request("https://dream.example/api/admin/diagnostics", { headers: key === undefined ? {} : { "X-Admin-Key": key } });
const ADMIN = "an-admin-key-for-tests-0123456789";
expect((await adminAccess(asking(ADMIN), {})) === "unset" && (await adminAccess(asking("short"), { ADMIN_KEY: "short" })) === "unset", "without a key of 16 or more characters, the routes don't exist");
expect((await adminAccess(asking(undefined), { ADMIN_KEY: ADMIN })) === "no", "no key sent");
expect((await adminAccess(asking(`${ADMIN}x`), { ADMIN_KEY: ADMIN })) === "no" && (await adminAccess(asking("wrong"), { ADMIN_KEY: ADMIN })) === "no", "a wrong key");
expect((await adminAccess(asking(ADMIN), { ADMIN_KEY: ADMIN })) === "yes", "the right key");

console.log("Server analytics events");
const realFetch = globalThis.fetch;
const sent = [];
const waited = [];
const ctx = { waitUntil: (promise) => waited.push(promise) };
globalThis.fetch = async (url, init) => {
  sent.push({ url: String(url), body: JSON.parse(init.body) });
  return new Response("{}");
};
capture({}, ctx, "user-1", "limit_reached", { kind: "pages" });
capture({ POSTHOG_KEY: "  " }, ctx, "user-1", "limit_reached");
expect(sent.length === 0 && waited.length === 0, "nothing is sent without a key");
limitReached({ POSTHOG_KEY: "phc_test", POSTHOG_HOST: "https://eu.i.posthog.com/" }, ctx, "user-1", "pages");
await Promise.all(waited);
expect(sent[0]?.url === "https://eu.i.posthog.com/i/v0/e/", `to the configured host's capture endpoint (got ${sent[0]?.url})`);
expect(sent[0]?.body.api_key === "phc_test" && sent[0]?.body.event === "limit_reached" && sent[0]?.body.distinct_id === "user-1", "the key, the event and Dream's id for the person");
expect(sent[0]?.body.properties.kind === "pages" && typeof sent[0]?.body.timestamp === "string", "with its properties and time");
capture({ POSTHOG_KEY: "phc_test", POSTHOG_HOST: "http://insecure.example" }, ctx, "user-1", "limit_reached");
expect(sent.length === 1, "only to an https host");
globalThis.fetch = async () => {
  throw new Error("offline");
};
let threw = false;
try {
  capture({ POSTHOG_KEY: "phc_test" }, ctx, "user-1", "subscription_ended");
  await Promise.all(waited);
} catch {
  threw = true;
}
expect(!threw, "a failure to send never throws");

console.log("Model requests, for LLM analytics");
const generations = [];
const waiting = [];
const later = { waitUntil: (promise) => waiting.push(promise) };
globalThis.fetch = async (_url, init) => {
  generations.push(JSON.parse(init.body));
  return new Response("{}");
};
expect(countsAllowed(new Request("https://dream.example/api/model", { headers: { "X-Dream-Analytics": "on" } })) && !countsAllowed(new Request("https://dream.example/api/model")), "only when the app says the person allows it");
aiGeneration({ POSTHOG_KEY: "phc_test" }, later, "user-1", { model: "grok-4.7", page: "PAGE-1234", plan: "free", tokensIn: 1000, tokensCached: 600, tokensOut: 300, cost: 0.0042, latency: 12.3456, firstToken: 1.2, stream: true, status: 200 });
aiGeneration({ POSTHOG_KEY: "phc_test" }, later, "user-1", { model: "grok-4.7", page: null, plan: "plus", tokensIn: 0, tokensCached: 0, tokensOut: 0, cost: null, latency: 0.5, firstToken: null, stream: true, status: 429 });
await Promise.all(waiting);
const [built, failed] = generations;
expect(built?.event === "$ai_generation" && built.distinct_id === "user-1" && built.properties.$ai_trace_id === "PAGE-1234" && built.properties.$ai_input_tokens === 1000 && built.properties.$ai_cache_read_input_tokens === 600, "a page's request, in its page's trace, with its tokens");
expect(built?.properties.$ai_total_cost_usd === 0.0042 && built.properties.$ai_latency === 12.346 && built.properties.$ai_time_to_first_token === 1.2 && built.properties.$ai_provider === "xai", "its cost and times");
expect(!Object.keys(built?.properties ?? {}).some((key) => key === "$ai_input" || key === "$ai_output_choices"), "never the messages or the answer");
expect(failed?.properties.$ai_is_error === true && failed.properties.$ai_http_status === 429 && failed.properties.$ai_span_name === "lists" && !("$ai_total_cost_usd" in failed.properties) && typeof failed.properties.$ai_trace_id === "string", "a failure, with no cost and a trace of its own");
globalThis.fetch = realFetch;

console.log("Chat completions as xAI's Responses API");
const photo = "data:image/jpeg;base64,AAAA";
const asked = toResponses(
  {
    model: "grok-4.7",
    stream: true,
    stream_options: { include_usage: true },
    max_tokens: 900,
    reasoning_effort: "low",
    response_format: { type: "json_schema", json_schema: { name: "response", strict: true, schema: { type: "object" } } },
    tools: [{ type: "function", function: { name: "lookup", description: "Looks up.", parameters: { type: "object", properties: {} } } }],
    tool_choice: "auto",
    messages: [
      { role: "system", content: "Make a page." },
      { role: "user", content: [{ type: "text", text: "What is this?" }, { type: "image_url", image_url: { url: photo } }] },
      { role: "assistant", content: "", tool_calls: [{ id: "call-1", type: "function", function: { name: "lookup", arguments: '{"q":"x"}' } }] },
      { role: "tool", tool_call_id: "call-1", content: "found" },
    ],
  },
  "cache-key",
);
expect(asked.store === false && asked.prompt_cache_key === "cache-key" && asked.stream === true && asked.max_output_tokens === 900 && asked.reasoning?.effort === "low", "nothing stored, the cache key, streaming, the cap and the effort");
expect(asked.text?.format?.type === "json_schema" && asked.text.format.name === "response" && asked.text.format.strict === true, "a JSON schema as text.format");
expect(asked.tools?.[0]?.type === "function" && asked.tools[0].name === "lookup" && asked.tools[0].parameters?.type === "object" && asked.tool_choice === "auto", "tools as Responses functions");
const [system, userTurn, call, result, extra] = asked.input;
expect(system?.role === "system" && system.content === "Make a page." && userTurn?.content?.[1]?.type === "input_image" && userTurn.content[1].image_url === photo, "a photo as an input_image");
expect(call?.type === "function_call" && call.call_id === "call-1" && call.arguments === '{"q":"x"}' && result?.type === "function_call_output" && result.call_id === "call-1" && result.output === "found" && extra === undefined, "a tool call and its result as items, without an empty assistant message");
expect(!("messages" in asked) && !("stream_options" in asked), "nothing chat completions only");
const mapped = chatUsage({ input_tokens: 100, input_tokens_details: { cached_tokens: 80 }, output_tokens: 30, output_tokens_details: { reasoning_tokens: 20 }, total_tokens: 130, cost_in_usd_ticks: 5 });
expect(mapped?.prompt_tokens === 100 && mapped.prompt_tokens_details.cached_tokens === 80 && mapped.completion_tokens === 10 && mapped.completion_tokens_details.reasoning_tokens === 20 && mapped.cost_in_usd_ticks === 5, "usage with reasoning apart, as chat completions count it");
const finished = chatCompletion({ id: "r1", status: "completed", output: [{ type: "reasoning" }, { type: "function_call", call_id: "c9", name: "lookup", arguments: "{}" }] }, "grok-4.7");
expect(finished.choices[0].finish_reason === "tool_calls" && finished.choices[0].message.tool_calls[0].id === "c9" && finished.choices[0].message.content === null, "a finished answer with a tool call");
const events = (list) => new Blob(list.map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`)).stream();
const cut = await new Response(chatStream(events([{ type: "response.created", response: { id: "r2" } }, { type: "response.output_text.delta", delta: "Hal" }]), "grok-4.7")).text();
expect(cut.includes('"content":"Hal"') && cut.trimEnd().endsWith("data: [DONE]") && cut.includes('"id":"r2"'), "a stream cut short still ends, with what came");
const failedStream = await new Response(chatStream(events([{ type: "response.created", response: { id: "r3" } }, { type: "response.failed", response: { error: { message: "secret prompt words" } } }]), "grok-4.7")).text();
expect(failedStream.trimEnd().endsWith("data: [DONE]") && !failedStream.includes("secret prompt words"), "a failed answer ends without passing on what xAI said");

console.log("Which model answers");
const all = offered("grok-4.7,nonsense,grok-4.20-fast");
expect(all.map((model) => model.id).join() === "grok-4.7,grok-4.20-fast" && offered("").length === CATALOG.length, "the models offered, in order, ignoring unknown ones");
expect(choose(undefined, "free", all).id === "grok-4.7" && choose("default", "plus", all).id === "grok-4.7", "nothing asked for is the default, on either plan");
expect(choose("grok-4.20-fast", "plus", all).id === "grok-4.20-fast" && choose("grok-4.20-fast", "free", all).id === "grok-4.7", "a Plus model for Dream Plus; the default for everyone else, so older apps and lapsed plans still work");
expect(choose("grok-4.20-fast", "free", all, true).id === "grok-4.20-fast", "test accounts on the bench may use any");
expect(choose("grok-5-heavy", "plus", all).id === "grok-4.7" && choose(42, "plus", all).id === "grok-4.7", "a model nobody offers, or one since retired, gets the default instead");
expect(choose(undefined, "free", offered("grok-4.20-fast")).id === "grok-4.20-fast", "with only Plus models offered, the first is everyone's");
const byID = (id) => CATALOG.find((model) => model.id === id);
expect(fitEffort("high", byID("grok-4.7")) === "high" && fitEffort(undefined, byID("grok-4.7")) === "low", "a level the model takes stands; none asked is low");
expect(fitEffort("none", byID("grok-4.7")) === "low" && fitEffort("max", byID("grok-4.7")) === "high", "Grok can't think less than low or more than high");
expect(fitEffort("medium", byID("deepseek-v4.1-flash")) === "high" && fitEffort("none", byID("deepseek-v4.1-flash")) === "none", "a level the model doesn't take moves to the nearest, leaning longer");
expect(fitEffort("high", byID("mistral-small-3.1")) === null && fitEffort("low", byID("kimi-k2.6")) === "none", "a model that doesn't think gets no level at all");
expect(CATALOG.every((model) => model.efforts.every((level) => ["none", "low", "medium", "high", "max"].includes(level))), "every model's levels are known ones");
expect(allowedEffort("max", "plus", true) === "max" && allowedEffort("none", "plus", true) === "none", "testers may ask any level");
expect(allowedEffort("none", "plus", false) === "low" && allowedEffort("max", "plus", false) === "high" && allowedEffort("medium", "plus", false) === "medium", "Dream Plus low to high");
expect(allowedEffort("high", "free", false) === "low" && allowedEffort(undefined, "free", false) === "low", "the free plan low");

console.log("Auto: reading Clef");
const clefSays = (answers) => ({ model: "clef-flash", answers, usage: { input_tokens: 812, output_tokens: 0 } });
const plainAnswers = {
  topic: { type: "choice", choice: "money", probabilities: { money: 0.9, science: 0.04, lists: 0.02, figures: 0.02, other: 0.02 }, confidence: 0.86 },
  fresh: { type: "noul", noul: 0.08 },
  foreign: { type: "noul", noul: 0.02 },
  difficulty: { type: "score", score: 1.8, legend: {}, probabilities: { 0: 0.1, 1: 0.2, 2: 0.5, 3: 0.2 }, confidence: 0.4 },
};
const read = readAnswers(clefSays(plainAnswers), false);
expect(read?.topic === "money" && read.fresh === 0.08 && read.foreign === 0.02 && read.difficulty === 1.8 && read.photo === false, "Clef's typed answers, read as the router's signals");
expect(readAnswers({ result: clefSays(plainAnswers) }, true)?.photo === true, "and the same wrapped in the REST API's result");
const without = (key, value) => clefSays({ ...plainAnswers, [key]: value });
expect(
  readAnswers(without("topic", undefined), false) === null &&
    readAnswers(without("topic", { ...plainAnswers.topic, choice: "poetry" }), false) === null &&
    readAnswers(without("fresh", { type: "noul", noul: 1.4 }), false) === null &&
    readAnswers(without("foreign", { type: "noul", noul: "yes" }), false) === null &&
    readAnswers(without("difficulty", { type: "score", score: Number.NaN }), false) === null &&
    readAnswers(null, false) === null && readAnswers({ error: "busy" }, false) === null,
  "an answer missing, out of range or of the wrong kind reads as nothing, so the default is used",
);
expect(readAnswers(without("difficulty", { type: "score", score: 3.4 }), false)?.difficulty === 3, "a score past the top is held to it");
expect(clefCost(clefSays(plainAnswers)).tokensIn === 812 && Math.abs(clefCost(clefSays(plainAnswers)).cost - 812 * CLEF.inputPrice) < 1e-9 && clefCost({}).cost === 0, "what Clef cost, from its input tokens alone");
const clefAsked = clefInput("split a ₹2,000 bill", true, "data:image/jpeg;base64,AAAA");
expect(clefAsked.model === "clef-flash" && clefAsked.state.includes('"split a ₹2,000 bill"') && clefAsked.images?.[0] === "data:image/jpeg;base64,AAAA" && clefAsked.questions === QUESTIONS, "Clef gets the request as state, the questions, and the photo");
expect(!("images" in clefInput("hello", false)) && clefInput("hello", true).state.includes("attached a photo"), "no photo sent unless there is one; one only mentioned is said");
expect(Object.keys(QUESTIONS.topic.criteria).join() === TOPICS.join() && QUESTIONS.difficulty.criteria.length === 4, "the topic question offers exactly the router's topics, and difficulty four levels");

console.log("Auto: the table");
const signals = (extra) => ({ topic: "money", fresh: 0.1, foreign: 0.1, difficulty: 1, photo: false, ...extra });
expect(classify(signals({})).category === "money" && classify(signals({})).difficulty === "easy", "the topic decides, easy below the line");
expect(classify(signals({ difficulty: HARD_FROM })).difficulty === "hard", `hard from ${HARD_FROM}`);
expect(classify(signals({ photo: true, fresh: 0.9, foreign: 0.9 })).category === "photo", "a photo outranks everything: the model has to read it");
expect(classify(signals({ fresh: 0.7, foreign: 0.9 })).category === "language" && classify(signals({}), "मेरे ₹50,000 पर ब्याज कितना होगा?").category === "language", "then another language, from Clef or from the script itself, even for live facts");
expect(classify(signals({ fresh: 0.7 })).category === "live", "then facts that must be looked up now");
expect(classify(signals({}), "Wie viel Zinsen?").category === "money" && !nonLatin("café crème brûlée") && nonLatin("சென்னை பயணம்"), "Latin letters with accents aren't another script");
const ids = CATALOG.map((model) => model.id);
const rows = Object.entries(TABLE).flatMap(([category, byLevel]) => Object.entries(byLevel).map(([level, row]) => ({ category, level, row })));
expect(rows.length === 16 && Object.keys(TABLE).sort().join() === [...TOPICS, "photo", "live", "language"].sort().join(), "a row for every category, easy and hard");
expect(rows.every(({ row }) => row.picks.length > 0 && row.why.length > 0 && row.why.length <= 120), "each with picks and one short line why");
expect(rows.every(({ row }) => row.picks.every((each) => ids.includes(each.model))), "only models in the catalogue");
expect(rows.every(({ row }) => row.picks.every((each) => { const model = byID(each.model); return model.efforts.length ? model.efforts.includes(each.effort) : each.effort === "none"; })), "each at a level its model takes (none for one that doesn't think)");
expect(rows.every(({ row }) => row.picks.some((each) => each.model === DEFAULT_PICK.model)), "every row names the default model too, so an account limited to it still gets the row's thinking level");
expect(rows.filter(({ category }) => category === "photo").every(({ row }) => row.picks.every((each) => READS_PHOTOS.has(each.model))), "a photo row only names models that read photos");
expect(rows.every(({ row }) => row.picks.at(-1).model === DEFAULT_PICK.model && row.picks.at(-1).effort === "low"), "and ends on it thinking low, which every plan may use");
// What route.ts asks of a pick: a model the account may use, at the level the bench used.
const usableFor = (plan, tester, offeredIDs = ids) => (each) => {
  const model = byID(each.model);
  return offeredIDs.includes(each.model) && (tester || !model.plus || plan === "plus") && (fitEffort(allowedEffort(each.effort, plan, tester), model) ?? "none") === each.effort;
};
const sums = TABLE.money.easy;
expect(sums.picks[0].effort === "none" && firstUsable(sums, usableFor("plus", true)) === sums.picks[0], "a tester gets the row's first pick as benched");
expect(firstUsable(sums, usableFor("plus", false))?.model === DEFAULT_PICK.model && firstUsable(sums, usableFor("free", false))?.model === DEFAULT_PICK.model, "Dream Plus and the free plan can't think 'none', so that pick gives way to the next, not to a level never benched");
const live = TABLE.live.easy;
expect(firstUsable(live, usableFor("plus", false)) === live.picks[0] && firstUsable(live, usableFor("free", false)) === live.picks.at(-1), "a Plus-only model for Dream Plus; the default for the free plan");
expect(firstUsable(live, usableFor("plus", false, [DEFAULT_PICK.model])) === live.picks.at(-1), "only the models this server offers (MODELS)");
expect(firstUsable(live, () => false) === null, "and nothing usable gives nothing, so the default");
const said = (content, more = []) => [{ role: "system", content: "Make one page." }, { role: "user", content }, ...more];
expect(guess(said([{ type: "text", text: "Request: what is this?" }, { type: "image_url", image_url: { url: "data:image/jpeg;base64,AAAA" } }])).category === "photo", "without Clef: a photo in any message makes it a photo page");
expect(guess(said("Request: प्रकाश संश्लेषण कैसे काम करता है?")).category === "language" && guess(said("Request: what's 2+2")).category === "other", "a run of another script in the first user message makes it another language; else the default's row");
expect(guess(said("Request: what's 2+2", [{ role: "assistant", content: "" }, { role: "tool", content: "प्रकाश संश्लेषण ".repeat(5) }])).category === "other" && guess(null).category === "other", "only the first user message is read, so a page's later tool results don't move it");

console.log("A quiet stream kept alive");
const slow = new ReadableStream({
  async start(controller) {
    await new Promise((resolve) => setTimeout(resolve, 130));
    controller.enqueue(new TextEncoder().encode("data: late\n\n"));
    controller.close();
  },
});
const beating = await new Response(withHeartbeat(slow, 50)).text();
expect(beating.startsWith(": thinking\n\n") && (beating.match(/: thinking/g) ?? []).length >= 2 && beating.endsWith("data: late\n\n"), "comments while the model is quiet, then what it says, none of it lost");

console.log("Workers AI, as the app reads it");
const piecesOf = (list) => new Blob(list.map((event) => `data: ${typeof event === "string" ? event : JSON.stringify(event)}\n\n`)).stream();
const delta = (d, extra = {}) => ({ id: "w1", object: "chat.completion.chunk", choices: [{ index: 0, delta: d, finish_reason: null }], ...extra });
const workers = await new Response(
  workersStream(
    piecesOf([
      delta({ role: "assistant", content: "" }, { usage: { prompt_tokens: 183, completion_tokens: 0, total_tokens: 183, neurons: 2.5 } }),
      delta({ reasoning_content: "Thinking" }),
      delta({ tool_calls: [{ id: "call_1", index: 0, type: "function", function: { name: "lookup_weather", arguments: "" } }] }),
      delta({ tool_calls: [{ index: 0, function: { arguments: '{"city":' } }] }),
      delta({ tool_calls: [{ index: 0, function: { arguments: '"Pune"}' } }] }),
      { id: "w1", choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
      { id: "w1", choices: [], usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0, neurons: 0 } },
      { response: "", usage: { prompt_tokens: 183, completion_tokens: 37, total_tokens: 220, prompt_tokens_details: { cached_tokens: 128 }, neurons: 4 } },
      "[DONE]",
    ]),
    "deepseek-v4.1-flash",
  ),
).text();
const workerChunks = workers.split("\n").filter((line) => line.startsWith("data:") && !line.includes("[DONE]")).map((line) => JSON.parse(line.slice(5)));
const wholeCalls = workerChunks.flatMap((chunk) => chunk.choices?.[0]?.delta?.tool_calls ?? []);
expect(wholeCalls.length === 1 && wholeCalls[0].id === "call_1" && wholeCalls[0].function.name === "lookup_weather" && wholeCalls[0].function.arguments === '{"city":"Pune"}', "a tool call's pieces go on as one whole call");
expect(workers.includes('"reasoning_content":"Thinking"') && workers.includes('"finish_reason":"tool_calls"') && workers.trimEnd().endsWith("data: [DONE]"), "reasoning as it comes, then the finish and [DONE]");
const workerUsage = workerChunks.filter((chunk) => chunk.usage);
expect(workerUsage.length === 1 && workerUsage[0].usage.total_tokens === 220 && workerUsage[0].usage.prompt_tokens_details.cached_tokens === 128 && workerUsage[0].usage.cost_in_usd_ticks === 440_000, "one usage, the total, with neurons as dollars");
expect(workersUsage({ prompt_tokens: 10, completion_tokens: 5, neurons: 1 })?.cost_in_usd_ticks === 110_000 && workersCompletion({ choices: [], usage: { prompt_tokens: 1, neurons: 2 } }, "deepseek-v4.1-flash").usage.cost_in_usd_ticks === 220_000, "a neuron is $0.000011");

console.log("Apple's sign-in keys, kept for every server");
const { publicKey } = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
const jwk = await crypto.subtle.exportKey("jwk", publicKey);
const keysBody = JSON.stringify({ keys: [{ kty: "RSA", kid: "K1", use: "sig", alg: "RS256", n: jwk.n, e: jwk.e }] });
const keptKeys = new Map();
const store = { read: async (url) => keptKeys.get(url) ?? null, write: async (url, body, fetchedAt) => void keptKeys.set(url, { body, fetchedAt }) };
let appleCalls = 0;
globalThis.fetch = async () => {
  appleCalls++;
  return new Response("", { status: 501 });
};
let unavailable = false;
try {
  await appleKeys("https://refused.example", store)("K1");
} catch (error) {
  unavailable = error instanceof AppleUnavailable;
}
expect(unavailable, "with Apple refusing and nothing kept, signing in says Apple can't be reached");
keptKeys.set("https://refused.example/auth/keys", { body: keysBody, fetchedAt: Date.now() - 3 * 86_400_000 });
expect((await appleKeys("https://refused.example", store)("K1")) !== null, "with Apple refusing, keys kept days ago still check tokens");
globalThis.fetch = async () => {
  appleCalls++;
  return new Response(keysBody);
};
expect((await appleKeys("https://fine.example", store)("K1")) !== null && keptKeys.get("https://fine.example/auth/keys")?.body === keysBody, "a good fetch is kept for every server");
keptKeys.set("https://kept.example/auth/keys", { body: keysBody, fetchedAt: Date.now() });
appleCalls = 0;
expect((await appleKeys("https://kept.example", store)("K1")) !== null && appleCalls === 0, "keys kept today are used without asking Apple");
globalThis.fetch = realFetch;

console.log(failures ? `\n${failures} failed` : "\nAll passed");
process.exit(failures ? 1 : 0);
