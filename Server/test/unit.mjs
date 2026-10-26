// Checks the reader's pure parts in Node, without a Worker: which addresses it may fetch,
// robots.txt, and how web text is tidied. Node runs the TypeScript files directly.
//
//   node test/unit.mjs

import { checkURL, isPublicIP, parseIP } from "../src/address.ts";
import { checkPublish, words } from "../src/moderation.ts";
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

console.log(failures ? `\n${failures} failed` : "\nAll passed");
process.exit(failures ? 1 : 0);
