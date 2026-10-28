// Auto's pick for one page: Clef reads the request, and the table in router.ts names the model.
//
//   POST /api/route   { request, hasImage?, image? }  → { model, name, effort, category, difficulty, why }
//
// The app asks once, at the start of a page, when Auto is picked in Account
// (Dream/Generation/Providers/Route.swift), then sends every request of that page to /api/model
// naming the model and thinking level it was given. `image` is the page's photo as a small data:
// URL, so Clef can see what it shows; `hasImage` says there is one without sending it.
//
// Like /api/model it needs a session and proof that it's the app, and it's rate-limited per
// account. What Clef costs (a few hundredths of a cent a thousand pages) is counted against the
// account like any small job that isn't a page. Nothing asked is logged or kept.
//
// The pick stays inside the account's plan, as /api/model would hold it anyway: testers may get
// any model in the catalogue, everyone else those offered (`MODELS`) and the ones the table routes
// to (`routed` in models.ts); Dream Plus thinks from none to high, and the free plan none or low. If Clef can't be asked, or answers something that doesn't
// read, the answer is the default (Grok 4.7, thinking low), never an error: Auto shouldn't stop a
// page from being made.
//
// The page loop on the server (compose/) asks the same once a page, in-process (`routePage`).

import { proveApp } from "./attest";
import { signInNeeded, userFrom } from "./auth";
import type { ModelEnv } from "./model";
import { allowedEffort, choose, fitEffort, usable as modelsFor, type Effort, type Model } from "./models";
import { allowed, bodyBytes, isJSON, json, object, problem } from "./reply";
import { classify, clefCost, clefInput, CLEF, DEFAULT_PICK, firstUsable, guess, readAnswers, TABLE, type Category, type Pick, type Row, type Signals } from "./router";
import { accountOf, recordModel, type Account } from "./usage";

export interface RouteEnv extends ModelEnv {
  /** Where Clef is asked instead of Workers AI. Only tests set it, to a stand-in on this Mac,
   * and only with DEV_LOGIN. */
  CLEF_URL?: string;
}

/** A request and a photo scaled down for Clef, which reads at most about a megapixel. */
const MAX_BODY = 1_500_000;
const MAX_REQUEST = 4_000;
/** Clef answers in well under a second; past this, the page goes ahead on the default. */
const CLEF_TIMEOUT = 6_000;

/** How a row is named when an account gets the best its plan has rather than the row's first pick. */
const NAMES: Record<Category, string> = {
  money: "money and sums",
  science: "explainers",
  lists: "lists and plans",
  figures: "simulations and figures",
  other: "pages like this",
  photo: "photos",
  live: "live facts",
  language: "other languages",
};

/** Asks Clef Flash through Dream's AI Gateway (logs off, no cache), or the tests' stand-in. */
async function askClef(env: RouteEnv, input: Record<string, unknown>): Promise<unknown> {
  const standIn = env.DEV_LOGIN === "1" ? env.CLEF_URL?.trim() : "";
  if (standIn) {
    const response = await fetch(standIn, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(input) });
    if (!response.ok) throw new Error(`Clef answered ${response.status}`);
    return response.json();
  }
  if (!env.AI) throw new Error("No AI binding");
  const gateway = env.AI_GATEWAY?.trim();
  const run = env.AI.run.bind(env.AI) as unknown as (model: string, input: unknown, options: unknown) => Promise<unknown>;
  return run(CLEF.model, input, gateway ? { gateway: { id: gateway, collectLog: false, skipCache: true } } : {});
}

function withTimeout<T>(work: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | null = null;
  const late = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error("Clef took too long")), ms);
  });
  return Promise.race([work, late]).finally(() => timer !== null && clearTimeout(timer));
}

/** The model and thinking level an account gets from a row: the row's first pick it may use as
 * benched, at a level its plan allows (models.ts). With no row, or no such pick, the default at
 * the level its plan allows. */
export function pickFor(row: Row | null, account: Account, env: RouteEnv): { model: Model; effort: Effort | "none" } {
  // The same lists /api/model holds a request to: testers and the bench any model, everyone else
  // those offered and the ones the table routes to, and the Plus-only ones only on Dream Plus.
  const anyModel = account.tester || env.DEV_LOGIN === "1";
  const models = modelsFor(env.MODELS, anyModel);
  const level = (asked: Effort, model: Model) => fitEffort(allowedEffort(asked, account.plan, account.tester), model) ?? "none";
  const usable = (pick: Pick) => {
    const model = models.find((each) => each.id === pick.model);
    return model !== undefined && (anyModel || !model.plus || model.routed || account.plan === "plus") && level(pick.effort, model) === pick.effort;
  };
  const picked = (row && firstUsable(row, usable)) ?? DEFAULT_PICK;
  const model = choose(picked.model, account.plan, models, anyModel);
  return { model, effort: level(model.id === picked.model ? picked.effort : DEFAULT_PICK.effort, model) };
}

/** For a model request that names "auto" itself (model.ts): the row that what the request shows
 * on its face lands on (router.ts, `guess`), without asking Clef. */
export function guessedPick(messages: unknown, account: Account, env: RouteEnv): { model: Model; effort: Effort | "none" } {
  const where = guess(messages);
  return pickFor(TABLE[where.category][where.difficulty], account, env);
}

/** Auto's pick for a page, as /api/route answers it, with what Clef said. */
export interface RouteAnswer {
  model: string;
  name: string;
  effort: string;
  category: Category;
  difficulty: string;
  why: string;
  signals: Signals | null;
}

/** Asks Clef about a request and picks from the table, within the account's plan. Never fails:
 * when Clef can't be asked, or `fake` (local development's stand-in) says not to, the default. */
export async function routePage(env: RouteEnv, ctx: { waitUntil: ExecutionContext["waitUntil"] }, userID: string, text: string, photo: boolean, image?: string, fake = false): Promise<RouteAnswer> {
  const account = await accountOf(env, userID);
  let where: ReturnType<typeof classify> | null = null;
  let signals: Signals | null = null;
  if (!fake) {
    try {
      const output = await withTimeout(askClef(env, clefInput(text, photo, image)), CLEF_TIMEOUT);
      signals = readAnswers(output, photo);
      if (signals) where = classify(signals, text);
      else console.error("Clef's answer didn't read");
      const { tokensIn, cost } = clefCost(output);
      if (tokensIn > 0) {
        ctx.waitUntil(recordModel(env, userID, null, { tokensIn, tokensCached: 0, tokensOut: 0, cost }).catch((error) => console.error("Usage not recorded", error instanceof Error ? error.name : typeof error)));
      }
    } catch (error) {
      // The kind of failure only, never the request.
      console.error("Clef failed", error instanceof Error ? error.message.slice(0, 80) : typeof error);
    }
  }

  const row = where ? TABLE[where.category][where.difficulty] : null;
  const { model, effort } = pickFor(row, account, env);
  // The row's reason is about its first pick, the model at that level; anything else is the plan's.
  const why = !row || !where
    ? "Couldn't tell what kind of page this is, so Dream's default"
    : model.id === row.picks[0].model && effort === row.picks[0].effort
      ? row.why
      : `${model.name}: the best your plan has for ${NAMES[where.category]}`;
  // `name` too, so the app can say what Auto picked without a list of models.
  return { model: model.id, name: model.name, effort, category: where?.category ?? "other", difficulty: where?.difficulty ?? "easy", why, signals };
}

export async function route(request: Request, env: RouteEnv, ctx: ExecutionContext): Promise<Response> {
  const user = await userFrom(request, env);
  if (!user) return signInNeeded();
  if (!(await allowed(env.MODEL_LIMIT, `route:${user.id}`))) return problem(429, "Too many requests at once. Try again in a minute.", { "Retry-After": "60" });
  if (!isJSON(request)) return problem(415, "Send application/json.");
  const raw = await bodyBytes(request, MAX_BODY);
  if (!raw) return problem(413, "That's too much to send at once. Send a smaller photo.");
  const refused = await proveApp(request, env, raw, "Dream's model");
  if (refused) return refused;

  const body = object(raw);
  if (!body) return problem(400, "Expected a JSON object.");
  const text = typeof body.request === "string" ? body.request.trim() : "";
  if (!text || text.length > MAX_REQUEST) return problem(400, `Send the request, up to ${MAX_REQUEST.toLocaleString("en")} characters.`);
  if (body.hasImage !== undefined && typeof body.hasImage !== "boolean") return problem(400, "hasImage is true or false.");
  // Only data: images, so Clef never fetches an address on Dream's behalf; JPEG, PNG or WebP, which it reads.
  if (body.image !== undefined && !(typeof body.image === "string" && /^data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$/.test(body.image))) {
    return problem(400, "image is a JPEG, PNG or WebP data: URL.");
  }
  const image = body.image as string | undefined;
  const photo = body.hasImage === true || image !== undefined;

  const { signals, ...answer } = await routePage(env, ctx, user.id, text, photo, image);
  // In local development, what Clef said as well, for tuning the table.
  return json(env.DEV_LOGIN === "1" ? { ...answer, signals } : answer);
}
