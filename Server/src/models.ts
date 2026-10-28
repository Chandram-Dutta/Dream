// The models Dream offers, and who may use which. Everyone gets the default, a fast and cheap
// model; Dream Plus can pick any of them in Account. The app asks for a model by its id here, or
// for none; the server decides, so models can change without an app update.
//
// Each model is reached through Dream's AI Gateway (model.ts): xAI's through its Responses API
// with Dream's xAI key, and Workers AI's through the Worker's AI binding, billed to the account.
// Sarvam's go straight to Sarvam with Dream's Sarvam key: the gateway's custom provider for it
// fails every request (model.ts, askSarvam).
//
// No imports, so test/unit.mjs runs it in Node.

export type Provider = "xai" | "workers-ai" | "sarvam";

export interface Model {
  /** What the app sends, and what usage is recorded under. */
  id: string;
  /** What Account shows. */
  name: string;
  /** One line under the name: what it's good for. */
  note: string;
  provider: Provider;
  /** The provider's own name for it. */
  upstream: string;
  /** Only for Dream Plus. */
  plus: boolean;
  /** Dollars per million tokens, for when the provider doesn't say what a request cost. */
  price: { input: number; cached: number; output: number };
  /** The thinking levels it takes, from least to most; empty for a model that doesn't think. A
   * level it doesn't take is moved to the nearest one it does (`fitEffort`). */
  efforts: Effort[];
  /** It holds every token to a request's JSON schema, so with one it can never start a tool
   * call: a round with tools goes first without the schema (toolsfirst.ts). True of what Workers
   * AI and Sarvam serve; Grok takes tools and a schema together. */
  toolsFirst: boolean;
}

/** How long a model thinks before it answers, from not at all to as long as it needs. */
export const EFFORTS = ["none", "low", "medium", "high", "max"] as const;
export type Effort = (typeof EFFORTS)[number];

// Benched with Dream's page bench (Tools/bench-many.sh) through the server, 2026-10-27, four
// everyday pages each. Grok 4.7 made the most careful pages (it looks facts up and explains more)
// at about $0.05 a page, and is everyone's model; Dream Plus picks how long it thinks. The rest are
// for testers (PLUS_ACCOUNTS) to try in Account: DeepSeek V4.1 Flash made every page at about
// $0.004, a little thinner, and twice as fast thinking "none", though one long list ran away;
// GLM 5.3 Flash wrote a rupee page in Spanish pesos; Kimi K2.6 took up to six minutes a page;
// Grok 4.20 Fast was no faster than 4.7 and cost more; Mistral Small 3.1 and Llama 4 Scout failed
// most pages. Thinking levels are from Workers AI's catalogue and xAI's API.
//
// Benched again 2026-10-28, seven pages each, before and after fixing the harness
// (docs/HarnessBench.md), which was more at fault than the models: the Spanish page was a repair
// that had lost its request, the runaways were padding nothing stopped, and no model here but
// Grok could call a tool with a schema on (`toolsFirst`). Since then Grok 4.7 makes every page at
// about $0.05 with most of its prompt cached; DeepSeek V4.1 Flash looks up and cites current facts
// it used to leave out, at about $0.01 a page, but takes about a minute; Gemma 4 on Sarvam
// searches too, but pads its answers, and Sarvam turns away a burst of requests.
export const CATALOG: Model[] = [
  {
    id: "grok-4.7",
    name: "Grok 4.7",
    note: "Looks things up and explains",
    provider: "xai",
    upstream: "grok-4.7",
    plus: false,
    price: { input: 2, cached: 0.5, output: 6 },
    efforts: ["low", "medium", "high"],
    toolsFirst: false,
  },
  {
    id: "grok-4.20-fast",
    name: "Grok 4.20 Fast",
    note: "Grok without thinking",
    provider: "xai",
    upstream: "grok-4.20-0309-non-reasoning",
    plus: true,
    price: { input: 2, cached: 0.5, output: 6 },
    efforts: [],
    toolsFirst: false,
  },
  {
    id: "deepseek-v4.1-flash",
    name: "DeepSeek V4.1 Flash",
    note: "Cheap; looks things up, so takes about a minute",
    provider: "workers-ai",
    upstream: "@cf/deepseek-ai/deepseek-v4.1-flash-1017",
    plus: true,
    price: { input: 0.3, cached: 0.006, output: 1.2 },
    efforts: ["none", "low", "high", "max"],
    toolsFirst: true,
  },
  {
    id: "glm-5.3-flash",
    name: "GLM 5.3 Flash",
    note: "Cheapest",
    provider: "workers-ai",
    upstream: "@cf/zai-org/glm-5.3-flash",
    plus: true,
    price: { input: 0.15, cached: 0.03, output: 0.5 },
    efforts: ["low", "high", "max"],
    toolsFirst: true,
  },
  {
    id: "kimi-k2.6",
    name: "Kimi K2.6",
    note: "Slow; thinks for minutes at high",
    provider: "workers-ai",
    upstream: "@cf/moonshotai/kimi-k2.6",
    plus: true,
    price: { input: 0.95, cached: 0.16, output: 4 },
    efforts: ["none", "high"],
    toolsFirst: true,
  },
  // Sarvam's open models (POST /v2/chat/completions). Sarvam prices in rupees per million tokens,
  // the same on every plan, reasoning billed as output (docs.sarvam.ai/api/getting-started/pricing,
  // October 2026), here at 88 rupees to the dollar. It doesn't say what a request cost, so these are
  // what's counted.
  {
    id: "sarvam-105b",
    name: "Sarvam 105B",
    note: "Sarvam's own model, made in India; thinks ~10 s first",
    provider: "sarvam",
    upstream: "sarvam-105b",
    plus: true,
    // ₹15, ₹5 cached, ₹60.
    price: { input: 0.17, cached: 0.057, output: 0.682 },
    efforts: [],
    toolsFirst: true,
  },
  {
    id: "sarvam-glm-5.3",
    name: "GLM 5.3 on Sarvam",
    note: "GLM 5.3, hosted by Sarvam",
    provider: "sarvam",
    upstream: "glm5.3",
    plus: true,
    // ₹126, ₹20 cached, ₹390.
    price: { input: 1.432, cached: 0.227, output: 4.432 },
    // Sarvam thinks at max when no level is sent; one always is.
    efforts: ["low", "high", "max"],
    toolsFirst: true,
  },
  {
    id: "sarvam-deepseek-v4.1-flash",
    name: "DeepSeek V4.1 Flash on Sarvam",
    note: "DeepSeek V4.1 Flash, hosted by Sarvam",
    provider: "sarvam",
    upstream: "deepseekv4.1-flash",
    plus: true,
    // ₹25, ₹0.50 cached, ₹105.
    price: { input: 0.284, cached: 0.0057, output: 1.193 },
    efforts: ["low", "high", "max"],
    toolsFirst: true,
  },
  {
    id: "sarvam-gemma-4",
    name: "Gemma 4 on Sarvam",
    note: "Gemma 4, hosted by Sarvam; reads photos",
    provider: "sarvam",
    upstream: "gemma4",
    plus: true,
    // ₹35, ₹10 cached, ₹90.
    price: { input: 0.398, cached: 0.114, output: 1.023 },
    efforts: [],
    toolsFirst: true,
  },
  {
    id: "mistral-small-3.1",
    name: "Mistral Small 3.1",
    note: "No thinking; failed most pages",
    provider: "workers-ai",
    upstream: "@cf/mistralai/mistral-small-3.1-24b-instruct",
    plus: true,
    price: { input: 0.351, cached: 0.351, output: 0.555 },
    efforts: [],
    toolsFirst: true,
  },
  {
    id: "llama-4-scout",
    name: "Llama 4 Scout",
    note: "No thinking; failed half its pages",
    provider: "workers-ai",
    upstream: "@cf/meta/llama-4-scout-17b-16e-instruct",
    plus: true,
    price: { input: 0.27, cached: 0.27, output: 0.85 },
    efforts: [],
    toolsFirst: true,
  },
];

/** Workers AI bills in neurons: $0.011 per 1,000, so one is 110,000 ticks of 1e-10 dollars. */
export const TICKS_PER_NEURON = 110_000;

/** The models this server offers (`MODELS`, ids separated by commas, the first the default), in
 * that order. Unknown ids are ignored; with none left, the whole catalogue. */
export function offered(list: string | undefined): Model[] {
  const ids = (list ?? "").split(",").map((id) => id.trim()).filter(Boolean);
  const chosen = ids.map((id) => CATALOG.find((model) => model.id === id)).filter((model): model is Model => model !== undefined);
  return chosen.length ? chosen : CATALOG;
}

/** The thinking level a model gets: the one asked for if it takes it, else the nearest it does,
 * leaning longer; null for a model that doesn't think, so none is sent. */
export function fitEffort(asked: string | undefined, model: Model): Effort | null {
  if (!model.efforts.length) return null;
  const wanted = EFFORTS.indexOf((asked ?? "low") as Effort);
  if (wanted < 0) return model.efforts[0];
  let best = model.efforts[0];
  for (const level of model.efforts) {
    const distance = Math.abs(EFFORTS.indexOf(level) - wanted);
    const bestDistance = Math.abs(EFFORTS.indexOf(best) - wanted);
    if (distance < bestDistance || (distance === bestDistance && EFFORTS.indexOf(level) > EFFORTS.indexOf(best))) best = level;
  }
  return best;
}

/** The thinking level an account may ask for, before it's fitted to the model: testers any,
 * Dream Plus low to high, everyone else low. */
export function allowedEffort(asked: string | undefined, plan: string, tester: boolean): string | undefined {
  if (tester) return asked;
  if (plan === "plus") return asked === "none" ? "low" : asked === "max" ? "high" : asked;
  return "low";
}

/** The model a request runs on: the one asked for, if this server offers it and the account may
 * use it; otherwise the default, so a lapsed subscription, an older app, or a pick from a model
 * since retired still gets a page. Nothing outside the catalogue is ever asked. */
export function choose(asked: unknown, plan: string, models: Model[], anyModel = false): Model {
  const fallback = models.find((model) => !model.plus) ?? models[0];
  const model = typeof asked === "string" ? models.find((each) => each.id === asked) : undefined;
  if (!model) return fallback;
  return !model.plus || plan === "plus" || anyModel ? model : fallback;
}
