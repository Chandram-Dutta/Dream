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
engine, because it runs every page's formulas on the phone.

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
  "editing": { "surface": {}, "instruction": "make it four people", "focus": "block id" }
}
```

`editing` is for a change to a page (Stage 2); without it, a new page. Answers `{ "id": "job id" }`.

Events, one JSON object per `data:` line, each with `seq`:

| `type` | fields | when |
| --- | --- | --- |
| `phase` | `phase`: `researching`, `composing`, `fixing` | the loop moves on |
| `trace` | `kind`: `search`, `read`, `lookup`; `text` | a step of the work starts (the glimpses) |
| `surface` | `surface`: a Surface, as the app's Codable reads it | the page so far, at most 5 a second |
| `asking` | `questions`, as the app's `Asking` reads them | the loop waits on answers |
| `log` | `line` | what Under the hood shows |
| `done` | `surface`, `model` | finished; the page is synced too |
| `failed` | `message` | it couldn't make the page |

## Stages

1. **A page survives the app closing.** New pages only, with lookup, search and read. The loop,
   the job object, the events, the exported prompts and schemas, the checker's core (calculation,
   blocks, citations, sourcing) and the repair loop. The app starts a page on the server behind a
   setting, renders the events, and picks up a page it left: by its job id while the job lasts, or
   from sync once it's done.
2. **Everything a page can be.** The rest of the checker (lists, figures, scenes, sounds, live,
   units), changes to a page, memory recall from synced facts, and live data (weather, exchange
   rates, travel times) from server-side sources.
3. **Come back to it.** Push notifications for a finished page and for a question (APNs; needs an
   auth key from the developer account). The shelf shows pages still being made.
4. **Server by default.** Connected services' tools on the server, then the server makes every
   page and the phone's loop is removed (the engine stays, to run pages).

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
