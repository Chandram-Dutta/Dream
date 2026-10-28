// Auto: which model makes a page, and how long it thinks, picked per page from what was asked.
//
// Cloudflare's Clef Flash, a small decision model on Workers AI, reads the request (and the
// photo, if there is one) and answers a few typed questions: what kind of page it is, whether it
// needs facts that change, whether it's written in English, and how hard it is (QUESTIONS). Those
// answers pick a row of the table below, which names the models to try, cheapest good enough
// first; the first one the account may use makes the page (route.ts). Clef is asked once a page:
// about 550 tokens, two thousandths of a cent, answered in about half a second (0.45 s median,
// under a second nine times in ten, through the gateway on 2026-10-27).
//
// The table is data: change a row and the router follows. Each row says why, with the numbers
// from the bench behind it (README.md, "Routing").
//
// No imports, so test/unit.mjs runs it in Node.

import type { Effort } from "./models";

/** What the app names as its model for Auto: listed in Account for testers (usage.ts), and asked
 * of /api/model directly by anything that hasn't asked /api/route first (model.ts). */
export const AUTO = "auto";

/** What a page is mostly about, as Clef reads the request. */
export const TOPICS = ["money", "science", "lists", "figures", "other"] as const;
export type Topic = (typeof TOPICS)[number];

/** A table row: the topic, unless the page needs a photo read, live facts, or another language,
 * which decide more about which model does well than the topic does. */
export type Category = Topic | "photo" | "live" | "language";
export type Difficulty = "easy" | "hard";

/** One model and how long it thinks. */
export interface Pick {
  model: string;
  effort: Effort;
}

/** The models a row tries, in order, and why. The first one an account may use makes the page. */
export interface Row {
  picks: Pick[];
  why: string;
}

const pick = (model: string, effort: Effort): Pick => ({ model, effort });

// The table, from Dream's page bench (Tools/router-bench/bench.py; README.md, "Routing"): 16
// requests in 7 categories, each made through the real pipeline and a local server, scored 0–10 by
// Grok 4.7 against the same rubric and ground truth (a page not made scores 0). These numbers are
// from the merged code of 2026-10-28, after the harness began sending Workers AI's and Sarvam's
// models their tools before the schema. Per category, pages made · mean score · median time ·
// mean cost:
//
//                       money             science           lists              live              photo             language          figures
//   Grok 4.7 low        2/2 10  48s 4.8¢  2/2 9.0 46s 4.7¢  2/2 10  32s 5.2¢   2/2 10  29s 7.8¢  3/3 9.3 44s 6.6¢  3/3 9.3 51s 5.9¢  2/2 10  48s 6.5¢
//   Grok 4.20 Fast                                                             2/2 9.0 12s 2.6¢
//   DeepSeek, none      2/2 7.0 80s 1.1¢  2/2 9.0 24s 0.3¢  2/2 5.0 158s 1.7¢  2/2 5.5 20s 0.3¢  3/3 7.0 56s 2.7¢  3/3 7.7 83s 1.4¢  2/2 8.0 56s 0.4¢
//   DeepSeek, low       2/2 6.0 101s 1.5¢ 2/2 9.5 81s 0.9¢  2/2 5.0 39s 0.5¢   2/2 8.5 37s 1.1¢  3/3 8.0 66s 3.4¢  3/3 8.7 63s 0.7¢  2/2 10  82s 1.0¢
//   Sarvam's DeepSeek   2/2 8.0 66s 1.0¢  2/2 9.5 75s 1.1¢  2/2 9.0 38s 0.5¢   2/2 10  24s 0.8¢  3/3 8.0 81s 1.2¢  3/3 7.7 40s 1.2¢  2/2 10  65s 0.9¢
//
// ("DeepSeek" is DeepSeek V4.1 Flash on Workers AI; Sarvam's is the same model, hosted by Sarvam,
// thinking low.) A pick is good enough for a row when it made every page of the category, scored
// none below 5 there, and averaged 8 or more on the row's own requests (the category's, where the
// bench had none at that difficulty). The good enough picks come cheapest first, and every row
// ends on Grok 4.7 thinking low, everyone's model, so an account that may use only the default
// still gets a page, and a plan that can't run a pick as benched gets the next.
//
// Three caveats:
// - Speed. The DeepSeeks now look things up and think twice on a page's last round, so they take
//   about a minute a page, and Grok 4.7 reads most of its prompt from cache: Auto saves money, not
//   time.
// - Workers AI's per-minute limit. Its error 3021 turned away 13 of 32 DeepSeek pages when 16
//   started at once; those were made again one at a time.
// - Sample size. One run of 16 requests, so a row's numbers are one or two pages.
//
// The first bench (2026-10-27, before the harness changes) is in README.md. Thinking high never
// paid there: Grok 4.7 high scored 9.0 to low's 9.6, at twice the time, so no row asks for it.
export const TABLE: Record<Category, Record<Difficulty, Row>> = {
  money: {
    // An EMI: Sarvam's DeepSeek 10, DeepSeek none 9, Grok 10. A bill split with a catch: Grok 10, the DeepSeeks 5 and 6.
    easy: { picks: [pick("sarvam-deepseek-v4.1-flash", "low"), pick("deepseek-v4.1-flash", "none"), pick("grok-4.7", "low")], why: "Simple sums: Sarvam's DeepSeek V4.1 Flash scored 10 like Grok, for 1¢ to Grok's 4.8¢" },
    hard: { picks: [pick("grok-4.7", "low")], why: "Money with a catch: Grok 4.7 scored 10; the DeepSeeks 5 and 6" },
  },
  science: {
    // Deriving the quadratic formula, time dilation: DeepSeek none 9 and 9, low 9 and 10, Sarvam's 10 and 9; Grok 8 and 10.
    easy: { picks: [pick("deepseek-v4.1-flash", "none"), pick("deepseek-v4.1-flash", "low"), pick("sarvam-deepseek-v4.1-flash", "low"), pick("grok-4.7", "low")], why: "Explainers: DeepSeek V4.1 Flash, no thinking, scored 9 like Grok, in 24 s for 0.3¢" },
    hard: { picks: [pick("deepseek-v4.1-flash", "none"), pick("deepseek-v4.1-flash", "low"), pick("sarvam-deepseek-v4.1-flash", "low"), pick("grok-4.7", "low")], why: "Explainers: DeepSeek V4.1 Flash, no thinking, scored 9 like Grok, in 24 s for 0.3¢" },
  },
  lists: {
    // A packing list for a winter trek, a habit tracker: Sarvam's DeepSeek 8 and 10, Grok 10 and 10; DeepSeek none 5 and 5, low 8 and 2.
    easy: { picks: [pick("sarvam-deepseek-v4.1-flash", "low"), pick("grok-4.7", "low")], why: "Lists: Sarvam's DeepSeek V4.1 Flash scored 9 to Grok's 10, for a tenth of the cost" },
    hard: { picks: [pick("sarvam-deepseek-v4.1-flash", "low"), pick("grok-4.7", "low")], why: "Lists: Sarvam's DeepSeek V4.1 Flash scored 9 to Grok's 10, for a tenth of the cost" },
  },
  figures: {
    // A pendulum to play with: every model 10. A water molecule in 3D: Sarvam's DeepSeek and DeepSeek low 10, DeepSeek none 6.
    easy: { picks: [pick("sarvam-deepseek-v4.1-flash", "low"), pick("deepseek-v4.1-flash", "low"), pick("grok-4.7", "low")], why: "Simulations and 3D: Sarvam's DeepSeek V4.1 Flash scored 10 like Grok, for 0.9¢" },
    hard: { picks: [pick("deepseek-v4.1-flash", "none"), pick("sarvam-deepseek-v4.1-flash", "low"), pick("deepseek-v4.1-flash", "low"), pick("grok-4.7", "low")], why: "Simulations: DeepSeek V4.1 Flash, no thinking, scored 10 like Grok, for 0.4¢" },
  },
  other: {
    // Not benched as a category: facts, advice and how-tos stay on the default.
    easy: { picks: [pick("grok-4.7", "low")], why: "Grok 4.7, Dream's default, which looks things up and explains" },
    hard: { picks: [pick("grok-4.7", "low")], why: "Grok 4.7, Dream's default, which looks things up and explains" },
  },
  photo: {
    // A restaurant bill to split, a plant: DeepSeek low 8 and 9, Grok 9 and 9, Sarvam's 5 and 9, DeepSeek none 3 and 8.
    // A maths worksheet: Sarvam's DeepSeek 10, DeepSeek none 10, Grok 10, DeepSeek low 7.
    easy: { picks: [pick("deepseek-v4.1-flash", "low"), pick("grok-4.7", "low")], why: "Photos: DeepSeek V4.1 Flash, thinking low, read the bill and the plant right (8, 9) for half Grok's cost" },
    hard: { picks: [pick("sarvam-deepseek-v4.1-flash", "low"), pick("grok-4.7", "low")], why: "A worksheet to solve: Sarvam's DeepSeek V4.1 Flash solved it from the photo (10) for 1.2¢" },
  },
  live: {
    // The dollar in rupees right now, the latest Formula 1 standings: Sarvam's DeepSeek 10 and 10, DeepSeek low 9 and 8,
    // Grok 4.20 Fast 8 and 10, Grok 4.7 10 and 10; DeepSeek none didn't look the race up and gave no result (1).
    easy: { picks: [pick("sarvam-deepseek-v4.1-flash", "low"), pick("deepseek-v4.1-flash", "low"), pick("grok-4.20-fast", "none"), pick("grok-4.7", "low")], why: "Live facts: Sarvam's DeepSeek V4.1 Flash looked them up and scored 10, in 24 s for 0.8¢" },
    hard: { picks: [pick("sarvam-deepseek-v4.1-flash", "low"), pick("deepseek-v4.1-flash", "low"), pick("grok-4.20-fast", "none"), pick("grok-4.7", "low")], why: "Live facts: Sarvam's DeepSeek V4.1 Flash looked them up and scored 10, in 24 s for 0.8¢" },
  },
  language: {
    // Compound interest and photosynthesis in Hindi, a trip in Tamil: DeepSeek low 10, 10, 6; Grok 10, 9, 9;
    // Sarvam's DeepSeek 10, 7, 6; DeepSeek none 10, 5, 8.
    easy: { picks: [pick("deepseek-v4.1-flash", "low"), pick("grok-4.7", "low")], why: "Other languages: DeepSeek V4.1 Flash, thinking low, scored 8.7 to Grok's 9.3 in Hindi and Tamil, for 0.7¢" },
    hard: { picks: [pick("deepseek-v4.1-flash", "low"), pick("grok-4.7", "low")], why: "Other languages: DeepSeek V4.1 Flash, thinking low, scored 8.7 to Grok's 9.3 in Hindi and Tamil, for 0.7¢" },
  },
};

/** The models that took the bench's photos (Sarvam 105B and Sarvam's GLM 5.3 refused them): a
 * photo row only names these. */
export const READS_PHOTOS = new Set(["grok-4.7", "grok-4.20-fast", "deepseek-v4.1-flash", "glm-5.3-flash", "sarvam-deepseek-v4.1-flash", "sarvam-gemma-4"]);

/** What Auto answers when it can't ask Clef, or Clef's answer makes no sense: everyone's model,
 * thinking a little, as if Auto weren't on. */
export const DEFAULT_PICK: Pick = pick("grok-4.7", "low");

// MARK: - Asking Clef

/** Clef Flash: 9B, $0.038 per million input tokens and nothing for output, 24K tokens of context,
 * and it reads images. A request and a photo come to about 1,500 tokens. */
export const CLEF = { model: "@cf/cloudflare/clef-flash", selector: "clef-flash", inputPrice: 0.038 };

/** Clef's level for "hard", on the 0 to 3 scale of the difficulty question. */
export const HARD_FROM = 1.5;

/** The questions Clef answers about a request, in its typed form: `choice` gives a probability
 * per option, `noul` the probability of yes, `score` a probability-weighted level. */
export const QUESTIONS = {
  topic: {
    type: "choice",
    instructions: "What kind of page does this request need?",
    criteria: {
      money: "Working out money or numbers: prices, loans, EMIs, interest, bills, budgets, tips, unit conversions",
      science: "Explaining science or maths: how something works, a formula, a derivation, a proof, solving a problem",
      lists: "A list or plan: packing lists, checklists, schedules, itineraries, routines, habit trackers",
      figures: "Something to watch or play with: a simulation, an interactive model, a 3D object or scene, a chart or diagram",
      other: "Anything else: facts about a person, place or thing, advice, comparisons, how-tos",
    },
  },
  fresh: {
    type: "noul",
    instructions: "Does a good answer depend on facts that change and must be looked up now, like today's exchange rates or prices, news, recent results, standings, weather or opening hours?",
    criteria: { true: "Needs current information from the web", false: "Timeless knowledge, or only the person's own numbers" },
  },
  foreign: {
    type: "noul",
    instructions: "Is the request written in a language other than English?",
  },
  difficulty: {
    type: "score",
    instructions: "How hard is it to make a correct, complete page for this request?",
    criteria: [
      "Simple: one fact, one formula, or a short list",
      "Some steps: a few connected quantities, or a plan with some structure",
      "Careful: several interacting quantities, exact rules or tricky arithmetic, or a long plan",
      "Demanding: long derivations or proofs, multi-step problems, or expert depth",
    ],
  },
} as const;

/** What Clef is sent: the request as state, the questions, and the photo when there is one. */
export function clefInput(request: string, hasImage: boolean, image?: string): Record<string, unknown> {
  const state = [
    "Someone asked Dream, an app that builds one interactive page (a calculator, an explainer, a list, a chart, live data) for each request:",
    JSON.stringify(request),
    hasImage ? (image ? "They attached the photo above." : "They attached a photo.") : "",
  ].filter(Boolean).join("\n");
  return { model: CLEF.selector, state, questions: QUESTIONS, ...(image ? { images: [image] } : {}) };
}

/** What Clef said, as the router reads it. */
export interface Signals {
  topic: Topic;
  /** The probability it needs facts looked up now. */
  fresh: number;
  /** The probability it isn't in English. */
  foreign: number;
  /** 0 (simple) to 3 (demanding). */
  difficulty: number;
  photo: boolean;
}

const isObject = (value: unknown): value is Record<string, unknown> => value !== null && typeof value === "object" && !Array.isArray(value);
const probability = (value: unknown): number | null => (typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1 ? value : null);

/** Clef's answers, or null when they aren't all there and the right shape, so the router falls
 * back to the default rather than guessing. */
export function readAnswers(output: unknown, photo: boolean): Signals | null {
  // The binding returns the model's object; the REST API wraps it in `result`.
  const body = isObject(output) && isObject(output.result) ? output.result : output;
  if (!isObject(body) || !isObject(body.answers)) return null;
  const { topic, fresh, foreign, difficulty } = body.answers;
  if (!isObject(topic) || !isObject(fresh) || !isObject(foreign) || !isObject(difficulty)) return null;
  const chosen = TOPICS.find((each) => each === topic.choice);
  const freshness = probability(fresh.noul);
  const foreignness = probability(foreign.noul);
  const level = typeof difficulty.score === "number" && Number.isFinite(difficulty.score) ? Math.min(3, Math.max(0, difficulty.score)) : null;
  if (!chosen || freshness === null || foreignness === null || level === null) return null;
  return { topic: chosen, fresh: freshness, foreign: foreignness, difficulty: level, photo };
}

/** What a Clef request cost, in millionths of a dollar, from the input tokens it reports. */
export function clefCost(output: unknown): { tokensIn: number; cost: number } {
  const body = isObject(output) && isObject(output.result) ? output.result : output;
  const tokens = isObject(body) && isObject(body.usage) && typeof body.usage.input_tokens === "number" && body.usage.input_tokens >= 0 ? body.usage.input_tokens : 0;
  return { tokensIn: tokens, cost: tokens * CLEF.inputPrice };
}

// MARK: - Deciding

/** Mostly written in a script other than Latin (Devanagari, Tamil, Arabic, Han, …): Clef's
 * "foreign" answer, checked without asking. */
export function nonLatin(text: string): boolean {
  const letters = text.match(/\p{L}/gu) ?? [];
  if (letters.length < 4) return false;
  const latin = text.match(/\p{Script=Latin}/gu) ?? [];
  return (letters.length - latin.length) / letters.length > 0.4;
}

/** The row a request lands on. A photo needs a model that reads it; another language one that
 * writes it well, which on the bench was also the one that looked live facts up best; live facts
 * one that looks them up; otherwise the topic decides. */
export function classify(signals: Signals, request = ""): { category: Category; difficulty: Difficulty } {
  const difficulty: Difficulty = signals.difficulty >= HARD_FROM ? "hard" : "easy";
  if (signals.photo) return { category: "photo", difficulty };
  if (signals.foreign >= 0.5 || nonLatin(request)) return { category: "language", difficulty };
  if (signals.fresh >= 0.5) return { category: "live", difficulty };
  return { category: signals.topic, difficulty };
}

/** The first of a row's picks this account may use, as it was benched (`usable` says, with the
 * account's models and thinking levels), or null: then the default. A pick that would have to
 * think differently on this plan isn't the one the bench measured, so the next is tried. */
export function firstUsable(row: Row, usable: (pick: Pick) => boolean): Pick | null {
  return row.picks.find(usable) ?? null;
}

/** A row without asking Clef, for a model request that names "auto" itself (model.ts): only what
 * the request shows on its face, from its first user message and whether any message carries a
 * photo, which is the same for every request of a page. */
export function guess(messages: unknown): { category: Category; difficulty: Difficulty } {
  const list = Array.isArray(messages) ? messages.filter(isObject) : [];
  const parts = (content: unknown): unknown[] => (Array.isArray(content) ? content : [content]);
  if (list.some((message) => parts(message.content).some((part) => isObject(part) && part.type === "image_url"))) return { category: "photo", difficulty: "easy" };
  const first = list.find((message) => message.role === "user");
  const text = first ? parts(first.content).map((part) => (typeof part === "string" ? part : isObject(part) && typeof part.text === "string" ? part.text : "")).join("\n") : "";
  // Dream's prompts are English around the request, so a run of another script is the tell.
  const other = (text.match(/\p{L}/gu) ?? []).length - (text.match(/\p{Script=Latin}/gu) ?? []).length;
  return other >= 12 ? { category: "language", difficulty: "easy" } : { category: "other", difficulty: "easy" };
}
