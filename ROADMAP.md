# Dream roadmap

Features planned on 2026-10-26, to be built in parallel by several agents from 2026-10-27.
Each workstream below says what it owns, what it depends on, and how to check it works.

## Status (2026-10-27)

All ten workstreams are merged into `main` and run on the iPhone:
- **Wave 1:** memory and questions, lists, speech, language and units, figures and diagrams, sounds.
- **Wave 2:** live data and actions, the MCP client with live sources and action buttons, sharing on Cloudflare, 3D.
- **Also merged:** the asking gap check.

Open items:
- **Not yet tried by hand:** a full MCP sign-in (Linear or Notion), and universal links. Universal links need Settings › Developer › Associated Domains Development.
- **Web viewer:** figures and tones are placeholders, and there's no live calculation.
- **Picture share:** always uses the page's original language.
- **Totals:** totals over list entries can't filter by date yet, so "this month" isn't possible.
- **Not built:** NASA models and AR placement.
- **Asking check:** takes 13–21 s before trip questions appear.

## Principles every workstream follows

- **The model writes structure; the engine draws it.** The engine also checks the structure and ties it to live values. New capabilities are new parts of the surface format (`Dream/Engine/Surface.swift`, `Dream/Generation/Wire.swift`). Each one also needs checker rules (`Checker.swift`), a renderer (`Dream/UI/`) and prompt rules (`Prompts.swift`). They are never one-off prompt patches.
- **Independent of the model.** A cloud model (Grok, or Apple's Private Cloud Compute once granted) builds every screen in one pass, through Foundation Models. Nothing may depend on Grok specifically. Apple's on-device model never builds screens. It's a helper for small private jobs, like the home ideas, picking memory facts, and turning "add milk" into list entries.
- **Facts are never controls.** Inputs have roles: adjustable, given, variable, and soon live. Real figures go in facts, stat or data blocks.
- **The template stays separate from your data.** A surface is a shareable template. Your values, records and memory stay private, on the phone.
- **Show, don't tell.** Distinctive but restrained visuals, using the surface's palette, and motion only to show a change.
- **Model output is untrusted.** Tool output, MCP results and shared screens are treated as data, never instructions. Writes happen only when the user taps.

## Done before splitting up (2026-10-27)

1. **Git.** The project is a repository on `main`. Each agent works in its own worktree and branch.
2. **Checking tools** (in `Tools/`):
   - `Tools/bench.sh "request"`: the composer on this Mac, on Grok.
   - `Tools/bench-many.sh outdir "request" …`: several requests in parallel, one file each.
   - Build the app for the iPhone (compile check):
     - `xcodebuild -project Dream.xcodeproj -scheme Dream -destination 'id=00008150-000E4D423A82401C' -derivedDataPath <your own folder> -allowProvisioningUpdates build`
     - Install with `xcrun devicectl device install app --device 00008150-000E4D423A82401C <Dream.app>`
   - `Tools/device-tour.sh outdir "request"`: runs one request on the iPhone and screenshots the whole page.
   - There's one iPhone, and only the integrator uses it. Never use the Simulator. Never print the xAI key.
3. **Foundation pass:**
   - The on-device step-by-step builder is gone. There's now one path: `Composer.write` in a single session, with the checker sending problems back.
   - Hooks so features don't edit the same lines:
     - **Rules:** each feature's rules go in its own `Generation/Prompts+<Feature>.swift` (`memoryRules`, `listRules`, `languageRules`, `figureRules`, `soundRules`). `Prompts.surface` gathers them.
     - **Context:** text the model gets alongside each request comes from `Prompts.memoryContext(for:)` and `Prompts.languageContext()`, gathered by `Prompts.context(for:)`.
     - **Tools:** model tools go in `Composer.tools(found:)`. The ask tool goes there.
   - **Where new content lives:** content a new block needs (a collection, a figure's shapes, a sound) is a named definition at the top level of the surface. Blocks point to it with `ref`, the way controls point to inputs. Each feature adds one optional array to `Surface`, decoded with a default so older surfaces still load, and one array to `WireSurface`. It does not add fields to `WireBlock`.

## Workstreams

Sizes: S is up to half a day, M about a day, L more than a day.

### Wave 1: can run in parallel right after the foundation

**1. User memory and questions (M)**
- Memory facts on the phone: what you said, what you answered, what Dream inferred. Each records its source and date.
- A "What Dream knows" screen to see, edit and delete facts. Inferred facts are confirmed before use.
- Relevant facts are picked per request with on-device NaturalLanguage embeddings, and only those go into the prompt.
- Screen memory: a request that matches a saved surface (by intent or question) opens it instead of rebuilding.
- An `ask` tool: up to 3 questions, one round, tappable options plus "You choose". It is never used for what a control or a lookup can handle.
  - The cards show while the page forms, with a calm Aura "waiting for you" state.
  - Answers fold into the header as tags. Tapping a tag rebuilds the page.
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
- Talking to a list: "add milk and eggs" or a receipt photo makes the model return insert, update and delete operations, checked against the fields. Try the on-device model for this, since it's private and free. Use the cloud model when it isn't good enough.
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
- Needs: WeatherKit enabled for `xyz.onlychan.Dream`, which requires a paid membership, plus the Apple Weather attribution on screen.

**8. MCP client (M)** (depends on 7)
- Uses the official MCP Swift SDK, with remote HTTP servers only.
- Each MCP tool becomes a Foundation Models `Tool` whose schema is built at runtime from its JSON Schema. Arguments arrive as `GeneratedContent`.
- Only the few tools relevant to each request are offered.
- Read tools become live sources. Write tools become `action` buttons, with MCP's read-only and destructive hints deciding which need a confirmation.
- A collection can be backed by an MCP server.
- Sign-in uses OAuth with ASWebAuthenticationSession, and tokens go in the Keychain. A "Connections" screen adds servers.
- Which memory facts may go to which server is explicit.

**9. Sharing (M–L)** (on Cloudflare)
- What gets shared is a surface, not a chat. Blank by default; your numbers only when you choose.
- Strip `Surface.answers` before sharing: personal answers (city, diet, household) are stored on the surface.
- Three levels:
  1. An image, via `ImageRenderer`.
  2. A link that opens in Dream: surfaces stored on Cloudflare (a Worker, with R2, D1 or KV).
  3. A web viewer for people without Dream, served by the same Worker.
- Shared lists (a family grocery list) sync through the same backend. Durable Objects could handle live editing.
- Shared surfaces form the start of the cross-user template library from the memory layer.
- Later: Dream as a remote MCP server on Cloudflare Workers, so other assistants can read your lists.

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
| `Engine/Surface.swift`, `Generation/Wire.swift` | new block kinds and top-level arrays | each workstream adds its own lines; the integrator merges the small conflicts |
| `Generation/Prompts.swift` | rule text, request context | done: one `Prompts+<Feature>.swift` per feature |
| `Engine/Checker.swift` | one `switch` over block kinds | each kind's case calls a function in that feature's own file |
| `UI/BlockView.swift` | one `switch` over block kinds | each kind renders from its own file in `UI/Blocks/` |
| `Generation/Composer.swift` | tools (ask, sources, MCP) | done: `tools(found:)` |
| `Dream.xcodeproj/project.pbxproj` | packages, capabilities | one agent at a time; folder sync means new files need no project edits |

## Decisions (2026-10-27)

- **On-device model:** removed as a page builder, kept as a helper for small private jobs.
- **Developer membership:** paid, so WeatherKit is available. Enable it for `xyz.onlychan.Dream` when workstream 7 starts.
- **Sharing backend:** Cloudflare (Workers with R2, D1 or KV). The same backend later serves the web viewer and Dream's MCP server. It needs the user's Cloudflare account and `wrangler login`.
- **Agents:** all six first-wave workstreams in parallel, each in its own worktree. Keep Grok use modest: about 15 bench requests per agent per round, unless the user says otherwise.

## Loose ends from 2026-10-26

- Not yet tried by hand: the chart's fading trace of the old curve and the drag readouts.
- Inline maths makes some lines taller than others in paragraphs.
- Confirm the finished page now stays at the top (`SurfaceScreen` scrolls to the top when done).
