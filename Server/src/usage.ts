// What each account uses, and how much it may: pages built, model tokens and what they cost,
// web searches and page reads, by day and by month (migrations/0007_usage.sql). Days and months
// are UTC.
//
// A page is one build or one change, as the app numbers it (`X-Dream-Page` on model requests):
// the gap check, the writing, its tool calls and its repairs all count as the same page. The
// allowance is counted in pages because that's what people see; what it costs Dream is
// counted too, and bounds what one page, one day, and everyone together can spend, whatever a
// client sends.
//
//   GET /api/usage   (signed in) → the plan, today's and this month's pages, and the subscription

import { CATALOG, EFFORTS, offered, type Model } from "./models";
import { AUTO } from "./router";
import { activeSubscription, type StoreEnv, type Subscription } from "./appstore";

export type Plan = "free" | "plus";

export interface Allowance {
  /** New pages and changes. */
  pagesPerDay: number;
  pagesPerMonth: number;
  /** The most one page may cost, in millionths of a dollar, before it's stopped. */
  pageCost: number;
  /** The most one account's model requests may cost in a day, all together: a backstop. */
  dailyCost: number;
  searchesPerDay: number;
  readsPerDay: number;
}

/** The allowances, from the costs worked out in README.md ("Plans and limits"). */
// Pages measured through the proxy on grok-4.7 (2026-10-26) cost $0.035 to $0.19 each, $0.08 on
// average; one that searches and reads the web is the dear end. A page makes at most 3 searches
// and 4 reads (WebSearch.swift), so the web allowances cover every page of the day.
export const ALLOWANCES: Record<Plan, Allowance> = {
  free: { pagesPerDay: 5, pagesPerMonth: 30, pageCost: 300_000, dailyCost: 600_000, searchesPerDay: 15, readsPerDay: 20 },
  // Dream Plus can ask Grok to think longer (model.ts), which can cost several times a page at low.
  plus: { pagesPerDay: 25, pagesPerMonth: 150, pageCost: 1_000_000, dailyCost: 5_000_000, searchesPerDay: 75, readsPerDay: 100 },
};

export interface UsageEnv extends StoreEnv {
  /** JSON overriding some allowances, like {"free":{"pagesPerDay":3}}: for tests, and changing
   * limits without a deploy of code. */
  ALLOWANCES?: string;
  /** Dollars a day that model requests may cost, for everyone together. */
  MODEL_DAILY_BUDGET?: string;
  /** The models offered, ids from models.ts separated by commas, the first the default. */
  MODELS?: string;
  /** Secret. Accounts that have Dream Plus without paying, by Dream's user id, separated by commas:
   * the developer's own, and testers'. Set with `wrangler secret put PLUS_ACCOUNTS`. */
  PLUS_ACCOUNTS?: string;
}

export function allowances(env: UsageEnv): Record<Plan, Allowance> {
  if (!env.ALLOWANCES) return ALLOWANCES;
  try {
    const custom = JSON.parse(env.ALLOWANCES) as Partial<Record<Plan, Partial<Allowance>>>;
    return { free: { ...ALLOWANCES.free, ...custom.free }, plus: { ...ALLOWANCES.plus, ...custom.plus } };
  } catch {
    return ALLOWANCES;
  }
}

export const dayOf = (at = Date.now()) => new Date(at).toISOString().slice(0, 10);
export const monthOf = (at = Date.now()) => new Date(at).toISOString().slice(0, 7);

/** When today and this month end, in seconds. */
function resets(at = Date.now()): { day: number; month: number } {
  const date = new Date(at);
  return {
    day: Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate() + 1) / 1000,
    month: Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1) / 1000,
  };
}

export interface Account {
  plan: Plan;
  subscription: Subscription | null;
  /** On PLUS_ACCOUNTS: the developer or a tester, who can try every model and thinking level. */
  tester: boolean;
}

export async function accountOf(env: UsageEnv, userID: string): Promise<Account> {
  const subscription = await activeSubscription(env, userID);
  const tester = (env.PLUS_ACCOUNTS ?? "").split(",").some((id) => id.trim() === userID);
  return { plan: subscription || tester ? "plus" : "free", subscription, tester };
}

interface Row {
  period: string;
  pages: number;
  tokens_in: number;
  tokens_cached: number;
  tokens_out: number;
  searches: number;
  reads: number;
  cost_micros: number;
}

const EMPTY: Omit<Row, "period"> = { pages: 0, tokens_in: 0, tokens_cached: 0, tokens_out: 0, searches: 0, reads: 0, cost_micros: 0 };

async function current(env: UsageEnv, userID: string, at = Date.now()): Promise<{ day: Omit<Row, "period">; month: Omit<Row, "period"> }> {
  const day = dayOf(at);
  const month = monthOf(at);
  const { results } = await env.DB.prepare("SELECT * FROM usage WHERE user_id = ? AND period IN (?, ?)").bind(userID, day, month).all<Row>();
  return { day: results.find((row) => row.period === day) ?? EMPTY, month: results.find((row) => row.period === month) ?? EMPTY };
}

/** Why something wasn't allowed, as the app shows it. `upgrade` means Dream Plus would allow it. */
export interface Refusal {
  status: 402 | 429 | 503;
  message: string;
  upgrade: boolean;
  /** When it's allowed again, in seconds. */
  resetsAt?: number;
}

export function refusalResponse(refusal: Refusal): Response {
  const headers: Record<string, string> = { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };
  if (refusal.resetsAt) headers["Retry-After"] = String(Math.max(1, Math.ceil(refusal.resetsAt - Date.now() / 1000)));
  return new Response(JSON.stringify({ error: refusal.message, reason: "allowance", upgrade: refusal.upgrade, resetsAt: refusal.resetsAt }), { status: refusal.status, headers });
}

function usedUp(plan: Plan, limit: number, period: "day" | "month", resetsAt: number): Refusal {
  if (plan === "free") {
    const message = period === "day"
      ? `You've made today's ${limit} free pages. You can make more tomorrow, or now with Dream Plus.`
      : `You've made this month's ${limit} free pages. You can make more next month, or now with Dream Plus.`;
    return { status: 402, message, upgrade: true, resetsAt };
  }
  const message = period === "day"
    ? `You've made ${limit} pages today, as many as Dream Plus allows in a day. You can make more tomorrow.`
    : `You've made ${limit} pages this month, as many as Dream Plus allows in a month. You can make more next month.`;
  return { status: 429, message, upgrade: false, resetsAt };
}

/** Whether a model request may go ahead. A request for a page this account hasn't built before
 * starts a new page, if the allowance has room, and is counted. `page` is null for small jobs
 * that aren't a page, like turning "add milk" into a list entry. */
export async function admitModel(env: UsageEnv, userID: string, page: string | null, account: Account, at = Date.now()): Promise<Refusal | null> {
  const allowance = allowances(env)[account.plan];
  const ends = resets(at);
  const { day, month } = await current(env, userID, at);
  const budget = Number(env.MODEL_DAILY_BUDGET ?? "");
  const everyone = await env.DB.prepare("SELECT amount FROM spend WHERE day = ? AND kind = 'model'").bind(dayOf(at)).first<{ amount: number }>();
  if ((everyone?.amount ?? 0) >= (Number.isFinite(budget) && budget > 0 ? budget : 100) * 1_000_000) {
    console.error("Model daily budget reached");
    return { status: 503, message: "Dream is very busy today. Try again later.", upgrade: false, resetsAt: ends.day };
  }
  if (day.cost_micros >= allowance.dailyCost) {
    return account.plan === "free"
      ? { status: 402, message: "You've used today's free allowance. You can make more tomorrow, or now with Dream Plus.", upgrade: true, resetsAt: ends.day }
      : { status: 429, message: "You've used today's allowance. You can make more tomorrow.", upgrade: false, resetsAt: ends.day };
  }
  if (!page) return null;
  const known = await env.DB.prepare("SELECT cost_micros FROM usage_pages WHERE user_id = ? AND page = ?").bind(userID, page).first<{ cost_micros: number }>();
  if (known) {
    return known.cost_micros >= allowance.pageCost
      ? { status: 429, message: "This page has used all the work one page can. Try asking for something smaller.", upgrade: false }
      : null;
  }
  if (day.pages >= allowance.pagesPerDay) return usedUp(account.plan, allowance.pagesPerDay, "day", ends.day);
  if (month.pages >= allowance.pagesPerMonth) return usedUp(account.plan, allowance.pagesPerMonth, "month", ends.month);
  // The gap check and the writing start together; only the first of them counts the page.
  const started = await env.DB.prepare("INSERT OR IGNORE INTO usage_pages (user_id, page, day, cost_micros) VALUES (?, ?, ?, 0)").bind(userID, page, dayOf(at)).run();
  if (started.meta.changes === 1) await add(env, userID, { pages: 1 }, at);
  return null;
}

export interface ModelUse {
  tokensIn: number;
  tokensCached: number;
  /** The answer and the reasoning before it. */
  tokensOut: number;
  /** Millionths of a dollar. */
  cost: number;
}

/** Counts what a model request used, once it's finished. */
export async function recordModel(env: UsageEnv, userID: string, page: string | null, use: ModelUse, at = Date.now()): Promise<void> {
  const cost = Math.max(0, Math.round(use.cost));
  await add(env, userID, { tokens_in: use.tokensIn, tokens_cached: use.tokensCached, tokens_out: use.tokensOut, cost_micros: cost }, at, [
    ...(page ? [env.DB.prepare("UPDATE usage_pages SET cost_micros = cost_micros + ? WHERE user_id = ? AND page = ?").bind(cost, userID, page)] : []),
    env.DB.prepare("INSERT INTO spend (day, kind, amount) VALUES (?, 'model', ?) ON CONFLICT (day, kind) DO UPDATE SET amount = amount + excluded.amount").bind(dayOf(at), cost),
    // Pages are only looked up while they're being built, so old ones go a few at a time.
    env.DB.prepare("DELETE FROM usage_pages WHERE rowid IN (SELECT rowid FROM usage_pages WHERE day < ? LIMIT 20)").bind(dayOf(at - 2 * 86_400_000)),
  ]);
}

/** Whether a web search or page read may go ahead, counting it if so. */
export async function admitWeb(env: UsageEnv, userID: string, kind: "search" | "read", at = Date.now()): Promise<Refusal | null> {
  const account = await accountOf(env, userID);
  const allowance = allowances(env)[account.plan];
  const { day } = await current(env, userID, at);
  const [used, limit] = kind === "search" ? [day.searches, allowance.searchesPerDay] : [day.reads, allowance.readsPerDay];
  if (used >= limit) {
    const what = kind === "search" ? "web searches" : "web pages Dream can read";
    return account.plan === "free"
      ? { status: 402, message: `You've used today's free ${what}. You can use more tomorrow, or now with Dream Plus.`, upgrade: true, resetsAt: resets(at).day }
      : { status: 429, message: `You've used today's ${what}. You can use more tomorrow.`, upgrade: false, resetsAt: resets(at).day };
  }
  await add(env, userID, kind === "search" ? { searches: 1 } : { reads: 1 }, at);
  return null;
}

type Counts = Partial<Omit<Row, "period">>;

/** Adds to today's and this month's rows, together with any other statements. */
async function add(env: UsageEnv, userID: string, counts: Counts, at: number, also: D1PreparedStatement[] = []): Promise<void> {
  const columns = Object.keys(counts) as (keyof Counts)[];
  const values = columns.map((column) => counts[column] ?? 0);
  const upsert = (period: string) =>
    env.DB.prepare(
      `INSERT INTO usage (user_id, period, ${columns.join(", ")}) VALUES (?, ?, ${columns.map(() => "?").join(", ")})
       ON CONFLICT (user_id, period) DO UPDATE SET ${columns.map((column) => `${column} = ${column} + excluded.${column}`).join(", ")}`,
    ).bind(userID, period, ...values);
  await env.DB.batch([upsert(dayOf(at)), upsert(monthOf(at)), ...also]);
}

const listed = ({ id, name, note, plus }: Model) => ({ id, name, note, plus });

/** Auto, everyone's default: it picks the model and thinking for each page (route.ts). */
const AUTO_ENTRY = { id: AUTO, name: "Auto", note: "Picks the model and thinking for each page", plus: false };

/** What the app shows: the plan, how many pages are left, and when more come. */
export async function status(env: UsageEnv, userID: string, at = Date.now()): Promise<Record<string, unknown>> {
  const account = await accountOf(env, userID);
  const allowance = allowances(env)[account.plan];
  const { day, month } = await current(env, userID, at);
  const ends = resets(at);
  return {
    plan: account.plan,
    pages: { today: day.pages, perDay: allowance.pagesPerDay, month: month.pages, perMonth: allowance.pagesPerMonth },
    resetsAt: month.pages >= allowance.pagesPerMonth ? ends.month : ends.day,
    // StoreKit's appAccountToken when buying, so a purchase is tied to this account.
    accountToken: userID,
    subscription: account.subscription,
    // Both plans, so the app can say what Dream Plus adds without a second request.
    plans: Object.fromEntries(Object.entries(allowances(env)).map(([plan, { pagesPerDay, pagesPerMonth }]) => [plan, { pagesPerDay, pagesPerMonth }])),
    // The models the app can offer, the default first: Auto for everyone; then, to pick by hand,
    // the ones offered on Dream Plus, or every one in the catalogue for testers. The free plan has
    // Auto alone, so there's nothing to pick.
    models: [AUTO_ENTRY, ...(account.tester ? CATALOG : account.plan === "plus" ? offered(env.MODELS) : []).map(listed)],
    // The thinking levels the app can offer by hand, beside a model that isn't Auto: every one for
    // testers, low to high for Dream Plus.
    thinking: account.tester ? [...EFFORTS] : account.plan === "plus" ? ["low", "medium", "high"] : [],
  };
}

/** Forgets everything this workstream keeps about a person, for account deletion. Their App
 * Store subscription carries on at Apple until they cancel it there. */
export async function deleteUserData(env: { DB: D1Database }, userID: string): Promise<void> {
  await env.DB.batch(planErasure(env, userID));
}

/** For an account's deletion batch (userdata.ts). The App Store subscription itself is Apple's:
 * deleting the account doesn't cancel it, which the deletion screen says. */
export function planErasure(env: { DB: D1Database }, userID: string): D1PreparedStatement[] {
  return ["usage", "usage_pages", "subscriptions", "attest_keys", "attest_challenges"].map((table) => env.DB.prepare(`DELETE FROM ${table} WHERE user_id = ?`).bind(userID));
}
