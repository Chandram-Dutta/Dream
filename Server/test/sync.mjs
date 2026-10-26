// Checks cloud sync over HTTP (src/sync.ts): who may read and write, that people only ever see
// their own items, the latest change winning, deletions, cursors and pages, the limits, and
// photos. Run by smoke.mjs against a local `wrangler dev` started with DEV_LOGIN, which makes
// test sessions; against a server without it, it's skipped.

/** A small JPEG's first bytes, enough to be recognised as one. */
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 16, 0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xff, 0xd9]);

const uuid = () => crypto.randomUUID().toUpperCase();

/** Signs in a test user, returning their session token, or null where test sessions are off. */
async function signIn(base, name) {
  const response = await fetch(`${base}/api/dev/session?user=${encodeURIComponent(name)}`, { method: "POST" });
  if (response.status !== 201) return null;
  return (await response.json()).token;
}

export async function runSync(base, expect, { quota }) {
  const run = Date.now().toString(36);
  const alice = await signIn(base, `sync-alice-${run}`);
  const bob = await signIn(base, `sync-bob-${run}`);
  if (!alice || !bob) {
    console.log("\nSync: skipped, since this server doesn't make test sessions (DEV_LOGIN).");
    return;
  }
  // Alice on a second phone: another session for the same person.
  const alicePhone = await signIn(base, `sync-alice-${run}`);

  const call = (token, method, path, body, type = "application/json") =>
    fetch(`${base}${path}`, {
      method,
      headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body !== undefined ? { "Content-Type": type } : {}) },
      body: body === undefined ? undefined : typeof body === "string" || body instanceof Uint8Array ? body : JSON.stringify(body),
    });
  const push = async (token, items) => {
    const response = await call(token, "POST", "/api/sync", { items });
    return { status: response.status, ...(await response.json()) };
  };
  /** Every change since a cursor, following pages to the end. */
  const pullAll = async (token, since = null, limit = undefined) => {
    const items = [];
    let cursor = since;
    let pages = 0;
    for (;;) {
      const query = new URLSearchParams();
      if (cursor) query.set("since", cursor);
      if (limit) query.set("limit", String(limit));
      const response = await call(token, "GET", `/api/sync?${query}`);
      const page = await response.json();
      if (response.status !== 200) throw new Error(`pull: ${response.status} ${page.error}`);
      items.push(...page.items);
      cursor = page.cursor;
      pages++;
      if (!page.more || pages > 50) return { items, cursor, pages, user: page.user, now: page.now };
    }
  };

  const now = Date.now();
  const page = uuid();
  const photoID = uuid();
  const surface = (stamp, title, extra = {}) => ({ kind: "surface", id: page, format: 1, updatedAt: stamp, deleted: false, body: { intent: "split a bill", template: { title }, history: [{ kind: "asked", text: "split a bill" }], ...extra } });
  const entry = (id, stamp, name) => ({ kind: "record", id, parent: page, format: 1, updatedAt: stamp, deleted: false, body: { collection: "groceries", values: { name } } });

  console.log("Sync: who may ask");
  let response = await call(null, "GET", "/api/sync");
  expect(response.status === 401 && response.headers.get("www-authenticate") === "Bearer", "reading without a session is refused");
  response = await call(null, "POST", "/api/sync", { items: [] });
  expect(response.status === 401, "and so is sending");
  response = await call("not-a-real-session-token-of-a-plausible-length", "GET", "/api/sync");
  expect(response.status === 401, "a made-up session is refused");
  response = await call(null, "GET", `/api/photos/${photoID}`);
  expect(response.status === 401, "photos need a session too");
  response = await call(alice, "PUT", "/api/sync", { items: [] });
  expect(response.status === 405, "only GET and POST");

  console.log("Sync: sending and reading back");
  const milk = uuid();
  const eggs = uuid();
  const fact = uuid();
  let result = await push(alice, [
    surface(now, "Split a bill", { photo: photoID }),
    entry(milk, now, "Milk"),
    entry(eggs, now, "Eggs"),
    { kind: "fact", id: fact, format: 1, updatedAt: now, deleted: false, body: { topic: "Home city", text: "Pune" } },
    { kind: "setting", id: "requestLanguages", format: 1, updatedAt: now, deleted: false, body: { value: ["hi"] } },
  ]);
  expect(result.status === 200 && result.applied === 5 && result.stale.length === 0, `five changes taken (got ${result.status} ${result.applied ?? result.error})`);
  expect(typeof result.now === "number" && Math.abs(result.now - Date.now()) < 60_000, "with the server's clock, for the phone to set its own by");
  let pulled = await pullAll(alicePhone);
  const byID = Object.fromEntries(pulled.items.map((item) => [item.id, item]));
  const aliceID = pulled.user;
  expect(pulled.items.length === 5 && aliceID, `Alice's other phone reads all five (got ${pulled.items.length})`);
  expect(byID[page]?.body?.template?.title === "Split a bill" && byID[page]?.body?.history?.[0]?.text === "split a bill", "the page, with its history, as sent");
  expect(byID[milk]?.parent === page && byID[milk]?.body?.values?.name === "Milk" && byID[fact]?.body?.text === "Pune", "entries with their page, and memory");
  expect(byID[page]?.updatedAt === now && byID[page]?.deleted === false && byID[page]?.format === 1, "when it changed, and its format");
  const cursor = pulled.cursor;
  pulled = await pullAll(alicePhone, cursor);
  expect(pulled.items.length === 0, "from the cursor on, nothing new");

  console.log("Sync: each person sees only their own");
  pulled = await pullAll(bob);
  expect(pulled.items.length === 0 && pulled.user && pulled.user !== aliceID, "Bob sees none of Alice's items");
  result = await push(bob, [surface(now + 50_000, "Bob's own", {})]);
  expect(result.applied === 1, "Bob can use the same item id");
  pulled = await pullAll(alicePhone, cursor);
  expect(pulled.items.length === 0, "and it never reaches Alice");
  const alicePage = (await pullAll(alice)).items.find((item) => item.id === page);
  expect(alicePage?.body?.template?.title === "Split a bill", "Alice's page is untouched by Bob's");
  response = await call(bob, "GET", `/api/sync?since=${encodeURIComponent(cursor)}`);
  const carried = await response.json();
  expect(response.status === 200 && carried.reset === true && carried.items.length === 1, "a cursor carried into another account starts that account from the beginning");

  console.log("Sync: the latest change wins");
  result = await push(alice, [surface(now - 1_000, "Older")]);
  expect(result.applied === 0 && result.stale.length === 1 && result.stale[0].body.template.title === "Split a bill", "an older change is refused, with what's stored instead");
  result = await push(alice, [surface(now, "Same time")]);
  expect(result.applied === 0 && result.stale.length === 1, "a tie keeps what's stored");
  result = await push(alice, [surface(now + 1_000, "Newer", { photo: photoID })]);
  expect(result.applied === 1, "a newer change is taken");
  result = await push(alice, [{ ...entry(milk, now + 2_000, "Oat milk") }, { ...entry(milk, now + 1_500, "Skim milk") }]);
  expect(result.applied === 1, "of two changes to one item in a batch, one is kept");
  pulled = await pullAll(alicePhone, cursor);
  expect(pulled.items.length === 2 && pulled.items.find((item) => item.id === milk)?.body?.values?.name === "Oat milk", "the later of the two");
  result = await push(alice, [{ kind: "fact", id: fact, format: 1, updatedAt: Date.now() + 365 * 86_400_000, deleted: false, body: { topic: "Home city", text: "Mumbai" } }]);
  pulled = await pullAll(alicePhone, cursor);
  const future = pulled.items.find((item) => item.id === fact);
  expect(result.applied === 1 && future.updatedAt < Date.now() + 11 * 60_000, "a clock far ahead is pulled back, so it can't win forever");

  console.log("Sync: photos");
  response = await call(alice, "PUT", `/api/photos/${photoID}`, JPEG, "image/jpeg");
  expect(response.status === 201, `a photo is stored (got ${response.status})`);
  response = await call(alice, "GET", `/api/photos/${photoID}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  expect(response.status === 200 && response.headers.get("content-type") === "image/jpeg" && bytes.length === JPEG.length && bytes[0] === 0xff, "and read back");
  expect(response.headers.get("cache-control") === "no-store", "never kept in a shared cache");
  response = await call(bob, "GET", `/api/photos/${photoID}`);
  expect(response.status === 404, "Bob can't read Alice's photo");
  response = await call(bob, "DELETE", `/api/photos/${photoID}`);
  response = await call(alice, "GET", `/api/photos/${photoID}`);
  expect(response.status === 200, "or delete it");
  response = await call(alice, "PUT", `/api/photos/${uuid()}`, new TextEncoder().encode("<html>not a photo</html>"), "image/jpeg");
  expect(response.status === 415, "only photos are taken");
  response = await call(alice, "PUT", `/api/photos/${uuid()}`, new Uint8Array(4_000_001), "image/jpeg");
  expect(response.status === 413, "a photo over 4 MB is refused");
  response = await call(alice, "PUT", "/api/photos/..%2F..%2Fescape", JPEG, "image/jpeg");
  expect(response.status === 400 || response.status === 404, "a photo id can't name another place");
  const spare = uuid();
  await call(alice, "PUT", `/api/photos/${spare}`, JPEG, "image/jpeg");
  response = await call(alice, "DELETE", `/api/photos/${spare}`);
  expect(response.status === 204 && (await call(alice, "GET", `/api/photos/${spare}`)).status === 404, "a photo can be deleted");

  console.log("Sync: deleting");
  const late = uuid();
  result = await push(alice, [entry(late, Date.now() + 120_000, "Bread")]);
  const before = (await pullAll(alicePhone)).cursor;
  result = await push(alice, [{ kind: "surface", id: page, format: 1, updatedAt: Date.now() + 60_000, deleted: true }]);
  expect(result.applied === 1, "a page's deletion is taken");
  pulled = await pullAll(alicePhone, before);
  const gone = Object.fromEntries(pulled.items.map((item) => [item.id, item]));
  expect(gone[page]?.deleted === true && gone[page]?.body === null, "it travels as a tombstone, without its content");
  expect(gone[milk]?.deleted === true && gone[eggs]?.deleted === true, "its entries go with it");
  expect(!gone[late], "but not one changed after the page was deleted");
  response = await call(alice, "GET", `/api/photos/${photoID}`);
  expect(response.status === 404, "and its photo is let go");
  result = await push(alice, [surface(now + 2_000, "Back again")]);
  expect(result.applied === 0 && result.stale[0]?.deleted === true, "an edit older than the deletion doesn't bring it back");

  console.log("Sync: pages and cursors");
  const many = Array.from({ length: 23 }, (_, index) => ({ kind: "fact", id: uuid(), format: 1, updatedAt: now + index, deleted: false, body: { topic: `Topic ${index}`, text: "x" } }));
  const mark = (await pullAll(alicePhone)).cursor;
  await push(alice, many.slice(0, 13));
  await push(alice, many.slice(13));
  pulled = await pullAll(alicePhone, mark, 5);
  const ids = pulled.items.map((item) => item.id);
  expect(pulled.pages === 5 && ids.length === 23 && new Set(ids).size === 23 && many.every((item) => ids.includes(item.id)), `23 changes read five at a time, each once (got ${ids.length} in ${pulled.pages} pages)`);
  response = await call(alice, "GET", "/api/sync?since=not-a-cursor!");
  expect(response.status === 400, "a malformed cursor is refused");

  console.log("Sync: limits");
  response = await call(alice, "POST", "/api/sync", "items=1", "text/plain");
  expect(response.status === 415, "only application/json");
  response = await call(alice, "POST", "/api/sync", "{not json");
  expect(response.status === 400, "malformed JSON is refused");
  result = await push(alice, Array.from({ length: 201 }, () => ({ kind: "fact", id: uuid(), format: 1, updatedAt: now, deleted: false, body: {} })));
  expect(result.status === 413, "more than 200 changes at once is refused");
  response = await call(alice, "POST", "/api/sync", { items: [{ kind: "fact", id: uuid(), format: 1, updatedAt: now, body: { text: "x".repeat(2_100_000) } }] });
  expect(response.status === 413, "a request over 2 MB is refused before it's read");
  result = await push(alice, [
    { kind: "fact", id: uuid(), format: 1, updatedAt: now, deleted: false, body: { text: "x".repeat(270_000) } },
    { kind: "secret", id: uuid(), format: 1, updatedAt: now, deleted: false, body: {} },
    { kind: "fact", id: "../../etc", format: 1, updatedAt: now, deleted: false, body: {} },
    { kind: "record", id: uuid(), format: 1, updatedAt: now, deleted: false, body: {} },
    { kind: "fact", id: uuid(), format: 0, updatedAt: now, deleted: false, body: {} },
    { kind: "fact", id: uuid(), format: 1, updatedAt: "yesterday", deleted: false, body: {} },
    { kind: "fact", id: uuid(), format: 1, updatedAt: now, deleted: false },
    { kind: "fact", id: uuid(), format: 1, updatedAt: now, deleted: false, body: { fine: true } },
  ]);
  const reasons = (result.refused ?? []).map((item) => item.reason).join(",");
  expect(result.status === 200 && result.applied === 1 && reasons === "size,kind,id,parent,format,updatedAt,body", `bad changes are refused one by one, and the good one is kept (got ${reasons})`);
  let full = false;
  for (let i = 0; i < 20 && !full; i++) {
    const big = Array.from({ length: 4 }, () => ({ kind: "fact", id: uuid(), format: 1, updatedAt: now, deleted: false, body: { text: "y".repeat(200_000) } }));
    full = (await push(alice, big)).status === 507;
  }
  expect(full, `past the allowance (${quota} bytes in this test), the account is full`);
  result = await push(alice, [{ kind: "fact", id: many[0].id, format: 1, updatedAt: Date.now(), deleted: true }]);
  expect(result.applied === 1, "deleting still works when it's full");
  expect((await pullAll(bob)).items.length === 1, "and none of it reached Bob");
}
