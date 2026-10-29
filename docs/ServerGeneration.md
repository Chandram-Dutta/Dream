# Pages made on the server

Today the page loop runs on the phone (Dream/Generation/Composer.swift). It decides what to ask,
looks things up, writes the page, checks it and repairs it. Close the app mid-page and the page is
lost. This moves that loop to Dream's Worker, so a page is made whether or not anyone is watching.
The phone starts a page, watches it form, and finds it finished if it left.

Decided with the user on 2026-10-28: move it, in stages.

## What it buys

- A page survives the app closing, being killed, or the phone going offline.
- A push says when a page is ready, or when Dream has a question: a reason to come back.
- One loop for every client: the iPhone now, the web and desktop later.
- Every page passes through one place, so pages can be measured, cached and reused across people
  (the memory layer in the project's vision).
- Lookups, searches and reads run next to the models, without a round trip to the phone each.

## How it runs

- **`PageJob`, a Durable Object, one per page.** `POST /api/compose` creates one and starts it on
  an alarm. The alarm handler runs the whole loop, up to its 15 minutes. Everything it does is
  appended to the job's event log in its storage. If the object is restarted mid-page (a deploy),
  the alarm runs again and the page starts over, so no page is left half made.
- **Watching is optional.** `GET /api/compose/:id/events?after=<seq>` is a server-sent event
  stream: first every event after `seq` from the log, then new ones as they happen. The app
  reconnects with the last `seq` it saw, so nothing is missed or shown twice.
- **Questions wait.** The gap check's questions, and a connected service's request for consent, are
  events. The loop waits for `POST /api/compose/:id/answers`. If nobody answers in 10 minutes it
  goes on as if the answer were "You choose".
- **Finished pages sync.** The finished page is written to the account's synced pages (sync kind
  `surface`, syncdata.ts), so it reaches the phone the next time it syncs, even if it never watched.
- **Models are called in-process.** model.ts's checks, routing (Auto), metering and provider
  translation become a function the loop calls, not an HTTP round trip. Usage is counted against the
  account as now.

## One source of truth while both exist

The prompts, the page's JSON schema, and the tools' descriptions and argument schemas stay defined
in Swift (Prompts*.swift, Wire.swift, the Tool types). `Tools/export-generation.sh` writes them to
`Server/src/generated/` as JSON, and the server reads them from there. Change a prompt in Swift, run
the export, deploy. When the on-device loop is gone, the generated files become the source.

The checker and the formula engine are ported to TypeScript (`Server/src/engine/`), and kept equal
to Swift's by golden tests: a Swift tool runs Swift's checker over a corpus of model outputs and
writes what it produced; the TypeScript checker must produce the same. The app keeps the Swift
engine, because it runs every page's formulas on the phone. The corpus is
`Server/test/golden/cases`; `Tools/engine-golden.sh` writes what Swift makes of it, and `npm test`
compares (`Server/test/engine.mjs`). Change the Swift engine, run the script, port the change.

## The contract

`POST /api/compose`, with the session as for `/api/model`:

```json
{
  "request": "split a 2400 rupee dinner between 3 friends",
  "image": "<base64 JPEG, optional>",
  "model": "auto",
  "thinking": "low",
  "locale": { "language": "en", "region": "IN", "currency": "INR", "measurementSystem": "metric" },
  "context": ["lines the phone adds, like what it remembers about the user"],
  "pageID": "the id the finished page is kept under, made by the app"
}
```

Answers `{ "id": "job id" }`. The types are `Server/src/compose/contract.ts`. Changes to a page
(Stage 2) add an `editing` field. When the user has already allowed location, the phone adds
`here`: its position rounded to about a kilometre, the place's name (town, region, country) and
its time zone, and a line in `context`, "The user is in Bengaluru, Karnataka, India." It never
asks for location for this, and waits at most two seconds for a fix. The server's weather "here"
uses it, or else where Cloudflare places the request; the coordinates never reach the model or
the page. The finished page is written to sync as a `surface` item
(the app's `SurfacePayload`, Dream/Sync/SyncPayloads.swift) under `pageID`, and the app saves a
page it watched under the same id, so it's never kept twice.

The engine's interface is `Server/src/engine/index.ts`: the job runner calls it, the engine port
fills it in.

Events, one JSON object per `data:` line, each with `seq`:

| `type` | fields | when |
| --- | --- | --- |
| `phase` | `phase`: `researching`, `composing`, `fixing` | the loop moves on |
| `trace` | `kind`: `search`, `read`, `lookup`; `text` | a step of the work starts (the glimpses) |
| `surface` | `surface`: a Surface, as the app's Codable reads it | the page so far, at most 5 a second |
| `asking` | `questions`, as the app's `Asking` reads them | the loop waits on answers |
| `log` | `line` | what Under the hood shows |
| `deviceTool` | `call` (`id`, `name`, `arguments`), `deadline` | the phone should run one of its tools; kept in the log only while it waits |
| `done` | `surface`, `model` | finished; the page is synced too |
| `failed` | `message` | it couldn't make the page |

`POST /api/push/devices` (`PushDevice`: the APNs token and `sandbox` or `production`) registers
the phone for notifications, and `DELETE /api/push/devices/:token` forgets it at sign-out. A
notification carries `PushPayload` (`page`, `job`, `kind`: `done` or `asking`) beside `aps`.

The phone answers a `deviceTool` call at `POST /api/compose/:id/tools` with `{ id, output }`, and
the live `source` it read, if any. After `deadline` (a minute) the model is told it couldn't be
read and the page goes on.

## Stages

1. **A page survives the app closing.** Done 2026-10-29, and the default since: new pages are made
   on the server (Under the hood can turn it off in a testing build).
2. **Everything a page can be.** Changes to a page (`editing`: an instruction, a different answer,
   or made again); memory, read from the account's synced facts; live data from the server (the
   weather from Apple Weather, WeatherKit's REST API, as the phone reads it, with Open-Meteo
   standing in until its secrets are set or when it fails; exchange rates from ExchangeRate-API;
   with the same fields the app's providers give, so the phone refreshes them as its own);
   recordings and molecules. Server side
   done 2026-10-29, with the phone's tools (Stage 4's `deviceTools`): the instructions are put
   together from the features whose tools are offered, so they never describe a tool that isn't
   offered, nor offer one they don't describe.
3. **Come back to it.** Push notifications for a finished page and for a question (APNs, with an
   auth key from the developer account set as secrets; off until they're set). The shelf shows
   pages still being made (done in Stage 1). Built 2026-10-29 (`Server/src/push.ts`, the app's
   `Dream/Account/Notifications.swift`): a page that finishes, or asks, while no event stream is
   open on it notifies the account's iPhones, and the app drops its streams when it goes to the
   background. The app asks to notify the first time a page is still being made when it's left.
   Tapping one opens the page, finished or forming. Setting up: Server/README.md, Notifications.
4. **Server by default, phone where only the phone can.** Tools only the phone can run go
   through it (`deviceTools`): connected services, whose sign-ins never leave the phone, and
   travel times from Apple Maps. While the app is open the phone runs them; when it isn't, the
   model is told they couldn't be read. The phone's own loop stays for a testing build that turns
   the server off, and for Private Cloud Compute.

## Who builds what

Three workstreams after a foundation pass (the contract above, the export tool, the corpus):

- **Engine port**: `Server/src/engine/`, the formula engine and the checker in TypeScript, golden
  tested against Swift.
- **Job runner**: `PageJob`, the routes, model calls in-process, the tools and the loop, using the
  engine's interface (a stub until the port lands).
- **App client**: `ServerComposer`, which starts a page, renders the events through the same
  views as now, and resumes pages left mid-way.

Agents never deploy, set secrets, write to the remote D1 or change Cloudflare settings; the
integrator merges, deploys and runs pages on the iPhone.
