# Dream roadmap

Features planned on 2026-10-26, to be built in parallel by several agents from 2026-10-27.
Each workstream below says what it owns, what it depends on, and how to check it works.

## Principles every workstream follows

- **The model writes structure; the engine draws it.** The engine also checks the structure and ties it to live values. New capabilities are new parts of the surface format (`Dream/Engine/Surface.swift`, `Dream/Generation/Wire.swift`). Each one also needs checker rules (`Checker.swift`), a renderer (`Dream/UI/`) and prompt rules (`Prompts.swift`). They are never one-off prompt patches.
- **Independent of the model.** A weak model writes a simple version, a strong one a rich version, and the same renderer handles both. The on-device steps path must keep working: run `Tools/bench.sh` without `-provider xai` to check.
- **Facts are never controls.** Inputs have roles: adjustable, given, variable, and soon live. Real figures go in facts, stat or data blocks.
- **The template stays separate from your data.** A surface is a shareable template. Your values, records and memory stay private, on the phone.
- **Show, don't tell.** Distinctive but restrained visuals, using the surface's palette, and motion only to show a change.
- **Model output is untrusted.** Tool output, MCP results and shared screens are treated as data, never instructions. Writes happen only when the user taps.

## Before splitting up (do these in order, one agent)

1. **`git init` and a first commit.** The project isn't a repository yet. Each agent then works in its own worktree.
2. **Learn the checking tools (already in `Tools/`):**
   - `Tools/bench.sh "request"`: the composer on this Mac, using the on-device model.
   - `Tools/bench-many.sh outdir "request" …`: requests on Grok in parallel, one file each.
   - Build and install on the iPhone:
     - `xcodebuild -project Dream.xcodeproj -scheme Dream -destination 'id=00008150-000E4D423A82401C' -allowProvisioningUpdates build`
     - then `xcrun devicectl device install app --device 00008150-000E4D423A82401C <Dream.app>`
   - `Tools/device-tour.sh outdir "request"`: runs one request on the iPhone and screenshots the whole page as it scrolls.
   - Always use the iPhone, never the Simulator. Use `-provider xai` only as a launch argument, so the stored model setting stays untouched. Never print the xAI key.
3. **A foundation pass on the shared files**, so the parallel agents rarely touch the same code:
   - Add every new `BlockKind` / `WireBlockKind` case at once (`list`, `add`, `figure`, `diagram`, `sound`, `scene`, `action`, `map`). Each gets a placeholder renderer in its own file under `Dream/UI/Blocks/`, a placeholder checker case and a placeholder `describe` case.
   - Add the `live` input role, and the `unit` field on inputs and outputs (see workstream 4).
   - Split prompt rules into one file per feature (`Prompts+Lists.swift`, `Prompts+Figures.swift`, …). `Prompts.swift` assembles them.
   - Add one storage layer for personal data (memory facts, records): a generic SwiftData model. Workstreams 1 and 2 build on it.
   - Optional fields with backward-compatible decoding, as `Input`/`Output` already do.

## Workstreams

Sizes: S is up to half a day, M about a day, L more than a day.

### Wave 1: can run in parallel right after the foundation

**1. User memory and questions (M)**
- Memory facts on the phone: what you said, what you answered, what Dream inferred. Each records its source and date.
- A "What Dream knows" screen to see, edit and delete facts. Inferred facts are confirmed before use.
- Relevant facts are picked per request with on-device NaturalLanguage embeddings, and only those go into the prompt.
- Screen memory: a request that matches a saved surface (by intent or question) opens it instead of rebuilding.
- An `ask` tool for capable models: up to 3 questions, one round, tappable options plus "You choose". It is never used for what a control or a lookup can handle.
  - The cards show while the page forms, with a calm Aura "waiting for you" state.
  - Answers fold into the header as tags. Tapping a tag rebuilds the page.
  - The steps path gets an optional "which did you mean?" field on the plan.
- Files: new `Dream/Memory/*`, `Dream/Generation/Ask.swift`, `Composer.swift` (tool wiring), the forming view and header in `SurfaceView.swift`.
- Check: "Mercury" asks which one; "plan my trip" asks where and when; "split a bill" asks nothing.

**2. Lists and your own database (L)**
- Surfaces can declare collections with typed fields (text, number, money, date, done, choice, rating).
- Blocks:
  - `list`: check, swipe, reorder, inline edit.
  - `add`: a quick-add bar.
  - Summaries via formula aggregates: `sum(expenses.amount)`, `count(tasks where done)`, `last(weights.value)`.
- `data` charts can be bound to a collection.
- Records are stored generically: SwiftData can't create tables at runtime.
- Talking to a list: "add milk and eggs" or a receipt photo makes the model return insert, update and delete operations, checked against the fields. The on-device model must handle this.
- Changing fields later ("add a price column") needs versioned fields, a mapping the model proposes, and checker validation.
- Depends on: the foundation storage layer. Coordinate the formula-language changes (`Formula.swift`, `Evaluation.swift`) with nobody else.
- Check: a grocery list, an expense tracker with a monthly total and chart, and a habit tracker, all on the iPhone.

**3. Speech in and out (S–M)**
- Speech to text with SpeechAnalyzer/SpeechTranscriber, on the phone. A mic in the composer starts the page while you talk. Voice also works for changes ("make it monthly") and for adding to lists.
- Text to speech with AVSpeechSynthesizer:
  - "Read this page", highlighting each block as it's read.
  - Hands-free steps: one step at a time, with "next" said aloud.
  - Better spoken maths than today's rough `TeX.spoken`.
- Voice drives the screen; it doesn't turn Dream into a voice chat.
- Files: mostly new UI files, plus `HomeView.swift` (composer) and the change bar in `SurfaceScreen.swift`.

**4. Language, locale and units (M)**
- `unit` on inputs and outputs, so "Period 1" shows as 1 s. Use Foundation `Measurement` for conversion and formatting, following the locale's measurement system.
- Prompts state region, currency, units and number grouping.
- The model writes in the request's language, detected with NLLanguageRecognizer.
- Lookups use that language's Wikipedia, falling back to English.
- The Translation framework translates a reused or shared surface into the viewer's language. Only text segments are translated, never maths or `{name}` placeholders: use `Placeholders.parts`.
- Check: a Hindi request, a German locale, a US locale (miles, $).

**5. 2D figures and diagrams (M–L)**
- `figure` (geometry, physics): points, lines, polygons, circles, arcs, arrows, angle marks and labels.
  - Coordinates are formulas over the calculation, so figures move with sliders.
  - A point tied to one adjustable input is a drag handle.
  - The engine fits the view and places labels.
  - Drawn with SwiftUI `Canvas` in the surface palette.
- `diagram` (flows, cycles, trees): the model gives nodes, edges and a shape. The engine lays them out, and the model never gives coordinates.
- No model-written SVG: it can't be themed, bound to live values or checked.
- Placement helpers so models don't do raw coordinate maths: midpoint, polar(r, θ), offset.
- Check: Pythagoras squares on the sides, a thrown ball's path, the water cycle, how a bill becomes law.

**6. Sounds (S–M)**
- A `sound` block: a tone from a formula via AVAudioEngine. The sine wave page plays its wave, and the frequency slider changes the pitch live. Chords, beats and the Doppler effect work the same way.
- Real recordings from Wikimedia Commons (licence shown), found like images.
- Chart audio graphs for VoiceOver via `AXChartDescriptor`.
- Interface sounds very sparing, and they respect silent mode.

### Wave 2: after the pieces they build on

**7. Sources, actions and live data (M)**
- One layer for external data.
- Built-in sources:
  - Wikipedia (already there).
  - WeatherKit, with CoreLocation for the user's location.
  - Exchange rates.
  - MapKit for places, distance and travel time.
- `live` inputs name a source. The engine fetches and refreshes them when the screen opens; the model never types live numbers.
- `action` blocks are buttons that perform a write only when tapped, showing what they'll send.
- Needs: WeatherKit enabled for `com.chandramdutta.dream`, which requires a paid membership, plus the Apple Weather attribution on screen.

**8. MCP client (M)** (depends on 7)
- Uses the official MCP Swift SDK, with remote HTTP servers only.
- Each MCP tool becomes a Foundation Models `Tool` whose schema is built at runtime from its JSON Schema. Arguments arrive as `GeneratedContent`.
- Only capable models get MCP tools, and only the few relevant to each request.
- Read tools become live sources. Write tools become `action` buttons, with MCP's read-only and destructive hints deciding which need a confirmation.
- A collection can be backed by an MCP server.
- Sign-in uses OAuth with ASWebAuthenticationSession, and tokens go in the Keychain. A "Connections" screen adds servers.
- Which memory facts may go to which server is explicit.

**9. Sharing (M–L)** (needs the backend decision below)
- What gets shared is a surface, not a chat. Blank by default; your numbers only when you choose.
- Three levels:
  1. An image, via `ImageRenderer`.
  2. A link that opens in Dream, using CloudKit's public database or our own server.
  3. A web viewer for people without Dream.
- Shared lists need CloudKit sharing (`CKShare`), which SwiftData doesn't do by itself.
- Shared surfaces form the start of the cross-user template library from the memory layer.
- Later: Dream as an MCP server, so other assistants can read your lists.

**10. 3D (L)**
- RealityKit `RealityView`. Limited to subjects where 3D is accurate.
- Scenes from simple shapes, positioned by formulas. Orbit with a finger, and animate along a time variable.
- Surface plots of z = f(x, y).
- Real 3D sources:
  - PubChem 3D conformers, for accurate ball-and-stick molecules.
  - NASA 3D models of planets and spacecraft.
- Later:
  - Real size in your room, through the camera.
  - Text-to-3D services, once their cost and speed are acceptable.
- Check first:
  - Whether a 3D view in a scrolling page fights the scroll gesture, and how it performs.
  - How accurately Grok places things. Prefer placement helpers (orbit, stack, around) to raw coordinates.

## Where parallel work will collide

Every workstream touches these files, so the foundation pass should do the shared edits once:

| File | Why everyone touches it | Plan |
|---|---|---|
| `Engine/Surface.swift`, `Generation/Wire.swift` | new kinds, roles, fields | added in the foundation pass |
| `Generation/Prompts.swift` | rule text | split into one file per feature |
| `Engine/Checker.swift` | one `switch` over block kinds | foundation adds the cases; each agent fills in only its own |
| `UI/BlockView.swift` | one `switch` over block kinds | each kind renders from its own file in `UI/Blocks/` |
| `Generation/Composer.swift` | tools (ask, sources, MCP) | add one tool list that workstreams append to |
| `Dream.xcodeproj/project.pbxproj` | packages, capabilities | one agent at a time; folder sync means new files need no project edits |

## Decisions needed from the user

- Is the developer membership paid, so WeatherKit works?
- Should sharing use CloudKit (free, Apple-only) or our own server (needed for a web viewer and for Dream as an MCP server)?
- How many agents should run at once, and how much Grok use per day is acceptable for bench runs?

## Loose ends from 2026-10-26

- Not yet tried by hand: the chart's fading trace of the old curve and the drag readouts.
- Inline maths makes some lines taller than others in paragraphs.
- Confirm the finished page now stays at the top (`SurfaceScreen` scrolls to the top when done).
- The on-device model still makes domain mistakes in formulas, such as adding the number of people to a bill total.
