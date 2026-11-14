# Dream on Apple Intelligence

This branch (`apple-intelligence`) makes every page with Apple's own models. Dream has no model
provider, no model proxy and no model of its own. What someone asks is processed on their iPhone
or on Private Cloud Compute, and nowhere else.

## What Dream is

You ask for anything, and Dream makes a page for it. The page is not a chat reply. It explains,
calculates, or both, as the request needs. "Split a dinner bill four ways with a tip" becomes a
working calculator with the answer at the top. "Who was Ada Lovelace" becomes a page to read,
with facts, a timeline and sources. "How does the angle change a throw" becomes a drawing you can
drag, with the equation worked through using your numbers.

Every page is generated, but the format, the checker and the renderer are hand-written. The model
writes a structured page (`WireSurface`, through guided generation). The engine checks it: the
formulas parse and work out, every control changes a result, facts aren't sliders, and the cited
sources were actually read. It fixes what it can, and sends what it can't back to the model in the
same session. SwiftUI then draws it as a real interface.

## Two models, one harness

| | Private Cloud Compute | On the iPhone |
|---|---|---|
| Model | `PrivateCloudComputeLanguageModel` | `SystemLanguageModel.default` |
| Window | 32,768 tokens, with reasoning | 8,192 tokens |
| Brief | The full brief (`Prompts.surface`, ~4.7k tokens) | A short brief (`Prompts.surfaceOnDevice`) |
| Format | `WireSurface`: every block kind, figures, diagrams, 3D scenes, sounds, lists, actions | `DeviceSurface`: text, facts, timelines, a calculation with controls, charts |
| Tools | Wikipedia, web search and reading, live data (weather, rates, places), memory, connected services (MCP) | None: Wikipedia is looked up first and given with the request |
| Repairs | Up to two, in the same session | One, in a fresh session |
| Asks first | Yes, a separate gap check, when only the user can say | No |

Both formats become the same `Surface`, go through the same checker and are drawn by the same
renderer (`Dream/Generation/Wire+OnDevice.swift`). PCC writes every page. The iPhone's model
can be picked in Under the hood, and can stand in automatically when PCC can't be reached
(`Composer.fallsBackOnDevice`, off for now, since its pages are much thinner). On the iPhone,
Dream looks the request up on Wikipedia first and the model only writes: calling tools while
writing, the small model looped or stopped. The safety filter is never routed around.

Private Cloud Compute measured on an iPhone Air: "square root of 420" took 10.9 s, and a page
about Kenya's languages took 26 s with one Wikipedia lookup.

## How a request goes

1. **Understanding.** Before anything is asked or written, a short session on PCC reads the
   request and, when it's about the user's own things or a name that could mean several things,
   looks first: in their connected services, what Dream remembers, Wikipedia and the web, with
   look-up tools only. "Check my project's GTM notes" searches Notion and asks which project, by
   the names it found, instead of guessing that GTM means Google Tag Manager. It writes down what
   it found, which the page is then built from, and asks only what it couldn't find out. A
   request that's already clear needs no tools and is understood in a couple of seconds.
2. **Your turn**, only if something was still open: tap an answer (the real options found), or "You choose". Answers worth
   keeping, like a home town, are remembered on the device.
3. **Researching.** The model looks up what it states about the world: Wikipedia, the web, live
   data, the user's connected services (each asks permission at the moment of use).
4. **Writing.** The page streams onto the screen block by block.
5. **Checking.** The checker's problems go back to the model, which fixes them.

The light behind the screen shows each stage in its own colors (`Dream/UI/StageLight.swift`):
violet while understanding, pearl and still on your turn, blue to teal while looking things up,
Dream's warm light while writing, and green while checking. Once the page is done, the light
settles at the top in the page's own color, chosen by its subject.

## Connected services

A service the request involves is offered whole, as far as looking things up goes: its search
finds a page and its fetch opens it. Tools that change things come only when the request asks
to act, never while it's still being understood, and always ask first. The same call made twice
gets the first answer back instead of another trip. Calls made together share one token refresh,
and a source a saved page keeps current backs off when its service fails.

## Room in the window

Every model session has a budget for what its tools return (`Dream/Generation/ContextBudget.swift`):
the window (32,768 tokens on PCC), less the instructions, the answer's schema, the tools' own
descriptions and room for the answer. Each result takes a share of what's left: half of it, at
most 8,000 characters. So ten pages opened at once each get a smaller piece instead of
overflowing the window, and once the budget is spent, tools tell the model to write from what
it has. A long result keeps its opening and the parts that share the request's words
(`Excerpt`), not just its first few thousand characters. Calls are counted too: 4 while
understanding a request, 14 while writing. A repair after heavy research goes in a fresh
session, given the request and the page as they stand, so it has room for both.

A result too long for its share is read apart, in a model session of its own
(`Dream/Generation/ResultReader.swift`): a reader with no tools and a whole 32K window for that
one result, which takes notes for the request (names, numbers, dates, ids and links exactly as
written, then what else is there to open) and ends. Only the notes, at most 3,000 characters,
come into the session writing the page. So a 20,000-character Notion page costs the writer
about 3,000, and the writer's window holds the brief, the notes and the page rather than every
page opened. At most three readers run at once; a reader that fails or takes longer than 45
seconds leaves the parts about the request instead (`Excerpt`). Web pages are fetched at up to
12,000 characters for a reader, instead of 4,000. Readers run on PCC, like the writer, so
nothing goes anywhere new.

## Pages carry on

A page is made by `PageMaker`, not by its screen. Going back to the shelf or opening another page
doesn't stop it, and it shows on the shelf as a live tile in its stage's light. Leaving the app
hands the work to iOS as a continued-processing task (`BGContinuedProcessingTask`), which shows
progress on the Lock Screen and in the Dynamic Island.

## What the server still does

Dream's Cloudflare Worker no longer touches models on this branch's app. It keeps accounts (Sign
in with Apple, optional now: pages are made without one), sync between devices, shared links, web
search and reading (Parallel). The Worker's old model routes (`/api/model`, `/api/compose`,
`/api/route`) and its WeatherKit token, which served pages made on the server, are unused by
this app. The weather comes from the WeatherKit framework on the iPhone
(`Dream/Generation/LiveWeather.swift`), with the Apple Weather mark and legal link wherever it's
shown.

## Building

- PCC needs the managed entitlement `com.apple.developer.private-cloud-compute`, set in
  `Dream/Dream.entitlements` and enabled for the App ID in the developer portal.
- Asking PCC anything without the entitlement stops the app. A build signed without it sets
  `DREAM_PRIVATE_CLOUD = NO`, and then never touches PCC.
- The Mac bench, `Tools/bench.sh -provider onDevice "a request"`, runs the whole harness on this
  Mac's on-device model. PCC needs a signed app, so PCC pages are checked on the iPhone.
- Under the hood (testing builds) shows both models' status, and can switch the model and PCC's
  reasoning level (light, moderate, deep).
