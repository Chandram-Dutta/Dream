// Shared links and their owners. Making a link needs an account; reading one doesn't. Each link
// belongs to whoever made it, who can see how often it's been viewed (a count, nothing about who),
// update it to their page's newest version, set it to expire, or stop sharing it.
//
//   POST   /api/surfaces[?page=<app's page id>&new=1]   a shared surface → 201 { id, url }, or 200 { …, reused }
//   GET    /api/surfaces/:id                             the page, for the app; 410 once it's stopped
//   PUT    /api/surfaces/:id                             the owner's newest version and/or { expiresAt }
//   DELETE /api/surfaces/:id                             the owner stops sharing it
//   GET    /api/me/shares                                the signed-in account's links
//   GET    /s/:id                                        the web viewer
//
// Sharing the same page again reuses its link, with the new version behind it, unless the app asks
// for a new one (`new=1`). A link with the sharer's numbers and one without are different links.

import { userFrom, signInNeeded, type User } from "./auth";
import { checkPublish } from "./moderation";
import { gonePage, messagePage, surfacePage } from "./page";
import { checkShared, isObject, parseJSON, readBody, Rejection, type Shared } from "./payload";
import { addressOf, html, isJSON, json, problem, tooMany, underLimit } from "./respond";
import { isBanned, isBlockedBy, resolveReports } from "./safety";
import type { SharingEnv } from "./sharing";
import { countView, find, ID_PATTERN, listed, madeToday, now, owned, replace, reusable, revoke, save, setExpiry, stateOf, type ListedRow, type ShareRow } from "./store";

/** New links an account may make in a day. Updating a link it has doesn't count. */
const LINKS_PER_DAY = 100;
/** The furthest ahead a link may be set to expire. */
const LONGEST_EXPIRY = 366 * 86_400;
/** The app's id for a page: a UUID, or something like one. */
const PAGE_ID = /^[A-Za-z0-9-]{8,64}$/;
/** Link previews and crawlers, which aren't people viewing a page. */
const NOT_A_VIEWER = /bot|crawl|spider|preview|facebookexternalhit|whatsapp|embedly|curl|wget/i;

/** A link as the owner's list in the app shows it. */
function listing(row: ListedRow, origin: string) {
  return {
    id: row.id,
    url: `${origin}/s/${row.id}`,
    page: row.page_id,
    title: row.title,
    accent: row.accent,
    symbol: row.symbol,
    created: row.created_at,
    updated: row.updated_at ?? row.created_at,
    hasValues: row.has_values === 1,
    views: row.views,
    expiresAt: row.expires_at,
    state: stateOf(row),
  };
}

/** The page someone sent, checked, and passed by the publish check; or the refusal. */
async function upload(request: Request, body?: unknown): Promise<Shared | Response> {
  try {
    const shared = checkShared(body ?? parseJSON(await readBody(request)));
    const refusal = checkPublish(shared);
    // 422, with the reason, so the app can say plainly why in its own words.
    return refusal ? problem(422, refusal.message, { reason: refusal.reason }) : shared;
  } catch (error) {
    if (error instanceof Rejection) return problem(error.status, error.message);
    throw error;
  }
}

/** Who's sharing, if they may: signed in, under their limit, and not barred from sharing. Making
 * links has a tighter limit than changing them, which the app's list does a few at a time. */
async function sharer(request: Request, env: SharingEnv, making: boolean): Promise<User | Response> {
  const user = await userFrom(request, env);
  if (!user) return signInNeeded();
  if (!(await underLimit(making ? env.CREATE_LIMIT : env.READ_LIMIT, `${making ? "share" : "change"}:${user.id}`))) return tooMany();
  if (await isBanned(env, user.id)) return problem(403, "This account can't share pages anymore.", { reason: "banned" });
  return user;
}

export async function create(request: Request, env: SharingEnv, url: URL): Promise<Response> {
  const user = await sharer(request, env, true);
  if (user instanceof Response) return user;
  if (!isJSON(request)) return problem(415, "Send the surface as application/json.");
  const shared = await upload(request);
  if (shared instanceof Response) return shared;

  const page = url.searchParams.get("page");
  const pageID = page && PAGE_ID.test(page) ? page : null;
  if (pageID && url.searchParams.get("new") !== "1") {
    const id = await reusable(env.DB, user.id, pageID, shared.values !== undefined);
    if (id) {
      await replace(env.DB, id, shared);
      return json({ id, url: `${url.origin}/s/${id}`, reused: true });
    }
  }
  if ((await madeToday(env.DB, user.id)) >= LINKS_PER_DAY) return problem(429, "That's a lot of links for one day. Try again tomorrow.", { reason: "daily" });
  const id = await save(env.DB, shared, { ownerID: user.id, pageID });
  return json({ id, url: `${url.origin}/s/${id}`, reused: false }, 201);
}

/** The owner's own link, or why they can't change it. */
async function ownLink(request: Request, env: SharingEnv, id: string): Promise<{ user: User; row: ShareRow } | Response> {
  const user = await sharer(request, env, false);
  if (user instanceof Response) return user;
  const found = ID_PATTERN.test(id) ? await find(env.DB, id) : null;
  if (!found) return problem(404, "There's no shared page here.");
  if (found.row.owner_id !== user.id) return problem(403, "Only the person who shared this page can change it.");
  return { user, row: found.row };
}

/** A newer version of the page, a new expiry, or both. A link that's stopped stays stopped. */
export async function update(request: Request, env: SharingEnv, id: string, origin: string): Promise<Response> {
  const owner = await ownLink(request, env, id);
  if (owner instanceof Response) return owner;
  const state = stateOf(owner.row);
  if (state === "stopped" || state === "removed") return problem(410, "This page is no longer shared.", { state });
  if (!isJSON(request)) return problem(415, "Send application/json.");

  let body: unknown;
  try {
    body = parseJSON(await readBody(request));
  } catch (error) {
    if (error instanceof Rejection) return problem(error.status, error.message);
    throw error;
  }
  if (!isObject(body) || (!("surface" in body) && !("expiresAt" in body))) return problem(400, "Send the page's newest version, an expiry, or both.");
  let expiresAt: number | null | undefined;
  if ("expiresAt" in body) {
    const value = body.expiresAt;
    const at = now();
    if (value !== null && (typeof value !== "number" || !Number.isInteger(value) || value <= at || value > at + LONGEST_EXPIRY)) {
      return problem(400, "A link can expire any time in the next year, or never.");
    }
    expiresAt = value;
  }
  if ("surface" in body) {
    const shared = await upload(request, body);
    if (shared instanceof Response) return shared;
    await replace(env.DB, id, shared);
  }
  if (expiresAt !== undefined) await setExpiry(env.DB, id, expiresAt);
  return json(listing((await listed(env.DB, id))!, origin));
}

/** Stops sharing: the link stays, saying the page is no longer shared, and the page is erased. */
export async function stop(request: Request, env: SharingEnv, id: string, origin: string): Promise<Response> {
  const owner = await ownLink(request, env, id);
  if (owner instanceof Response) return owner;
  if (stateOf(owner.row) !== "removed") {
    await revoke(env.DB, id, "owner");
    await resolveReports(env, id, "gone");
  }
  return json(listing((await listed(env.DB, id))!, origin));
}

export async function mine(request: Request, env: SharingEnv, origin: string): Promise<Response> {
  const user = await userFrom(request, env);
  if (!user) return signInNeeded();
  return json({ shares: (await owned(env.DB, user.id)).map((row) => listing(row, origin)) });
}

/** A shared page, for the app. Someone who blocked its sharer doesn't get it. */
export async function read(request: Request, env: SharingEnv, ctx: ExecutionContext, id: string): Promise<Response> {
  if (!(await underLimit(env.READ_LIMIT, `read:${addressOf(request)}`))) return tooMany();
  const found = ID_PATTERN.test(id) ? await find(env.DB, id) : null;
  if (!found) return problem(404, "There's no shared page here.");
  if (!found.stored) return problem(410, "This page is no longer shared.", { state: found.state });
  const viewer = request.headers.has("Authorization") ? await userFrom(request, env) : null;
  const owner = found.row.owner_id;
  if (viewer && owner && (await isBlockedBy(env, viewer.id, owner))) return problem(403, "You chose not to see pages from this person.", { reason: "blocked" });
  if (request.method === "GET" && viewer?.id !== owner) ctx.waitUntil(countView(env.DB, id));
  const { preview: _, ...forApp } = found.stored;
  return json(forApp, 200, { "Cache-Control": "private, no-store" });
}

/** The web viewer, for people without Dream. */
export async function view(request: Request, env: SharingEnv, ctx: ExecutionContext, id: string, origin: string): Promise<Response> {
  if (!(await underLimit(env.READ_LIMIT, `read:${addressOf(request)}`))) return html(messagePage("Slow down", "Too many requests at once. Try again in a minute."), 429);
  const found = ID_PATTERN.test(id) ? await find(env.DB, id) : null;
  if (!found) return html(messagePage("This page isn't here", "The link may be incomplete."), 404);
  if (!found.stored) return html(gonePage(found.state as "stopped" | "expired" | "removed"), 410);
  if (request.method === "GET" && !NOT_A_VIEWER.test(request.headers.get("User-Agent") ?? "")) ctx.waitUntil(countView(env.DB, id));
  // Briefly, so a page that's stopped or changed stops showing soon after.
  return html(surfacePage(found.stored, origin), 200, "public, max-age=60");
}
