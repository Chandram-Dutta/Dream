// Checks the reader's pure parts in Node, without a Worker: which addresses it may fetch,
// robots.txt, and how web text is tidied; and sync's rules, with deleting someone's data.
// Node runs the TypeScript files directly.
//
//   node test/unit.mjs

import { checkURL, isPublicIP, parseIP } from "../src/address.ts";
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

console.log(failures ? `\n${failures} failed` : "\nAll passed");
process.exit(failures ? 1 : 0);
