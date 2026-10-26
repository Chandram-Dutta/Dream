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
}

export const CATALOG: Model[] = [
  {
    id: "glm-5.3-flash",
    name: "GLM 5.3 Flash",
    note: "Fast, and the one everyone has",
    provider: "workers-ai",
    upstream: "@cf/zai-org/glm-5.3-flash",
    plus: false,
    price: { input: 0.15, cached: 0.03, output: 0.5 },
  },
  {
    id: "grok-4.7",
    name: "Grok 4.7",
    note: "The most careful, for detailed pages",
    provider: "xai",
    upstream: "grok-4.7",
    plus: true,
    price: { input: 2, cached: 0.5, output: 6 },
  },
  {
    id: "deepseek-v4.1-flash",
    name: "DeepSeek V4.1 Flash",
    note: "Quick, with a long memory for big pages",
    provider: "workers-ai",
    upstream: "@cf/deepseek-ai/deepseek-v4.1-flash-1017",
    plus: true,
    price: { input: 0.3, cached: 0.006, output: 1.2 },
  },
  {
    id: "kimi-k2.6",
    name: "Kimi K2.6",
    note: "Thinks longer before it answers",
    provider: "workers-ai",
    upstream: "@cf/moonshotai/kimi-k2.6",
    plus: true,
    price: { input: 0.95, cached: 0.16, output: 4 },
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

/** The model a request runs on: the one asked for, if this server offers it and the account may
 * use it; otherwise the default, so a lapsed subscription, an older app, or a pick from a model
 * since retired still gets a page. Nothing outside the catalogue is ever asked. */
export function choose(asked: unknown, plan: string, models: Model[], anyModel = false): Model {
  const fallback = models.find((model) => !model.plus) ?? models[0];
  const model = typeof asked === "string" ? models.find((each) => each.id === asked) : undefined;
  if (!model) return fallback;
  return !model.plus || plan === "plus" || anyModel ? model : fallback;
}
