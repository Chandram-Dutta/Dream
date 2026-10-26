# Dream sharing server

A Cloudflare Worker that keeps surfaces people share from Dream (ROADMAP.md, workstream 9). It
stores each one under a short link, hands it back to the app, shows it on the web to people
without Dream, and tells iOS that `/s/` links open in the app.

What's shared is a surface, never a chat: the template, its reference and credits, and its
locale. The sharer's numbers go only when they switch on "Include my numbers". Their answers,
list entries, photo and memory never leave the phone.

| Request | What it does |
|---|---|
| `POST /api/surfaces` | Stores a shared surface (`application/json`, at most 200 KB). Answers `201 { id, url }`. |
| `GET /api/surfaces/:id` | The shared surface, for the app. |
| `GET /s/:id` | The web viewer. Also the universal link the app opens. |
| `GET /.well-known/apple-app-site-association` | Which app opens `/s/` links (`APP_IDS`). |
| `POST /api/search` | Web search, for the app only. See [Web search and reading](#web-search-and-reading). |
| `POST /api/read` | A web page's text, for the app only. |
| `GET /reader` | What DreamReader is, for site owners who see it in their logs. |
| `POST /api/model` | The model, for signed-in users of the app. See [The model](#the-model). |
| `GET /api/usage` | The account's plan, and pages used and left. See [Plans and limits](#plans-and-limits). |
| `POST /api/appstore/transactions` | Dream Plus purchases the app made or restored. See [Dream Plus](#dream-plus). |
| `POST /api/appstore/notifications` | App Store Server Notifications v2. |
| `POST /api/attest/challenge`, `POST /api/attest/key` | App Attest. See [App Attest](#app-attest). |

## What's uploaded

The app builds it in `Dream/Engine/Sharing.swift`:

```json
{
  "format": 1,
  "surface": { "title": "…", "blocks": [], "inputs": [], "outputs": [], "locale": { "language": "en", "measurementSystem": "metric" } },
  "values": { "bill": 240 },
  "currency": "INR",
  "preview": { "values": {}, "tex": {}, "equations": {}, "charts": {} }
}
```

- `surface` is the template, without `answers`. The Worker deletes `answers` too, in case.
- `values` is there only when the sharer chose to include their numbers.
- `preview` is the app engine's own working: each value as shown, each calculated equation and
  its worked line, and each chart's points. The web viewer shows these, so it never needs a
  formula engine of its own and can't disagree with the app. It's kept on the server and left
  out of what the app fetches.

## Why D1

Shared surfaces are small JSON documents, written once and read many times. D1 suits that, and
what comes next:

- **Consistent at once.** A link works the moment it's made, wherever it's opened. KV can take a
  minute to show a new key in other locations, which is exactly when a link is sent.
- **Queryable.** The public template library is the likely next step. It needs listing and
  searching by title, language and date. The `surfaces` table already keeps those columns. KV
  can't query; R2 is for files.
- **Small enough.** Rows hold up to 2 MB; shares are capped at 200 KB and are usually 5–40 KB.

R2 is the place for anything large later, like rendered share images for link previews.

## Protection

- **Size:** bodies over 200 KB are refused before they're read in full. JSON is also bounded in
  nesting depth (20), node count (25,000), string length (4,000) and list length (400).
- **Content type:** only `application/json` is accepted.
- **Rate limits:** per address, 10 shares and 120 reads a minute, through Cloudflare's rate
  limiting binding. Addresses are only rate-limit keys: the Worker never stores or logs them.
- **No personal data in logs:** the Worker logs only the kind of an unexpected failure.
  Invocation logs (which carry request details) are turned off in `wrangler.jsonc`.
- **Ids:** ten random base-62 characters (about 60 bits), so links can't be guessed or walked.
- **The web viewer is static:** no scripts, and a content security policy that allows none.
  Every string is escaped. KaTeX runs on the server with `trust` off, so maths can't make links.
  Images and audio load only from `upload.wikimedia.org`. Links go to Wikipedia, Wikimedia
  Commons and the http(s) pages a surface cites, marked `nofollow noopener noreferrer`.
- **The app doesn't trust the server.** It bounds, strips and re-checks everything it opens
  (`SharedSurface.received`), with the same checker as anything the model writes.

## Develop and test locally

```sh
cd Server
npm install
npm run migrate:local     # creates the local D1 database
npm run dev               # http://localhost:8787
```

`npm run dev` copies KaTeX's stylesheet and fonts into `public/katex` first. Open
`http://localhost:8787/s/<id>` for a surface you've stored.

Checks:

```sh
npm run check             # TypeScript
npm test                  # starts wrangler dev on a free port and checks every endpoint
../Tools/sharing.sh       # the app's side: what's shared, the preview, opening as untrusted

# The app's encoding through the real Worker and back (with npm run dev running):
DREAM_SHARE_URL=http://127.0.0.1:8787 ../Tools/sharing.sh
```

## Deploy

1. Log in to Cloudflare, once per Mac:

   ```sh
   cd Server
   npm install
   npx wrangler login
   ```

2. Create the database, then put the `database_id` it prints into `wrangler.jsonc`, in place of
   `00000000-0000-0000-0000-000000000000`:

   ```sh
   npx wrangler d1 create dream-share
   ```

3. Create the table:

   ```sh
   npx wrangler d1 migrations apply dream-share --remote
   ```

4. Deploy:

   ```sh
   npx wrangler deploy
   ```

   It prints the address, `https://dream-share.<your-subdomain>.workers.dev`. If the account has
   no workers.dev subdomain yet, Wrangler asks you to choose one first.

5. Check it's up:

   ```sh
   curl https://dream-share.<your-subdomain>.workers.dev/.well-known/apple-app-site-association
   DREAM_SHARE_URL=https://dream-share.<your-subdomain>.workers.dev npm test
   ```

   The test stores about 15 copies of a sample surface and ends by tripping the share rate
   limit for a minute.

6. Point the app at it. In Xcode, set the Dream target's `DREAM_SHARE_HOST` build setting (Debug
   and Release) to `dream-share.<your-subdomain>.workers.dev`. It sets both:
   - the associated domain in `Dream/Dream.entitlements` (`applinks:$(DREAM_SHARE_HOST)`), so
     links open in Dream;
   - the app's default sharing server (`DreamShareHost` in `Config/Info.plist`).

   Until then it's `dream-share.invalid`, which the app treats as "not set". To try a server
   without rebuilding, enter it in Under the hood › Sharing; that overrides the build setting
   for making and opening links, but universal links still need the build setting.

### Universal links

iOS fetches `/.well-known/apple-app-site-association` through Apple's CDN when Dream is
installed, so a new domain can take a while to work. Development builds also list
`applinks:<host>?mode=developer`, which fetches straight from the server: on the iPhone, turn on
Settings › Developer › Associated Domains Development, then reinstall.

Universal links open the app when tapped in Messages, Mail or Notes, not when typed into
Safari's address bar. The web page's Open in Dream button uses `dream://s/<id>` instead, which
always works where Dream is installed.

The app ID in the association file comes from `APP_IDS` in `wrangler.jsonc`
(`DR99P625RR.xyz.onlychan.Dream`). If the bundle ID changes, change it there and deploy again.
Several IDs can be listed, separated by commas.

## Web search and reading

So a screen can rest on the whole web rather than Wikipedia alone, the model has `search` and
`read` tools beside `lookup` (`Dream/Generation/WebSearch.swift`). They call these routes
(`src/web.ts`), which call a provider (`src/providers.ts`). The app never talks to a provider.

```
POST /api/search  { "query": "best budget phones India", "objective": "Which budget phones are best in India now?",
                    "count": 5, "freshness": "week", "region": "in" }
→ { "results": [{ "title", "url", "snippet", "site", "date" }], "provider": "parallel", "cached": false }

POST /api/read    { "url": "https://…", "focus": "new features", "maxChars": 4000, "language": "en" }
→ { "url", "canonical", "title", "site", "date", "language", "text", "excerpted", "truncated", "via", "cached" }
```

Both need the user's session (`Authorization: Bearer <session>`) and proof that it's the app
asking: an App Attest assertion, or the shared app key in `X-Dream-Key` (see
[App Attest](#app-attest)). Each counts against the account's daily allowance. `count` is 1 to 8
(default 5); `freshness` is day, week, month or year; `region` is a two-letter country;
`maxChars` is 500 to 12,000 (default 6,000).

### Providers

[Parallel](https://docs.parallel.ai) does both, behind a small interface, so another can be added
without touching the app:

- **Search:** `POST https://api.parallel.ai/v1/search`, header `x-api-key`, with
  `objective`, `search_queries`, `mode: "fast"` (about 700 ms), `max_chars_total`, and
  `advanced_settings` holding `max_results`, `excerpt_settings.max_chars_per_result`,
  `source_policy.after_date` (freshness) and `location` (region). Results are
  `{ url, title, publish_date, excerpts[] }`. **$1 per 1,000** in fast mode, 10 results included.
- **Read:** `POST https://api.parallel.ai/v1/extract`, with `urls`, `objective` (the focus), and
  `advanced_settings` holding `excerpt_settings`, `full_content` and `fetch_policy`. Results are
  `{ url, title, publish_date, excerpts[], full_content }`, with failures in `errors[]`.
  **$1 per 1,000 pages.** It reads pages that need JavaScript and PDFs, and with a focus returns
  just the parts about it, which keeps what the model reads short.

Alongside Parallel, the Worker fetches the page itself (free): that gives the page's own title,
site name, canonical address and date, and its words when there's no Parallel key or Parallel
can't read it. That fetch asks for Markdown first, for sites that serve it to agents, and
otherwise reads HTML with the runtime's streaming `HTMLRewriter`, keeping `main` or `article`
and dropping scripts, menus, headers and footers (`src/html.ts`).

Cloudflare's Web Search API (beta, through AI Gateway) would slot in as another `SearchProvider`:
`env.AI.websearch({ gatewayId, query, limit, provider })` with an `"ai": { "binding": "AI" }`
binding returns a `Response` whose JSON is `{ items: [{ url, title, description, lastModifiedDate? }] }`;
Ceramic.ai, its default, is $0.25 per 1,000. It has no freshness or region filter. Browser
Rendering (`env.BROWSER.quickAction("markdown", …)`, or `POST /accounts/:id/browser-run/markdown`)
isn't used: Parallel already reads pages that need JavaScript, without a browser per page.

### Protection

These cost money, so they mustn't become an open proxy:

- **Only signed-in people, using the app:** a session, then an App Attest assertion or a shared
  app key in `X-Dream-Key`, checked in constant time against the `DREAM_APP_KEYS` secret
  (several, comma-separated, so one can be rotated out). Without the secret, a request without
  an assertion is refused. The app keeps the key in its Keychain (Under the hood › Web search).
- **An allowance per account:** searches and reads a day, by plan (`src/usage.ts`).
- **Rate limits:** per address, 30 searches and 30 page reads a minute (`SEARCH_LIMIT`,
  `PAGE_LIMIT`), checked before anything else.
- **A daily budget:** at most `WEB_DAILY_LIMIT` (2,000) paid calls of each kind a day, for
  everyone together, counted in D1. Past it, searches stop until tomorrow and reads fall back to
  the free fetch. At Parallel's prices that's at most $4 a day.
- **A cache:** the same search is answered from D1 for an hour (15 minutes for the past day),
  the same read for six hours, and robots.txt for a day. Keys are hashes of what was asked.
- **Sizes and times:** bodies up to 4 KB; queries up to 300 characters; pages read up to 2 MB of
  HTML and returned as at most 12,000 characters, without their links; 10 s for a search, 20 s
  for a read.
- **Only public pages:** http and https on the usual ports, without names or passwords. Private,
  loopback, link-local, carrier-grade NAT, documentation and metadata addresses are refused, in
  every way of writing them (`src/address.ts`), and so are names like `localhost` and `.local`.
  Before fetching, the Worker asks Cloudflare's resolver (DNS over HTTPS) where a name points
  and refuses one that points anywhere private. Each redirect is checked the same way, at most
  five, never from https to http.
- **Polite:** it says who it is (`DreamReader/1.0`, linking to `/reader`), follows robots.txt
  for `DreamReader` or else `*` (RFC 9309), and reads a page only when someone asks.
- **Nothing personal is logged:** no queries, addresses or page addresses; only a provider's
  HTTP status when one fails.

What the routes return is untrusted text from the web. The app fences it between random markers
and labels it as data for the model, and the checker keeps only citations of pages that were read.

### App Attest

See [App Attest](#app-attest) below: it covers the model too.

### Setting it up

```sh
cd Server
npx wrangler d1 migrations apply dream-share --remote     # adds web_cache and web_usage (and later tables)
security find-generic-password -a parallel -s dream -w | tr -d '\n' | npx wrangler secret put PARALLEL_API_KEY
security add-generic-password -U -a web -s dream -w "$(openssl rand -hex 32)"         # once: makes the app key
security find-generic-password -a web -s dream -w | tr -d '\n' | npx wrangler secret put DREAM_APP_KEYS
npx wrangler deploy
```

Then paste the same key into Dream on the phone, in Under the hood › Web search. The bench
reads it from the login Keychain too.

Locally, `wrangler dev` reads both secrets from `Server/.dev.vars` (gitignored):

```
PARALLEL_API_KEY="…"
DREAM_APP_KEYS="a-long-random-local-key"
```

`npm test` doesn't use them: it points the Worker at a stand-in for Parallel on this Mac
(`test/stub-parallel.mjs`), so nothing is paid for, and checks refusals, SSRF, caching, the
budget and the rate limits. `node test/unit.mjs` checks the address rules, robots.txt and text
tidying on their own. `../Tools/web.sh` checks the app's side.

## The model

The app never holds a provider key. Its default model, "Dream"
(`Dream/Generation/Providers/DreamModel.swift`), sends the chat completion it would send xAI to
`POST /api/model` (`src/model.ts`), which passes it to xAI with the server's `XAI_API_KEY` and
streams the answer back byte for byte, reasoning included, so the app's stall watchdog sees the
model thinking. The app's xAI adapter and the Dream adapter share one translation
(`ChatCompletions.swift`); Grok with your own key and Private Cloud Compute stay in Under the
hood as developer options.

A request needs a session, proof that it's the app (as for web search), and room in the
account's allowance. It's checked and rebuilt from the fields Dream uses: the model must be on
the list (`MODELS`, default `grok-4.7`), tools must be the app's own functions (never a
provider's paid server-side tools), pictures go only as `data:` URLs, `reasoning_effort` is low,
medium or high, `max_tokens` is capped (`MAX_OUTPUT_TOKENS`, default 32,000), the body is at
most 2 MB, and anything else (`n`, `search_parameters`, `user`, …) is dropped. Streams ask xAI
for usage (`stream_options.include_usage`); the Worker reads only that last chunk, and counts
its tokens and cost (`cost_in_usd_ticks`, in 10⁻¹⁰ dollars) against the account. A stream cut
short is estimated from its size. Requests carry `x-grok-conv-id`, a hash of the account, so
xAI serves its long instructions from its prompt cache at a quarter of the price.

`X-Dream-Page` names the page a request belongs to: the app makes one id per build or change,
so the gap check, the writing, its tool calls and repairs count as one page. Small jobs that
aren't a page (turning "add milk" into a list entry) send none and count only their cost.

Nothing asked or answered is logged or kept; only counts and costs (`migrations/0007_usage.sql`).
xAI's errors become plain answers: its rate limit is a 503 to retry, a malformed request a 400
with xAI's reason, anything else a 502.

## Plans and limits

`GET /api/usage` tells the app the plan, pages used today and this month, the limits of both
plans, when more come, and the account's purchase token. When a page doesn't fit, the model
route answers:

```
402  { "error": "You've made today's 5 free pages. You can make more tomorrow, or now with Dream Plus.",
       "reason": "allowance", "upgrade": true, "resetsAt": 1761523200 }      (and Retry-After)
429  … "upgrade": false …   for a subscriber who's used a day's or a month's pages
```

The app shows `error` as it is and, when `upgrade` is true, offers Dream Plus right then.

| | Free | Dream Plus |
|---|---|---|
| Pages a day (a change counts as a page) | 5 | 25 |
| Pages a month | 30 | 150 |
| Web searches / reads a day | 15 / 20 | 75 / 100 |
| Most one page may cost | $0.30 | $0.40 |
| Most a day may cost, all requests (backstop) | $0.60 | $3.00 |

Everyone together may spend `MODEL_DAILY_BUDGET` ($100) a day on the model; past it, pages wait
until tomorrow (503). `ALLOWANCES` (JSON, like `{"free":{"pagesPerDay":3}}`) changes any of the
per-plan numbers without a code change.

**The maths.** grok-4.7 costs $2 per million input tokens, $0.50 cached, and $6 per million
output tokens, reasoning included (docs.x.ai, October 2026). Parallel costs $1 per 1,000
searches and $1 per 1,000 page reads. Five pages built through the proxy on 2026-10-26 cost
$0.035, $0.036, $0.053, $0.082 and $0.191: about 34,000 tokens in and 3,000 out each, and the
dearest searched three times and read four pages. Input is four fifths of the cost, so cache
hits matter more than anything else. A page's web use is at most 3 searches and 4 reads, $0.007.

- Planning cost: **$0.08 a page**, $0.20 for one that researches the web.
- Free: at most 30 pages a month, about **$2.40** an account at the average, and never more than
  $9 (30 × the $0.30 page cap). Most free accounts will make far fewer.
- Dream Plus at **$9.99 a month or $79.99 a year**. After Apple's 15% (the Small Business
  Program, or any subscription after its first year) that's $8.49 a month, or $5.67 a month on
  the yearly plan; at 30%, $6.99 and $4.67. At $0.08 a page the monthly plan pays for about 106
  pages a month and the yearly about 71. A subscriber who makes two pages a day costs about
  $4.80; one who uses all 150 costs about $12, which the many who don't pay for.

## Dream Plus

One subscription group, "Dream Plus", with `xyz.onlychan.dream.plus.monthly` and
`xyz.onlychan.dream.plus.yearly` at the same level (`Dream/Subscription/Products.swift`; for
Xcode, `Config/Dream.storekit`). The app buys with StoreKit 2, passing the account's id as the
`appAccountToken`, then sends the signed transaction to `POST /api/appstore/transactions`; on
every launch and sign-in it sends the subscriptions the Apple Account has
(`Transaction.currentEntitlements`). The App Store also tells the server itself, at
`POST /api/appstore/notifications` (Server Notifications v2), which covers renewals, refunds and
expiry while the app is closed.

Both are JWS, checked as Apple's App Store Server Library checks them (`src/appstore.ts`,
`src/x509.ts`): `alg` ES256; three certificates in `x5c`; the intermediate signed by Apple Root
CA - G3, which is pinned in the code (the root a sender includes is never trusted); the leaf
signed by the intermediate, which must be a CA; Apple's marker extensions
(`1.2.840.113635.100.6.11.1` on the leaf, `1.2.840.113635.100.6.2.1` on the intermediate); every
certificate valid when the data was signed; then the signature. Online revocation checks
(OCSP) aren't made. The transaction must be for this bundle ID, an auto-renewable subscription
to one of the two products, in an environment that counts (`APPSTORE_ENVIRONMENTS`, default
`Production,Sandbox`: TestFlight and App Review buy in the sandbox), and name this account or
none. Production notifications are also checked against `APPSTORE_APP_APPLE_ID` once it's set.

A subscription is one row per original transaction id: who it belongs to, its product, when it
ends (counting a billing grace period from the renewal info), and whether it was refunded or
revoked. The newest signed state wins, so notifications arriving out of order can't undo a
refund. A subscription tied to one account can't be claimed by another (409). Notifications
already handled are remembered by `notificationUUID` for a month. Account deletion removes it
all (`deleteUserData` in `src/usage.ts`); the App Store subscription itself carries on until the
person cancels it in Settings.

## App Attest

[App Attest](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)
proves a request comes from a genuine copy of Dream on a real device, so an extracted key is no
use (`src/attest.ts`, `Dream/Generation/Providers/AppProof.swift`):

1. The app asks `POST /api/attest/challenge` (signed in) for a one-time challenge, kept five minutes.
2. It makes a key with `DCAppAttestService.generateKey()`, has it attested with
   `attestKey(keyId, clientDataHash: SHA256(challenge))`, and sends `POST /api/attest/key
   { keyId, attestation, challenge }`.
3. The Worker checks the attestation as Apple's "Validating apps that connect to your server"
   lays out: the chain up to the pinned Apple App Attestation Root CA; the nonce
   `SHA256(authData ‖ SHA256(challenge))` in the credential certificate's
   `1.2.840.113635.100.8.2` extension; the key id is `SHA256` of the public key; the RP ID is
   `SHA256("DR99P625RR.xyz.onlychan.Dream")`; the counter is 0; the AAGUID is `appattest`
   (production) or `appattestdevelop` (development); the credential id is the key id; and, where
   newer systems report one, the launch validation category is TestFlight, development or the
   App Store. It keeps the public key and the receipt.
4. Each model and web request then carries `X-Dream-Attest-Key`, `X-Dream-Attest-Time` and
   `X-Dream-Assertion`, an assertion over `METHOD\npath\ntime\nhex(SHA256(body))`. The Worker
   checks the signature with the kept key, the RP ID, that the time is within two minutes, and
   that the counter hasn't been used: it may arrive up to 20 below the highest seen, once, since
   the app sends requests in parallel.

Apple suggests a fresh challenge for every assertion. Instead, the time bounds when an assertion
can be used, the body hash ties it to one request, and the counter stops replays, which saves a
round trip on every model request.

A key the server doesn't know answers `401` with `X-Dream-Attest: again`, and the app makes a new
one. If attesting fails, the app sends requests without an assertion and tries again ten minutes
later; the shared key still counts where it's set. **`APP_PROOF=off`** lets signed-in requests
through without either: an emergency switch if App Attest misbehaves in production, since
release builds carry no shared key.

## Setting up the model and Dream Plus

Secrets (`wrangler secret put`): **`XAI_API_KEY`**, Dream's production xAI key. Nothing else new:
App Store data is verified with Apple's public certificates, so no App Store key is needed yet.

```sh
cd Server
npx wrangler d1 migrations apply dream-share --remote     # 0007_usage.sql, after 0004–0006
npx wrangler secret put XAI_API_KEY
npx wrangler deploy
```

Optional settings (`vars`): `APPSTORE_APP_APPLE_ID` (the app's Apple ID, from App Store Connect),
`APPSTORE_ENVIRONMENTS`, `MODEL_DAILY_BUDGET`, `MODELS`, `MAX_OUTPUT_TOKENS`, `ALLOWANCES`,
`APP_PROOF`.

In App Store Connect: sign the Paid Apps agreement; create the subscription group "Dream Plus"
with the two products above, both at level 1, priced $9.99 a month and $79.99 a year; and set
the App Store Server Notifications URL (Version 2) for production and sandbox to
`https://dream.onlychan.xyz/api/appstore/notifications`.

Locally, `.dev.vars` takes `XAI_API_KEY` and `DEV_LOGIN=1`. Then `POST /api/dev/session?user=bench`
gives a session, and `DREAM_SERVER=http://127.0.0.1:8787 ../Tools/bench.sh "a request"` builds
pages through the proxy, as the app does. `npm test` uses a stand-in for xAI
(`test/stub-xai.mjs`) and test roots for the App Store and App Attest (`test/vectors.mjs`, trusted
only with `DEV_LOGIN=1`), so nothing is paid for. `node test/billing.mjs` checks JWS and App
Attest verification, the counter window and what the proxy forwards, on their own.

## Later: shared lists

Shared lists, like a family grocery list, are out of scope for now. The plan:

- **One Durable Object per shared list.** It holds the list's entries in its own SQLite storage
  and is the single place their order is decided. Members connect over a WebSocket (with
  hibernation, so idle lists cost nothing) and get each change as it happens.
- **Changes travel as operations,** the insert, update and delete operations the app already
  uses for talking to lists (`RecordOperations.swift`), with record ids and a per-field
  last-writer-wins clock. The phone keeps working offline and sends what it queued when it's
  back.
- **The list's shape stays in the surface.** The collection's fields are shared as part of the
  template, as now. Only a list the user explicitly shares has its entries leave the phone; every
  other list stays local.
- **Membership by capability link:** sharing a list makes an invite link with a secret, and each
  member's token goes in their Keychain. The Durable Object checks it on every connection.
- **The server needn't read entries.** The invite link's fragment (`#key`, which browsers and
  servers never send) can carry a key, so entries are encrypted on the phones and the Durable
  Object only stores and orders ciphertext.
- Changing a shared list's fields ("add a price column") needs the versioned field mapping from
  workstream 2 applied on every member's phone, from a version number the object keeps.

## Later: the template library

The `surfaces` table already keeps each share's title, summary and language. A library needs a
`listed` flag that a sharer opts into, some moderation, and search: SQLite's FTS5 in D1 for
words, and Workers AI with Vectorize for finding a template by meaning, which is what Dream's
screen memory would ask it.
