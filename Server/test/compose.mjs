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

// MARK: - What's asked for

console.log("POST /api/compose's body");
{
  const good = readComposeRequest({ ...REQUEST, model: "auto", thinking: "low", image: "data:image/jpeg;base64,/9j/4AAQ" });
  expect("request" in good && good.request.image === "/9j/4AAQ" && good.request.locale.currency === "INR", "a request as the app sends it");
  expect("error" in readComposeRequest({ ...REQUEST, pageID: "not-a-uuid" }) && "error" in readComposeRequest({ ...REQUEST, request: "" }) && "error" in readComposeRequest({ ...REQUEST, image: "iVBORw0KGgo=" }) && "error" in readComposeRequest({ ...REQUEST, locale: {} }), "and what isn't one");
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
