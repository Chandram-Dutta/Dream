// Sharing's routes, in one place for index.ts: links and their owners (shares.ts), and reports,
// blocks and the admin (safety.ts). Also what deleting an account does to them.

import { signInNeeded, userFrom, type AuthEnv } from "./auth";
import { html, json, problem } from "./respond";
import { messagePage } from "./page";
import { adminAPI, adminPage, block, blockedList, reportForm, reportFromApp, reportFromWeb, unblock } from "./safety";
import { create, mine, read, stop, update, view } from "./shares";
import { now } from "./store";

export interface SharingEnv extends AuthEnv {
  DB: D1Database;
  /** Per account: links made, and sharers blocked. */
  CREATE_LIMIT?: RateLimit;
  /** Per address: pages read, by the app and the web viewer. Per account: links changed and stopped. */
  READ_LIMIT?: RateLimit;
  /** Per address: reports. */
  REPORT_LIMIT?: RateLimit;
  /** Secret. Lets an admin review reports and take pages down. Without it, the admin routes don't exist. */
  ADMIN_KEY?: string;
}

const onlyGET = (api: boolean) => (api ? problem(405, "Only GET.", {}, { Allow: "GET, HEAD" }) : html(messagePage("Nothing here", "This page doesn't exist."), 405));

/** Sharing's routes, or null for any other path. */
export async function routeSharing(request: Request, env: SharingEnv, ctx: ExecutionContext, url: URL): Promise<Response | null> {
  const path = url.pathname;
  const method = request.method;
  const reading = method === "GET" || method === "HEAD";

  if (path === "/api/surfaces") return method === "POST" ? create(request, env, url) : problem(405, "Only POST.", {}, { Allow: "POST" });
  const api = path.match(/^\/api\/surfaces\/([^/]+)(?:\/(report|block))?$/);
  if (api) {
    const [, id, action] = api;
    if (action === "report") return method === "POST" ? reportFromApp(request, env, id) : problem(405, "Only POST.", {}, { Allow: "POST" });
    if (action === "block") return method === "POST" ? block(request, env, id) : problem(405, "Only POST.", {}, { Allow: "POST" });
    if (reading) return read(request, env, ctx, id);
    if (method === "PUT") return update(request, env, id, url.origin);
    if (method === "DELETE") return stop(request, env, id, url.origin);
    return problem(405, "Only GET, PUT and DELETE.", {}, { Allow: "GET, HEAD, PUT, DELETE" });
  }
  const viewer = path.match(/^\/s\/([^/]+?)(\/report)?\/?$/);
  if (viewer) {
    const [, id, report] = viewer;
    if (report) return method === "POST" ? reportFromWeb(request, env, id) : reading ? reportForm(env, id) : onlyGET(false);
    return reading ? view(request, env, ctx, id, url.origin) : onlyGET(false);
  }
  if (path === "/api/me/shares") return reading ? mine(request, env, url.origin) : onlyGET(true);
  if (path === "/api/me/blocked") return reading ? blockedList(request, env) : onlyGET(true);
  const blocked = path.match(/^\/api\/me\/blocked\/([^/]+)$/);
  if (blocked) return method === "DELETE" ? unblock(request, env, blocked[1]) : problem(405, "Only DELETE.", {}, { Allow: "DELETE" });
  if (path === "/admin") return adminPage(request, env);
  if (path.startsWith("/api/admin/")) return adminAPI(request, env, path);
  // Local development only, until account deletion calls deleteUserData: what it does to sharing.
  if (path === "/api/dev/forget-sharing" && method === "POST" && env.DEV_LOGIN === "1") {
    const user = await userFrom(request, env);
    if (!user) return signInNeeded();
    await deleteUserData(env, user.id);
    return json(null, 204);
  }
  return null;
}

/** Deleting an account (workstream A calls this): every link it made stops, and its pages and
 * titles are erased, though the ids stay so old links say they're gone. Its blocks, and others'
 * blocks of it, go too. Reports on its pages are closed; they never said who reported. */
export async function deleteUserData(env: SharingEnv, userID: string): Promise<void> {
  const at = now();
  await env.DB.batch([
    env.DB.prepare("UPDATE reports SET resolved_at = ?, resolution = 'gone' WHERE resolved_at IS NULL AND share_id IN (SELECT id FROM surfaces WHERE owner_id = ?)").bind(at, userID),
    env.DB.prepare(
      `UPDATE surfaces SET revoked_at = COALESCE(revoked_at, ?), revoked_by = CASE WHEN revoked_by = 'admin' THEN 'admin' ELSE 'account' END,
         body = '', title = '', summary = '', size = 0, owner_id = NULL, page_id = NULL WHERE owner_id = ?`,
    ).bind(at, userID),
    env.DB.prepare("DELETE FROM blocked_sharers WHERE user_id = ? OR owner_id = ?").bind(userID, userID),
    env.DB.prepare("DELETE FROM sharing_bans WHERE user_id = ?").bind(userID),
  ]);
}
