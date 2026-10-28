// Checks pages made on the server over HTTP (src/compose/): starting one, watching it form and
// catching up from a seq, answering its question, and finding it in sync once it's done. Run by
// smoke.mjs against a local `wrangler dev` started with MODEL_FAKE and DEV_LOGIN, so the page's
// model is the stand-in (src/compose/fake.ts) and nothing is paid for; elsewhere it's skipped.

/** A small JPEG's first bytes, enough to be recognised as one (as in sync.mjs). */
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 16, 0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xff, 0xd9]).toString("base64");

const uuid = () => crypto.randomUUID().toUpperCase();
const locale = { language: "en", region: "IN", currency: "INR", measurementSystem: "metric" };

/** Reads server-sent events until `stop` says so or the stream ends, then lets go of it. */
async function watch(base, token, id, after = 0, stop = (event) => event.type === "done" || event.type === "failed", ms = 30_000) {
  const response = await fetch(`${base}/api/compose/${id}/events?after=${after}`, { headers: { Authorization: `Bearer ${token}` } });
  if (response.status !== 200) return { status: response.status, events: [], text: "" };
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  const events = [];
  let text = "";
  let pending = "";
  const until = Date.now() + ms;
  for (;;) {
    const result = await Promise.race([reader.read(), new Promise((resolve) => setTimeout(() => resolve(null), Math.max(0, until - Date.now())))]);
    if (!result || result.done) break;
    const chunk = decoder.decode(result.value, { stream: true });
    text += chunk;
    pending += chunk;
    let end;
    let stopped = false;
    while ((end = pending.indexOf("\n\n")) >= 0) {
      const part = pending.slice(0, end);
      pending = pending.slice(end + 2);
      if (!part.startsWith("data: ")) continue;
      const event = JSON.parse(part.slice(6));
      events.push(event);
      if (stop(event)) stopped = true;
    }
    if (stopped) break;
  }
  await reader.cancel().catch(() => undefined);
  return { status: 200, events, text, type: response.headers.get("content-type") };
}

export async function runCompose(base, expect, { appKey, signIn, query }) {
  const alice = await signIn("compose-alice");
  const bob = await signIn("compose-bob");
  const carol = await signIn("compose-carol");
  if (!alice || !bob || !carol) {
    console.log("\nPages on the server: skipped, since this server doesn't make test sessions (DEV_LOGIN).");
    return;
  }
  const start = (who, body, { key = appKey, type = "application/json" } = {}) =>
    fetch(`${base}/api/compose`, {
      method: "POST",
      headers: { "Content-Type": type, ...(who ? { Authorization: `Bearer ${who.token}` } : {}), ...(key ? { "X-Dream-Key": key } : {}) },
      body: JSON.stringify(body),
    });

  console.log("Pages on the server: who may start one");
  const ada = { request: "look up Ada Lovelace", locale, context: ["Now it's Thursday, 29 October 2026, 10:00 AM, where the user is."], pageID: uuid(), model: "auto" };
  let response = await start(null, ada);
  expect(response.status === 401, "no session is refused");
  response = await start(alice, ada, { key: null });
  expect(response.status === 401, "nor without the app's proof");
  response = await start(alice, { ...ada, pageID: "page-1" });
  expect(response.status === 400 && /UUID/.test((await response.json()).error), "a page needs an id sync can keep it under");
  response = await fetch(`${base}/api/compose`, { headers: { Authorization: `Bearer ${alice.token}` } });
  expect(response.status === 405, "only POST");

  console.log("Pages on the server: a page, watched as it forms");
  response = await start(alice, ada);
  const { id } = await response.json();
  expect(response.status === 200 && /^[0-9a-f]{64}$/.test(id ?? ""), "a page starts, and its job's id comes back");
  const watched = await watch(base, alice.token, id);
  const done = watched.events.at(-1);
  expect(watched.type?.startsWith("text/event-stream") && done?.type === "done" && done.pageID === ada.pageID, "its events stream in until it's done");
  expect(watched.events.every((event, index) => index === 0 || event.seq > watched.events[index - 1].seq), "each with the next seq");
  expect(watched.events.some((event) => event.type === "phase" && event.phase === "composing") && watched.events.some((event) => event.type === "trace" && event.kind === "lookup" && event.text === "Ada Lovelace"), "it composes, and the lookup shows as it starts");
  expect(watched.events.some((event) => event.type === "surface") && done.surface.title === "Look up Ada Lovelace" && done.model === "Auto → Grok 4.7 · low", "the page streams in, and the finished one comes with the model it ran on");
  const lines = watched.events.filter((event) => event.type === "log").map((event) => event.line);
  expect(lines[0] === "Request: look up Ada Lovelace" && lines.some((line) => line.startsWith("Check: nothing to ask")) && lines.at(-1)?.startsWith("Done in"), "and the log, as the app's reads");
  const middle = watched.events[Math.floor(watched.events.length / 2)].seq;
  const caught = await watch(base, alice.token, id, middle);
  expect(caught.events.length > 0 && caught.events.every((event) => event.seq > middle) && caught.events.at(-1).type === "done", "catching up from a seq gives only what came after it");
  expect((await watch(base, bob.token, id)).status === 404, "nobody else may watch it");
  expect((await watch(base, alice.token, "f".repeat(64))).status === 404 && (await watch(base, alice.token, "nope")).status === 404, "nor watch a page that isn't there");
  response = await fetch(`${base}/api/compose/${id}/events?after=-1`, { headers: { Authorization: `Bearer ${alice.token}` } });
  expect(response.status === 400, "after is a seq");

  console.log("Pages on the server: kept in sync");
  const synced = await (await fetch(`${base}/api/sync`, { headers: { Authorization: `Bearer ${alice.token}` } })).json();
  const item = synced.items?.find((each) => each.kind === "surface" && each.id === ada.pageID);
  const body = item?.body ?? {};
  expect(item && item.format === 1 && !item.deleted && body.intent === ada.request && body.template?.title === "Look up Ada Lovelace" && body.modelName === done.model, "the finished page is in the account's sync, under its id");
  expect(body.history?.[0]?.kind === "asked" && body.history[0].text === ada.request && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(body.createdAt) && body.openCount === 0 && body.generationLog?.[0] === lines[0], "as the app's SurfacePayload, with its log");
  const usage = await (await fetch(`${base}/api/usage`, { headers: { Authorization: `Bearer ${alice.token}` } })).json();
  expect(usage.pages?.today === 1, "and it counted as one page, whatever it asked the model");
  if (query && alice.user) {
    await new Promise((resolve) => setTimeout(resolve, 500));
    const [day] = query(`SELECT tokens_in, tokens_out FROM usage WHERE user_id = '${alice.user}' AND period = '${new Date().toISOString().slice(0, 10)}'`);
    const [counted] = query(`SELECT cost_micros FROM usage_pages WHERE user_id = '${alice.user}' AND page = '${id}'`);
    expect(day?.tokens_in > 0 && day.tokens_out > 0 && counted?.cost_micros > 0, "what its model requests used is counted against the account, under the page");
  }

  console.log("Pages on the server: a question, answered");
  const mercury = { request: "tell me about mercury", locale, pageID: uuid() };
  const second = await (await start(bob, mercury)).json();
  const asked = await watch(base, bob.token, second.id, 0, (event) => event.type === "asking");
  const asking = asked.events.at(-1);
  expect(asking?.type === "asking" && asking.questions[0].text === "Which Mercury?" && asking.questions[0].options.join() === "The planet,The element,The god", "the gap check's question comes as an event, and the page waits");
  const answer = (who, answers) =>
    fetch(`${base}/api/compose/${second.id}/answers`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${who.token}` }, body: JSON.stringify({ answers }) });
  expect((await answer(alice, [])).status === 404, "only the page's owner may answer it");
  response = await answer(bob, [{ question: asking.questions[0], choice: "The planet", isRemembered: false }]);
  expect(response.status === 200, "its owner answers");
  expect((await answer(bob, [])).status === 409, "once");
  const after = await watch(base, bob.token, second.id, asking.seq);
  const finished = after.events.at(-1);
  expect(finished?.type === "done" && finished.surface.answers?.[0]?.choice === "The planet" && finished.surface.blocks?.[1]?.items?.some((item) => item.value === "Which Mercury? The planet"), "and the page is made for the answer");

  console.log("Pages on the server: from a photo");
  const photo = { request: "what is this", image: JPEG, locale, pageID: uuid() };
  const third = await (await start(carol, photo)).json();
  const made = await watch(base, carol.token, third.id);
  expect(made.events.at(-1)?.type === "done" && !made.events.some((event) => event.type === "asking"), "a photo needs no questions");
  const kept = (await (await fetch(`${base}/api/sync`, { headers: { Authorization: `Bearer ${carol.token}` } })).json()).items?.find((each) => each.id === photo.pageID);
  const stored = kept?.body?.photo ? await fetch(`${base}/api/photos/${kept.body.photo}`, { headers: { Authorization: `Bearer ${carol.token}` } }) : null;
  expect(stored?.status === 200 && Buffer.from(await stored.arrayBuffer()).toString("base64") === JPEG, "and the photo is kept with the page, as the app keeps one");
}
