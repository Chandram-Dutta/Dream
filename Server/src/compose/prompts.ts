// What the page loop tells the model, from the app's own words: src/generated/generation.json,
// which Tools/export-generation.sh writes from Prompts*.swift, Wire.swift and the tools
// (docs/ServerGeneration.md). Nothing here is a prompt of its own. Templates hold {{slots}};
// this fills them, and joins lists the way the Swift functions do.
//
// The instructions for writing a page are put together here from their core and each feature's
// rules, so they always agree with the tools a session offers: a feature's rules go in only
// when every tool they describe is offered, and a tool is offered only when the instructions
// describe it (`writing`).
//
// No imports, so test/compose.mjs runs it in Node.

type JSONObject = Record<string, unknown>;

const isObject = (value: unknown): value is JSONObject => value !== null && typeof value === "object" && !Array.isArray(value);

export interface ToolDefinition {
  name: string;
  description: string;
  parameters: JSONObject;
}

/** One feature's rules in the instructions, and the tools they describe (Prompts.features). */
export interface FeatureRules {
  name: string;
  rules: string;
  tools: string[];
  /** Connected services' rules, which go in only when one of a service's tools is offered. */
  connections: boolean;
}

/** src/generated/generation.json. */
export interface Generation {
  prompts: {
    /** The app's instructions as a whole, without a connected service: what `writing` puts together. */
    surface: string;
    gapCheck: string;
    /** The instructions up to {{features}}, where the features' rules go. */
    surfaceCore: string;
    featureSeparator: string;
    features: FeatureRules[];
    /** The app's instructions with a connected service, for the tests. */
    surfaceWithConnections: string;
  };
  schemas: { surface: JSONObject; gaps: JSONObject };
  tools: ToolDefinition[];
  templates: {
    gapRequest: string;
    gapRequestRemembering: string;
    surfaceRequest: { alone: string; withContext: string; withPhoto: string; withPhotoAndContext: string };
    answers: { block: string; line: string; leftToDream: string; remembered: string };
    repair: { block: string; problem: string; restating: string; screen: string; screenWithLogic: string };
    edit: { block: string; withContext: string; whole: string; pointing: string; describe: Record<string, string>; labelSeparator: string };
    changedAnswer: { said: string; saidLeft: string; left: string; leftLeft: string };
    memory: { line: string; topicSeparator: string };
  };
  toolText: {
    lookupEnough: string;
    searchEnough: string;
    readEnough: string;
    readNotAddress: string;
    readAlready: string;
    searchFailed: string;
    readFailed: string;
    webErrors: Record<string, string>;
    recall: { found: string; line: string; nothing: string };
    live: { header: string; field: string; fieldPlain: string; closing: string; failed: string };
  };
  context: { webUnavailable: string };
}

/** A question the gap check asks, as the app's Question encodes it (Dream/Engine/Answer.swift). */
export type Question = {
  text: string;
  topic: string;
  options: string[];
  allowsTyping: boolean;
  isPersonal: boolean;
};

/** What the user said to one, as the app's Answer encodes it. An empty choice is "You choose". */
export type Answer = {
  question: Question;
  choice: string;
  isRemembered: boolean;
};

/** Every {{slot}} at once, so words that look like a slot, in a request say, stay as written. */
export function fill(template: string, values: Record<string, string>): string {
  return template.replace(/\{\{(\w+)\}\}/g, (slot, name: string) => (name in values ? values[name] : slot));
}

// MARK: - The instructions, with the tools they describe

/** Whether text names a tool, as a word of its own. */
const names = (text: string, tool: string) => new RegExp(`(^|[^\\p{L}\\p{N}_])${tool.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}($|[^\\p{L}\\p{N}_])`, "u").test(text);

/** The phone's tools among those a session could offer: a connected service's, and its tool for
 * travel times, which the live rules describe with the server's live tool. */
export interface PhoneTools {
  connections: string[];
  live: string[];
}

/** The instructions for writing a page in the user's currency, and the tools to offer with them,
 * from those the session could offer. A feature's rules go in when every tool they describe is
 * offered; connected services' when one of a service's tools is. Then a tool is kept only if
 * what goes in describes it: a feature's own (the phone's travel tool goes with live), one the
 * core names (lookup, search, read), or a connected service's beside its rules. With every tool
 * the app has, and no connected service, the instructions are the app's own (Prompts.surface). */
export function writing(generation: Generation, currency: string, available: ToolDefinition[], phone: PhoneTools = { connections: [], live: [] }): { instructions: string; tools: ToolDefinition[] } {
  const offered = new Set(available.map((tool) => tool.name));
  const services = new Set(phone.connections.filter((name) => offered.has(name)));
  const theirs = new Set([...services, ...phone.live]);
  const features = generation.prompts.features.filter((feature) => feature.rules && feature.tools.every((tool) => offered.has(tool) && !theirs.has(tool)) && (!feature.connections || services.size > 0));
  const instructions = fill(generation.prompts.surfaceCore, { currency, features: features.map((feature) => feature.rules).join(generation.prompts.featureSeparator) });
  const described = new Set(features.flatMap((feature) => feature.tools));
  if (described.has("live")) for (const tool of phone.live) described.add(tool);
  const core = fill(generation.prompts.surfaceCore, { currency, features: "" });
  const connected = features.some((feature) => feature.connections);
  const tools = available.filter((tool) => described.has(tool.name) || (connected && services.has(tool.name)) || (!theirs.has(tool.name) && names(core, tool.name)));
  return { instructions, tools };
}

/** Prompts.surface(currency:): the app's instructions as a whole, for every tool it has. */
export function surfaceInstructions(generation: Generation, currency: string): string {
  return fill(generation.prompts.surface, { currency });
}

// MARK: - Asking

/** Prompts.gapRequest: the request, and the topics Dream remembers about the user. */
export function gapRequest(generation: Generation, request: string, topics: string[] = []): string {
  if (!topics.length) return fill(generation.templates.gapRequest, { request });
  return fill(generation.templates.gapRequestRemembering, { request, topics: topics.join(generation.templates.memory.topicSeparator) });
}

/** Prompts.memoryContext: what Dream remembers, as topics only, beside the request. None when
 * it remembers nothing. */
export function memoryContext(generation: Generation, topics: string[]): string[] {
  return topics.length ? [fill(generation.templates.memory.line, { topics: topics.join(generation.templates.memory.topicSeparator) })] : [];
}

/** Whether a line beside the request is the phone's own memory line, which the server's takes
 * the place of: recall reads what's synced, so the topics it lists are those recall can find. */
export function isMemoryLine(generation: Generation, line: string): boolean {
  const [before, after] = generation.templates.memory.line.split("{{topics}}");
  return line.startsWith(before) && line.endsWith(after ?? "") && line.length > before.length + (after ?? "").length;
}

/** Prompts.surfaceRequest: the request, a word about the photo, then the context, one per line. */
export function surfaceRequest(generation: Generation, request: string, hasImage: boolean, context: string[]): string {
  const templates = generation.templates.surfaceRequest;
  const template = hasImage ? (context.length ? templates.withPhotoAndContext : templates.withPhoto) : context.length ? templates.withContext : templates.alone;
  return fill(template, { request, context: context.join("\n") });
}

/** Prompts.answersContext: the answers beside the request when the page is written for them. */
export function answersContext(generation: Generation, answers: Answer[]): string[] {
  if (!answers.length) return [];
  const templates = generation.templates.answers;
  const lines = answers.map((answer) => {
    if (!answer.choice) return fill(templates.leftToDream, { question: answer.question.text });
    return fill(answer.isRemembered ? templates.remembered : templates.line, { question: answer.question.text, choice: answer.choice });
  });
  return [fill(templates.block, { lines: lines.join("\n") })];
}

/** Prompts.screen: a page in the engine's shorthand, its calculation first when it has one. */
function screen(generation: Generation, shown: { outline: string; logic: string | null }): string {
  const templates = generation.templates.repair;
  return shown.logic ? fill(templates.screenWithLogic, { logic: shown.logic, outline: shown.outline }) : fill(templates.screen, { outline: shown.outline });
}

/** Prompts.repair: the checker's problems, sent back in the session the page was written in.
 * When that session lost the request and the page (it stopped early), `restating` carries both:
 * the request as it was asked, and the page in the engine's shorthand. */
export function repairPrompt(generation: Generation, problems: string[], restating?: { asked: string; outline: string; logic: string | null }): string {
  const templates = generation.templates.repair;
  const list = problems.map((problem) => fill(templates.problem, { problem })).join("\n");
  if (!restating) return fill(templates.block, { problems: list });
  return fill(templates.restating, { asked: restating.asked, screen: screen(generation, restating), problems: list });
}

// MARK: - Changes to a page

/** What a page holds that describing a block needs, as the engine reads it. */
export interface Labels {
  /** Surface.label(of:): what the page calls a name. */
  label(name: string): string;
  /** The page's sounds and actions, by name. */
  sound(name: string): { label: string } | undefined;
  action(name: string): { kind: string; fields: Record<string, string> } | undefined;
}

/** A block, as far as describing it goes. */
export interface Pointed {
  id: string;
  kind: string;
  title: string;
  ref: string;
  over: string;
}

/** Prompts.describe: the block the user points at, in words, by its kind. Null for a kind the
 * app doesn't describe, which is then asked about as the whole screen. */
export function describeBlock(generation: Generation, block: Pointed, labels: Labels): string | null {
  const templates = generation.templates.edit.describe;
  const titled = block.title ? " titled" : "";
  const refs = block.ref.split(",").map((ref) => ref.trim()).filter(Boolean);
  let key = `${block.kind}${titled}`;
  if (block.kind === "equation" && !block.ref) key = `equation plain${titled}`;
  const action = block.kind === "action" ? labels.action(block.ref) : undefined;
  if (block.kind === "action" && !action) key = "action missing";
  const template = templates[key];
  if (template === undefined) return null;
  const label = block.kind === "sound" ? (labels.sound(block.ref)?.label ?? block.ref) : labels.label(block.ref);
  return fill(template, {
    id: block.id,
    title: block.title,
    ref: block.ref,
    Label: label,
    label: label.toLowerCase(),
    labels: refs.map((ref) => labels.label(ref)).join(generation.templates.edit.labelSeparator),
    Over: labels.label(block.over),
    actionKind: action?.kind ?? "",
    actionTitle: action ? action.fields.title || action.fields.place || "" : "",
  });
}

/** Prompts.edit: the page as it is, what the user asked to change about it (or the block they
 * point at), and the context, one per line. */
export function editPrompt(generation: Generation, change: { intent: string; outline: string; logic: string | null; instruction: string; pointing: string | null; context: string[] }): string {
  const templates = generation.templates.edit;
  const request = change.pointing ? fill(templates.pointing, { block: change.pointing, instruction: change.instruction }) : fill(templates.whole, { instruction: change.instruction });
  return fill(change.context.length ? templates.withContext : templates.block, {
    intent: change.intent,
    screen: screen(generation, change),
    request,
    context: change.context.join("\n"),
  });
}

/** Prompts.changedAnswer: a different answer to one of the questions, in the user's words. An
 * empty choice, before or now, is leaving it to Dream. */
export function changedAnswer(generation: Generation, before: Answer, choice: string): string {
  const templates = generation.templates.changedAnswer;
  const template = before.choice ? (choice ? templates.said : templates.saidLeft) : choice ? templates.left : templates.leftLeft;
  return fill(template, { question: before.question.text, before: before.choice, after: choice });
}

/** What a change says, in the user's words: the instruction (Composer.edit), or for a different
 * answer (Composer.rebuild), the change in their words, with the page's answers holding the new
 * one in place of the old. `question` is the question it changes the answer to. */
export function changeOf(generation: Generation, editing: { instruction?: string; answer?: { question: unknown; choice: string } }, pageAnswers: unknown): { instruction: string; answers: Answer[] | null; question: Question | null } {
  if (!editing.answer) return { instruction: editing.instruction ?? "", answers: null, question: null };
  const empty: Question = { text: "", topic: "", options: [], allowsTyping: false, isPersonal: false };
  const question = questionOf(editing.answer.question) ?? empty;
  const choice = editing.answer.choice;
  const given = (Array.isArray(pageAnswers) ? pageAnswers : []).filter(isObject) as Answer[];
  const same = (answer: Answer) => sameQuestion(questionOf(answer.question) ?? empty, question);
  const before = given.find(same) ?? { question, choice: "", isRemembered: false };
  return {
    instruction: changedAnswer(generation, before, choice),
    answers: given.map((answer) => (same(answer) ? { question: answer.question, choice, isRemembered: false } : answer)),
    question,
  };
}

/** A question as the app's Question decodes it, or null. */
export function questionOf(value: unknown): Question | null {
  if (!isObject(value) || typeof value.text !== "string") return null;
  return {
    text: value.text,
    topic: typeof value.topic === "string" ? value.topic : "",
    options: Array.isArray(value.options) ? value.options.filter((option): option is string => typeof option === "string") : [],
    allowsTyping: value.allowsTyping === true,
    isPersonal: value.isPersonal === true,
  };
}

/** Question's ==: every field the same. */
export function sameQuestion(a: Question, b: Question): boolean {
  return a.text === b.text && a.topic === b.topic && a.allowsTyping === b.allowsTyping && a.isPersonal === b.isPersonal && a.options.length === b.options.length && a.options.every((option, index) => option === b.options[index]);
}
