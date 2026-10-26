// Product analytics the server sends itself, to PostHog, for what only the server knows: a free
// allowance running out, a subscription starting or ending. They join the app's own events
// (Dream/Engine/Analytics.swift, docs/Analytics.md) under the same person: Dream's own user id,
// never Apple's or an email. Like the app's, they say what happened and never carry anything
// anyone wrote.
//
// Without `POSTHOG_KEY` nothing is sent. Sending never holds up the response, never throws and
// never logs. Workstream D calls these from metering and subscriptions:
//
//   limitReached(env, ctx, user.id, "pages")
//   subscriptionStarted(env, ctx, user.id, "dream.plus.monthly")
//
// The server can't see whether the person turned on "Help improve Dream" on their phone. Until
// that choice reaches the server with the account's settings, leave POSTHOG_KEY unset here, or
// check the setting before calling these.
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
