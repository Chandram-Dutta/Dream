// The models Dream offers, and who may use which. Everyone gets the default, a fast and cheap
// model; Dream Plus can pick any of them in Account. The app asks for a model by its id here, or
// for none; the server decides, so models can change without an app update.
//
// Each model is reached through Dream's AI Gateway (model.ts): xAI's through its Responses API
// with Dream's xAI key, Workers AI's through the Worker's AI binding, billed to the account.
//
// No imports, so test/unit.mjs runs it in Node.

export type Provider = "xai" | "workers-ai";

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
  },
  {
    id: "deepseek-v4.1-flash",
    name: "DeepSeek V4.1 Flash",
    note: "Cheap and quick; thinking off is quicker still",
    provider: "workers-ai",
    upstream: "@cf/deepseek-ai/deepseek-v4.1-flash-1017",
    plus: true,
    price: { input: 0.3, cached: 0.006, output: 1.2 },
    efforts: ["none", "low", "high", "max"],
  },
  {
    id: "glm-5.3-flash",
    name: "GLM 5.3 Flash",
    note: "Cheapest; wrote a rupee page in Spanish once",
    provider: "workers-ai",
    upstream: "@cf/zai-org/glm-5.3-flash",
    plus: true,
    price: { input: 0.15, cached: 0.03, output: 0.5 },
    efforts: ["low", "high", "max"],
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

/** The model a request runs on: the one asked for, if this server offers it and the account may
 * use it; otherwise the default, so a lapsed subscription, an older app, or a pick from a model
 * since retired still gets a page. Nothing outside the catalogue is ever asked. */
export function choose(asked: unknown, plan: string, models: Model[], anyModel = false): Model {
  const fallback = models.find((model) => !model.plus) ?? models[0];
  const model = typeof asked === "string" ? models.find((each) => each.id === asked) : undefined;
  if (!model) return fallback;
  return !model.plus || plan === "plus" || anyModel ? model : fallback;
}
