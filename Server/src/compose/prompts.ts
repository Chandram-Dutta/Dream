// What the page loop tells the model, from the app's own words: src/generated/generation.json,
// which Tools/export-generation.sh writes from Prompts*.swift, Wire.swift and the tools
// (docs/ServerGeneration.md). Nothing here is a prompt of its own. Templates hold {{slots}};
// this fills them, and joins lists the way the Swift functions do.
//
// No imports, so test/compose.mjs runs it in Node.

type JSONObject = Record<string, unknown>;

export interface ToolDefinition {
  name: string;
  description: string;
  parameters: JSONObject;
}

/** src/generated/generation.json. */
export interface Generation {
  prompts: { surface: string; gapCheck: string };
  schemas: { surface: JSONObject; gaps: JSONObject };
  tools: ToolDefinition[];
  templates: {
    gapRequest: string;
    gapRequestRemembering: string;
    surfaceRequest: { alone: string; withContext: string; withPhoto: string; withPhotoAndContext: string };
    answers: { block: string; line: string; leftToDream: string; remembered: string };
    repair: { block: string; problem: string; restating: string; screen: string; screenWithLogic: string };
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
  };
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

/** Prompts.surface(currency:): the instructions for writing a page, in the user's currency. */
export function surfaceInstructions(generation: Generation, currency: string): string {
  return fill(generation.prompts.surface, { currency });
}

/** Prompts.gapRequest, with nothing remembered: memory recall is Stage 2, and the app sends what
 * it remembers as context lines instead. */
export function gapRequest(generation: Generation, request: string): string {
  return fill(generation.templates.gapRequest, { request });
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

/** Prompts.repair: the checker's problems, sent back in the session the page was written in.
 * When that session lost the request and the page (it stopped early), `restating` carries both:
 * the request as it was asked, and the page in the engine's shorthand. */
export function repairPrompt(generation: Generation, problems: string[], restating?: { asked: string; outline: string; logic: string | null }): string {
  const templates = generation.templates.repair;
  const list = problems.map((problem) => fill(templates.problem, { problem })).join("\n");
  if (!restating) return fill(templates.block, { problems: list });
  const screen = restating.logic ? fill(templates.screenWithLogic, { logic: restating.logic, outline: restating.outline }) : fill(templates.screen, { outline: restating.outline });
  return fill(templates.restating, { asked: restating.asked, screen, problems: list });
}

/** The tools the app offers for writing a page, by name. Memory recall, live data and connected
 * services are Stage 2, so only lookup, search and read are exported. */
export function toolDefinitions(generation: Generation, names: string[]): ToolDefinition[] {
  return generation.tools.filter((tool) => names.includes(tool.name));
}
