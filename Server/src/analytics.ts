// Product analytics the server sends itself, to PostHog, for what only the server knows: a free
// allowance running out, a subscription starting or ending. They join the app's own events
// (Dream/Engine/Analytics.swift, docs/Analytics.md) under the same person: Dream's own user id,
// never Apple's or an email. Like the app's, they say what happened and never carry anything
// anyone wrote.
//
// Without `POSTHOG_KEY` nothing is sent. Sending never holds up the response, never throws and
// never logs.
//
// Only for someone who turned on "Help improve Dream": the app says so on each request it makes
// while the choice is on (`countsAllowed`), and callers check it first. That's why the App
// Store's notifications, which come from Apple rather than the phone, send nothing here; the app
// counts purchases itself.
//
//   if (countsAllowed(request)) limitReached(env, ctx, user.id, "pages")
//
// No imports, so test/unit.mjs runs it in Node.

export interface AnalyticsEnv {
  /** PostHog's project key: public, so a var, not a secret. Empty turns server events off. */
  POSTHOG_KEY?: string;
  /** PostHog's ingestion host: https://us.i.posthog.com or https://eu.i.posthog.com. */
  POSTHOG_HOST?: string;
}

const DEFAULT_HOST = "https://us.i.posthog.com";

type Value = string | number | boolean | null;

/** Whether the person lets Dream count what's used: the app sends `X-Dream-Analytics: on` with
 * its requests while "Help improve Dream" is on (Dream/Generation/Providers/DreamModel.swift). */
export function countsAllowed(request: Request): boolean {
  return request.headers.get("X-Dream-Analytics") === "on";
}

/** Sends one event about a person, after the response. */
export function capture(env: AnalyticsEnv, ctx: Pick<ExecutionContext, "waitUntil">, userID: string, event: string, properties: Record<string, Value> = {}): void {
  const key = env.POSTHOG_KEY?.trim();
  if (!key || !userID) return;
  const host = (env.POSTHOG_HOST?.trim() || DEFAULT_HOST).replace(/\/+$/, "");
  if (!host.startsWith("https://")) return;
  const body = JSON.stringify({
    api_key: key,
    event,
    distinct_id: userID,
    properties: { ...properties, source: "server" },
    timestamp: new Date().toISOString(),
  });
  const sending = fetch(`${host}/i/v0/e/`, { method: "POST", headers: { "Content-Type": "application/json" }, body }).then(
    () => undefined,
    () => undefined,
  );
  ctx.waitUntil(sending);
}

/** A free allowance ran out: "pages", "tokens" or "searches". */
export function limitReached(env: AnalyticsEnv, ctx: Pick<ExecutionContext, "waitUntil">, userID: string, kind: "pages" | "tokens" | "searches"): void {
  capture(env, ctx, userID, "limit_reached", { kind });
}

/** A subscription started, by its App Store product id. */
export function subscriptionStarted(env: AnalyticsEnv, ctx: Pick<ExecutionContext, "waitUntil">, userID: string, product: string): void {
  capture(env, ctx, userID, "subscription_started", { product: product.slice(0, 100) });
}

/** A subscription ended: it expired, was refunded or was revoked. */
export function subscriptionEnded(env: AnalyticsEnv, ctx: Pick<ExecutionContext, "waitUntil">, userID: string): void {
  capture(env, ctx, userID, "subscription_ended");
}

/** One request to the model, for PostHog's LLM analytics: what it used, what it cost, how long
 * it took. Never the messages or the answer: no `$ai_input` or `$ai_output_choices`. */
export interface Generation {
  model: string;
  /** The page it's part of. A page's requests (tool rounds, repairs) make one trace. */
  page: string | null;
  plan: string;
  tokensIn: number;
  tokensCached: number;
  /** The answer and the reasoning before it. */
  tokensOut: number;
  /** Dollars, or null when the request failed before using anything. */
  cost: number | null;
  /** Seconds, from the request to the end of the answer. */
  latency: number;
  /** Seconds to the first streamed bytes. */
  firstToken: number | null;
  stream: boolean;
  /** xAI's status: 200, or what it failed with. */
  status: number;
}

export function aiGeneration(env: AnalyticsEnv, ctx: Pick<ExecutionContext, "waitUntil">, userID: string, generation: Generation): void {
  const seconds = (value: number) => Math.round(value * 1000) / 1000;
  capture(env, ctx, userID, "$ai_generation", {
    $ai_trace_id: generation.page ?? crypto.randomUUID(),
    $ai_session_id: null,
    // Besides pages, only talking to lists asks the model through the server (RecordTalk.swift).
    $ai_span_name: generation.page ? "page" : "lists",
    $ai_provider: "xai",
    $ai_model: generation.model,
    $ai_base_url: "https://api.x.ai/v1",
    $ai_input_tokens: generation.tokensIn,
    $ai_cache_read_input_tokens: generation.tokensCached,
    $ai_output_tokens: generation.tokensOut,
    ...(generation.cost === null ? {} : { $ai_total_cost_usd: generation.cost }),
    $ai_latency: seconds(generation.latency),
    ...(generation.firstToken === null ? {} : { $ai_time_to_first_token: seconds(generation.firstToken) }),
    $ai_stream: generation.stream,
    $ai_http_status: generation.status,
    $ai_is_error: generation.status >= 400,
    plan: generation.plan,
  });
}
