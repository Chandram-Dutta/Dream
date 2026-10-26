// Checks the Worker's pure parts in Node, without a Worker: which addresses the reader may fetch,
// robots.txt, how web text is tidied, crash reports, the operator's key, and the server's own
// analytics events. Node runs the TypeScript files directly.
//
//   node test/unit.mjs

import { readFileSync } from "node:fs";
import { checkURL, isPublicIP, parseIP } from "../src/address.ts";
import { adminAccess } from "../src/adminkey.ts";
import { capture, limitReached } from "../src/analytics.ts";
import { MAX_REPORTS, MAX_STACK, parseReports, ReportError, signatureOf } from "../src/metrickit.ts";
import { robotsAllows } from "../src/robots.ts";
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
globalThis.fetch = realFetch;

console.log(failures ? `\n${failures} failed` : "\nAll passed");
process.exit(failures ? 1 : 0);
