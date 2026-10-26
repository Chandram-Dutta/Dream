// Checks shared links' owners, reports, blocks, the admin and the publish check (src/shares.ts,
// src/safety.ts, src/moderation.ts), over HTTP against the local server smoke.mjs starts. It needs
// the dev sign-in (DEV_LOGIN) for several test users, and the admin key the server was started with.
//
// The publish check's word lists are tested with the made-up words each holds for the purpose
// (moderation.ts), so no real slur is written here.

const BROWSER = { "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15" };
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export async function runSharing(base, { expect, signIn, fixture, adminKey, legacyID }) {
  const send = (method, path, { auth, body, type = "application/json", headers = {} } = {}) =>
    fetch(`${base}${path}`, {
      method,
      headers: { ...(body !== undefined ? { "Content-Type": type } : {}), ...auth, ...headers },
      body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
    });
  const page = (title, text = "Tipping customs vary.") => {
    const shared = JSON.parse(fixture);
    shared.surface.title = title;
    shared.surface.blocks.push({ id: "said", kind: "paragraph", title: "", text, ref: "", over: "", items: [], children: [] });
    return shared;
  };
  const blank = (shared) => {
    const { values: _, ...rest } = shared;
    return rest;
  };
  const share = async (who, shared, query = "") => {
    const response = await send("POST", `/api/surfaces${query}`, { auth: who.auth, body: shared });
    return { status: response.status, ...(await response.json()) };
  };
  const listOf = async (who) => (await (await send("GET", "/api/me/shares", { auth: who.auth })).json()).shares ?? [];

  const [ada, ben, cat, dee] = await Promise.all(["ada", "ben", "cat", "dee"].map(signIn));

  console.log("Sharing needs an account");
  let response = await send("POST", "/api/surfaces", { body: fixture });
  expect(response.status === 401, "making a link without signing in is refused");
  response = await send("POST", "/api/surfaces", { auth: { Authorization: `Bearer ${"x".repeat(43)}` }, body: fixture });
  expect(response.status === 401, "and with a session that isn't one");
  response = await send("GET", `/api/surfaces/${legacyID}`);
  expect(response.status === 200 && (await response.json()).surface?.title === "Split a bill", "a link from before accounts still opens");
  response = await send("GET", `/s/${legacyID}`, { headers: BROWSER });
  expect(response.status === 200, "and shows on the web");

  console.log("Links belong to whoever made them");
  const pageID = crypto.randomUUID();
  const first = await share(ada, page("Ada bill"), `?page=${pageID}`);
  expect(first.status === 201 && first.reused === false, `a new link (got ${first.status})`);
  const again = await share(ada, page("Ada bill, tidied"), `?page=${pageID}`);
  expect(again.status === 200 && again.reused === true && again.id === first.id, "sharing the same page again reuses its link");
  response = await send("GET", `/api/surfaces/${first.id}`, { auth: ada.auth });
  expect((await response.json()).surface?.title === "Ada bill, tidied", "with the newest version behind it");
  const fresh = await share(ada, page("Ada bill, tidied"), `?page=${pageID}&new=1`);
  expect(fresh.status === 201 && fresh.id !== first.id, "unless a new link is asked for");
  const withoutNumbers = await share(ada, blank(page("Ada bill, blank")), `?page=${pageID}`);
  expect(withoutNumbers.status === 201 && withoutNumbers.id !== first.id, "a link without the sharer's numbers is a different link");
  const elsewhere = await share(ben, page("Ada bill, tidied"), `?page=${pageID}`);
  expect(elsewhere.status === 201 && elsewhere.id !== first.id, "and someone else sharing a page with the same id gets their own");

  let mine = await listOf(ada);
  const listed = mine.find((link) => link.id === first.id);
  expect(mine.length === 3 && listed?.state === "shared" && listed.hasValues === true && listed.page === pageID, "the owner's list has their links, with numbers or not");
  expect(listed?.title === "Ada bill, tidied" && listed.accent === JSON.parse(fixture).surface.accent && listed.url.endsWith(`/s/${first.id}`), "each with its title, colors and link");
  expect(mine.find((link) => link.id === withoutNumbers.id)?.hasValues === false, "and whether the numbers went too");
  expect(!(await listOf(ben)).some((link) => link.id === first.id), "nobody else's list has them");
  response = await send("GET", "/api/me/shares");
  expect(response.status === 401, "the list needs signing in");

  console.log("Only the owner changes a link");
  response = await send("PUT", `/api/surfaces/${first.id}`, { auth: ben.auth, body: page("Ben was here") });
  expect(response.status === 403, "someone else can't update it");
  response = await send("DELETE", `/api/surfaces/${first.id}`, { auth: ben.auth });
  expect(response.status === 403, "or stop it");
  response = await send("PUT", `/api/surfaces/${first.id}`, { body: page("Nobody") });
  expect(response.status === 401, "nor can someone signed out");
  response = await send("PUT", `/api/surfaces/${legacyID}`, { auth: ada.auth, body: page("Mine now") });
  expect(response.status === 403, "a link from before accounts stays as it is");
  response = await send("PUT", `/api/surfaces/${first.id}`, { auth: ada.auth, body: page("Ada bill, final") });
  const updated = await response.json();
  expect(response.status === 200 && updated.title === "Ada bill, final" && updated.id === first.id, "the owner updates it to the newest version");
  response = await send("GET", `/s/${first.id}`, { headers: BROWSER });
  expect((await response.text()).includes("Ada bill, final"), "which the web viewer shows");
  const soon = Math.floor(Date.now() / 1000) + 3_600;
  response = await send("PUT", `/api/surfaces/${first.id}`, { auth: ada.auth, body: { expiresAt: soon } });
  expect(response.status === 200 && (await response.json()).expiresAt === soon, "the owner sets it to expire");
  response = await send("PUT", `/api/surfaces/${first.id}`, { auth: ada.auth, body: { expiresAt: null } });
  expect(response.status === 200 && (await response.json()).expiresAt === null, "or never to");
  response = await send("PUT", `/api/surfaces/${first.id}`, { auth: ada.auth, body: { expiresAt: 1_000 } });
  expect(response.status === 400, "but not in the past");
  response = await send("PUT", `/api/surfaces/${first.id}`, { auth: ada.auth, body: {} });
  expect(response.status === 400, "an update needs something in it");

  console.log("Views");
  // Views are counted after the page is sent; let the ones above land first.
  await sleep(300);
  const before = (await listOf(ada)).find((link) => link.id === first.id)?.views ?? -1;
  await send("GET", `/s/${first.id}`, { headers: BROWSER });
  await send("GET", `/s/${first.id}`, { headers: { "User-Agent": "facebookexternalhit/1.1 Facebot Twitterbot/1.0" } });
  await send("HEAD", `/s/${first.id}`, { headers: BROWSER });
  await send("GET", `/api/surfaces/${first.id}`, { auth: ada.auth });
  await send("GET", `/api/surfaces/${first.id}`, { auth: cat.auth });
  let views = before;
  for (let attempt = 0; attempt < 20 && views < before + 2; attempt++) {
    await sleep(100);
    views = (await listOf(ada)).find((link) => link.id === first.id)?.views ?? -1;
  }
  await sleep(300);
  views = (await listOf(ada)).find((link) => link.id === first.id)?.views ?? -1;
  expect(views === before + 2, `a person on the web and one in the app count; previews, the owner and HEAD don't (${before} → ${views})`);

  console.log("Stopping");
  response = await send("DELETE", `/api/surfaces/${fresh.id}`, { auth: ada.auth });
  expect(response.status === 200 && (await response.json()).state === "stopped", "the owner stops sharing");
  response = await send("GET", `/api/surfaces/${fresh.id}`);
  expect(response.status === 410 && (await response.json()).state === "stopped", "the app is told it's gone (410)");
  response = await send("GET", `/s/${fresh.id}`, { headers: BROWSER });
  expect(response.status === 410 && (await response.text()).includes("This page is no longer shared"), "the web viewer says so calmly");
  response = await send("PUT", `/api/surfaces/${fresh.id}`, { auth: ada.auth, body: page("Back again") });
  expect(response.status === 410, "a stopped link stays stopped");
  response = await send("DELETE", `/api/surfaces/${fresh.id}`, { auth: ada.auth });
  expect(response.status === 200, "stopping twice is fine");
  mine = await listOf(ada);
  expect(mine.find((link) => link.id === fresh.id)?.state === "stopped" && mine.find((link) => link.id === fresh.id)?.accent === null, "the list keeps it as stopped, without its page");

  console.log("Expiry");
  const briefPage = crypto.randomUUID();
  const brief = await share(dee, page("A brief page"), `?page=${briefPage}`);
  await send("PUT", `/api/surfaces/${brief.id}`, { auth: dee.auth, body: { expiresAt: Math.floor(Date.now() / 1000) + 2 } });
  await sleep(3_100);
  response = await send("GET", `/api/surfaces/${brief.id}`);
  expect(response.status === 410 && (await response.json()).state === "expired", "an expired link is gone (410)");
  response = await send("GET", `/s/${brief.id}`, { headers: BROWSER });
  expect(response.status === 410 && (await response.text()).includes("set to stop working"), "and says it expired");
  const replaced = await share(dee, page("A brief page"), `?page=${briefPage}`);
  expect(replaced.status === 201 && replaced.id !== brief.id, "sharing the page again makes a new link");

  console.log("Reports");
  response = await send("POST", `/api/surfaces/${first.id}/report`, { body: { reason: "spam", note: "Looks like an ad.\u0000" } });
  expect(response.status === 202, "the app reports a page");
  response = await send("POST", `/api/surfaces/${first.id}/report`, { body: { reason: "boring" } });
  expect(response.status === 400, "with one of the reasons");
  response = await send("POST", `/api/surfaces/${fresh.id}/report`, { body: { reason: "spam" } });
  expect(response.status === 410, "a page that's no longer shared can't be reported");
  response = await send("POST", "/api/surfaces/ZZZZZZZZZZ/report", { body: { reason: "spam" } });
  expect(response.status === 404, "nor one that never was");
  response = await send("GET", `/s/${first.id}`, { headers: BROWSER });
  expect((await response.text()).includes(`href="/s/${first.id}/report"`), "the web viewer links to a report form");
  response = await send("GET", `/s/${first.id}/report`, { headers: BROWSER });
  const form = await response.text();
  expect(response.status === 200 && form.includes('name="reason"') && form.includes("<textarea") && !form.includes("<script"), "a form with reasons and a note, without script");
  expect(response.headers.get("content-security-policy")?.includes("form-action 'self'"), "which may only post back here");
  response = await send("POST", `/s/${first.id}/report`, { body: "reason=hate&note=Not+nice", type: "application/x-www-form-urlencoded" });
  expect(response.status === 202 && (await response.text()).includes("Thanks"), "the web viewer takes a report");
  response = await send("POST", `/s/${first.id}/report`, { body: "note=No+reason", type: "application/x-www-form-urlencoded" });
  expect(response.status === 400 && (await response.text()).includes("Choose what"), "and asks again without a reason");
  let limited = false;
  for (let attempt = 0; attempt < 8 && !limited; attempt++) {
    limited = (await send("POST", `/api/surfaces/${first.id}/report`, { body: { reason: "other" } })).status === 429;
  }
  expect(limited, "too many reports from one address are refused for a while");

  console.log("Admin");
  const admin = { "X-Admin-Key": adminKey };
  response = await send("GET", "/api/admin/reports");
  expect(response.status === 401, "no key is refused");
  response = await send("GET", "/api/admin/reports", { headers: { "X-Admin-Key": `${adminKey}x` } });
  expect(response.status === 401, "a wrong key is refused");
  response = await send("GET", "/api/admin/reports", { headers: admin });
  let cases = (await response.json()).cases ?? [];
  const reported = cases.find((item) => item.id === first.id);
  expect(response.status === 200 && reported?.reports >= 2 && reported.reasons.spam === 1 && reported.reasons.hate === 1, "the right key lists open reports by page");
  expect(reported?.notes.includes("Looks like an ad.") && reported.owner === ada.user, "with notes (tidied) and who shared it");
  response = await send("GET", "/admin");
  expect(response.status === 200 && (await response.text()).includes('type="password"'), "the admin page asks for the key");
  response = await send("POST", "/admin", { body: "key=wrong", type: "application/x-www-form-urlencoded" });
  expect(response.status === 401, "and refuses a wrong one");
  response = await send("POST", "/admin", { body: `key=${encodeURIComponent(adminKey)}`, type: "application/x-www-form-urlencoded" });
  const dashboard = await response.text();
  expect(response.status === 200 && dashboard.includes("Ada bill, final") && dashboard.includes(`value="${first.id}"`), "and with the right one, lists reported pages with what can be done");
  response = await send("POST", `/api/admin/surfaces/${first.id}/dismiss`, { headers: admin });
  cases = (await (await send("GET", "/api/admin/reports", { headers: admin })).json()).cases ?? [];
  expect(response.status === 200 && !cases.some((item) => item.id === first.id), "dismissing closes a page's reports");
  response = await send("GET", `/api/surfaces/${first.id}`);
  expect(response.status === 200, "and leaves it up");

  const bensOther = await share(ben, page("Ben other page"));
  response = await send("POST", `/api/admin/surfaces/${elsewhere.id}/remove`, { headers: admin, body: { block: true } });
  expect(response.status === 200, "the admin takes a page down and blocks its sharer");
  response = await send("GET", `/s/${elsewhere.id}`, { headers: BROWSER });
  expect(response.status === 410 && (await response.text()).includes("This page was removed"), "the page says it was removed");
  response = await send("GET", `/api/surfaces/${elsewhere.id}`);
  expect(response.status === 410 && (await response.json()).state === "removed", "and the app is told");
  response = await send("GET", `/api/surfaces/${bensOther.id}`);
  expect(response.status === 410, "the sharer's other pages come down too");
  const refused = await share(ben, page("Ben tries again"));
  expect(refused.status === 403 && refused.reason === "banned", "and they can't share again");
  response = await send("POST", `/api/admin/users/${ben.user}/unblock`, { headers: admin });
  expect(response.status === 200 && (await share(ben, page("Ben back"))).status === 201, "until the admin lets them");
  response = await send("POST", "/api/admin/surfaces/ZZZZZZZZZZ/remove", { headers: admin });
  expect(response.status === 404, "taking down a link that doesn't exist says so");

  console.log("Blocking a sharer");
  const adaOther = await share(ada, page("Ada other page"));
  const bensNew = await share(ben, page("Ben new page"));
  response = await send("GET", `/api/surfaces/${first.id}`, { auth: cat.auth });
  expect(response.status === 200, "someone opens a shared page");
  response = await send("POST", `/api/surfaces/${first.id}/block`, { auth: cat.auth, body: { opened: [first.id, adaOther.id, bensNew.id, "not-an-id"] } });
  const blocked = await response.json();
  expect(response.status === 200 && blocked.blocked === true, "and chooses not to see its sharer again");
  expect(blocked.hidden?.length === 2 && blocked.hidden.includes(first.id) && blocked.hidden.includes(adaOther.id), "learning which pages they've opened came from them, and no others");
  response = await send("GET", `/api/surfaces/${adaOther.id}`, { auth: cat.auth });
  expect(response.status === 403 && (await response.json()).reason === "blocked", "the sharer's pages don't open for them");
  response = await send("GET", `/api/surfaces/${adaOther.id}`, { auth: dee.auth });
  expect(response.status === 200, "but do for everyone else");
  response = await send("POST", `/api/surfaces/${first.id}/block`, { auth: ada.auth });
  expect(response.status === 400, "nobody blocks themselves");
  response = await send("POST", `/api/surfaces/${first.id}/block`);
  expect(response.status === 401, "blocking needs signing in");
  response = await send("POST", `/api/surfaces/${legacyID}/block`, { auth: cat.auth });
  expect(response.status === 200 && (await response.json()).blocked === false, "a page from before accounts has nobody to block");
  response = await send("GET", "/api/me/blocked", { auth: cat.auth });
  const list = (await response.json()).blocked ?? [];
  expect(list.length === 1 && list[0].title === "Ada bill, final" && !JSON.stringify(list).includes(ada.user), "their list names the page, never the sharer");
  response = await send("DELETE", `/api/me/blocked/${list[0]?.id}`, { auth: dee.auth });
  expect(response.status === 204 && (await send("GET", `/api/surfaces/${adaOther.id}`, { auth: cat.auth })).status === 403, "nobody else can unblock for them");
  response = await send("DELETE", `/api/me/blocked/${list[0]?.id}`, { auth: cat.auth });
  expect(response.status === 204 && (await send("GET", `/api/surfaces/${adaOther.id}`, { auth: cat.auth })).status === 200, "they can unblock");

  console.log("The publish check");
  const refusal = async (who, text) => share(who, page("A page", text));
  let checked = await refusal(dee, "This mentions dreamslurcheck in passing.");
  expect(checked.status === 422 && checked.reason === "slur" && /slur/.test(checked.error), "a slur is refused, saying why");
  checked = await refusal(dee, "Spelled D R E A M S L U R C H E C K, or dr3amslurch3ck.");
  expect(checked.reason === "slur", "however it's spelled");
  checked = await refusal(dee, "Some kids dreamexplicitcheck.");
  expect(checked.status === 422 && checked.reason === "minors", "sexual content with a child is refused");
  checked = await refusal(dee, "A 9-year-old and dreamexplicitcheck.");
  expect(checked.reason === "minors", "an age under 16 counts as a child");
  checked = await refusal(dee, "Looking for child dreamporncheck.");
  expect(checked.reason === "minors", "so does slang for pornography after a word for a child");
  checked = await refusal(cat, "Her SSN is 512-44-3321.");
  expect(checked.status === 422 && checked.reason === "private", "someone's ID number is refused");
  checked = await refusal(cat, "Card 4539 1488 0343 6467, expires soon.");
  expect(checked.reason === "private", "and a card number");
  checked = await refusal(cat, "Children learn how sexual reproduction works. Keeping kids safe from abuse online matters.");
  expect(checked.status === 201, "teaching about the body, or keeping children safe, isn't refused");
  checked = await refusal(cat, "Sherlock Holmes lives at 221B Baker Street. A sample SSN looks like 123-45-6789.");
  expect(checked.status === 201, "nor a famous address, or an example number");
  response = await send("PUT", `/api/surfaces/${checked.id}`, { auth: cat.auth, body: page("A page", "Now with dreamslurcheck.") });
  expect(response.status === 422 && (await (await send("GET", `/api/surfaces/${checked.id}`)).json()).surface?.title === "A page", "an update is checked too, and a refused one changes nothing");

  console.log("Deleting an account");
  response = await send("POST", "/api/dev/forget-sharing", { auth: ada.auth });
  expect(response.status === 204, "what account deletion does to sharing");
  response = await send("GET", `/api/surfaces/${adaOther.id}`);
  expect(response.status === 410, "every link it made stops");
  response = await send("GET", `/s/${first.id}`, { headers: BROWSER });
  const gone = await response.text();
  expect(response.status === 410 && !gone.includes("Ada bill"), "and its pages and titles are gone");
  expect((await listOf(ada)).length === 0, "nothing is left in its list");
}
