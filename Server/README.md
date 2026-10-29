# Dream sharing server

A Cloudflare Worker that keeps surfaces people share from Dream (ROADMAP.md, workstream 9). It
stores each one under a short link, hands it back to the app, shows it on the web to people
without Dream, and tells iOS that `/s/` links open in the app.

What's shared is a surface, never a chat: the template, its reference and credits, and its
locale. The sharer's numbers go only when they switch on "Include my numbers". Their answers,
list entries, photo and memory are never part of a share. When someone signs in, they're kept in
their own account instead, for their devices only: see [Sync](#sync).

| Request | What it does |
|---|---|
| `POST /api/surfaces` | Stores a shared surface (`application/json`, at most 200 KB), for a signed-in user. Answers `201 { id, url }`, or `200 { id, url, reused: true }` when it updates the page's link. See [Owners, reports and safety](#owners-reports-and-safety). |
| `GET /api/surfaces/:id` | The shared surface, for the app; `410` once it's stopped. `PUT` and `DELETE` are its owner's. |
| `GET /s/:id` | The web viewer. Also the universal link the app opens. |
| `GET /api/me/shares` | The signed-in user's links. |
| `/s/:id/report`, `POST /api/surfaces/:id/report` | Reporting a page, on the web or from the app. |
| `POST /api/surfaces/:id/block`, `/api/me/blocked` | Not seeing a sharer's pages again. |
| `/admin`, `/api/admin/…` | Reviewing reports, behind `ADMIN_KEY`. |
| `GET /.well-known/apple-app-site-association` | Which app opens `/s/` links (`APP_IDS`). |
| `POST /api/search` | Web search, for the app only. See [Web search and reading](#web-search-and-reading). |
| `POST /api/read` | A web page's text, for the app only. |
| `GET /reader` | What DreamReader is, for site owners who see it in their logs. |
| `GET /api/sync`, `POST /api/sync` | A signed-in person's changes, read and sent. See [Sync](#sync). |
| `PUT`, `GET`, `DELETE /api/photos/:id` | Photos from a signed-in person's pages. |
| `POST /api/model` | The model, for signed-in users of the app. See [The model](#the-model). |
| `POST /api/compose` | Starts a page made on the server; answers `{ id }`. See [Pages made on the server](#pages-made-on-the-server). |
| `GET /api/compose/:id/events?after=<seq>` | The page's events as server-sent events: from the log after `seq`, then live. |
| `POST /api/compose/:id/answers` | The answers to the page's questions. |
| `POST /api/push/devices`, `DELETE /api/push/devices/:token` | This iPhone, for notifications about its pages, and forgetting it. See [Notifications](#notifications). |
| `GET /api/usage` | The account's plan, and pages used and left. See [Plans and limits](#plans-and-limits). |
| `POST /api/appstore/transactions` | Dream Plus purchases the app made or restored. See [Dream Plus](#dream-plus). |
| `POST /api/appstore/notifications` | App Store Server Notifications v2. |
| `POST /api/attest/challenge`, `POST /api/attest/key` | App Attest. See [App Attest](#app-attest). |
| `GET /privacy`, `/terms`, `/support` | The privacy policy, terms of use and support page. Drafts, see [Policy pages](#policy-pages). |
| `POST /api/diagnostics` | Crash, hang and slow-launch reports from the app, anonymous. See [Diagnostics](#diagnostics). |
| `GET /api/admin/diagnostics` | A summary of them, with the operator's key. |

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
- **Rate limits:** 10 shares a minute per account, and 120 reads and 5 reports a minute per
  address, through Cloudflare's rate limiting binding. Addresses are only rate-limit keys: the
  Worker never stores or logs them.
- **No personal data in logs:** the Worker logs only the kind of an unexpected failure.
  Invocation logs (which carry request details) are turned off in `wrangler.jsonc`.
- **Ids:** ten random base-62 characters (about 60 bits), so links can't be guessed or walked.
- **The web viewer is static:** no scripts, and a content security policy that allows none.
  Every string is escaped. KaTeX runs on the server with `trust` off, so maths can't make links.
  Images and audio load only from `upload.wikimedia.org`. Links go to Wikipedia, Wikimedia
  Commons and the http(s) pages a surface cites, marked `nofollow noopener noreferrer`.
- **The app doesn't trust the server.** It bounds, strips and re-checks everything it opens
  (`SharedSurface.received`), with the same checker as anything the model writes.

## Owners, reports and safety

Shared pages are content anyone with a link can read, so App Store guideline 1.2 applies:
there's a check before publishing, a way to report, a takedown, and a way to block. The code is
in `src/shares.ts`, `src/safety.ts` and `src/moderation.ts`; the tables in
`migrations/0006_sharing.sql`.

**Links belong to an account.** Making one needs a session (`src/auth.ts`). Links made before
accounts have no owner and keep working, read-only.

```
POST   /api/surfaces?page=<app's page id>[&new=1]   → 201 { id, url, reused: false }, or 200 { id, url, reused: true }
GET    /api/me/shares                              → { shares: [{ id, url, page, title, accent, symbol, created, updated,
                                                                   hasValues, views, expiresAt, state }] }
PUT    /api/surfaces/:id   the page's newest version, and/or { "expiresAt": <unix seconds> | null }   (owner only)
DELETE /api/surfaces/:id   stops sharing                                                          (owner only)
```

- **Sharing a page again reuses its link**, with the new version behind it, unless the app asks
  for a new one (`new=1`). A link with the sharer's numbers and one without are separate links.
  A link that's stopped or expired is never reused.
- **Views** are a count, bumped after each page is sent. Link previews and crawlers (by their
  user agent), `HEAD` requests and the owner's own opens don't count. Nothing about viewers is kept.
- **Stopping** keeps the id: `/s/:id` says "This page is no longer shared" and the API answers
  `410` with `{ state }`. The page itself is erased; only its title stays, for the owner's list,
  which shows stopped links for 30 days.
- **Expiry** is optional, up to a year ahead. An expired link answers like a stopped one.
- **Limits:** 10 new links a minute and 100 a day per account; updates and stops share the
  read limit, per account.

**The publish check** runs before a page is stored or updated (`checkPublish` in
`src/moderation.ts`). A refusal is `422 { error, reason }`, with `reason` one of `slur`,
`minors` or `private`; the app shows its own words for each.

It's a short word list and a few patterns, not a model. Llama Guard on Workers AI was the other
choice, and was turned down: Dream's pages are mostly explanations (history, the body, crime,
the law), which classifiers flag far more often than real abuse; it costs time and money on
every share; it can give different answers to the same page; and it can't run in `npm test`.
Each rule asks for something an honest page has almost no reason to contain:

| Reason | What's refused | Where it could be wrong |
|---|---|---|
| `slur` | One of a few racial and ethnic slurs with no other everyday meaning, as a whole word, after folding accents, l33t spelling, stretched and spelled-out letters. | A page that quotes a slur, like a history of the word. Words that are also innocent (a meatball, a lime, an idiom) aren't listed, so the list misses them as slurs. English only. |
| `minors` | A word for a child, or an age under 16, in the same sentence as an explicit sex word; slang for pornography right after a word for a child; a few words that only mean sexual material of children. Clinical words (sex, sexual, abuse) don't count. | Quoted lyrics or swearing next to "kids". It misses anything written clinically, which is left to reports. |
| `private` | A US Social Security number, an Indian Aadhaar number (check digit), or a payment card number (Luhn, card prefixes), apart from well-known examples; or "his/her/their address" given with "his/her/their phone". | A number that happens to have the right shape and checksum, about 1 in 10 for card-shaped numbers. |

Listed words are stored as hashes. To add one, `node scripts/blockword.mjs <word>` and add what
it prints to the right list. Each list holds a made-up test word too (`dreamslurcheck` and the
like), so the tests never quote a real one.

**Reports** come from the web viewer's "Report this page" (a form, no script) and the app's
report sheet, with a reason (`hate`, `sexual`, `violence`, `private`, `spam`, `other`) and an
optional note of up to 500 characters. Nothing about the reporter is kept, and the app sends
reports without its session. Limits: 5 a minute per address (`REPORT_LIMIT`), and at most 50
open reports per page.

**Blocking a sharer** is for someone in the app who doesn't want to see a person's pages again.
It's kept with their account (`blocked_sharers`); their list names the page they blocked from,
never the sharer. `GET /api/surfaces/:id` answers `403 { reason: "blocked" }` to them for that
sharer's pages. The web viewer has no accounts, so it can't block.

**Admin.** Set the secret `ADMIN_KEY` (32 characters or more). Without it, the admin routes don't
exist.

- **The page:** open `https://dream.onlychan.xyz/admin` and enter the key. It lists pages with
  open reports, the most reported first: reasons, notes, views, and the sharer's account id. For
  each: Look (the page as shared, even after a takedown), Take down, Take down and block sharer,
  and Dismiss (close the reports and leave it up). Below: taking down any link by its id, and the
  accounts blocked from sharing. The key travels in each form; there's no script or cookie.
- **The API**, with `X-Admin-Key: <key>`: `GET /api/admin/reports`;
  `POST /api/admin/surfaces/:id/remove` (body `{ "block": true }` also blocks the sharer);
  `POST /api/admin/surfaces/:id/dismiss`; `POST /api/admin/users/:id/block` and `/unblock`.
- A takedown shows "This page was removed" and keeps the page, unserved, for review. Blocking a
  sharer takes down everything they still share, and refuses new links (`403 { reason: "banned" }`).
- The key is compared as a hash, in constant time, and attempts are rate limited per address.

**Deleting an account** calls `deleteUserData(env, userID)` (`src/sharing.ts`): every link it made
stops, its pages and titles are erased (the ids stay, so old links say they're gone), its blocks
and others' blocks of it go, and open reports on its pages are closed.

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
npm test                  # unit checks, then wrangler dev on a free port and every endpoint
../Tools/sharing.sh       # the app's side: what's shared, the preview, opening as untrusted
npx wrangler deploy --dry-run --env staging   # the staging config, without deploying

# The app's encoding through the real Worker and back, as a test user (with npm run dev
# running, and DEV_LOGIN=1 in .dev.vars):
DREAM_SHARE_URL=http://127.0.0.1:8787 ../Tools/sharing.sh
```

`npm test` starts its own server with the dev sign-in and a test admin key, so it can check
owners, reports, blocks and the admin with several test users. Against a server that's already
running, those parts are skipped, and making links needs `DREAM_SESSION`.

`npm test` also checks the page engine (`src/engine`, the app's checker and formula engine in
TypeScript) against the app's own: `test/engine.mjs` runs every model answer in
`test/golden/cases` through it and compares what it makes with `test/golden/expected`, which
`../Tools/engine-golden.sh` writes from the Swift engine. After changing Dream/Engine, run that
script, port the change, and the test says where the two still differ.

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

   With `DREAM_SESSION` set to a real session, the test stores about 15 copies of a sample
   surface and ends by tripping the share rate limit for a minute.

7. For reviewing reports, set the admin key once, and keep it in the login Keychain:

   ```sh
   security add-generic-password -U -a admin -s dream -w "$(openssl rand -hex 32)"
   security find-generic-password -a admin -s dream -w | tr -d '\n' | npx wrangler secret put ADMIN_KEY
   ```

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

## Accounts

People sign in with Apple; the account is Dream's own (`users`, `sessions`; migrations 0003 and
0004). The app's side is `Dream/Account/`.

| Request | What it does |
|---|---|
| `POST /api/auth/apple` | `{ identityToken, nonce, name?, device? }` → `201 { token, expiresAt, user, isNew }` |
| `GET /api/me` | `{ id, name, email, isPrivateEmail, createdAt }` |
| `GET /api/me/sessions` | `{ sessions: [{ id, device, createdAt, lastUsedAt, current }] }` |
| `DELETE /api/me/sessions/:id` | Signs one device out (`current` is the one asking). `204`. |
| `POST /api/me/export` | Everything kept for the person, as a JSON file. |
| `DELETE /api/me` | `{ authorizationCode? }` → erases everything, then asks Apple to forget Dream. |

Everything but signing in needs `Authorization: Bearer <session>` and answers `401` without one.

### Signing in

The app makes a random nonce for each sign-in and puts its SHA-256 in the request to Apple, which
writes it into the identity token. The Worker (`src/apple.ts`) checks the token:

- **Signature:** RS256 only, against Apple's keys (`https://appleid.apple.com/auth/keys`), kept
  for a day and fetched again when Apple rotates them.
- **Claims:** `iss` is `https://appleid.apple.com`; `aud` is the bundle ID (`APPLE_CLIENT_ID`);
  `exp` hasn't passed and `iat` isn't in the future, a minute either way; and `nonce` is the hash of
  the nonce the app sends.
- **Once only:** each token's nonce is kept until the token expires (`apple_nonces`), so a token
  can't sign in twice.

It finds the person by Apple's `sub`, or makes a new account. The email comes from the token;
the name comes from the app, since Apple gives it only to the app and only the first time. Both
are kept from the first sign-in. Sign-ins are limited to 10 a minute per address.

### Export and deletion

`src/userdata.ts` lists everything kept for a person, and both export and deletion work from
that list. **A table that holds someone's data needs one entry there:** `export` gives its rows
as plain JSON, without secrets or hashes, and `erase` gives the D1 statements that remove them.
The file's header has an example. All the statements run in one batch, so a deletion is all or
nothing and can be tried again. Anything outside D1, like photos in R2, is removed inside
`erase`.

Deleting an account:

1. Marks the user deleted, so every session stops at once.
2. Erases every holding in one batch, sessions and the user last.
3. Revokes Apple's tokens. The app asks the person to confirm with Apple first, which gives a
   fresh authorization code. The Worker exchanges it at `/auth/token` for a refresh token, checks
   it's the same Apple ID, and revokes it at `/auth/revoke`. Both calls take a client secret
   signed with Dream's Sign in with Apple key (ES256).

Without the key, or without a code, everything is still erased, and the Worker logs
`Apple revocation pending` with the reason. The person can remove Dream in Settings, under Sign in
with Apple, and the app tells them so.

### Setting it up

`APPLE_CLIENT_ID` (`xyz.onlychan.Dream`) and `APPLE_TEAM_ID` (`DR99P625RR`) are in
`wrangler.jsonc`. The key needs two secrets. Make it in the developer portal under Certificates,
Identifiers & Profiles › Keys: add a key, tick Sign in with Apple, and configure it for the primary
App ID `xyz.onlychan.Dream`. Download the .p8 (Apple only lets you do this once) and note its Key ID.

```sh
cd Server
npx wrangler d1 migrations apply dream-share --remote     # adds apple_nonces
printf %s "ABC123DEFG" | npx wrangler secret put APPLE_KEY_ID
npx wrangler secret put APPLE_PRIVATE_KEY < AuthKey_ABC123DEFG.p8
npx wrangler deploy
```

Then delete the .p8 from the Mac, or keep it in a password manager.

### Trying it locally

`npm test` runs `test/accounts.mjs`. It checks the token rules with test keys, then signs in,
lists and signs out devices, exports and deletes through `wrangler dev`, against a stand-in for
Apple on this Mac (`test/stub-apple.mjs`). The stand-in is only used where `DEV_LOGIN` is `1`
(`APPLE_BASE_URL`).

For trying the app's other features under `wrangler dev`, put `DEV_LOGIN=1` in `.dev.vars` and
take a session from `POST /api/dev/session?user=name`.

## Sync

A signed-in person's pages, list entries, memory, connections and settings are kept in their
account, so they're the same on each device they use (PRODUCTION.md, workstream B; `src/sync.ts`,
`migrations/0005_sync.sql`). The server can read them: that was decided, so it can export them
and work with them later. A connection's sign-in tokens never leave the phone's Keychain.

Every route needs `Authorization: Bearer <session>` (`src/auth.ts`) and only ever reads or
writes that person's own rows and photos.

```
GET  /api/sync?since=<cursor>&limit=200
→ { "user", "items": [{ "kind", "id", "parent", "format", "updatedAt", "deleted", "body" }],
    "cursor", "more", "reset", "now" }

POST /api/sync  { "items": [ the same shape ] }
→ { "applied", "stale": [ the server's versions ], "refused": [{ "kind", "id", "reason" }], "now" }
```

- **Items.** `kind` is `surface` (a page: template, the user's numbers, its conversation of
  requests, answers and changes, its generation log, and its photo's id), `record` (a list entry,
  whose `parent` is its page), `fact`, `connection` or `setting`. `id` is made on the phone.
  `format` is the body's shape: the app reads every format up to its own, and keeps items in a
  newer one until it updates. `deleted` items are tombstones with no body.
- **The latest change wins.** `updatedAt` is when the change was made, in ms, by the server's
  clock as the phone reckons it (each reply carries `now`, so phones correct their clocks). The
  server keeps an incoming change only if it's later than what it has; a tie keeps what it has.
  An older change comes back in `stale` with the server's version, which the phone takes. A time
  more than ten minutes ahead of the server's clock is pulled back, so a wrong clock can't win
  for ever. A deleted page takes its entries with it, except any changed after it was deleted.
- **Reading changes.** Each person has a change counter; every batch the server takes gets the
  next number, and each row keeps the number it was last written with. A cursor is where a
  device left off (change number, kind, id), opaque to the app and tied to the account: a cursor
  from another account reads from the beginning, with `reset: true`. Pages stop at `limit`
  (at most 500) or after about 2 MB.
- **Photos.** `PUT /api/photos/:id` with the bytes (JPEG, PNG, HEIC or WebP, recognised by their
  first bytes, at most 4 MB) keeps a page's photo in R2 under `<user id>/<id>`; the page names it
  in its `photo` field. When a page's photo changes, or the page is deleted, the server deletes
  the photo it no longer has.
- **Limits.** 2 MB a request, 200 changes a request, 256 KB an item, 50 MB of items and 500 MB
  of photos a person (`507 Your account is full`; deleting always works), 300 requests a minute
  a person (`SYNC_LIMIT`). A malformed change is refused on its own (`refused`), never the batch.
- **Deleting an account** (workstream A): `deleteUserData(env, userID)` in `src/syncdata.ts`
  removes the person's photos from R2, then their rows. `exportUserData` returns everything that
  still exists, for "Export my data". The tables also go with the `users` row (`ON DELETE CASCADE`),
  but R2 doesn't, so the function has to be called.

To try it locally, put `DEV_LOGIN=1` in `.dev.vars`, run `npm run dev`, and get a session with
`curl -X POST 'http://127.0.0.1:8787/api/dev/session?user=me'`. `npm test` checks every rule
above (`test/sync.mjs`), and `../Tools/sync.sh` checks the app's side; with
`DREAM_SYNC_URL=http://127.0.0.1:8787` it syncs two simulated phones through the Worker.

To set it up:

```sh
npx wrangler r2 bucket create dream-photos
npx wrangler d1 migrations apply dream-share --remote     # adds sync_items, sync_state and sync_photos
npx wrangler deploy
```
## The model

The app never holds a provider key. Its default model, "Dream"
(`Dream/Generation/Providers/DreamModel.swift`), sends the chat completion it would send xAI to
`POST /api/model` (`src/model.ts`), which passes it to xAI with the server's `XAI_API_KEY` and
streams the answer back as it comes, reasoning included, so the app's stall watchdog sees the
model thinking. The app's xAI adapter and the Dream adapter share one translation
(`ChatCompletions.swift`); Grok with your own key and Private Cloud Compute stay in Under the
hood as developer options.

### Which model

`src/models.ts` lists the models Dream offers, and `MODELS` (wrangler.jsonc) which of them this
server offers, in Account's order. Everyone gets the first that isn't Dream Plus only, **Grok
4.7**; Dream Plus picks how long it thinks, and testers (`PLUS_ACCOUNTS`) can try every model in
the catalogue. The app names the model it was given, or none; the server checks the plan on every
request, and anything it can't give (a Plus model on the free plan, a retired model, an unknown
id) gets the default. `GET /api/usage` lists the models for Account.

They were chosen with the page bench through a local server (`DREAM_SERVER=http://127.0.0.1:8787
Tools/bench-many.sh out -xaiModel <id> "request" …`, with `DEV_LOGIN=1`, which lets test accounts
use any model). A second bench, on seven requests before and after fixing the harness
(`docs/HarnessBench.md`), found the harness at fault more than the models: GLM 5.3 Flash's rupee
page in Spanish pesos was a repair that had lost its request, the runaways were padding nothing
stopped, and the cheaper models never looked anything up because the schema kept them from
calling tools. Since then Grok 4.7 makes every page at about $0.05, with most of its prompt read
from cache; DeepSeek V4.1 Flash looks up and cites what it used to leave out, at about $0.01 a
page, but takes about a minute; Gemma 4 on Sarvam pads its answers, and Sarvam turns away a burst
of requests. Kimi K2.6 took up to six minutes a page. Bench a model before adding it.

Workers AI's models go through the same gateway by the AI binding, billed to the account in
neurons (10,000 a day free, then $0.011 per 1,000), with each account's `x-session-affinity` for
prompt caching. `src/workersai.ts` joins a tool call's streamed pieces into one call, keeps one
usage total, and turns neurons into dollars, so usage and limits work the same as for Grok.

Workers AI and Sarvam hold every token a model writes to the request's JSON schema, so with one
the model can never start a tool call, and writes facts from memory instead (benched: asked who
won the 2026 World Cup, DeepSeek wrote "I'll look this up." as the page, and Gemma 4 that the final
hadn't been played). Their models are marked `toolsFirst` in `src/models.ts`, and
`src/toolsfirst.ts` sends each round that has tools first without the schema. A tool call there
is the answer; once the model starts writing an answer instead, it's dropped unread (its cost
estimated and counted) and the round is asked again with the schema, after a short wait if the
model is busy. After three rounds of tools the schema holds the model to answering. The tool
calls themselves, which nothing held, are fitted to their tools' schemas (`fitArguments` in
`src/workersai.ts`): Gemma sent search its keywords as a list. Grok takes tools and a schema
together, so its requests go as they are. The price is a second prefill, and thinking twice, on
each page's last round: DeepSeek's pages take about a minute now, but rest on what it read.

### Through Cloudflare's AI Gateway

Requests go to xAI's **Responses API** through the AI Gateway named in `AI_GATEWAY` (`dream`),
reached with the Worker's `AI` binding, which signs in as the account, so no gateway token is
needed. `src/responses.ts` translates both ways: the app's chat completion becomes a Responses
request (tool calls and their results as items, a photo as `input_image`, the JSON schema as
`text.format`, `store: false`), and the streamed events become chat completion chunks again (text
and reasoning as deltas, each tool call whole when its arguments are done, then the usage and
`[DONE]`). The app doesn't know.

Why: xAI reads a repeated prompt from its cache, at about a third of the price, only when requests
carry a cache key that sends them to the same server. Chat completions take it as the
`x-grok-conv-id` header, which the gateway doesn't pass on reliably (hits were about half in
testing); the Responses API takes it in the body as `prompt_cache_key`, which arrives intact (every
repeat hit). Each account has its own key, a hash of its id.

The `dream` gateway was made with the Cloudflare CLI: authentication on, logs off, no cache, and
provider keys required (`byok_only`), so nothing falls back to Cloudflare's billing. Each request
also says `cf-aig-collect-log: false`. To check it: `cf ai-gateway gateways get dream`. With
`AI_GATEWAY` empty, or `XAI_BASE_URL` set (the tests' stand-in, `test/stub-xai.mjs`), requests go
straight to xAI. Other providers can go through the same gateway later, keys stored with
`cf ai-gateway gateways providers`.

A request needs a session, proof that it's the app (as for web search), and room in the
account's allowance. It's checked and rebuilt from the fields Dream uses: the model must be on
the list (`MODELS`, default `grok-4.7`), tools must be the app's own functions (never a
provider's paid server-side tools), pictures go only as `data:` URLs, `reasoning_effort` is low,
medium or high, `max_tokens` is capped (`MAX_OUTPUT_TOKENS`, default 32,000, thinking included,
which is why a page asks for no less), the body is at
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
with xAI's reason, anything else a 502. The app asks again, up to three times, after 2, 6 and 15
seconds, when a model didn't answer (502) or was busy (503 with `Retry-After`), since nothing has
streamed yet: Sarvam turns away a second request at once, a page's check and writing start
together, and Workers AI limits requests per minute (its error code, like 3021, is the one thing
logged).

### Routing

**Auto** has the server pick the model, and how long it thinks, for each page. It's everyone's
default: first in the list `GET /api/usage` gives, and the free plan's only entry. Dream Plus can
pick Grok 4.7 and its thinking by hand instead, and testers any model. Anyone may be routed to the
table's picks (`routed` in models.ts), all of them no dearer than Grok 4.7, and to thinking "none",
which is cheaper than low. Unless something else was picked, the app asks once as a page or a
change starts (`Dream/Generation/Providers/Route.swift`):

```
POST /api/route   { "request": "split this bill between the 4 of us", "hasImage": true,
                    "image": "data:image/jpeg;base64,…" }
→ 200 { "model": "grok-4.7", "name": "Grok 4.7", "effort": "low", "category": "photo",
        "difficulty": "easy", "why": "Photos: Grok 4.7 read the bill and the plant right; cheaper models misread them" }
```

Then every request of that page, the gap check and repairs included, names that model and level
to `/api/model`. The composer's log and model name say so: "Auto → Grok 4.7 · low".

- **Request.** `request` is the person's words, up to 4,000 characters. `image` is the page's
  photo as a JPEG, PNG or WebP `data:` URL; the app sends it at most 768 pixels on the longer
  side. `hasImage` says there's a photo without sending it.
- **Who may ask.** As for `/api/model`: a session and proof that it's the app, limited per account
  (`MODEL_LIMIT`, key `route:<id>`). The answers are 401, 405, 415, 413 (over 1.5 MB), 400 (a
  missing or long request, an image that isn't a `data:` URL) and 429.
- **The plan holds.** The pick is what `/api/model` would allow anyway: testers any model and
  level; everyone else only the offered models (`MODELS`), with Plus-only models on Dream Plus;
  Dream Plus thinks from low to high, and the free plan low. A row's pick is used only as it was
  benched. DeepSeek thinking "none" isn't turned into DeepSeek thinking low, which made 11 of 16
  pages, for a plan held to low; the row's next pick is used instead, and `why` says it's "the
  best your plan has".
- **Never an error from Clef.** If Clef fails, takes more than 6 seconds, or answers something that
  doesn't read, the answer is Dream's default, Grok 4.7 thinking low. If the route itself fails,
  the app uses the server's default at low.
- **"auto" sent to `/api/model` directly.** It's routed on what the request shows on its face,
  without Clef: a photo, a run of another script in the first user message, or else the
  default's row. That's the same for every request of a page.
- **Local development.** With `DEV_LOGIN`, the answer also carries Clef's `signals`, for tuning.

**How it decides.** `src/route.ts` asks Cloudflare's **Clef Flash** (`@cf/cloudflare/clef-flash`:
9B, $0.038 per million input tokens and nothing for output) through the gateway. It answers four
typed questions (`QUESTIONS` in `src/router.ts`):

- `topic`: a choice of money, science, lists, figures or other;
- `fresh`: a yes/no on whether it needs facts looked up now;
- `foreign`: a yes/no on whether it's not in English;
- `difficulty`: a score from 0 to 3.

A request lands on a row in this order: a photo; another language (Clef's answer, or the script
itself); live facts; then the topic. It's "hard" from a difficulty of 1.5. A call is about 550
tokens, $0.00002, counted against the account like a small job. On 2026-10-27 it answered in
0.45 s median, under a second nine times in ten. On 32 test requests every one landed where it
should, except "a bar chart of India's GDP growth by decade", which went to live facts.

**The table** is data: `TABLE` in `src/router.ts` maps category × difficulty to picks, cheapest
good enough first, each row ending on Grok 4.7 thinking low. Its comment has the numbers behind
every row.

In the table below, "DeepSeek" is DeepSeek V4.1 Flash on Workers AI, and "Sarvam's DeepSeek" is
the same model hosted by Sarvam, thinking low.

| Row | Picks, in order | Why, from the bench of 2026-10-28 |
|---|---|---|
| Money, easy | Sarvam's DeepSeek; DeepSeek (none); Grok 4.7 low | 10 on the EMI page like Grok, for 1¢ to Grok's 4.8¢ |
| Money, hard | Grok 4.7 low | 10 on a split with a catch; the DeepSeeks 5 and 6 |
| Science | DeepSeek (none); DeepSeek (low); Sarvam's DeepSeek; Grok 4.7 low | 9 like Grok, in 24 s for 0.3¢ |
| Lists | Sarvam's DeepSeek; Grok 4.7 low | 9 to Grok's 10, for a tenth of the cost |
| Live facts | Sarvam's DeepSeek; DeepSeek (low); Grok 4.20 Fast; Grok 4.7 low | Looked them up and scored 10, in 24 s for 0.8¢ |
| Photos, easy | DeepSeek (low); Grok 4.7 low | Read the bill and the plant right (8, 9), for half Grok's cost |
| Photos, hard | Sarvam's DeepSeek; Grok 4.7 low | Solved the worksheet from the photo (10), for 1.2¢ |
| Other languages | DeepSeek (low); Grok 4.7 low | 8.7 to Grok's 9.3 in Hindi and Tamil, for 0.7¢ |
| Figures, easy | Sarvam's DeepSeek; DeepSeek (low); Grok 4.7 low | 10 on the 3D molecule like Grok, for 0.9¢ |
| Figures, hard | DeepSeek (none); Sarvam's DeepSeek; DeepSeek (low); Grok 4.7 low | 10 on the pendulum like Grok, for 0.4¢ |
| Everything else | Grok 4.7 low | Not benched as a category |

On the merged code's bench, how the choices compare:

| Choice | Score | Cost a page | Median time |
|---|---|---|---|
| This table | 9.3 | 1.0¢ | 43 s |
| Grok 4.7 low on every page | 9.6 | 6.0¢ | 39 s |
| The table before this bench | 9.2 | 3.8¢ | — |

The table was made from those same pages, so the comparison flatters it. With one run of 16
requests, a row rests on one or two pages.

Auto now saves money, not time. The DeepSeeks look things up and think twice on a page's last
round, so they take about a minute a page, while Grok 4.7 reads most of its prompt from cache.

**The bench** ran twice, and the tool to run it again is `Tools/router-bench/bench.py`:

- **2026-10-27:** every candidate, about $6.25.
- **2026-10-28, on the merged code:** after the harness began sending Workers AI's and Sarvam's
  models their tools before the schema (`docs/HarnessBench.md`). It ran the table's picks, Grok 4.7
  low as the reference, both DeepSeek levels and Sarvam's DeepSeek, for $2.12. The table comes
  from this run.

Both ran the same way:

- **Requests:** 16, two or three in each of seven kinds of page: money, science and maths
  explainers, lists and trackers, live facts, photos (a restaurant bill, a maths worksheet, a
  plant), Hindi and Tamil, and simulations and 3D.
- **How they ran:** every candidate made every page through the real pipeline (the Mac bench and
  a local server), each page on its own tester account, so its cost is that account's usage.
- **How they were scored:** Grok 4.7, thinking low, scored each request's pages 0 to 10, side by
  side, anonymised and shuffled. Against ground truth it judged correctness (4), fit and language
  (2), usefulness (2) and clarity (2). Live facts not backed by a search or live tool call in the
  page's log count as invented.
- **Failures:** a page not made scores 0.

On the merged code (2026-10-28):

| Model and thinking | Made | Score | Median time | Cost a page |
|---|---|---|---|---|
| Grok 4.7, low | 16/16 | 9.6 | 39 s | 6.0¢ |
| Grok 4.20 Fast (live facts only) | 2/2 | 9.0 | 12 s | 2.6¢ |
| DeepSeek V4.1 Flash, none | 16/16 † | 7.1 | 57 s | 1.2¢ |
| DeepSeek V4.1 Flash, low | 16/16 † | 8.0 | 65 s | 1.4¢ |
| Sarvam's DeepSeek V4.1 Flash, low | 16/16 | 8.8 | 50 s | 1.0¢ |

† Started 16 at once, 7 and 6 of these pages were turned away by Workers AI's per-minute limit
(error 3021), even after the app's three retries. They were made again one at a time.

Before the harness changes (2026-10-27):

| Model and thinking | Made | Score | Median time | Cost a page |
|---|---|---|---|---|
| Grok 4.7, low | 16/16 | 9.6 | 42 s | 7.0¢ |
| Grok 4.7, high | 15/16 | 9.0 | 85 s | 10.4¢ |
| Grok 4.20 Fast | 16/16 | 6.9 | 22 s | 5.9¢ |
| DeepSeek V4.1 Flash, none | 16/16 | 5.9 | 9 s | 0.3¢ |
| DeepSeek V4.1 Flash, low | 11/16 | 3.2 | 28 s | 0.6¢ |
| GLM 5.3 Flash, low | 12/16 | 4.6 | 41 s | 0.3¢ |
| Sarvam's DeepSeek V4.1 Flash, low * | 14/16 | 7.2 | 20 s | 0.9¢ |
| Sarvam's GLM 5.3, low * (8 requests) | 6/8 | 4.8 | 15 s | 1.9¢ |
| Sarvam 105B * | 2/16 | 0.4 | — | 1.3¢ |
| Gemma 4 on Sarvam * | 2/16 | 1.0 | — | 1.1¢ |

\* Sarvam was reached directly, as the Worker now always does. Through the gateway's custom
provider, every request failed with error 2006, "The provider did not return a valid response".

What they showed:

- **Tools changed the cheap models.** With their tools sent first, both DeepSeeks look things up
  and cite them. DeepSeek at low went from 3.2 to 8.0, and Sarvam's DeepSeek from 7.2 to 8.8.
  The price is time: about a minute a page, where they used to take 10 to 30 s.
- **The cheap models are now the slower ones.** Grok 4.7, reading most of its prompt from cache,
  went from 42 s and 7.0¢ to 39 s and 6.0¢.
- **Workers AI's per-minute limit.** It turned away 13 of 32 DeepSeek pages started 16 at once,
  because tools first means several requests a page. The Worker reports that as a 502 ("didn't
  answer"). Under load, Auto's Workers AI rows would meet it too.
- **Thinking high never paid.** Grok 4.7 high scored lower than low, took twice as long (one
  photo page ten minutes) and cost half again as much. No row asks for it.
- **GLM 5.3 Flash** wrote JSON that didn't parse on a quarter of its pages (first run).
- **Sarvam 105B** stopped partway through most pages: its plan caps the answer, and its thinking
  counts against that. It refused photos, and so did Sarvam's GLM 5.3 (first run).
- **Gemma 4** was mostly refused by Sarvam's per-minute limit, even one page at a time, and
  stalled when it wasn't (first run).
- **Sarvam's DeepSeek** is the best of the cheap models. It made every page, four at a time, and
  reads photos despite Sarvam's docs. It leads easy money, lists, live facts, hard photos and easy
  figures.

The full model × category matrix is in the comment above `TABLE`.

**Public benchmarks, against ours** (October 2026; no public IFEval, BFCL or structured-output
numbers exist yet for most of these):

- **Where they agree.** Grok 4.7 has the highest Artificial Analysis index of the set (42 at low,
  46 at high), and it was the most reliable here. Gemma 4 (index 14–15) and Sarvam 105B (index 9,
  IFBench 34) are weak with long instructions and strict schemas. They failed most pages here, and
  Sarvam's own docs warn that Gemma returns whitespace under `response_format`. Grok 4.20 Fast's
  index (14) and Artificial Analysis's 97% hallucination rate for it fit its weak money and
  figure pages, though it searched properly for live facts.
- **Where they disagree.**
  - DeepSeek V4.1 Flash (index 45, the best at maths of the set on MathArena) did better here with
    its thinking off until it could call tools; since then thinking low scores higher (8.0 to
    7.1), still well below Grok 4.7.
  - GLM 5.3 Flash (index 42) broke JSON on a quarter of its pages.
  - Grok 4.7 at high rates above low publicly but scored below it here.
  - Sarvam's self-reported numbers (τ² 68, IFEval 85) are far above independent ones (τ² 47).

What decides a Dream page is following a 60–120 KB prompt into one strict schema, with tool
calls. No public benchmark measures that, so the page bench decides.

**Benching again, and changing the table.**

1. **Start a local server.** Write `.dev.vars` (made with `umask 077`, keys from the Keychain):
   `DEV_LOGIN=1`, the app key, the xAI, Parallel and Sarvam keys, `MODELS` with every catalogue
   id, and generous `ALLOWANCES`. Then run
   `CI=1 npx wrangler d1 migrations apply dream-share --local` and
   `npx wrangler dev --port 8792 --ip 127.0.0.1`.
2. **Build the bench and make accounts.** Run `Tools/router-bench/bench.py build`, then
   `Tools/router-bench/bench.py accounts g47l dsn g420 …`. Add the ids it prints to
   `PLUS_ACCOUNTS` in `.dev.vars`, so those accounts may think at any level, and restart the
   server.
3. **Make the pages.** Run `Tools/router-bench/bench.py run g47l dsn g420` for each config in
   turn.
   - Sarvam and Workers AI both limit requests a minute, and with tools first a page makes
     several, so run their configs a few at a time: `Tools/router-bench/bench.py run -p 4 sds`.
   - A page turned away with error 3021 in the Worker's log is the limit, not the model. Run it
     again on its own, like `run dsn:m1`; its cost is counted from where the account was.
   - Don't edit `Server/src` while pages are being made: `wrangler dev` reloads and cuts the
     streams in flight.
4. **Score them.** Run `judge` (about $0.40) and then `matrix`. `probe` shows what Clef and the
   table pick for each request.
5. **Change the table by the rule.** A pick is good enough for a row when it made every page of
   the category, scored none below 5 there, and averaged 8 or more on the row's own requests (the
   category's, where there were none at that difficulty). Put the cheapest such pick first and
   update the numbers in the comment.
6. **Test, and clean up.** `npm test` checks every pick is in the catalogue at a level its model
   takes, that each row ends on Grok 4.7 low, and that photo rows only name models that read
   photos. It also clears the local usage tables, so read the matrix first. Delete `.dev.vars`
   when you're done.

## Pages made on the server

The page loop the app runs (`Dream/Generation/Composer.swift`) also runs here, so a page is made
whether or not anyone watches (docs/ServerGeneration.md, Stage 1). `POST /api/compose` takes the
request (`src/compose/contract.ts`) with the session and the app's proof, as `/api/model` does,
counts the page against the allowance, and starts a `PageJob`: a Durable Object for that page,
which runs the loop on its alarm and keeps its events in its own storage (`src/compose/`).

- **The loop** (`loop.ts`) is Composer's: Auto once, the gap check beside the writing with its
  hold, lookup, search and read, the check and repair loop, and the stall, runaway and padding
  guards. It calls the model, Auto, search and read in-process, through the same checks as their
  routes (`askModel`, `routePage`, `searchFor`, `readFor`). Its prompts, schemas and tools come
  from `src/generated/generation.json`, which `Tools/export-generation.sh` writes from the app.
- **Questions** stop the loop: the job waits for `POST …/answers`, and after ten minutes goes on
  as if every answer were "You choose".
- **Watching** catches up from the log after `after`, then streams events as they happen, with a
  `: keep-alive` comment every 15 seconds, and ends after `done` or `failed`. Only the latest
  page shown is kept in the log. Only the account the page is for may watch it or answer it.
- **Finished** pages go into the account's sync as `surface` items under the request's `pageID`
  (`payload.ts`), with the photo they started from, and the job is forgotten a day later.
- **A restart** mid-page (a deploy) runs the alarm again, and the page starts over, keeping Auto's
  pick and any answers; after three starts it fails.

Locally, `MODEL_FAKE=1` with `DEV_LOGIN=1` answers the page loop's model requests with a
stand-in (`src/compose/fake.ts`) and skips Clef, so `wrangler dev` makes whole pages without a
provider's key; `/api/model` never uses it. `npm test` runs the loop on scripted streams
(`test/compose.mjs`) and the routes on the stand-in (`test/compose-http.mjs`).

## Notifications

A page made with nobody watching tells the account's iPhones when it's ready, and when Dream has
a question about it (docs/ServerGeneration.md, Stage 3; `src/push.ts`). The job counts the event
streams open on it; a page that finishes, or asks, while none are open asks `push.ts` for a
notification. The app drops its streams when it goes to the background, so leaving the app is
what makes a page notify.

- **Devices.** After signing in, the app sends `POST /api/push/devices` with
  `{ token, environment }` (`contract.ts`'s `PushDevice`): the APNs token, hex, and `sandbox`
  for a development build or `production` for TestFlight and the App Store. It's kept in
  `push_devices` (`migrations/0010_push.sql`) with the session that sent it, so a session that
  ends, signed out here or from another iPhone, takes it along. At most five per account; a token
  registered again by someone else moves to their account. `DELETE /api/push/devices/:token` at
  sign-out. Both need the session, and share `CREATE_LIMIT` per account.
- **What a notification says.** "Your page is ready" with the page's title, or "Dream has a
  question about “the request's first six words”". Nothing else from the page or the request:
  it shows on a lock screen and passes through Apple. Beside `aps`, it carries `PushPayload`
  (`page`, `job`, `kind`), which the app opens. `apns-collapse-id` is the page, so a question's
  notification is replaced by the page's; a question's expires when the question would be left to
  Dream, a page's after a day.
- **Sending.** Token-based: an ES256 JWT signed with the APNs key through WebCrypto, issued at the
  start of each half hour so every copy of the Worker uses the same moment, and reused until the
  next (APNs wants a token kept 20 to 60 minutes). Development builds' tokens go to
  `api.sandbox.push.apple.com`, the rest to `api.push.apple.com`. A token APNs answers with 410
  or `BadDeviceToken` is forgotten; after a 403 the next notification signs a new JWT.

### Setting it up

Off until the three secrets are set; without them the job logs once that notifications are off
and sends nothing. In the developer portal, under Certificates, Identifiers & Profiles:

1. **Identifiers** › `xyz.onlychan.Dream`: tick Push Notifications and save. (Xcode's automatic
   signing does this too, the first time it builds with the `aps-environment` entitlement.)
2. **Keys** › add a key, tick Apple Push Notifications service (APNs), and choose Sandbox &
   Production for its environment. Download the .p8 (Apple only lets you do this once) and note
   its Key ID.

```sh
cd Server
npx wrangler d1 migrations apply dream-share --remote     # adds push_devices
npx wrangler secret put APNS_KEY < AuthKey_ABC123DEFG.p8
printf %s "ABC123DEFG" | npx wrangler secret put APNS_KEY_ID
printf %s "DR99P625RR" | npx wrangler secret put APNS_TEAM_ID
npx wrangler deploy
```

Locally, `npm test` runs `test/push.mjs`: the sender in Node with a key made for the test and a
stand-in for fetch, the job in memory on the stand-in model, then the routes and whole pages under
`wrangler dev` against a stand-in for APNs on this Mac (`test/stub-apns.mjs`, reached through
`APNS_BASE_URL`, which only counts with `DEV_LOGIN`).

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
## Policy pages

`/privacy`, `/terms` and `/support` (`src/legal.ts`) are what the app links from its first run and
Account, and what App Store Connect asks for: the privacy policy URL is
`https://dream.onlychan.xyz/privacy`, the support URL `https://dream.onlychan.xyz/support`. They're
plain HTML in the web viewer's style, with no scripts.

All three are **drafts that need a lawyer's review**, and say so at the top. Everything still to
be decided is in highlighted `[brackets]`: the company's name and address, contact addresses, the
DPDP grievance officer, legal bases, retention for usage and purchase records, PostHog's region,
the minimum age, the subscription's names and prices, liability and governing law. When the text
changes, change `UPDATED` in `src/legal.ts` too.

## Diagnostics

When someone turns on "Help improve Dream", the app sends MetricKit's crash, hang and slow-launch
reports (`Dream/Privacy/Diagnostics.swift`) to `POST /api/diagnostics`:

```json
{ "format": 1, "reports": [{ "kind": "crash", "app": "1.0", "build": "7", "os": "iPhone OS 27.0 (24A335)",
  "device": "iPhone18,1", "testFlight": false, "start": 1761400000, "end": 1761486400,
  "exceptionType": 6, "exceptionCode": 1, "signal": 5, "terminationReason": "…", "stack": { "callStacks": [] } }] }
```

- **Anonymous.** The app sends no session, and the Worker stores no address, account or region.
  An Objective-C exception's message is never sent, since it can quote the app's data; only its
  name and class.
- **Checked** (`src/metrickit.ts`): at most 20 reports and 256 KB an upload, every string bounded
  and printable, numbers finite, and the kind one of crash, hang or launch. A stack bigger than
  64 KB is dropped and the rest of its report kept. 10 uploads a minute per address
  (`DIAGNOSTICS_LIMIT`). Answers `202 { accepted }`.
- **Grouped:** each report gets a `signature`, the innermost frame in Dream's own code (or else the
  innermost frame), after the crash's kind: `EXC_BREAKPOINT SIGTRAP Dream+0x1a2b4`.
- **Kept 90 days** (`diagnostics` table, migrations/0008), deleted as new reports arrive.
- **Symbolication:** stacks are binary names and offsets. To turn `Dream+0x1a2b4` into a function
  and line, use the dSYM of that exact build (App Store Connect keeps one for every upload; Xcode's
  Organizer can download it). The offset counts from the start of Dream's code, which `atos`
  places at `0x100000000`, so `Dream+0x1a2b4` is
  `atos -o Dream.app.dSYM/Contents/Resources/DWARF/Dream -arch arm64 -l 0x100000000 0x10001a2b4`.
  The stored `stack` is MetricKit's own JSON, for tools that read it.

The summary is for whoever runs Dream, with the `ADMIN_KEY` secret in `X-Admin-Key`. Without the
secret the route doesn't exist (404); with a wrong key it's 403.

```sh
curl -s -H "X-Admin-Key: $(security find-generic-password -a admin -s dream -w)" \
  "https://dream.onlychan.xyz/api/admin/diagnostics?days=7"
→ { "days": 7, "total": 12, "byKind": { "crash": 2, "hang": 9, "launch": 1 },
    "byVersion": [{ "app": "1.0", "build": "7", "crash": 2, "hang": 9, "launch": 1 }],
    "perDay": [{ "day": "2026-10-26", "crash": 1, "hang": 4, "launch": 0 }],
    "topSignatures": [{ "kind": "hang", "signature": "Dream+0xbeef", "count": 6, "lastSeen": "…", "latest": "1.0 (7)" }],
    "durations": { "hang": { "count": 9, "average": 1.8, "median": 1.2, "p90": 4.1, "max": 6 }, "launch": { … } } }
```

`days` is 1 to 90 (default 7). Make the key once and keep it in the login Keychain:

```sh
security add-generic-password -U -a admin -s dream -w "$(openssl rand -hex 32)"
security find-generic-password -a admin -s dream -w | tr -d '\n' | npx wrangler secret put ADMIN_KEY
```

## Server analytics events

The app sends its own usage events to PostHog (`Dream/Engine/Analytics.swift`,
`docs/Analytics.md`). A few things only the server knows, so `src/analytics.ts` can send them
itself, under the same person (Dream's own user id, never Apple's or an email):

| Helper | Event | Properties |
|---|---|---|
| `limitReached(env, ctx, user.id, "pages")` | `limit_reached` | `kind`: pages, tokens or searches |
| `subscriptionStarted(env, ctx, user.id, productID)` | `subscription_started` | `product` |
| `subscriptionEnded(env, ctx, user.id)` | `subscription_ended` | |

Metering and subscriptions (workstream D) call them. They send after the response, never throw
and never log, and do nothing while the `POSTHOG_KEY` var is empty. Set it, and `POSTHOG_HOST`
(`https://us.i.posthog.com` or `https://eu.i.posthog.com`), in `wrangler.jsonc`: the project key
is public, like the app's. The server can't see whether the person turned on "Help improve
Dream" on their phone, so keep `POSTHOG_KEY` empty here until that choice reaches the server
with the account's settings, or check it before calling these.

## Staging

`wrangler.jsonc` has a `staging` environment: a second Worker, `dream-share-staging`, on
`dream-share-staging.<subdomain>.workers.dev` with no custom domain, its own D1 database, rate
limits counted apart from production's, and a tenth of the web search budget. Cloudflare doesn't
copy bindings between environments, so a binding added at the top of `wrangler.jsonc` (an R2
bucket, a new rate limit) must be added under `env.staging` too.

To set it up, once:

```sh
cd Server
npx wrangler d1 create dream-share-staging      # put the database_id it prints into env.staging
npx wrangler d1 migrations apply dream-share-staging --remote --env staging
# Secrets are per environment. Use different keys from production's.
npx wrangler secret put PARALLEL_API_KEY --env staging
npx wrangler secret put DREAM_APP_KEYS --env staging
npx wrangler secret put ADMIN_KEY --env staging
npx wrangler deploy --env staging
DREAM_SHARE_URL=https://dream-share-staging.<subdomain>.workers.dev npm test
```

After that, `npx wrangler deploy --env staging` to try a change, and
`npx wrangler d1 migrations apply dream-share-staging --remote --env staging` before deploying a
migration to production. To point a Debug build of the app at staging, enter its address in Under
the hood › Sharing; universal links still name production. Leave `DEV_LOGIN` unset on staging:
it's public, and anyone could make sessions there.

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
  template, as now. Only a list the user explicitly shares reaches other people; every other
  list stays the user's own (in their account, once they sign in: see [Sync](#sync)).
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
