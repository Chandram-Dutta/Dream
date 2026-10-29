// Checks the page loop on the server (src/compose/) in Node, with a fake model whose streams are
// scripted (tool calls, partial answers, stalls, a hang that only sends heartbeats, a repair that
// breaks), a fake engine and fake tools, so nothing is paid for: the loop, the job's event log
// and catching up from a seq, the questions' wait and its timeout, a restart, and the exact
// shape of the page it keeps in sync. Timings are shortened; the ratios are the app's.
//
//   node test/compose.mjs
//
// The compose files import each other without extensions, as the Worker's bundler takes them, so
// a resolve hook finds the .ts file.

import { registerHooks } from "node:module";
import { readFileSync } from "node:fs";

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (/^\.\.?\//.test(specifier) && !/\.(ts|mjs|js|json)$/.test(specifier)) {
      try {
        return nextResolve(`${specifier}.ts`, context);
      } catch {
        // Not a TypeScript file.
      }
    }
    return nextResolve(specifier, context);
  },
});

const { PageLoop, TIMING, questionFrom } = await import("../src/compose/loop.ts");
const { Runner, memoryStore, pageShape } = await import("../src/compose/runner.ts");
const { readPartial, partialObject, fitted } = await import("../src/compose/partial.ts");
const { answersContext, repairPrompt, surfaceRequest, surfaceInstructions, gapRequest, writing, editPrompt, describeBlock, changedAnswer, memoryContext, isMemoryLine } = await import("../src/compose/prompts.ts");
const { Padding, readRound, Activity, ModelProblem, requestBody } = await import("../src/compose/chat.ts");
const { citationKey, fenced, toolBox, ReferenceLog, WebLog, ServiceLog } = await import("../src/compose/tools.ts");
const { surfaceItem, surfacePayload, changedItem, keptValues } = await import("../src/compose/payload.ts");
const { readComposeRequest } = await import("../src/compose/request.ts");
const { fakeModel } = await import("../src/compose/fake.ts");
const { find, wikipedia } = await import("../src/compose/lookup.ts");
const { Memory, confirmedFacts, recallKey } = await import("../src/compose/memory.ts");
const { LiveLog, liveCall, liveDay, today, forgetLiveReadings } = await import("../src/compose/live.ts");
const { findRecording, findMolecule, structureOf, cleaned, forgetMolecules } = await import("../src/compose/media.ts");
const realEngine = await import("../src/engine/index.ts");

const generation = JSON.parse(readFileSync(new URL("../src/generated/generation.json", import.meta.url), "utf8"));

let failures = 0;
function expect(condition, message) {
  console.log(`${condition ? "  ok  " : "  FAIL"}  ${message}`);
  if (!condition) failures++;
}

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// MARK: - Fakes

/** The app's timings, scaled down: the stall rules keep their ratio. */
const FAST = { ...TIMING, patience: 400, ceiling: 1_000, watch: 20, gapPatience: 3_000, hold: 150, surfaceEvery: 50, partialEvery: 30, runawayEvery: 40, retries: [20, 40, 60] };

const chunk = (delta, finish = null) => `data: ${JSON.stringify({ id: "x", object: "chat.completion.chunk", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;

/** A scripted answer: `steps` are deltas to send, `{ wait }` pauses, `{ beat }` a heartbeat,
 * `{ hang: true }` waits until it's cancelled. `seen` records whether it was cancelled. */
function stream(steps, seen = {}) {
  const encoder = new TextEncoder();
  let stopped = false;
  return new Response(
    new ReadableStream({
      async start(controller) {
        const send = (text) => !stopped && controller.enqueue(encoder.encode(text));
        send(chunk({ role: "assistant" }));
        for (const step of steps) {
          if (stopped) return;
          if (step.wait) await pause(step.wait);
          else if (step.beat) send(": thinking\n\n");
          else if (step.hang) {
            while (!stopped) await pause(10);
            return;
          } else if (step.finish) send(chunk({}, step.finish));
          else send(chunk(step));
          await pause(step.gap ?? 4);
        }
        if (stopped) return;
        send(`data: ${JSON.stringify({ choices: [], usage: { prompt_tokens: 10, completion_tokens: 10 } })}\n\n`);
        send("data: [DONE]\n\n");
        controller.close();
      },
      cancel() {
        stopped = true;
        seen.cancelled = true;
      },
    }),
    { status: 200, headers: { "Content-Type": "text/event-stream" } },
  );
}

/** Text in pieces, as a model streams it. */
const pieces = (text, size = 30, gap = 4) => {
  const out = [];
  for (let at = 0; at < text.length; at += size) out.push({ content: text.slice(at, at + size), gap });
  return out;
};

const block = (kind, fields = {}) => ({ kind, title: "", text: "", ref: "", over: "", items: [], children: [], ...fields });
const page = (overrides = {}) => ({
  subject: "learning",
  mode: "read",
  title: "Mercury",
  summary: "The smallest planet.",
  symbol: "sparkles",
  collections: [],
  question: "",
  inputs: [],
  outputs: [],
  sounds: [],
  figures: [],
  diagrams: [],
  actions: [],
  scenes: [],
  blocks: [block("paragraph", { text: "Mercury is the closest planet to the Sun." }), block("facts", { title: "Facts", items: [{ label: "Moons", value: "0" }] })],
  related: ["Venus", "The Sun", "Orbits"],
  citations: [],
  ...overrides,
});

const isGaps = (body) => body.response_format?.json_schema?.schema?.title === "WireGaps";
const lastUser = (body) => [...body.messages].reverse().find((message) => message.role === "user");
const textOf = (content) => (typeof content === "string" ? content : content.map((part) => part.text ?? "").join("\n"));

/** A fake model: `gaps` answers the gap check, `write` each writing request, by how many came before. */
function fakeModelOf({ gaps = () => stream(pieces(JSON.stringify({ questions: [] }))), write }) {
  const calls = { gaps: [], write: [] };
  return {
    calls,
    async model(body) {
      const clone = JSON.parse(JSON.stringify(body));
      if (isGaps(body)) {
        calls.gaps.push(clone);
        return gaps(calls.gaps.length - 1, clone);
      }
      calls.write.push(clone);
      return write(calls.write.length - 1, clone);
    },
  };
}

/** The engine's interface, with checks a test can set. */
function fakeEngine(logicIssues = () => []) {
  const surface = (wire, reference) => ({ title: "", summary: "", blocks: [], ...wire, ...(reference ? { reference } : {}) });
  return {
    surfaceFromWire: surface,
    surfaceFromPartial: surface,
    isEmpty: (s) => !s.title && !s.summary && s.blocks.length === 0,
    isRepeatingItself: (s) => (s.blocks ?? []).some((b) => typeof b.text === "string" && /(again ){12}/.test(b.text)),
    checkLogic: (s) => ({ surface: s, issues: logicIssues(s) }),
    checkSourcing: () => [],
    checkCitations: (s) => ({ surface: s, issues: [] }),
    checkBlocks: (s) => ({ surface: s, issues: [] }),
    outline: (s) => `${s.title}: ${s.summary}`,
    logicSummary: () => "Inputs:",
    hasLogic: (s) => (s.inputs?.length ?? 0) > 0 || (s.outputs?.length ?? 0) > 0,
    label: (s, name) => s.inputs?.find((input) => input.name === name)?.label ?? name,
    recordingSearches: realEngine.recordingSearches,
    addRecordings: realEngine.addRecordings,
    moleculeNames: realEngine.moleculeNames,
    addMolecules: realEngine.addMolecules,
  };
}

/** A stand-in for the network: each request goes to the first handler whose pattern its address
 * matches, and is noted. Anything else is a failure, so nothing reaches the real thing. */
function fakeFetch(routes = []) {
  const asked = [];
  const fetcher = async (url, init) => {
    asked.push(String(url));
    for (const [pattern, answer] of routes) {
      if (pattern.test(String(url))) return answer(new URL(String(url)), init);
    }
    throw new Error(`No stand-in for ${url}`);
  };
  fetcher.asked = asked;
  return fetcher;
}

const fakeTools = (overrides = {}) => ({
  calls: [],
  async lookup(subject, language) {
    this.calls.push(["lookup", subject, language]);
    return { title: "Mercury (planet)", extract: "Mercury is the first planet from the Sun.", url: "https://en.wikipedia.org/wiki/Mercury_(planet)" };
  },
  async related() {
    return ["Venus", "Mars", "Jupiter"];
  },
  async search(query) {
    this.calls.push(["search", query]);
    return { status: 200, body: { results: [{ title: "Mercury facts", url: "https://www.example.com/mercury", snippet: "A small planet.", site: "example.com", date: "2026-10-01" }] } };
  },
  async read(query) {
    this.calls.push(["read", query]);
    return { status: 200, body: { url: "https://m.example.com/mercury", canonical: "https://example.com/mercury", title: "Mercury", site: "Example", text: "Mercury has no moons.", excerpted: true, truncated: false } };
  },
  async memory() {
    return [];
  },
  fetch: fakeFetch(),
  here: null,
  ...overrides,
});

/** A tool session as the loop makes one, with what a test sets. */
const toolSession = (overrides = {}) => ({
  found: new ReferenceLog(),
  web: new WebLog(),
  live: new LiveLog(),
  memory: new Memory(async () => []),
  services: new ServiceLog(),
  language: "en",
  reader: { language: "en", region: "IN", currency: "INR", measurementSystem: "metric" },
  device: null,
  now: Date.now,
  ...overrides,
});
const silent = { trace() {}, use() {}, note() {} };

const REQUEST = { request: "tell me about mercury", locale: { language: "en", region: "IN", currency: "INR", measurementSystem: "metric" }, context: ["Now it's Wednesday, 28 October 2026, 9:00 PM, where the user is."], pageID: "6F9619FF-8B86-D011-B42D-00C04FC964FF" };
const PICK = { model: "grok-4.7", effort: "low", name: "Grok 4.7", category: "other", difficulty: "easy", why: "Dream's default" };

function services(model, { engine = fakeEngine(), tools = fakeTools(), route = async () => PICK } = {}) {
  return {
    engine,
    generation,
    model: model.model,
    route,
    tools,
    now: Date.now,
    sleep: (ms) => pause(ms),
  };
}

function recorder() {
  const events = [];
  const at = Date.now();
  return {
    events,
    picks: [],
    sink: {
      phase: (phase) => events.push({ type: "phase", phase, at: Date.now() - at }),
      trace: (kind, text) => events.push({ type: "trace", kind, text, at: Date.now() - at }),
      surface: (surface) => events.push({ type: "surface", surface, at: Date.now() - at }),
      log: (line) => events.push({ type: "log", line, at: Date.now() - at }),
      picked(pick) {
        this.picks?.push(pick);
      },
    },
    lines: () => events.filter((event) => event.type === "log").map((event) => event.line),
  };
}

const startFresh = () => ({ pick: null, answers: null, checkedAt: null, startedAt: Date.now(), first: true });

async function runLoop(model, options = {}, start = startFresh(), request = REQUEST) {
  const record = recorder();
  const controller = new AbortController();
  const loop = new PageLoop(request, services(model, options), record.sink, controller.signal, options.timing ?? FAST);
  const outcome = await loop.run(start);
  return { outcome, ...record };
}

// MARK: - Partial JSON

console.log("Partial answers");
{
  const whole = JSON.stringify(page());
  let ok = true;
  let last = null;
  for (let at = 1; at <= whole.length; at++) {
    const read = readPartial(whole.slice(0, at));
    if (at > 1 && !read) ok = false;
    if (read) last = read;
  }
  expect(ok, "every prefix of a page reads as something");
  expect(last?.complete && JSON.stringify(last.value) === whole, "the whole answer reads as itself");
  expect(JSON.stringify(readPartial('{"title":"Merc')?.value) === '{"title":"Merc"}', "a string counts as far as it's written");
  expect(JSON.stringify(readPartial('{"title":"Mercury","sum')?.value) === '{"title":"Mercury"}', "a name with no value yet is left out");
  expect(JSON.stringify(readPartial('{"a":12.')?.value) === '{"a":12}' && JSON.stringify(readPartial('{"a":tr')?.value) === "{}", "a number counts as far as it reads; true only once it's whole");
  expect(JSON.stringify(readPartial('{"a":"x\\')?.value) === '{"a":"x"}' && JSON.stringify(readPartial('{"a":"\\u00e')?.value) === '{"a":""}', "an escape cut off waits for the rest");
  expect(readPartial('{"a":"\\ud83d\\ude00"}')?.value.a === "😀" && readPartial("nope") === null, "surrogate pairs join; what isn't JSON isn't read");
  const held = partialObject('{"subject":"mon","blocks":[{"kind":"hea","text":"x"},{"kind":"hero","ref":"total"', generation.schemas.surface);
  expect(!("subject" in held) && held.blocks.length === 2 && !("kind" in held.blocks[0]) && held.blocks[1].kind === "hero", "an enum that isn't one of its cases yet is left out, as the app's decoding leaves it");
  expect(JSON.stringify(fitted({ blocks: [{ kind: "paragraph", items: "no" }] }, generation.schemas.surface)) === '{"blocks":[{"kind":"paragraph"}]}', "a value of the wrong type goes too");
}

// MARK: - Prompts, from the app's own words

console.log("Prompts from generation.json");
{
  expect(surfaceInstructions(generation, "INR").includes("in INR") && !surfaceInstructions(generation, "INR").includes("{{currency}}"), "the instructions are in the user's currency");
  expect(gapRequest(generation, "split {{context}}") === "Request: split {{context}}", "a request that looks like a slot stays as written");
  expect(surfaceRequest(generation, "a bill", false, []) === "Request: a bill", "a request alone");
  expect(surfaceRequest(generation, "a bill", true, ["one", "two"]) === `Request: a bill\n\n${generation.templates.surfaceRequest.withPhoto.split("\n\n")[1]}\n\none\ntwo`, "with a photo, then the context a line each");
  const asked = { text: "Which Mercury?", topic: "Subject", options: ["The planet"], allowsTyping: false, isPersonal: false };
  expect(
    answersContext(generation, [{ question: asked, choice: "The planet", isRemembered: false }, { question: asked, choice: "", isRemembered: false }])[0] ===
      "Before building, the user answered:\n- Which Mercury? The planet\n- Which Mercury? You choose: pick what's most likely.\nBuild the screen for these answers.",
    "the answers as Prompts.answersContext writes them",
  );
  expect(repairPrompt(generation, ["a", "b"]) === "That screen has problems:\n- a\n- b\n\nReturn the whole screen again with these problems fixed. Keep everything else the same.", "a repair in the same session");
  const restated = repairPrompt(generation, ["a"], { asked: "Request: x", outline: "T: s", logic: "Inputs:" });
  expect(restated.startsWith("Request: x\n\nYou began this screen") && restated.includes("\nInputs:\nScreen:\nT: s\n\nIt has problems:\n- a\n"), "a repair that restates the request and the page, its calculation first");
}

// MARK: - Chat completions

console.log("Chat completions");
{
  const body = requestBody([{ role: "user", content: "hi" }], { model: "grok-4.7", effort: "low", thinking: "medium", schema: { type: "object" }, temperature: 0.2, maximumResponseTokens: 600, tools: generation.tools.slice(0, 1) });
  expect(body.stream === true && body.max_tokens === 600 + 8_000 && body.response_format.json_schema.strict === true && body.response_format.json_schema.name === "response" && body.tools[0].type === "function", "the request as ChatCompletions.body writes it, thinking room on top");
  const padding = new Padding();
  expect(padding.read("{") === null && padding.read(" ".repeat(400)) === "400 blank characters in a row", "padding: hundreds of blanks");
  expect(new Padding().read('{"pi":"' + "1".repeat(60) + '"}') === null && new Padding().read("1".repeat(40))?.startsWith("a number"), "digits in a string are fine, in a number they're padding");
  const problem = new ModelProblem(503, { error: "busy" }, "20");
  const allowance = new ModelProblem(402, { error: "You've made today's 5 free pages.", reason: "allowance" }, null);
  expect(problem.transient && problem.message === "busy" && !allowance.transient && allowance.allowance, "busy is worth asking again; a used-up allowance isn't");
  const activity = new Activity(0);
  const round = await readRound(stream([{ reasoning_content: "hmm" }, { beat: true }, { content: '{"a":' }, { tool_calls: [{ index: 0, id: "c1", type: "function", function: { name: "lookup", arguments: '{"subject":' } }] }, { tool_calls: [{ index: 0, function: { arguments: '"x"}' } }] }]).body, activity, Date.now, () => undefined, new AbortController().signal);
  let released = false;
  const open = new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode(`${chunk({ content: "{}" })}data: ${JSON.stringify({ choices: [], usage: { prompt_tokens: 1 } })}\n\ndata: [DONE]\n\n`));
    },
    cancel() {
      released = true;
    },
  });
  await readRound(open, new Activity(0), Date.now, () => undefined, new AbortController().signal);
  expect(released, "after [DONE] the stream is let go, so model.ts's meter counts what it used");
  expect(round.text === '{"a":' && round.toolCalls.length === 1 && round.toolCalls[0].arguments === '{"subject":"x"}' && activity.heard > 0, "a round's text, and a tool call put together from its pieces");
}

// MARK: - Tools

console.log("Tools");
{
  expect(citationKey("https://www.Example.com/a/?q=1#top") === "example.com/a?q=1" && citationKey("ftp://x") === null, "addresses compare however they're written");
  const fence = fenced("text\u0000 with ​ controls\nkept", "page");
  expect(/^<<<page [0-9a-z]+\ntext with  controls\nkept\npage [0-9a-z]+>>>$/.test(fence), "untrusted text goes between markers, without control characters");
  const traces = [];
  const uses = [];
  const tools = fakeTools();
  const found = new ReferenceLog();
  const web = new WebLog();
  const box = toolBox(generation, tools, { trace: (kind, text) => traces.push([kind, text]), use: (line) => uses.push(line), note() {} }, toolSession({ found, web }));
  expect(box.definitions.map((tool) => tool.name).join() === "lookup,recall,live,search,read", "lookup, recall, live, search and read are offered, in the app's order");
  const looked = await box.run("lookup", JSON.stringify({ subject: "Mercury", language: "xx-nonsense" }));
  expect(looked.startsWith('Wikipedia, "Mercury (planet)" (cite it as https://en.wikipedia.org/wiki/Mercury_(planet)):') && tools.calls[0][2] === "en", "lookup answers as LookupTool does, in the request's language when the model's isn't one");
  const searched = await box.run("search", JSON.stringify({ question: "q", keywords: "mercury planet", freshness: "week", country: "IN" }));
  expect(searched.startsWith('Search results for "mercury planet".') && tools.calls[1][1].region === "in" && tools.calls[1][1].freshness === "week" && uses.includes("Search: mercury planet, from the past week, region IN"), "search sends what WebService.search sends");
  const read = await box.run("read", JSON.stringify({ url: "https://www.example.com/mercury", focus: "moons" }));
  expect(read.startsWith("Read the page. Cite it as https://example.com/mercury") && read.includes('(The parts about "moons")'), "read answers as ReadTool does");
  expect((await box.run("read", JSON.stringify({ url: "https://example.com/mercury/", focus: "" }))) === generation.toolText.readAlready, "a page read already isn't read again");
  expect(traces.map(([kind]) => kind).join() === "lookup,search,read", "each step is traced as it starts");
  const reading = web.reading(found.all);
  expect(reading.length === 2 && reading[0].url === "https://example.com/mercury" && reading[0].addresses?.join() === "https://m.example.com/mercury" && reading[1].site === "Wikipedia", "what was read goes to the checker, under every address it was read at");
  const failing = toolBox(generation, fakeTools({ search: async () => ({ status: 402, body: { error: "no" } }) }), silent, toolSession({ found }));
  expect((await failing.run("search", "{}")).startsWith(generation.toolText.webErrors["402"]), "a refused search says why, in the app's words");
  for (let i = 0; i < 3; i++) await failing.run("search", "{}");
  expect((await failing.run("search", "{}")) === generation.toolText.searchEnough, "and after three, that's enough searching");
  expect((await box.run("nope", "{}")).includes("no tool") && (await box.run("lookup", "not json")).includes("weren't JSON"), "a call it can't decode is told so");
}

// MARK: - Instructions and tools that agree

console.log("Instructions with the tools they describe");
{
  const all = generation.tools;
  const named = (instructions, tools, services = []) => tools.every((tool) => services.includes(tool.name) || new RegExp(`(^|[^A-Za-z_])${tool.name}($|[^A-Za-z_])`).test(instructions));
  const whole = writing(generation, "INR", all);
  expect(whole.instructions === surfaceInstructions(generation, "INR") && whole.tools.map((tool) => tool.name).join() === "lookup,recall,live,search,read", "with every tool the app has, the instructions are the app's own, whole, and every tool is offered");
  const rules = (name) => generation.prompts.features.find((feature) => feature.name === name).rules;
  const noRecall = writing(generation, "INR", all.filter((tool) => tool.name !== "recall"));
  expect(!noRecall.instructions.includes(rules("memory")) && !/recall/.test(noRecall.instructions) && noRecall.instructions.includes(rules("lists")), "without recall, its rules go, and the rest stay");
  const noLive = writing(generation, "INR", all.filter((tool) => tool.name !== "live"));
  expect(!noLive.instructions.includes(rules("live")) && !noLive.tools.some((tool) => tool.name === "live"), "without live, its rules go");
  expect(!whole.instructions.includes(rules("connections")), "with no connected service, nothing about connected services");
  const notes = { name: "notes_search", description: "From Notes, a service the user connected.", parameters: { type: "object", properties: { query: { type: "string" } } } };
  const connected = writing(generation, "INR", [...all.slice(0, 3), notes, ...all.slice(3)], { connections: ["notes_search"], live: [] });
  expect(connected.instructions === generation.prompts.surfaceWithConnections.replaceAll("{{currency}}", "INR") && connected.tools.map((tool) => tool.name).join() === "lookup,recall,live,notes_search,search,read", "a connected service's tool brings the app's rules for connected services, where the app has them");
  const stray = writing(generation, "INR", [...all, { name: "teleport", description: "x", parameters: {} }]);
  expect(!stray.tools.some((tool) => tool.name === "teleport"), "a tool the instructions don't describe isn't offered");
  expect([whole, noRecall, noLive, stray].every((set) => named(set.instructions, set.tools)) && named(connected.instructions, connected.tools, ["notes_search"]), "every tool offered is one the instructions name");
}

console.log("Changes to a page, in the app's words");
{
  const asked = editPrompt(generation, { intent: "split a bill", outline: "Bill: s", logic: "Inputs:\n- people", instruction: "make it 4 people", pointing: null, context: ["line one", "line two"] });
  expect(asked === 'The user has this screen, made for "split a bill":\nInputs:\n- people\nScreen:\nBill: s\n\nAbout the whole screen, they say: "make it 4 people"\n\nReturn the whole updated screen. Keep what they didn\'t ask to change.\n\nline one\nline two', "a change as Prompts.edit writes it: the page, its calculation first, what they said, then the context");
  const plain = editPrompt(generation, { intent: "x", outline: "T: s", logic: null, instruction: "shorter", pointing: 'the paragraph block "Why" (#p1)', context: [] });
  expect(plain === 'The user has this screen, made for "x":\nT: s\n\nThey\'re pointing at the paragraph block "Why" (#p1) and say: "shorter"\n\nReturn the whole updated screen. Keep what they didn\'t ask to change.', "pointing at a block, with no context");
  const labels = {
    label: (name) => ({ people: "People", total: "Total", share: "Share", x: "x", groceries: "Groceries" })[name] ?? name,
    sound: (name) => (name === "loon" ? { label: "Loon call" } : undefined),
    action: (name) => (name === "plan" ? { kind: "calendarEvent", fields: { title: "", place: "Cubbon Park" } } : undefined),
  };
  const described = (kind, fields = {}) => describeBlock(generation, { id: "b1", kind, title: "", ref: "", over: "", ...fields }, labels);
  expect(described("slider", { ref: "people" }) === 'the slider for "People" (people, #b1)', "a control, by what it sets");
  expect(described("chart", { ref: "total, share", over: "x" }) === "the chart of Total and Share along x (#b1)", "a chart, by what it draws and along what");
  expect(described("list", { ref: "groceries" }) === "the list of groceries (groceries, #b1)" && described("add", { ref: "groceries" }) === "the bar for adding to groceries (groceries, #b1)", "a list in lower case");
  expect(described("section", { title: "Costs" }) === 'the section "Costs" (#b1)' && described("row") === "a row of results (#b1)", "a section by its heading, a row of results");
  expect(described("paragraph") === "the paragraph block (#b1)" && described("facts", { title: "Key facts" }) === 'the facts block "Key facts" (#b1)', "information, with its heading if it has one");
  expect(described("figure", { ref: "triangle", title: "Sides" }) === 'the figure "triangle", titled "Sides" (#b1)' && described("equation", { ref: "total" }) === 'the equation for "Total" (total, #b1)' && described("equation") === "the equation block (#b1)", "a figure, and an equation with and without what it works out");
  expect(described("sound", { ref: "loon" }) === 'the sound "Loon call" (loon, #b1)' && described("action", { ref: "plan" }) === 'the button for calendarEvent "Cubbon Park" (plan, #b1)' && described("action", { ref: "gone" }) === "the button for 'gone' (gone, #b1)", "a sound, and a button by what it does");
  expect(described("hologram") === null, "a kind the app doesn't know isn't described");
  const question = { text: "Which Mercury?", topic: "Subject", options: ["The planet", "The element"], allowsTyping: false, isPersonal: false };
  expect(changedAnswer(generation, { question, choice: "The planet", isRemembered: false }, "The element") === "I mean The element. (You asked Which Mercury? and I said The planet.) Rebuild the screen for that.", "a different answer, in the user's words");
  expect(changedAnswer(generation, { question, choice: "", isRemembered: false }, "") === "Choose for me instead. (You asked Which Mercury? and I left it to you.) Rebuild the screen for that.", "and from leaving it to Dream, to leaving it again");
  expect(memoryContext(generation, ["Home city", "Diet"])[0] === "Dream remembers these about the user: Home city, Diet." && memoryContext(generation, []).length === 0, "what Dream remembers, as topics");
  expect(gapRequest(generation, "plan a trip", ["Home city"]) === "Request: plan a trip\n\nDream remembers these about the user: Home city." && isMemoryLine(generation, "Dream remembers these about the user: Diet.") && !isMemoryLine(generation, REQUEST.context[0]), "and beside the gap check's request");
}

// MARK: - Memory

const FACTS = [
  { topic: "Home city", text: "Pune", source: "answered", confirmed: true, request: "", createdAt: "2026-10-01T10:00:00.000Z", updatedAt: "2026-10-20T10:00:00.000Z" },
  { topic: "Diet", text: "Vegetarian", source: "said", confirmed: true, request: "", createdAt: "2026-10-02T10:00:00.000Z", updatedAt: "2026-10-25T10:00:00.000Z" },
  { topic: "Job", text: "Teacher", source: "inferred", confirmed: false, request: "I teach maths", createdAt: "2026-10-28T10:00:00.000Z", updatedAt: "2026-10-28T10:00:00.000Z" },
  { topic: "home  City", text: "Mumbai", source: "said", confirmed: true, createdAt: "2026-09-01T10:00:00.000Z", updatedAt: "2026-09-01T10:00:00.000Z" },
  "not a fact",
];

console.log("What Dream remembers, from the account's synced facts");
{
  const memory = new Memory(async () => confirmedFacts(FACTS));
  expect((await memory.topics()).join("|") === "Diet|Home city", "confirmed topics only, most recent first, each once however it's written");
  expect((await memory.facts(["HOME CITY "])).map((fact) => fact.detail).join() === "Pune,Mumbai" && recallKey("  Home-City ") === "home city", "facts by topic, without case or extra spaces");
  const notes = [];
  const box = toolBox(generation, fakeTools(), { ...silent, note: (line) => notes.push(line) }, toolSession({ memory }));
  const recalled = await box.run("recall", JSON.stringify({ topics: ["Diet", "Pets"] }));
  expect(recalled === "What Dream remembers about the user:\n- Diet: Vegetarian" && notes.includes("Recalled: Diet, Pets (1 found)"), "recall answers as RecallTool does, and the log names the topics, never the details");
  expect((await box.run("recall", JSON.stringify({ topics: ["Pets"] }))) === generation.toolText.recall.nothing, "and when there's nothing, says so in the app's words");
  const broken = new Memory(async () => {
    throw new Error("D1 is down");
  });
  expect((await broken.topics()).length === 0, "a memory that can't be read is an empty one");
}

// MARK: - Live data

/** Open-Meteo as it answers: Mysuru for any place but Atlantis, and a forecast for the day asked. */
const openMeteo = () => [
  [/^https:\/\/geocoding-api\.open-meteo\.com\/v1\/search/, (url) =>
    url.searchParams.get("name") === "Atlantis"
      ? Response.json({ generationtime_ms: 0.2 })
      : Response.json({ results: [{ id: 1262321, name: "Mysuru", latitude: 12.29791, longitude: 76.63925, timezone: "Asia/Kolkata", country: "India", admin1: "Karnataka" }] })],
  [/^https:\/\/api\.open-meteo\.com\/v1\/forecast/, (url) => {
    const day = url.searchParams.get("start_date");
    const hours = Array.from({ length: 24 }, (_, hour) => `${day}T${String(hour).padStart(2, "0")}:00`);
    const rising = (from) => hours.map((_, hour) => from + hour);
    return Response.json({
      timezone: url.searchParams.get("timezone"),
      current: { time: `${day}T09:15`, temperature_2m: 24.6, apparent_temperature: 25.9, relative_humidity_2m: 78, wind_speed_10m: 9.4, uv_index: 3.4, cloud_cover: 64, weather_code: 3 },
      hourly: { time: hours, temperature_2m: rising(18), apparent_temperature: rising(19), precipitation_probability: rising(10), relative_humidity_2m: rising(50), wind_speed_10m: rising(5), uv_index: hours.map((_, hour) => hour / 2), cloud_cover: rising(20), weather_code: hours.map(() => 61) },
      daily: { time: [day], temperature_2m_max: [29.4], temperature_2m_min: [19.1], precipitation_probability_max: [70], precipitation_sum: [6.2], wind_speed_10m_max: [14.8], uv_index_max: [7.6], weather_code: [61] },
    });
  }],
];

/** ExchangeRate-API's open endpoint, last updated 29 October 2026 at midnight UTC. */
const erAPI = (answer = () => Response.json({ result: "success", base_code: "USD", time_last_update_unix: 1793232001, time_next_update_unix: 1793318401, rates: { USD: 1, INR: 88.0123456, EUR: 0.8612 } })) => [
  [/^https:\/\/open\.er-api\.com\/v6\/latest\//, answer],
];

const IN = { language: "en", region: "IN", currency: "INR", measurementSystem: "metric" };
const US = { language: "en", region: "US", currency: "USD", measurementSystem: "ussystem" };
const DAY = 86_400_000;
const liveArgs = (fields) => ({ name: "", kind: "weather", place: "", day: "", time: "", from: "", to: "", travel: "", ...fields });

async function live(fields, { fetcher = fakeFetch([...openMeteo(), ...erAPI()]), reader = IN, here = null, now = Date.now, log = new LiveLog() } = {}) {
  const notes = [];
  const output = await liveCall(generation, liveArgs(fields), log, { fetch: fetcher, now, here, reader }, (line) => notes.push(line));
  return { output, sources: log.sources, notes, fetcher };
}

console.log("Live data: the weather, as WeatherKit's reading gives it");
{
  forgetLiveReadings();
  const tomorrow = await live({ name: "weather", place: "Mysuru", day: "tomorrow" });
  const day = new Date(today(Date.now(), "Asia/Kolkata") + DAY).toISOString().slice(0, 10);
  const asked = new URL(tomorrow.fetcher.asked.find((url) => url.includes("/v1/forecast")));
  expect(asked.searchParams.get("start_date") === day && asked.searchParams.get("timezone") === "Asia/Kolkata" && asked.searchParams.get("latitude") === "12.29791", "tomorrow is tomorrow where the place is, from the place Open-Meteo's geocoding finds");
  expect(
    JSON.stringify(tomorrow.sources) ===
      JSON.stringify([{ name: "weather", kind: "weather", parameters: { place: "Mysuru", day: "tomorrow" }, fields: [
        { name: "high", value: 29.4, unit: "°C", format: "number", meaning: "the day's highest temperature" },
        { name: "low", value: 19.1, unit: "°C", format: "number", meaning: "the day's lowest temperature" },
        { name: "rainChance", value: 70, unit: "", format: "percent", meaning: "the chance of rain during the day" },
        { name: "windSpeed", value: 14.8, unit: "km/h", format: "number", meaning: "wind speed during the day" },
        { name: "uvIndex", value: 8, unit: "", format: "integer", meaning: "the day's highest UV index" },
        { name: "rainAmount", value: 6.2, unit: "mm", format: "number", meaning: "how much rain is expected during the day" },
      ] }]),
    "another day: the day's high and low, chance of rain, wind, highest UV index and rain, in WeatherKit's fields, units and meanings",
  );
  expect(tomorrow.output.startsWith("Live source weather: Mysuru, ") && tomorrow.output.includes(": Rain\n- weather.high = 29.4 °C: the day's highest temperature\n") && tomorrow.output.includes("\n- weather.rainChance = 70%: the chance of rain during the day\n") && tomorrow.output.endsWith("\nShow each value you use with an input whose role is live and whose source is the field's full name, like weather.high. Dream keeps them current."), "what the model reads, as the live tool says it");
  expect(tomorrow.notes[0] === "Live: weather, weather (day tomorrow, place Mysuru)", "and the log, as the app's");

  const here = { latitude: 12.97, longitude: 77.59, city: "Bengaluru", timeZone: "Asia/Kolkata" };
  const now = await live({ name: "now", place: "here" }, { here });
  expect(
    JSON.stringify(now.sources[0]) ===
      JSON.stringify({ name: "now", kind: "weather", parameters: { place: "current location" }, fields: [
        { name: "high", value: 29.4, unit: "°C", format: "number", meaning: "the day's highest temperature" },
        { name: "low", value: 19.1, unit: "°C", format: "number", meaning: "the day's lowest temperature" },
        { name: "temperature", value: 24.6, unit: "°C", format: "number", meaning: "the temperature now" },
        { name: "feelsLike", value: 25.9, unit: "°C", format: "number", meaning: "what it feels like now" },
        { name: "rainChance", value: 70, unit: "", format: "percent", meaning: "the chance of rain today" },
        { name: "humidity", value: 78, unit: "", format: "percent", meaning: "humidity now" },
        { name: "windSpeed", value: 9.4, unit: "km/h", format: "number", meaning: "wind speed now" },
        { name: "uvIndex", value: 3, unit: "", format: "integer", meaning: "the UV index now" },
        { name: "cloudCover", value: 64, unit: "", format: "percent", meaning: "cloud cover now" },
        { name: "rainAmount", value: 6.2, unit: "mm", format: "number", meaning: "how much rain is expected during the day" },
      ] }),
    "today, where the user is: now, with the day's chance of rain; the page says current location, never where",
  );
  expect(now.output.startsWith("Live source now: Bengaluru, now and today: Cloudy") && !now.fetcher.asked.some((url) => url.includes("geocoding")), "where the request came from is the place, unlooked-up");
  const nowhere = await live({ name: "now", place: "current location" });
  expect(nowhere.output === "Dream couldn't find where you are. Don't show these values, and don't make them up." && nowhere.sources.length === 0, "and without it, the model is told so, in the app's words");

  const later = await live({ name: "picnic", place: "Mysuru", day: "saturday", time: "16:00" }, { reader: US });
  const fields = Object.fromEntries(later.sources[0].fields.map((field) => [field.name, field]));
  expect(later.sources[0].fields.map((field) => field.name).join() === "high,low,temperature,feelsLike,rainChance,humidity,windSpeed,uvIndex,cloudCover,rainAmount" && fields.temperature.value === 34 && fields.rainChance.value === 26 && fields.uvIndex.value === 8 && fields.cloudCover.value === 36, "at an hour: the forecast for that hour, nearest first");
  expect(/^the temperature at 4:00\sPM$/u.test(fields.temperature.meaning) && fields.temperature.unit === "°C" && later.output.includes("- picnic.high = 84.92 °F: the day's highest temperature"), "said for the reader, in their units, though the page keeps °C");
  const saturday = new URL(later.fetcher.asked.find((url) => url.includes("/v1/forecast"))).searchParams.get("start_date");
  expect(new Date(`${saturday}T00:00:00Z`).getUTCDay() === 6, "saturday is the coming Saturday");

  expect((await live({ name: "w", place: "Atlantis", day: "today" })).output === "Maps couldn't find Atlantis. Don't show these values, and don't make them up.", "a place that can't be found");
  expect((await live({ name: "w", place: "Mysuru", day: "someday" })).output === 'Dream can\'t tell which day "someday" is. Don\'t show these values, and don\'t make them up.', "a day that can't be read");
  expect((await live({ name: "w", place: "Mysuru", day: "in 12 days" })).output === "Forecasts only reach 10 days ahead. Don't show these values, and don't make them up.", "a day too far ahead");
  const down = await live({ name: "w", place: "Mysuru", day: "today" }, { fetcher: fakeFetch([[/geocoding/, () => Response.json({ results: [{ name: "Mysuru", latitude: 1, longitude: 2, timezone: "Asia/Kolkata" }] })], [/forecast/, () => new Response("busy", { status: 503 })]]) });
  expect(down.output === "The weather isn't available right now. Don't show these values, and don't make them up." && down.notes[0].endsWith("failed: The weather isn't available right now."), "and a forecast that doesn't come");

  const start = Date.UTC(2026, 9, 28);
  expect(liveDay("tomorrow", start) === start + DAY && liveDay("this saturday", start) === start + 3 * DAY && liveDay("wednesday", start) === start && liveDay("weekend", start) === start + 3 * DAY && liveDay("2026-11-02", start) === Date.UTC(2026, 10, 2) && liveDay("in 3 days", start) === start + 3 * DAY && liveDay("soon", start) === null, "days as LiveDay reads them, from a Wednesday");
}

console.log("Live data: exchange rates, each base kept until it's updated");
{
  forgetLiveReadings();
  let clock = Date.UTC(2026, 9, 29, 12);
  const fetcher = fakeFetch(erAPI());
  const rate = await live({ name: "rate", kind: "exchangeRate", from: "usd" }, { fetcher, now: () => clock });
  expect(JSON.stringify(rate.sources) === JSON.stringify([{ name: "rate", kind: "exchangeRate", parameters: { from: "usd" }, fields: [{ name: "rate", value: 88.0123456, unit: "", format: "number", meaning: "how many INR one USD buys" }] }]), "a rate to the user's own currency when it doesn't say: the field ExchangeRateProvider reads");
  expect(rate.output === "Live source rate: 1 US Dollar is 88.0123 Indian Rupee\n- rate.rate = 88.01: how many INR one USD buys\nShow each value you use with an input whose role is live and whose source is the field's full name, like rate.rate. Dream keeps them current.", "what the model reads");
  await live({ name: "euro", kind: "exchangeRate", from: "USD", to: "eur" }, { fetcher, now: () => clock });
  expect(fetcher.asked.length === 1 && fetcher.asked[0] === "https://open.er-api.com/v6/latest/USD", "another rate from the same base reads the table kept");
  expect((await live({ name: "pound", kind: "exchangeRate", from: "USD", to: "GBP" }, { fetcher, now: () => clock })).output === "There's no rate from USD to GBP. Don't show these values, and don't make them up.", "a currency the table hasn't");
  clock = Date.UTC(2026, 9, 30, 2);
  await live({ name: "rate", kind: "exchangeRate", from: "USD", to: "INR" }, { fetcher, now: () => clock });
  expect(fetcher.asked.length === 2, "once the next update is due, it's read again");
  clock = Date.UTC(2026, 9, 31, 2);
  const stale = await live({ name: "rate", kind: "exchangeRate", from: "USD", to: "EUR" }, { fetcher: fakeFetch(erAPI(() => new Response("<html>down</html>", { status: 500 }))), now: () => clock });
  expect(stale.sources[0]?.fields[0].value === 0.8612, "and when the service is down, yesterday's rates beat none");
  expect((await live({ name: "x", kind: "exchangeRate", from: "dollars" })).output === "Exchange rates need two currency codes, like USD and INR. Don't show these values, and don't make them up.", "two currency codes, or nothing");
}

console.log("Live data: travel times are the phone's");
{
  forgetLiveReadings();
  const definition = generation.tools.find((tool) => tool.name === "live");
  expect(!JSON.stringify(definition).includes("route") && definition.parameters.properties.kind.enum.join() === "weather,exchangeRate" && !("travel" in definition.parameters.properties) && definition.description.includes("the weather for a place and day, or an exchange rate."), "the server's live tool offers the weather and exchange rates, never routes");
  const away = await live({ name: "trip", kind: "route", to: "Kempegowda Airport" });
  expect(away.output === "Dream can't read route here. Don't show these values, and don't make them up." && away.sources.length === 0, "and a route asked of it can't be read");
  const asked = [];
  const trip = { name: "trip", kind: "route", parameters: { from: "current location", to: "Kempegowda Airport", travel: "driving" }, fields: [{ name: "distance", value: 36.2, unit: "km", format: "number", meaning: "how far it is driving" }, { name: "duration", value: 52, unit: "min", format: "number", meaning: "how long it takes driving, leaving now" }] };
  const travel = { name: "travel", description: "Fetches the distance and travel time between places now, by car, on foot or by transit, from Apple Maps.", parameters: { type: "object", properties: { name: { type: "string" }, from: { type: "string" }, to: { type: "string" }, travel: { type: "string" } } } };
  const device = { tools: [travel], run: async (call) => (asked.push(call), { output: "Live source trip: Home to Kempegowda Airport, driving\n- trip.distance = 36.2 km", source: trip }) };
  const log = new LiveLog();
  const box = toolBox(generation, fakeTools({ fetch: fakeFetch(openMeteo()) }), silent, toolSession({ device, live: log }));
  const said = await box.run("travel", JSON.stringify({ name: "trip", from: "", to: "Kempegowda Airport", travel: "" }));
  expect(box.definitions.map((tool) => tool.name).join() === "lookup,recall,live,travel,search,read" && box.connections.length === 0 && box.live.join() === "travel", "the phone's travel tool is offered beside live, and isn't a connected service's");
  expect(asked.length === 1 && asked[0].name === "travel" && JSON.parse(asked[0].arguments).to === "Kempegowda Airport" && said.startsWith("Live source trip:") && JSON.stringify(log.sources) === JSON.stringify([trip]), "a travel time goes to the phone as it was asked, and the source it read is the page's");
  const weather = await box.run("live", JSON.stringify(liveArgs({ name: "w", kind: "weather", place: "Mysuru", day: "today" })));
  expect(asked.length === 1 && weather.startsWith("Live source w: Mysuru, now and today") && log.sources.map((source) => source.name).join() === "trip,w", "the weather is still the server's own");
  const set = writing(generation, "INR", box.definitions, box);
  expect(set.instructions === surfaceInstructions(generation, "INR") && set.tools.some((tool) => tool.name === "travel"), "the live rules describe it, so it's offered, with the app's instructions as they are");
  const unanswered = toolBox(generation, fakeTools(), silent, toolSession({ device: { tools: [travel], run: async () => null } }));
  expect((await unanswered.run("travel", "{}")) === "Dream couldn't reach the phone to read this. Don't show these values, and don't make them up.", "and when the phone doesn't answer, the model is told it couldn't be read, as the live tool says it");
}

// MARK: - Recordings and molecules

const COMMONS = {
  query: {
    pages: [
      { title: "File:Gavia immer dawn chorus.ogg", index: 1, videoinfo: [{ url: "https://upload.wikimedia.org/a/dawn.ogg", mime: "application/ogg", duration: 1_800, derivatives: [{ src: "https://upload.wikimedia.org/t/dawn.mp3", type: "audio/mpeg" }], extmetadata: { ImageDescription: { value: "Gavia immer call at dawn" } } }] },
      { title: "File:Loon.mid", index: 2, videoinfo: [{ url: "https://upload.wikimedia.org/a/loon.mid", mime: "audio/midi", duration: 10, extmetadata: { ImageDescription: { value: "Gavia immer call" } } }] },
      {
        title: "File:Gavia immer - Common Loon XC1.ogg",
        index: 3,
        videoinfo: [{
          url: "https://upload.wikimedia.org/a/loon.ogg",
          descriptionurl: "https://commons.wikimedia.org/wiki/File:Gavia_immer_-_Common_Loon_XC1.ogg",
          mime: "application/ogg",
          duration: 12.5,
          derivatives: [{ src: "//upload.wikimedia.org/t/loon.ogg.mp3?t=2", type: "audio/mpeg; codecs=mp3" }],
          extmetadata: { ObjectName: { value: "Common <b>loon</b> call" }, Artist: { value: "<ul><li>Recordist: Jane Doe</li><li>Uploader: Bob</li></ul>" }, LicenseShortName: { value: "CC BY-SA 4.0" }, ImageDescription: { value: "Gavia immer call, Minnesota &amp; Ontario" } },
        }],
      },
      { title: "File:Mallard quack.ogg", index: 4, videoinfo: [{ url: "https://upload.wikimedia.org/a/duck.mp3", mime: "audio/mpeg", duration: 3, extmetadata: { ImageDescription: { value: "A duck's quack" } } }] },
    ],
  },
};

const WATER = { PC_Compounds: [{ id: { id: { cid: 962 } }, atoms: { aid: [1, 2, 3], element: [8, 1, 1] }, bonds: { aid1: [1, 1], aid2: [2, 3], order: [1, 1] }, coords: [{ type: [1, 5, 255], aid: [1, 2, 3], conformers: [{ x: [0, 0.2774, 0.6068], y: [0.3, 1.1929, 0.0617], z: [0, 0.2544, -0.7169] }] }] }] };
const pubChem = () => [
  [/\/compound\/name\/water\/JSON\?record_type=3d$/, () => Response.json(WATER)],
  [/\/compound\/cid\/962\/property\/Title,MolecularFormula\/JSON$/, () => Response.json({ PropertyTable: { Properties: [{ CID: 962, MolecularFormula: "H2O", Title: "Water" }] } })],
  [/\/compound\/name\//, () => new Response("not found", { status: 404 })],
];

console.log("Recordings from Wikimedia Commons, molecules from PubChem");
{
  const fetcher = fakeFetch([[/^https:\/\/commons\.wikimedia\.org\/w\/api\.php/, () => Response.json(COMMONS)]]);
  const found = await findRecording("Gavia immer call", fetcher);
  expect(
    JSON.stringify(found) === JSON.stringify({ title: "Common loon call", audioURL: "https://upload.wikimedia.org/t/loon.ogg.mp3", pageURL: "https://commons.wikimedia.org/wiki/File:Gavia_immer_-_Common_Loon_XC1.ogg", credit: "Recordist: Jane Doe", licence: "CC BY-SA 4.0", duration: 12.5 }),
    "the best file iOS can play, as SoundLookup finds it: not half an hour of dawn, not MIDI, not a duck; Commons' MP3, its credit and licence",
  );
  const query = new URL(fetcher.asked[0]).searchParams;
  expect(query.get("gsrsearch") === "Gavia immer call filetype:audio" && query.get("gsrnamespace") === "6" && query.get("viprop") === "url|size|mime|extmetadata|derivatives", "searched as the app searches");
  expect((await findRecording("xy", fetcher)) === null && (await findRecording("Gavia immer call", fakeFetch([[/commons/, () => new Response("", { status: 500 })]]))) === null, "nothing for a search too short, or a Commons that doesn't answer");

  forgetMolecules();
  const chemistry = fakeFetch(pubChem());
  const water = await findMolecule(" Water ", chemistry);
  expect(water?.cid === 962 && water.title === "Water" && water.formula === "H2O" && water.atoms.length === 3 && water.atoms.map((atom) => atom.element).join() === "8,1,1" && JSON.stringify(water.bonds) === '[{"from":0,"to":1,"order":1},{"from":0,"to":2,"order":1}]', "a molecule's structure from PubChem, with its own name and formula");
  const middle = [0, 1, 2].map((axis) => water.atoms.reduce((sum, atom) => sum + [atom.x, atom.y, atom.z][axis], 0));
  expect(middle.every((value) => Math.abs(value) < 1e-9) && chemistry.asked[0] === "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/water/JSON?record_type=3d", "centred on its middle, asked for by its name");
  await findMolecule("water", chemistry);
  expect(chemistry.asked.length === 2 && (await findMolecule("unobtainium", chemistry)) === null, "found once, and nothing for what PubChem hasn't");
  const far = structuredClone(WATER);
  far.PC_Compounds[0].coords[0].conformers[0].x[1] = 900;
  const strange = structuredClone(WATER);
  strange.PC_Compounds[0].atoms.element[2] = 200;
  expect(structureOf(far) === null && structureOf(strange) === null && structureOf({}) === null, "a record that doesn't make sense is refused, as MoleculeStructure(pubChem:) refuses it");
  expect(cleaned(" Caffeine <script>alert(1)</script> ") === "Caffeine scriptalert(1)script", "names come cleaned of anything but what chemical names use");
}

// MARK: - The loop

console.log("The loop: a page, held while the check decides");
{
  const model = fakeModelOf({
    gaps: () => stream([{ wait: 250 }, ...pieces(JSON.stringify({ questions: [] }))]),
    write: () => stream([{ reasoning_content: "Thinking" }, ...pieces(JSON.stringify(page()), 20, 20)]),
  });
  const { outcome, events, lines } = await runLoop(model);
  const surfaces = events.filter((event) => event.type === "surface");
  expect(outcome.kind === "done" && outcome.surface.title === "Mercury" && outcome.model === "Auto → Grok 4.7 · low", "the page is done, on the model Auto picked");
  expect(lines()[0] === "Request: tell me about mercury" && lines()[1].startsWith("Auto → Grok 4.7 · low (other, easy: Dream's default; ") && lines()[2] === "Model: Auto → Grok 4.7 · low", "the log starts as the app's does");
  expect(lines().some((line) => line.startsWith("Check: nothing to ask (") && line.endsWith(", while the page was held back)")), "the check found nothing, while the page was held back");
  expect(surfaces.length > 2 && surfaces.every((event) => event.at >= 150), "no page shows while the check may still ask");
  const gaps = surfaces.slice(1).map((event, index) => event.at - surfaces[index].at);
  expect(gaps.every((gap) => gap >= 45), `at most one page every 50 ms here (five a second in production): ${surfaces.length} pages`);
  expect(surfaces.at(-1).surface.blocks.length === 2, "the last page shown is the whole one");
  const sent = model.calls.write[0];
  expect(sent.messages[0].role === "system" && sent.messages[0].content === surfaceInstructions(generation, "INR") && textOf(sent.messages[1].content) === `Request: tell me about mercury\n\n${REQUEST.context[0]}` && sent.model === "grok-4.7" && sent.reasoning_effort === "low" && sent.temperature === 0.4 && sent.tools.map((tool) => tool.function.name).join() === "lookup,recall,live,search,read", "the writing is asked what the app asks: its instructions whole, with its tools");
  const gapBody = model.calls.gaps[0];
  expect(gapBody.messages[0].content === generation.prompts.gapCheck && textOf(gapBody.messages[1].content) === "Request: tell me about mercury" && gapBody.max_tokens === 4_600 && gapBody.temperature === 0.2 && !gapBody.tools, "the gap check is asked what the app asks");
  expect(events.filter((event) => event.type === "phase").map((event) => event.phase).join() === "composing", "it composes");
  expect(lines().some((line) => line === "Written in English, for metric units") && lines().at(-1).startsWith("Done in "), "it says what it's written in, and when it's done");
}

console.log("The loop: Auto, when it can't be asked");
{
  const model = fakeModelOf({ write: () => stream(pieces(JSON.stringify(page()))) });
  const { outcome, lines } = await runLoop(model, { route: async () => { throw new Error("down"); } });
  expect(outcome.kind === "done" && lines().includes("Auto → Dream's default · low (the router didn't answer: Something went wrong. Try again in a moment.)") && !("model" in model.calls.write[0]) && model.calls.write[0].reasoning_effort === "low", "the page is made on the server's default, thinking low");
  const named = await runLoop(model, {}, startFresh(), { ...REQUEST, model: "grok-4.7", thinking: "high" });
  expect(named.outcome.model === "Dream (grok-4.7)" && model.calls.write.at(-1).model === "grok-4.7" && model.calls.write.at(-1).reasoning_effort === "high", "a model picked by name isn't routed, and thinks as long as asked");
}

console.log("The loop: tools");
{
  const tools = fakeTools();
  const model = fakeModelOf({
    write: (index, body) => {
      if (index === 0) {
        return stream([
          { tool_calls: [{ index: 0, id: "a", type: "function", function: { name: "lookup", arguments: JSON.stringify({ subject: "Mercury", language: "en" }) } }, { index: 1, id: "b", type: "function", function: { name: "search", arguments: JSON.stringify({ question: "q", keywords: "mercury news", freshness: "any", country: "" }) } }] },
          { finish: "tool_calls" },
        ]);
      }
      return stream(pieces(JSON.stringify(page())));
    },
  });
  const { outcome, events } = await runLoop(model, { tools });
  const second = model.calls.write[1].messages;
  expect(outcome.kind === "done" && outcome.surface.reference?.title === "Mercury (planet)", "the page has the article it looked up");
  expect(events.filter((event) => event.type === "trace").map((event) => `${event.kind}:${event.text}`).join() === "lookup:Mercury,search:mercury news", "each search and lookup is traced as it starts");
  expect(second.at(-3).tool_calls?.length === 2 && second.at(-2).role === "tool" && second.at(-2).tool_call_id === "a" && second.at(-1).content.startsWith("Search results"), "the tools' answers go back to the model, in order");
  const phases = events.filter((event) => event.type === "phase").map((event) => event.phase);
  expect(phases.join() === "composing,researching,composing", "it researches, then composes again once it writes");
}

console.log("The loop: questions");
{
  let seen = {};
  const model = fakeModelOf({
    gaps: () => stream(pieces(JSON.stringify({ questions: [{ question: "Which Mercury?", topic: "Subject", options: ["The planet", "The element", "You choose", "the planet"], personal: false, typing: false, remembered: "" }] }))),
    write: (index) => (index === 0 ? stream([{ wait: 40 }, { hang: true }], (seen = {})) : stream(pieces(JSON.stringify(page())))),
  });
  const first = await runLoop(model);
  expect(first.outcome.kind === "asking" && first.outcome.questions.length === 1, "the check's questions stop the page");
  const [question] = first.outcome.questions;
  expect(JSON.stringify(question) === JSON.stringify({ text: "Which Mercury?", topic: "Subject", options: ["The planet", "The element"], allowsTyping: false, isPersonal: false }), "as the app's Question tidies them: no You choose, no repeats");
  expect(seen.cancelled === true, "the writing that started gives way");
  expect(first.lines().some((line) => line === "Check: 1 to ask after " + line.split("after ")[1]?.split("s,")[0] + "s, so the screen stopped before it began: Which Mercury? (The planet / The element)"), "the log says what it asked");
  const resumed = await runLoop(model, {}, { pick: PICK, answers: [{ question, choice: "The planet", isRemembered: false }], checkedAt: Date.now() - 5_000, startedAt: Date.now() - 6_000, first: false });
  const asked = textOf(lastUser(model.calls.write[1]).content);
  expect(resumed.outcome.kind === "done" && resumed.outcome.surface.answers?.[0]?.choice === "The planet", "the page is built for the answer, and carries it");
  expect(asked.endsWith("Before building, the user answered:\n- Which Mercury? The planet\nBuild the screen for these answers."), "the answers go beside the request");
  expect(resumed.lines()[0].startsWith("Answered: The planet after 5.") && model.calls.gaps.length === 1, "it says so, and doesn't check again");
  expect(questionFrom({ question: "Where to?", topic: "", options: ["Goa"], personal: true, typing: false }).allowsTyping === true, "a question with too few options takes a typed answer");
}

console.log("The loop: stalls");
{
  const half = JSON.stringify(page()).slice(0, JSON.stringify(page()).indexOf("related") - 3);
  const stalled = fakeModelOf({ write: () => stream([...pieces(half), { hang: true }]) });
  const { outcome, lines } = await runLoop(stalled);
  expect(lines().some((line) => /^Surface stopped making progress after [\d.]+s; stopped it there\.$/.test(line)), "silence past the patience stops it");
  expect(outcome.kind === "done" && outcome.surface.blocks.length === 2 && lines().includes("Kept the 2 finished blocks."), "and after a stall everything there is kept");

  const beats = [];
  for (let i = 0; i < 200; i++) beats.push({ beat: true, gap: 20 });
  const hanging = fakeModelOf({ write: () => stream(beats) });
  const started = Date.now();
  const hung = await runLoop(hanging);
  const took = Date.now() - started;
  expect(hung.outcome.kind === "failed" && hung.outcome.message === "The model stopped making progress.", "a hang that only sends heartbeats fails the page");
  expect(took >= FAST.ceiling && took < FAST.ceiling + 1_500, `not before the ceiling, though heartbeats keep coming (${took} ms)`);
}

console.log("The loop: runaways, padding, empty pages");
{
  const looping = page({ blocks: [block("paragraph", { text: "again ".repeat(40) })] });
  const model = fakeModelOf({ write: (index) => (index === 0 ? stream(pieces(JSON.stringify(looping), 15, 3)) : stream(pieces(JSON.stringify(page())))) });
  const { outcome, lines } = await runLoop(model);
  expect(lines().some((line) => line.startsWith("Surface started repeating itself after")) && lines().some((line) => line === "Writing again in a new session, after: The model stopped before finishing."), "a page that loops is stopped, and with nothing finished, written again");
  expect(outcome.kind === "done" && model.calls.write[1].messages.length === 2, "in a new session");

  const padded = fakeModelOf({ write: (index) => (index === 0 ? stream([{ content: '{"title":"x","blocks":[' }, { content: " ".repeat(450) }]) : stream(pieces(JSON.stringify(page())))) });
  const pad = await runLoop(padded);
  expect(pad.lines().includes("Surface ended before it was finished.") && pad.outcome.kind === "done", "padding ends the answer there, and it's written again");

  const hollow = fakeModelOf({ write: (index) => stream(pieces(JSON.stringify(index === 0 ? page({ blocks: [] }) : page()))) });
  const empty = await runLoop(hollow);
  expect(empty.lines().includes("Writing again in a new session, after: The model wrote an empty screen.") && empty.outcome.surface.blocks.length === 2, "a title and a sentence with nothing under them is written again");

  const busy = fakeModelOf({ write: (index) => (index === 0 ? new Response(JSON.stringify({ error: "busy" }), { status: 503, headers: { "Retry-After": "20" } }) : stream(pieces(JSON.stringify(page())))) });
  expect((await runLoop(busy)).outcome.kind === "done" && busy.calls.write.length === 2, "a busy model is asked again");
  const refused = fakeModelOf({ write: () => new Response(JSON.stringify({ error: "You've made today's 5 free pages.", reason: "allowance" }), { status: 402 }) });
  const used = await runLoop(refused);
  expect(used.outcome.kind === "failed" && used.outcome.message === "You've made today's 5 free pages." && refused.calls.write.length === 1, "a used-up allowance isn't, and says so");
}

console.log("The loop: repairs");
{
  let checks = 0;
  const engine = fakeEngine(() => (checks++ === 0 ? [{ kind: "needsModel", message: "total is never shown" }] : []));
  const model = fakeModelOf({ write: (index) => stream(pieces(JSON.stringify(page({ title: index === 0 ? "Mercury" : "Mercury, fixed" })))) });
  const { outcome, events, lines } = await runLoop(model, { engine });
  const repair = textOf(lastUser(model.calls.write[1]).content);
  expect(outcome.surface.title === "Mercury, fixed" && repair === "That screen has problems:\n- total is never shown\n\nReturn the whole screen again with these problems fixed. Keep everything else the same.", "a problem goes back in the same session, and the repair is kept");
  expect(model.calls.write[1].messages.at(-2).role === "assistant" && lines().includes("Problem: total is never shown") && events.some((event) => event.type === "phase" && event.phase === "fixing"), "after the page it wrote, while fixing");

  const engine2 = fakeEngine(() => [{ kind: "needsModel", message: "still wrong" }]);
  const broken = fakeModelOf({ write: (index) => (index === 0 ? stream(pieces(JSON.stringify(page()))) : new Response(JSON.stringify({ error: "no" }), { status: 500 })) });
  const kept = await runLoop(broken, { engine: engine2 });
  expect(kept.outcome.kind === "done" && kept.outcome.surface.title === "Mercury" && kept.lines().some((line) => line.startsWith("Kept the screen as it was: repair 1 didn't finish")), "a repair that breaks keeps the page as it was");

  // A repair cut off partway: the page it was repairing, not the block or two of its rewrite.
  const cut = fakeModelOf({ write: (index) => stream(pieces(index === 0 ? JSON.stringify(page()) : JSON.stringify(page({ title: "Half" })).slice(0, 80))) });
  const halfway = await runLoop(cut, { engine: fakeEngine(() => [{ kind: "needsModel", message: "still wrong" }]) });
  expect(halfway.outcome.kind === "done" && halfway.outcome.surface.title === "Mercury" && halfway.outcome.surface.blocks.length === 2 && halfway.lines().some((line) => line.startsWith("Kept the screen as it was: repair 1")), "a repair that stops early keeps the page it was repairing");

  // A repair that loses most of the page isn't worth having.
  const shrunk = fakeModelOf({ write: (index) => stream(pieces(JSON.stringify(index === 0 ? page() : page({ title: "Smaller", blocks: [] })))) });
  const smaller = await runLoop(shrunk, { engine: fakeEngine(() => [{ kind: "needsModel", message: "still wrong" }]) });
  expect(smaller.outcome.surface.title === "Mercury" && smaller.lines().includes("Kept the screen as it was: repair 1 left 0 of its 2 blocks."), "a repair that loses most of the page is undone");

  // A page about the world looks something up before it writes; the sourcing repair must too.
  const science = fakeModelOf({ write: () => stream(pieces(JSON.stringify(page()))) });
  await runLoop(science, { route: async () => ({ ...PICK, category: "science" }) });
  const plain = fakeModelOf({ write: () => stream(pieces(JSON.stringify(page()))) });
  await runLoop(plain);
  expect(science.calls.write[0].tool_choice === "required" && plain.calls.write[0].tool_choice === undefined, "an explainer's first round must call a tool; other pages may write straight away");
  let sourced = 0;
  const unsourced = { ...fakeEngine(), checkSourcing: () => (sourced++ === 0 ? [{ kind: "needsModel", message: "It states facts about the world without looking any up." }] : []) };
  const looked = fakeModelOf({ write: () => stream(pieces(JSON.stringify(page()))) });
  await runLoop(looked, { engine: unsourced });
  expect(looked.calls.write[1]?.tool_choice === "required", "the repair for a page that looked nothing up must look something up");

  const stopped = JSON.stringify(page()).slice(0, JSON.stringify(page()).indexOf("related") - 3);
  let rounds = 0;
  const engine3 = fakeEngine(() => (rounds++ === 0 ? [{ kind: "needsModel", message: "a" }] : []));
  const early = fakeModelOf({ write: (index) => (index === 0 ? stream([...pieces(stopped), { finish: "length" }]) : stream(pieces(JSON.stringify(page())))) });
  await runLoop(early, { engine: engine3 });
  const restated = textOf(lastUser(early.calls.write[1]).content);
  expect(restated.startsWith(`Request: tell me about mercury\n\n${REQUEST.context[0]}\n\nYou began this screen`) && early.calls.write[1].messages.length === 2, "a page that stopped early is repaired with the request and the page restated");
}

console.log("The loop: what Dream remembers");
{
  const memoryTools = () => fakeTools({ memory: async () => confirmedFacts(FACTS) });
  const asks = (questions) => () => stream(pieces(JSON.stringify({ questions })));
  const home = { question: "Where do you live?", topic: "Home city", options: [], personal: true, typing: true, remembered: "" };
  const model = fakeModelOf({ gaps: asks([home]), write: (index) => (index === 0 ? stream([{ hang: true }]) : stream(pieces(JSON.stringify(page())))) });
  const request = { ...REQUEST, context: ["Dream remembers these about the user: Old topic.", ...REQUEST.context] };
  const { outcome, lines } = await runLoop(model, { tools: memoryTools() }, startFresh(), request);
  expect(textOf(lastUser(model.calls.gaps[0]).content) === "Request: tell me about mercury\n\nDream remembers these about the user: Diet, Home city.", "the gap check is told the topics Dream remembers, from the account's facts");
  expect(outcome.kind === "done" && outcome.surface.answers?.[0]?.choice === "Pune, Mumbai" && outcome.surface.answers[0].isRemembered === true, "a question about a remembered topic is answered from it, and nobody is asked");
  expect(lines().includes("Remembered: Home city") && lines().some((line) => /^Answered: Pune, Mumbai \(remembered\) after [\d.]+s$/.test(line)), "and the log says so");
  const written = textOf(lastUser(model.calls.write[1]).content);
  expect(written.startsWith(`Request: tell me about mercury\n\nDream remembers these about the user: Diet, Home city.\n${REQUEST.context[0]}\n`) && !written.includes("Old topic") && written.includes("- Where do you live? Pune, Mumbai (from what Dream remembers)"), "the page is written with the server's memory line in place of the phone's, and the answer");

  const both = fakeModelOf({ gaps: asks([home, { question: "Which Mercury?", topic: "Subject", options: ["The planet", "The element"], personal: false, typing: false, remembered: "" }]), write: () => stream([{ hang: true }]) });
  const asking = await runLoop(both, { tools: memoryTools() });
  expect(asking.outcome.kind === "asking" && asking.outcome.questions.map((question) => question.text).join() === "Which Mercury?" && asking.outcome.remembered[0].choice === "Pune, Mumbai", "only what Dream can't answer is asked");

  const recalling = fakeModelOf({
    write: (index) => (index === 0 ? stream([{ tool_calls: [{ index: 0, id: "r", type: "function", function: { name: "recall", arguments: JSON.stringify({ topics: ["Diet"] }) } }] }, { finish: "tool_calls" }]) : stream(pieces(JSON.stringify(page())))),
  });
  const recalled = await runLoop(recalling, { tools: memoryTools() });
  expect(recalling.calls.write[1].messages.at(-1).content === "What Dream remembers about the user:\n- Diet: Vegetarian" && recalled.lines().includes("Recalled: Diet (1 found)"), "recall reads the account's facts while the page is written");
}

const QUESTION = { text: "Which Mercury?", topic: "Subject", options: ["The planet", "The element"], allowsTyping: false, isPersonal: false };
const CURRENT = {
  ...page(),
  blocks: [{ id: "b1", ...block("paragraph", { text: "Mercury is close to the Sun." }) }, { id: "b2", ...block("facts", { title: "Facts", items: [{ label: "Moons", value: "0" }] }) }],
  answers: [{ question: QUESTION, choice: "The planet", isRemembered: false }],
  reference: { title: "Mercury (planet)", extract: "A planet.", url: "https://en.wikipedia.org/wiki/Mercury_(planet)" },
  citations: [{ title: "Mercury facts", site: "example.com", url: "https://www.example.com/mercury" }],
  sources: [{ name: "rate", kind: "exchangeRate", parameters: { from: "USD" }, fields: [{ name: "rate", value: 88, unit: "", format: "number", meaning: "how many INR one USD buys" }] }],
  services: ["Notes"],
  locale: { language: "en", measurementSystem: "ussystem" },
};

console.log("The loop: a change to a page");
{
  let read = null;
  const engine = { ...fakeEngine(), checkCitations: (surface, reading) => ((read = reading), { surface, issues: [] }) };
  const routed = [];
  const model = fakeModelOf({ write: () => stream(pieces(JSON.stringify(page({ title: "Mercury, monthly" })))) });
  const change = { ...REQUEST, editing: { surface: CURRENT, instruction: "make it monthly", focus: "b2" } };
  const { outcome, events, lines } = await runLoop(model, { engine, route: async (text) => (routed.push(text), PICK) }, startFresh(), change);
  expect(model.calls.gaps.length === 0 && lines()[0] === "Change: make it monthly (pointing at #b2)" && routed[0] === "tell me about mercury. make it monthly", "a change isn't checked for questions, and is routed with the request and the change together");
  const asked = textOf(lastUser(model.calls.write[0]).content);
  expect(asked === editPrompt(generation, { intent: "tell me about mercury", outline: "Mercury: The smallest planet.", logic: null, instruction: "make it monthly", pointing: 'the facts block "Facts" (#b2)', context: REQUEST.context }), "it's asked as Prompts.edit asks, pointing at the block");
  expect(outcome.kind === "done" && outcome.surface.title === "Mercury, monthly" && outcome.surface.answers?.[0]?.choice === "The planet" && outcome.surface.sources?.[0]?.name === "rate" && outcome.surface.services?.join() === "Notes" && outcome.surface.reference?.title === "Mercury (planet)", "the changed page keeps its answers, its live sources, the services it read and its article");
  expect(outcome.surface.locale.measurementSystem === "ussystem" && lines().includes("Written in English, for ussystem units"), "and the units it was written in");
  const surfaces = events.filter((event) => event.type === "surface");
  expect(surfaces[0].surface.title === "Mercury" && surfaces.every((event) => ["Mercury", "Mercury, monthly"].includes(event.surface.title)), "the page as it is shows first, then the change whole: a change isn't streamed");
  expect(read.some((credit) => credit.url === "https://www.example.com/mercury") && read.some((credit) => credit.site === "Wikipedia" && credit.url === CURRENT.reference.url), "the pages it already credits may be cited again");

  const answering = fakeModelOf({ write: () => stream(pieces(JSON.stringify(page({ title: "Mercury, the element" })))) });
  const rebuilt = await runLoop(answering, {}, startFresh(), { ...REQUEST, editing: { surface: CURRENT, answer: { question: QUESTION, choice: "The element" } } });
  const words = "I mean The element. (You asked Which Mercury? and I said The planet.) Rebuild the screen for that.";
  expect(rebuilt.lines()[0] === `Change: ${words}` && textOf(lastUser(answering.calls.write[0]).content).includes(`About the whole screen, they say: "${words}"`), "a different answer is a change in the user's words");
  expect(JSON.stringify(rebuilt.outcome.surface.answers) === JSON.stringify([{ question: QUESTION, choice: "The element", isRemembered: false }]), "and the page carries the new answer");

  const remaking = fakeModelOf({ write: () => stream(pieces(JSON.stringify(page()))) });
  const again = await runLoop(remaking, {}, startFresh(), { ...REQUEST, editing: { surface: CURRENT, again: true } });
  expect(again.lines()[0] === "Request: tell me about mercury" && remaking.calls.gaps.length === 1 && again.outcome.kind === "done" && !again.outcome.surface.services && !again.outcome.surface.sources, "made again, it's made as a new page is: checked for questions, keeping nothing of the old one");
}

console.log("The loop: live data, checked by the engine");
{
  forgetLiveReadings();
  const wireInput = (fields) => ({ name: "", label: "", role: "adjustable", source: "", symbol: "", unit: "", format: "number", initial: 0, min: 0, max: 0, step: 1, options: [], ...fields });
  const wireOutput = (fields) => ({ name: "", label: "", symbol: "", unit: "", formula: "", format: "number", ...fields });
  const umbrella = page({
    title: "An umbrella tomorrow?",
    summary: "Whether you'll need one in Mysuru tomorrow.",
    mode: "use",
    subject: "places",
    inputs: [wireInput({ name: "rain", label: "Chance of rain", role: "live", source: "weather.rainChance", format: "percent" })],
    outputs: [wireOutput({ name: "umbrella", label: "Take an umbrella", formula: "rain >= 40", format: "toggle" })],
    blocks: [block("hero", { ref: "umbrella" }), block("metric", { ref: "rain" }), block("paragraph", { text: "The chance of rain is {rain}." })],
  });
  const model = fakeModelOf({
    write: (index) =>
      index === 0
        ? stream([{ tool_calls: [{ index: 0, id: "w", type: "function", function: { name: "live", arguments: JSON.stringify(liveArgs({ name: "weather", place: "Mysuru", day: "tomorrow" })) } }] }, { finish: "tool_calls" }])
        : stream(pieces(JSON.stringify(umbrella))),
  });
  const { outcome, lines } = await runLoop(model, { engine: realEngine, tools: fakeTools({ fetch: fakeFetch(openMeteo()) }) });
  const rain = outcome.surface.inputs?.find((input) => input.name === "rain");
  expect(outcome.kind === "done" && rain?.role === "live" && rain.source === "weather.rainChance" && rain.initial === 70 && rain.format === "percent", "the live input is bound to what was read, at its value");
  expect(outcome.surface.sources?.length === 1 && outcome.surface.sources[0].fields.find((field) => field.name === "rainChance")?.meaning === "the chance of rain during the day" && lines().includes("Live: weather, weather (day tomorrow, place Mysuru)"), "and the page keeps the source as the app declares it");
}

console.log("The loop: recordings and molecules, once the page is written");
{
  forgetMolecules();
  const sounding = page({ sounds: [{ name: "loon", label: "Loon call", tones: [], search: "Gavia immer call" }], scenes: [{ name: "molecule", objects: [], plots: [], molecule: { name: "water" }, time: "" }] });
  const fetcher = fakeFetch([[/commons\.wikimedia\.org/, () => Response.json(COMMONS)], ...pubChem()]);
  const model = fakeModelOf({ write: () => stream(pieces(JSON.stringify(sounding))) });
  const { outcome } = await runLoop(model, { tools: fakeTools({ fetch: fetcher }) });
  expect(outcome.surface.sounds[0].recording?.title === "Common loon call" && outcome.surface.scenes[0].molecule.structure?.cid === 962, "the page has the recording and the molecule's structure, as the app finds them");
}

/** A connected service's tool, as the phone would send it. */
const NOTES = { name: "notes_search", description: "From Notes, a service the user connected. It only looks things up.", parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"], additionalProperties: false }, service: "Notes" };
const callsNotes = (index) => (index === 0 ? stream([{ tool_calls: [{ index: 0, id: "n", type: "function", function: { name: "notes_search", arguments: '{"query":"trip"}' } }] }, { finish: "tool_calls" }]) : stream(pieces(JSON.stringify(page()))));

console.log("The loop: the phone's own tools");
{
  const calls = [];
  const device = async (call) => (calls.push(call), { output: "What Notes returned: three notes.", service: "Notes", source: { name: "notesSearch", kind: "connection", parameters: { service: "Notes", tool: "search" }, fields: [{ name: "count", value: 3, unit: "", format: "number", meaning: "" }] } });
  const model = fakeModelOf({ write: callsNotes });
  const record = recorder();
  const loop = new PageLoop({ ...REQUEST, deviceTools: [NOTES] }, { ...services(model), device }, record.sink, new AbortController().signal, FAST);
  const outcome = await loop.run(startFresh());
  const sent = model.calls.write[0];
  const rules = generation.prompts.features.find((feature) => feature.name === "connections").rules;
  expect(sent.tools.map((tool) => tool.function.name).join() === "lookup,recall,live,notes_search,search,read" && sent.messages[0].content.includes(rules), "the phone's tools are offered with the server's, after live, and bring the rules for connected services");
  expect(calls[0].name === "notes_search" && calls[0].arguments === '{"query":"trip"}' && model.calls.write[1].messages.at(-1).content === "What Notes returned: three notes.", "a call to one is the phone's to run, and what it returns goes to the model");
  expect(outcome.surface.services?.join() === "Notes" && outcome.surface.sources?.[0]?.name === "notesSearch", "the page lists the service it read, and keeps the source");
}

// MARK: - The job

/** A job's services, with a clock the test moves. */
function jobServices(model, clock, extra = {}) {
  const finished = [];
  const counted = [];
  return {
    finished,
    counted,
    services: {
      loop: () => ({ ...services(model, extra), now: () => clock.now() }),
      async finish(job, request, surface, log, modelName) {
        finished.push({ job, request, surface, log, modelName });
        return null;
      },
      analytics: (job, event, properties) => counted.push([event, properties]),
      now: () => clock.now(),
    },
  };
}

const JOB = { id: "a".repeat(64), owner: "user-1", counted: true, origin: "https://dream.example" };
const QUICK_JOB = { answerWait: 600_000, runLimit: 60_000, keep: 86_400_000, attempts: 3, keepAlive: 60 };

/** Reads a watcher's stream to its end, or until `ms` pass. */
async function collect(stream, ms = 5_000) {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let text = "";
  const until = Date.now() + ms;
  for (;;) {
    const result = await Promise.race([reader.read(), pause(Math.max(0, until - Date.now())).then(() => null)]);
    if (!result) {
      await reader.cancel();
      break;
    }
    if (result.done) break;
    text += decoder.decode(result.value);
  }
  const events = text.split("\n\n").filter((part) => part.startsWith("data: ")).map((part) => JSON.parse(part.slice(6)));
  return { text, events };
}

console.log("The job: events, catching up, and the page kept");
{
  const clock = { now: () => Date.now() };
  const store = memoryStore();
  const model = fakeModelOf({ write: () => stream([{ wait: 100 }, ...pieces(JSON.stringify(page()), 20, 10)]) });
  const { services: jobs, finished, counted } = jobServices(model, clock);
  const runner = new Runner(store, jobs, QUICK_JOB, FAST);
  await runner.start(JOB, REQUEST);
  expect(store.alarm !== null && runner.job.status === "queued", "starting a page sets it to run at once, on the alarm");
  expect(runner.watch("someone-else", 0) === null, "only the page's owner may watch it");
  const live = collect(runner.watch(JOB.owner, 0));
  await runner.alarm();
  const { events, text } = await live;
  expect(events.at(-1)?.type === "done" && events.at(-1).pageID === REQUEST.pageID && events.at(-1).model === "Auto → Grok 4.7 · low", "a watcher sees it through to done");
  expect(events.every((event, index) => index === 0 || event.seq > events[index - 1].seq), "every event has the next seq");
  expect(text.includes(": keep-alive"), "and a keep-alive comment while it's quiet");
  expect(events.filter((event) => event.type === "surface").length > 1, "the page streams in as it's written");

  const all = (await collect(runner.watch(JOB.owner, 0))).events;
  expect(all.filter((event) => event.type === "surface").length === 1 && all.at(-1).type === "done", "catching up from the start: one page as it stood, superseded ones dropped, then done");
  const middle = all[Math.floor(all.length / 2)].seq;
  const rest = (await collect(runner.watch(JOB.owner, middle))).events;
  expect(rest.length > 0 && rest.every((event) => event.seq > middle) && rest.length === all.filter((event) => event.seq > middle).length, "catching up from a seq: only what came after it, nothing twice");
  expect((await collect(runner.watch(JOB.owner, all.at(-1).seq), 300)).events.length === 0, "after the last seq, nothing, and the stream ends");

  const [kept] = finished;
  expect(kept && kept.log[0] === "Request: tell me about mercury" && kept.log.at(-1).startsWith("Done in ") && kept.modelName === "Auto → Grok 4.7 · low", "the finished page is kept with its log");
  expect(counted.map(([event]) => event).join() === "page_requested,page_built" && counted[1][1].blocks === 2 && counted[1][1].block_kinds.join() === "facts,paragraph" && counted[1][1].mode === "read", "analytics as the app counts a page");
  expect(runner.job.status === "done" && store.alarm >= Date.now() + 86_000_000, "a done job is kept a day for its watchers");
  clock.now = () => Date.now() + 86_400_001;
  await runner.alarm();
  expect(store.cleared && !runner.job, "then forgotten");
}

console.log("The job: questions wait for answers");
{
  let now = Date.now();
  const clock = { now: () => now };
  const store = memoryStore(() => now);
  const model = fakeModelOf({
    gaps: () => stream(pieces(JSON.stringify({ questions: [{ question: "Which Mercury?", topic: "Subject", options: ["The planet", "The element"], personal: false, typing: false, remembered: "" }] }))),
    write: (index) => (index === 0 ? stream([{ hang: true }]) : stream(pieces(JSON.stringify(page())))),
  });
  const { services: jobs } = jobServices(model, clock);
  const runner = new Runner(store, jobs, QUICK_JOB, FAST);
  await runner.start(JOB, REQUEST);
  await runner.alarm();
  const asked = store.after(0).find((event) => event.type === "asking");
  expect(runner.job.status === "asking" && asked?.questions[0].text === "Which Mercury?", "the questions are an event, and the page waits");
  expect(store.alarm === now + QUICK_JOB.answerWait, "for ten minutes at most");
  expect((await runner.answer("someone-else", { answers: [] })).status === 404, "only the owner may answer");
  await runner.alarm();
  expect(runner.job.status === "asking" && model.calls.write.length === 1, "an early alarm leaves it waiting");
  const answered = await runner.answer(JOB.owner, { answers: [{ question: { text: "Which Mercury?" }, choice: " The element " }] });
  expect(answered.status === 200 && store.alarm === now && (await runner.answer(JOB.owner, { answers: [] })).status === 409, "an answer wakes it at once; a second isn't taken");
  await runner.alarm();
  const done = store.after(0).at(-1);
  expect(done.type === "done" && done.surface.answers[0].choice === "The element" && textOf(lastUser(model.calls.write[1]).content).includes("- Which Mercury? The element"), "and the page is built for it");

  // Nobody answers this time.
  const store2 = memoryStore(() => now);
  const model2 = fakeModelOf({ gaps: model.calls ? () => stream(pieces(JSON.stringify({ questions: [{ question: "Which Java?", topic: "Subject", options: ["The island", "The language"], personal: false, typing: false, remembered: "" }] }))) : undefined, write: (index) => (index === 0 ? stream([{ hang: true }]) : stream(pieces(JSON.stringify(page())))) });
  const runner2 = new Runner(store2, jobServices(model2, clock).services, QUICK_JOB, FAST);
  await runner2.start(JOB, REQUEST);
  await runner2.alarm();
  now += QUICK_JOB.answerWait + 1;
  await runner2.alarm();
  const log = store2.after(0).filter((event) => event.type === "log").map((event) => event.line);
  expect(store2.after(0).at(-1).type === "done" && log.some((line) => /^Answered: You choose after 600\.\ds$/.test(line)), "with no answer in ten minutes, it goes on as if the answer were You choose");
  expect(textOf(lastUser(model2.calls.write[1]).content).includes("- Which Java? You choose: pick what's most likely."), "and tells the model so");
}

console.log("The job: a restart starts the page over");
{
  const clock = { now: () => Date.now() };
  const store = memoryStore();
  const model = fakeModelOf({ write: () => stream(pieces(JSON.stringify(page()))) });
  const first = new Runner(store, jobServices(model, clock).services, QUICK_JOB, FAST);
  await first.start(JOB, REQUEST);
  // As if the object stopped mid-page: its record says running, and a new instance's alarm runs.
  const record = first.job;
  store.put("job", { ...record, status: "running", attempts: 1, pick: PICK });
  const again = new Runner(store, jobServices(model, clock).services, QUICK_JOB, FAST);
  await again.alarm();
  const lines = store.after(0).filter((event) => event.type === "log").map((event) => event.line);
  expect(lines[0] === "Started again: Dream's server restarted while it was making this page." && store.after(0).at(-1).type === "done" && again.job.attempts === 2, "it starts over, and finishes");
  expect(!lines.some((line) => line.startsWith("Auto →") && line.includes("(other")), "keeping the model Auto picked");
  store.put("job", { ...again.job, status: "running", attempts: 3 });
  await new Runner(store, jobServices(model, clock).services, QUICK_JOB, FAST).alarm();
  expect(store.after(0).at(-1).type === "failed", "after three starts, it gives up and says so");
}

console.log("The job: what Dream remembers comes first");
{
  const clock = { now: () => Date.now() };
  const store = memoryStore();
  const model = fakeModelOf({
    gaps: () => stream(pieces(JSON.stringify({ questions: [{ question: "Where do you live?", topic: "Home", options: [], personal: true, typing: true, remembered: "Home city" }, { question: "Which Mercury?", topic: "Subject", options: ["The planet", "The element"], personal: false, typing: false, remembered: "" }] }))),
    write: (index) => (index === 0 ? stream([{ hang: true }]) : stream(pieces(JSON.stringify(page())))),
  });
  const runner = new Runner(store, jobServices(model, clock, { tools: fakeTools({ memory: async () => confirmedFacts(FACTS) }) }).services, QUICK_JOB, FAST);
  await runner.start(JOB, REQUEST);
  await runner.alarm();
  const asked = store.after(0).find((event) => event.type === "asking");
  expect(asked?.questions.length === 1 && asked.questions[0].text === "Which Mercury?", "only the question Dream can't answer waits, the one whose topic the model named answered");
  await runner.answer(JOB.owner, { answers: [{ question: { text: "Which Mercury?" }, choice: "The element" }] });
  await runner.alarm();
  const done = store.after(0).at(-1);
  expect(done.type === "done" && done.surface.answers.map((answer) => answer.choice).join("|") === "Pune, Mumbai|The element" && done.surface.answers[0].isRemembered, "the page is built for what Dream remembered, then what the user said");
}

console.log("The job: the phone's tools");
{
  const clock = { now: () => Date.now() };
  const store = memoryStore();
  const model = fakeModelOf({ write: callsNotes });
  const runner = new Runner(store, jobServices(model, clock).services, { ...QUICK_JOB, deviceWait: 600 }, FAST);
  await runner.start(JOB, { ...REQUEST, deviceTools: [NOTES] });
  const running = runner.alarm();
  let event;
  for (let tries = 0; tries < 300 && !event; tries++) {
    await pause(10);
    event = store.after(0).find((item) => item.type === "deviceTool");
  }
  expect(event?.call.name === "notes_search" && event.call.arguments === '{"query":"trip"}' && /^[0-9a-f-]{36}$/.test(event.call.id), "a call to one of the phone's tools is an event, with an id of its own");
  expect(event.deadline > Date.now() && event.deadline <= Date.now() + 600, "and when the server stops waiting on it");
  expect((await runner.output("someone-else", { id: event.call.id, output: "x" })).status === 404, "only the page's own account may answer it");
  expect((await runner.output(JOB.owner, { id: "not-waiting", output: "x" })).status === 409 && (await runner.output(JOB.owner, { id: event.call.id })).status === 400, "an id that isn't waiting is a conflict, and an answer has its output");
  expect((await runner.output(JOB.owner, { id: event.call.id, output: "Three notes about the trip.", service: "Notes", source: { name: "trip notes", kind: "connection", parameters: {}, fields: [{ name: "count", value: 3 }] } })).status === 200, "the owner's answer is taken");
  await running;
  const done = store.after(0).at(-1);
  expect((await runner.output(JOB.owner, { id: event.call.id, output: "again" })).status === 409 && !store.after(0).some((item) => item.type === "deviceTool"), "once it's answered it isn't waiting, and the call leaves the log, so a phone catching up never runs it twice");
  expect(model.calls.write[1].messages.at(-1).content === "Three notes about the trip." && done.type === "done" && done.surface.services?.join() === "Notes" && done.surface.sources?.[0]?.name === "tripNotes", "and the page goes on with what it returned");

  // Nobody answers: the app isn't open.
  const quiet = memoryStore();
  const unanswered = fakeModelOf({ write: callsNotes });
  const nobody = new Runner(quiet, jobServices(unanswered, clock).services, { ...QUICK_JOB, deviceWait: 600 }, FAST);
  await nobody.start(JOB, { ...REQUEST, deviceTools: [NOTES] });
  const started = Date.now();
  await nobody.alarm();
  const lines = quiet.after(0).filter((item) => item.type === "log").map((item) => item.line);
  expect(unanswered.calls.write[1].messages.at(-1).content === "Notes couldn't answer this time. Build the screen without it, and don't claim anything about what it holds." && Date.now() - started >= 600, "with no answer in its time (60 seconds; 600 ms here), the model is told it couldn't be read");
  expect(quiet.after(0).at(-1).type === "done" && !lines.some((line) => line.includes("stopped making progress") || line.includes("stopped after")), `and the page carries on: the wait, longer than a stall's ${FAST.patience} ms, isn't taken for a stalled model`);
  expect(lines.includes("The phone didn't answer notes_search, so it couldn't be read") && !quiet.after(0).some((item) => item.type === "deviceTool"), "the log says so, and the call is gone from it");
}

console.log("The job: a change is counted as one");
{
  const store = memoryStore();
  const model = fakeModelOf({ write: () => stream(pieces(JSON.stringify(page()))) });
  const { services: jobs, counted, finished } = jobServices(model, { now: () => Date.now() });
  const runner = new Runner(store, jobs, QUICK_JOB, FAST);
  await runner.start(JOB, { ...REQUEST, editing: { surface: CURRENT, instruction: "shorter", focus: "b1" } });
  await runner.alarm();
  expect(counted.map(([event]) => event).join() === "page_changed" && counted[0][1].pointed_at_block === true && counted[0][1].blocks === 2 && finished.length === 1, "a change is counted as Composer counts one, not as a page asked for, and kept");
}

// MARK: - What's kept in sync

console.log("The page in sync");
{
  const question = { text: "Which Mercury?", topic: "Subject", options: ["The planet"], allowsTyping: false, isPersonal: false };
  const surface = { title: "Mercury", summary: "s", blocks: [], answers: [{ question, choice: "The planet", isRemembered: false }], locale: { language: "en", measurementSystem: "metric" } };
  const at = Date.UTC(2026, 9, 29, 10, 20, 30, 456);
  const item = surfaceItem(REQUEST.pageID, { intent: "tell me about mercury", surface, modelName: "Auto → Grok 4.7 · low", log: ["Request: tell me about mercury", "Done in 9.1s"], at });
  const expected =
    '{"kind":"surface","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","parent":null,"format":1,"updatedAt":1793269230456,"deleted":false,"body":' +
    '{"createdAt":"2026-10-29T10:20:30.456Z","editRequests":[],"generationLog":["Request: tell me about mercury","Done in 9.1s"],' +
    '"history":[{"answers":[{"choice":"The planet","isRemembered":false,"question":{"allowsTyping":false,"isPersonal":false,"options":["The planet"],"text":"Which Mercury?","topic":"Subject"}}],"at":"2026-10-29T10:20:30.456Z","kind":"asked","text":"tell me about mercury"}],' +
    '"intent":"tell me about mercury","modelName":"Auto → Grok 4.7 · low","openCount":0,"seeded":[],' +
    '"template":{"answers":[{"choice":"The planet","isRemembered":false,"question":{"allowsTyping":false,"isPersonal":false,"options":["The planet"],"text":"Which Mercury?","topic":"Subject"}}],"blocks":[],"locale":{"language":"en","measurementSystem":"metric"},"summary":"s","title":"Mercury"},' +
    '"updatedAt":"2026-10-29T10:20:30.456Z","values":{}}}';
  expect(JSON.stringify(item) === expected, "a surface item whose body is SurfacePayload as SyncCoding writes it: sorted keys, ISO dates with milliseconds, nothing for nil");
  expect(surfacePayload({ intent: "x", surface, modelName: "", log: [], at, photo: "PHOTO-ID-1234" }).photo === "PHOTO-ID-1234", "and the photo's id, when it has one");
  const long = Array.from({ length: 3_000 }, (_, i) => `line ${i} ${"x".repeat(90)}`);
  const trimmed = surfaceItem(REQUEST.pageID, { intent: "x", surface, modelName: "", log: long, at });
  expect(trimmed.body.generationLog.length === 200 && trimmed.body.generationLog[0] === long[2_800], "a page grown too big lets its log go first, as the app's sync does");
}

console.log("A change in sync, onto the page the account keeps");
{
  const at = Date.UTC(2026, 9, 29, 10, 20, 30, 456);
  const before = { title: "Bill", summary: "s", inputs: [{ name: "people", label: "People", initial: 3 }, { name: "tip", label: "Tip", initial: 10 }], outputs: [], blocks: [] };
  const after = { title: "Bill", summary: "s", inputs: [{ name: "people", label: "People", initial: 4 }, { name: "tip", label: "Tip", initial: 10 }, { name: "tax", label: "Tax", initial: 5 }], outputs: [], blocks: [] };
  const stored = {
    createdAt: "2026-10-20T08:00:00.000Z", editRequests: [], generationLog: ["Request: split a bill"],
    history: [{ answers: [], at: "2026-10-20T08:00:00.000Z", kind: "asked", text: "split a bill" }],
    intent: "split a bill", lastOpenedAt: "2026-10-28T08:00:00.000Z", modelName: "Grok", openCount: 4, photo: "PHOTO-1234-ABCD", seeded: ["groceries"],
    template: before, updatedAt: "2026-10-20T08:00:00.000Z", values: { people: 5, tip: 12, gone: 1 },
  };
  const change = { kind: "changed", text: "make it 4 people", request: "make it 4 people", answers: [], before, surface: after, modelName: "Auto → Grok 4.7 · high", log: ["Change: make it 4 people", "Done in 5.0s"], narrowsValues: true, at };
  const item = changedItem(REQUEST.pageID, { updatedAt: Date.UTC(2026, 9, 20, 8), body: stored }, change);
  const expected =
    '{"kind":"surface","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","parent":null,"format":1,"updatedAt":1793269230456,"deleted":false,"body":' +
    '{"createdAt":"2026-10-20T08:00:00.000Z","editRequests":["make it 4 people"],"generationLog":["Request: split a bill","Change: make it 4 people","Done in 5.0s"],' +
    '"history":[{"answers":[],"at":"2026-10-20T08:00:00.000Z","kind":"asked","text":"split a bill"},{"answers":[],"at":"2026-10-29T10:20:30.456Z","kind":"changed","text":"make it 4 people"}],' +
    '"intent":"split a bill","lastOpenedAt":"2026-10-28T08:00:00.000Z","modelName":"Auto → Grok 4.7 · high","openCount":4,"photo":"PHOTO-1234-ABCD","seeded":["groceries"],' +
    '"template":{"blocks":[],"inputs":[{"initial":4,"label":"People","name":"people"},{"initial":10,"label":"Tip","name":"tip"},{"initial":5,"label":"Tax","name":"tax"}],"outputs":[],"summary":"s","title":"Bill"},' +
    '"updatedAt":"2026-10-29T10:20:30.456Z","values":{"tip":12}}}';
  expect(JSON.stringify(item) === expected, "a change: the new page, its turn after the account's own and the change asked for, its log added, and only the numbers whose inputs start where they did; everything else as it was");
  expect(JSON.stringify(keptValues({ people: 5, tip: 12 }, before, after)) === '{"tip":12}' && JSON.stringify(keptValues({ tip: 12 }, before, { ...after, inputs: [] })) === "{}", "the user's numbers as the app keeps them after a change");

  const question = { allowsTyping: false, isPersonal: false, options: ["The planet", "The element"], text: "Which Mercury?", topic: "Subject" };
  const planet = { choice: "The planet", isRemembered: false, question };
  const element = { choice: "The element", isRemembered: false, question };
  const old = { ...stored, history: undefined, editRequests: ["make it shorter"], template: { ...before, answers: [planet] } };
  delete old.history;
  const words = "I mean The element. (You asked Which Mercury? and I said The planet.) Rebuild the screen for that.";
  const answered = changedItem(REQUEST.pageID, { updatedAt: Date.UTC(2026, 9, 20, 8), body: old }, { ...change, kind: "answered", text: "The element", request: words, answers: [element], before: old.template, surface: { ...before, answers: [element] } });
  expect(
    JSON.stringify(answered.body.history) === JSON.stringify([{ answers: [planet], at: "2026-10-20T08:00:00.000Z", kind: "asked", text: "split a bill" }, { answers: [], at: "2026-10-20T08:00:00.000Z", kind: "changed", text: "make it shorter" }, { answers: [element], at: "2026-10-29T10:20:30.456Z", kind: "answered", text: "The element" }]) &&
      answered.body.editRequests.join("|") === `make it shorter|${words}` && JSON.stringify(answered.body.values) === '{"people":5,"tip":12}',
    "a different answer: on a page from before turns were kept, its request and changes first, as SavedSurface.history makes them; then the answer, in the user's words",
  );
  const again = changedItem(REQUEST.pageID, { updatedAt: Date.UTC(2026, 9, 30), body: stored }, { ...change, kind: "rebuilt", text: "split a bill", request: null, answers: [], narrowsValues: false });
  expect(again.body.history.at(-1).kind === "rebuilt" && again.body.history.at(-1).text === "split a bill" && again.body.editRequests.length === 0 && JSON.stringify(again.body.values) === "{\"gone\":1,\"people\":5,\"tip\":12}", "made again: a turn of its own, no change asked for, every number kept");
  expect(again.updatedAt === Date.UTC(2026, 9, 30) + 1 && again.body.updatedAt === new Date(Date.UTC(2026, 9, 30) + 1).toISOString(), "stamped after what's kept, so it's the latest");
}

// MARK: - What's asked for

console.log("POST /api/compose's body");
{
  const good = readComposeRequest({ ...REQUEST, model: "auto", thinking: "low", image: "data:image/jpeg;base64,/9j/4AAQ" });
  expect("request" in good && good.request.image === "/9j/4AAQ" && good.request.locale.currency === "INR", "a request as the app sends it");
  expect("error" in readComposeRequest({ ...REQUEST, pageID: "not-a-uuid" }) && "error" in readComposeRequest({ ...REQUEST, request: "" }) && "error" in readComposeRequest({ ...REQUEST, image: "iVBORw0KGgo=" }) && "error" in readComposeRequest({ ...REQUEST, locale: {} }), "and what isn't one");
  const changing = readComposeRequest({ ...REQUEST, editing: { surface: CURRENT, instruction: "  make it monthly ", focus: "b2" }, deviceTools: [NOTES, { name: "travel", description: "Travel times.", parameters: { type: "object" } }] });
  expect(changing.request?.editing.instruction === "make it monthly" && changing.request.editing.focus === "b2" && changing.request.deviceTools.map((tool) => tool.name).join() === "notes_search,travel" && changing.request.deviceTools[0].service === "Notes", "a change, and the phone's tools");
  expect("request" in readComposeRequest({ ...REQUEST, editing: { surface: CURRENT, answer: { question: QUESTION, choice: "" } } }) && "request" in readComposeRequest({ ...REQUEST, editing: { surface: CURRENT, again: true } }), "a different answer, or made again");
  const refused = [
    { editing: { surface: CURRENT, instruction: "x", again: true } },
    { editing: { surface: CURRENT } },
    { editing: { surface: { title: "no blocks" }, instruction: "x" } },
    { editing: { surface: CURRENT, answer: { choice: "x" } } },
    { deviceTools: [{ ...NOTES, name: "has spaces" }] },
    { deviceTools: [NOTES, NOTES] },
    { deviceTools: [{ name: "x", description: "y" }] },
  ];
  expect(refused.every((fields) => "error" in readComposeRequest({ ...REQUEST, ...fields })), "and a change or a tool that isn't one");
}

console.log("The stand-in model");
{
  const gap = await (fakeModel({ stream: false, messages: [{ role: "user", content: "Request: tell me about Mercury" }], response_format: { type: "json_schema", json_schema: { schema: { title: "WireGaps" } } } })).json();
  expect(JSON.parse(gap.choices[0].message.content).questions[0].question === "Which Mercury?", "asks which Mercury");
  const call = await (fakeModel({ stream: false, messages: [{ role: "user", content: "Request: look up Ada Lovelace" }], tools: [{ type: "function", function: { name: "lookup" } }] })).json();
  expect(call.choices[0].message.tool_calls[0].function.name === "lookup", "looks up what it's asked to");
  const written = await (fakeModel({ stream: false, messages: [{ role: "user", content: "Request: a bill\n\nBefore building, the user answered:\n- Who pays? Me\nBuild the screen for these answers." }] })).json();
  const wire = JSON.parse(written.choices[0].message.content);
  expect(wire.title === "A bill" && wire.blocks[1].items.some((item) => item.value === "Who pays? Me"), "writes a page that shows the answers it was given");
}

console.log("Wikipedia");
{
  expect(wikipedia("nb-NO") === "no" && wikipedia("hi") === "hi" && wikipedia("fil") === "tl", "the Wikipedia for a language");
  const asked = [];
  const fetcher = async (url) => {
    asked.push(new URL(url));
    return Response.json({ query: { pages: [{ title: "Mercury (mythology)", index: 2, extract: "A god." }, { title: "Mercury (disambiguation)", index: 0, extract: "May refer to", pageprops: { disambiguation: "" } }, { title: "Mercury (planet)", index: 1, extract: "A planet.", fullurl: "https://en.wikipedia.org/wiki/Mercury_(planet)", thumbnail: { source: "https://upload.wikimedia.org/x.jpg" } }] } });
  };
  const found = await find("mercury planet", "en", fetcher);
  expect(found?.title === "Mercury (planet)" && found.imageURL === "https://upload.wikimedia.org/x.jpg" && asked[0].searchParams.get("gsrsearch") === "mercury planet" && asked[0].host === "en.wikipedia.org", "the best article that isn't a disambiguation and shares a word with the subject");
}

console.log(failures ? `\n${failures} failed` : "\nAll passed");
process.exit(failures ? 1 : 0);
