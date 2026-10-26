// Keeping shared pages safe: they're content anyone with a link can read (App Store guideline 1.2).
// Readers report a page, on the web or in the app; someone in the app can choose not to see a
// sharer again; and an admin reviews reports, takes pages down, and can stop an account sharing.
//
//   GET  /s/:id/report, POST /s/:id/report    the web viewer's report form (no script)
//   POST /api/surfaces/:id/report             { reason, note? } from the app
//   POST /api/surfaces/:id/block              { opened?: [ids] } → { blocked, hidden: [ids] }, signed in
//   GET  /api/me/blocked                      sharers the account blocked, by the page it blocked them from
//   DELETE /api/me/blocked/:n                 unblocks one
//   GET  /admin, POST /admin                  the admin's page, behind ADMIN_KEY
//   GET  /api/admin/reports                   open reports, by page (X-Admin-Key)
//   POST /api/admin/surfaces/:id/remove       takes a page down; { block: true } also stops its sharer sharing
//   POST /api/admin/surfaces/:id/dismiss      closes its reports, leaving it up
//   POST /api/admin/users/:id/block, …/unblock
//
// Nothing about who reports is kept, and nobody is shown who shared a page: the app's list of
// blocked sharers names the page instead. Reports are limited per address, and per page.

import { signInNeeded, userFrom } from "./auth";
import { escape } from "./text";
import { FORM_CSP, formPage, gonePage, messagePage, REPORT_REASONS, reportPage, surfacePage } from "./page";
import { isObject, readBody, Rejection } from "./payload";
import { addressOf, html, isJSON, json, problem, tooMany, underLimit } from "./respond";
import type { SharingEnv } from "./sharing";
import { find, ID_PATTERN, loadForReview, now, revoke, revokeAllOf, stateOf, type ShareRow } from "./store";

const REASONS = new Set(REPORT_REASONS.map(([value]) => value));
/** Open reports kept per page; past that, more say nothing new and aren't stored. */
const REPORTS_PER_PAGE = 50;

// MARK: - Queries other routes use

export async function isBanned(env: SharingEnv, userID: string): Promise<boolean> {
  return (await env.DB.prepare("SELECT 1 AS banned FROM sharing_bans WHERE user_id = ?").bind(userID).first()) !== null;
}

export async function isBlockedBy(env: SharingEnv, userID: string, ownerID: string): Promise<boolean> {
  return (await env.DB.prepare("SELECT 1 AS blocked FROM blocked_sharers WHERE user_id = ? AND owner_id = ?").bind(userID, ownerID).first()) !== null;
}

export async function resolveReports(env: SharingEnv, shareID: string, resolution: "removed" | "dismissed" | "gone"): Promise<void> {
  await env.DB.prepare("UPDATE reports SET resolved_at = ?, resolution = ? WHERE share_id = ? AND resolved_at IS NULL").bind(now(), resolution, shareID).run();
}

// MARK: - Reports

/** A reason and note as the form or the app sent them, tidied; or what's wrong. */
function reportOf(reason: unknown, note: unknown): { reason: string; note: string | null } | string {
  if (typeof reason !== "string" || !REASONS.has(reason)) return "Choose what's wrong with the page.";
  if (note !== undefined && note !== null && typeof note !== "string") return "The note should be text.";
  // Control characters out, at most 500 characters kept.
  const text = (note ?? "").replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "").trim().slice(0, 500);
  return { reason, note: text || null };
}

/** Stores a report on a page that's still shared, unless it already has plenty. */
async function fileReport(env: SharingEnv, id: string, report: { reason: string; note: string | null }, via: "web" | "app"): Promise<void> {
  const open = await env.DB.prepare("SELECT COUNT(*) AS count FROM reports WHERE share_id = ? AND resolved_at IS NULL").bind(id).first<{ count: number }>();
  if ((open?.count ?? 0) >= REPORTS_PER_PAGE) return;
  await env.DB.prepare("INSERT INTO reports (share_id, reason, note, via, created_at) VALUES (?, ?, ?, ?, ?)").bind(id, report.reason, report.note, via, now()).run();
}

/** The page being reported, if it's still shared. */
async function reportable(env: SharingEnv, id: string): Promise<{ row: ShareRow; title: string } | "missing" | "gone"> {
  const found = ID_PATTERN.test(id) ? await find(env.DB, id) : null;
  if (!found) return "missing";
  return found.stored ? { row: found.row, title: String(found.stored.surface.title) } : "gone";
}

// Reports are limited per address once they're well formed, before anything is looked up or kept.

export async function reportFromApp(request: Request, env: SharingEnv, id: string): Promise<Response> {
  if (!isJSON(request)) return problem(415, "Send application/json.");
  let body: unknown;
  try {
    body = JSON.parse(await readBody(request, 4_000));
  } catch (error) {
    return problem(error instanceof Rejection ? error.status : 400, "Expected a reason, and maybe a note.");
  }
  if (!isObject(body)) return problem(400, "Expected a reason, and maybe a note.");
  const report = reportOf(body.reason, body.note);
  if (typeof report === "string") return problem(400, report);
  if (!(await underLimit(env.REPORT_LIMIT, `report:${addressOf(request)}`))) return tooMany();
  const page = await reportable(env, id);
  if (page === "missing") return problem(404, "There's no shared page here.");
  if (page === "gone") return problem(410, "This page is no longer shared.");
  await fileReport(env, id, report, "app");
  return json({ reported: true }, 202);
}

export async function reportForm(env: SharingEnv, id: string): Promise<Response> {
  const page = await reportable(env, id);
  if (page === "missing") return html(messagePage("This page isn't here", "The link may be incomplete."), 404);
  if (page === "gone") return html(messagePage("This page is no longer shared", "There's nothing here to report anymore."), 410);
  return html(reportPage(id, page.title), 200, "no-store", FORM_CSP);
}

export async function reportFromWeb(request: Request, env: SharingEnv, id: string): Promise<Response> {
  if (!/^application\/x-www-form-urlencoded(\s*;|$)/i.test(request.headers.get("Content-Type") ?? "")) return html(messagePage("That didn't work", "Send the report from its form."), 415);
  let form: URLSearchParams;
  try {
    form = new URLSearchParams(await readBody(request, 4_000));
  } catch {
    return html(messagePage("That didn't work", "The report was too long. Try a shorter note."), 413);
  }
  const report = reportOf(form.get("reason"), form.get("note"));
  // Showing the form again costs what showing the page does.
  const limiter = typeof report === "string" ? env.READ_LIMIT : env.REPORT_LIMIT;
  if (!(await underLimit(limiter, `${typeof report === "string" ? "read" : "report"}:${addressOf(request)}`))) return html(messagePage("Slow down", "Too many reports at once. Try again in a minute."), 429);
  const page = await reportable(env, id);
  if (page === "missing") return html(messagePage("This page isn't here", "The link may be incomplete."), 404);
  if (page === "gone") return html(messagePage("This page is no longer shared", "There's nothing here to report anymore."), 410);
  if (typeof report === "string") return html(reportPage(id, page.title, report), 400, "no-store", FORM_CSP);
  await fileReport(env, id, report, "web");
  return html(messagePage("Thanks for telling us", "We'll look at this page, and take it down if it breaks Dream's rules."), 202);
}

// MARK: - Blocking a sharer

/** Someone in the app chooses not to see a sharer again. Of the shared pages they've opened
 * (`opened`), it says which came from the same sharer, so the app can remove those too. */
export async function block(request: Request, env: SharingEnv, id: string): Promise<Response> {
  const user = await userFrom(request, env);
  if (!user) return signInNeeded();
  if (!(await underLimit(env.CREATE_LIMIT, `block:${user.id}`))) return tooMany();
  let opened: string[] = [];
  // The list is optional; without one, only this page is hidden.
  if (isJSON(request)) {
    try {
      const body: unknown = JSON.parse(await readBody(request, 20_000));
      if (isObject(body) && Array.isArray(body.opened)) opened = body.opened.filter((item): item is string => typeof item === "string" && ID_PATTERN.test(item)).slice(0, 500);
    } catch {
      return problem(400, "Expected the shared pages you've opened, or nothing.");
    }
  }
  const found = ID_PATTERN.test(id) ? await find(env.DB, id) : null;
  if (!found) return problem(404, "There's no shared page here.");
  const owner = found.row.owner_id;
  // Shared before accounts: there's nobody to block, only this page to remove.
  if (!owner) return json({ blocked: false, hidden: [id] });
  if (owner === user.id) return problem(400, "This is your own page.");
  await env.DB.prepare("INSERT INTO blocked_sharers (user_id, owner_id, title, created_at) VALUES (?, ?, ?, ?) ON CONFLICT (user_id, owner_id) DO NOTHING")
    .bind(user.id, owner, found.row.title.slice(0, 300), now())
    .run();
  const others = opened.filter((other) => other !== id);
  let hidden = [id];
  if (others.length) {
    const { results } = await env.DB.prepare(`SELECT id FROM surfaces WHERE owner_id = ? AND id IN (${others.map(() => "?").join(", ")})`)
      .bind(owner, ...others)
      .all<{ id: string }>();
    hidden = hidden.concat(results.map((row) => row.id));
  }
  return json({ blocked: true, hidden });
}

export async function blockedList(request: Request, env: SharingEnv): Promise<Response> {
  const user = await userFrom(request, env);
  if (!user) return signInNeeded();
  const { results } = await env.DB.prepare("SELECT id, title, created_at FROM blocked_sharers WHERE user_id = ? ORDER BY created_at DESC LIMIT 500")
    .bind(user.id)
    .all<{ id: number; title: string; created_at: number }>();
  return json({ blocked: results.map((row) => ({ id: row.id, title: row.title, created: row.created_at })) });
}

export async function unblock(request: Request, env: SharingEnv, n: string): Promise<Response> {
  const user = await userFrom(request, env);
  if (!user) return signInNeeded();
  if (!/^\d{1,15}$/.test(n)) return problem(404, "Not found.");
  await env.DB.prepare("DELETE FROM blocked_sharers WHERE id = ? AND user_id = ?").bind(Number(n), user.id).run();
  return json(null, 204);
}

// MARK: - Admin

async function sha256(text: string): Promise<ArrayBuffer> {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
}

/** Whether `given` is the admin key: compared as hashes, in constant time, so neither its length
 * nor its content leaks through timing. Without a key of a sensible length set, nobody is admin. */
async function isAdminKey(env: SharingEnv, given: string | null): Promise<boolean> {
  const key = env.ADMIN_KEY ?? "";
  if (key.length < 32 || !given) return false;
  return crypto.subtle.timingSafeEqual(await sha256(given), await sha256(key));
}

interface Case {
  id: string;
  title: string;
  state: string;
  owner: string | null;
  views: number;
  created: number;
  reports: number;
  reasons: Record<string, number>;
  notes: string[];
  last: number;
}

/** Open reports, one case per page, the most reported first. */
async function openCases(env: SharingEnv): Promise<Case[]> {
  const { results } = await env.DB.prepare(
    `SELECT reports.share_id AS id, reports.reason AS reason, reports.note AS note, reports.created_at AS at,
       surfaces.title AS title, surfaces.owner_id AS owner, surfaces.views AS views, surfaces.created_at AS created,
       surfaces.revoked_at AS revoked_at, surfaces.revoked_by AS revoked_by, surfaces.expires_at AS expires_at
     FROM reports JOIN surfaces ON surfaces.id = reports.share_id
     WHERE reports.resolved_at IS NULL ORDER BY reports.created_at DESC LIMIT 2000`,
  ).all<{ id: string; reason: string; note: string | null; at: number; title: string; owner: string | null; views: number; created: number; revoked_at: number | null; revoked_by: string | null; expires_at: number | null }>();
  const cases = new Map<string, Case>();
  for (const row of results) {
    const state = stateOf({ revoked_at: row.revoked_at, revoked_by: row.revoked_by, expires_at: row.expires_at } as ShareRow);
    const item = cases.get(row.id) ?? { id: row.id, title: row.title, state, owner: row.owner, views: row.views, created: row.created, reports: 0, reasons: {}, notes: [], last: row.at };
    item.reports++;
    item.reasons[row.reason] = (item.reasons[row.reason] ?? 0) + 1;
    if (row.note && item.notes.length < 10) item.notes.push(row.note);
    cases.set(row.id, item);
  }
  return [...cases.values()].sort((a, b) => b.reports - a.reports || b.last - a.last).slice(0, 200);
}

async function bans(env: SharingEnv): Promise<{ user: string; created: number }[]> {
  const { results } = await env.DB.prepare("SELECT user_id, created_at FROM sharing_bans ORDER BY created_at DESC LIMIT 200").all<{ user_id: string; created_at: number }>();
  return results.map((row) => ({ user: row.user_id, created: row.created_at }));
}

/** Stops an account sharing, and takes down everything it still shares. */
async function ban(env: SharingEnv, userID: string): Promise<void> {
  await env.DB.prepare("INSERT INTO sharing_bans (user_id, created_at) VALUES (?, ?) ON CONFLICT (user_id) DO NOTHING").bind(userID, now()).run();
  await revokeAllOf(env.DB, userID);
}

/** Takes a page down; with `andSharer`, its sharer can't share again either. */
async function takeDown(env: SharingEnv, id: string, andSharer: boolean): Promise<"done" | "missing"> {
  const found = ID_PATTERN.test(id) ? await find(env.DB, id) : null;
  if (!found) return "missing";
  await revoke(env.DB, id, "admin");
  await resolveReports(env, id, "removed");
  if (andSharer && found.row.owner_id) await ban(env, found.row.owner_id);
  return "done";
}

const USER_ID = /^[A-Za-z0-9-]{8,64}$/;

/** The admin's JSON routes, for scripts and curl. */
export async function adminAPI(request: Request, env: SharingEnv, path: string): Promise<Response> {
  if (!env.ADMIN_KEY) return problem(404, "Not found.");
  if (!(await underLimit(env.READ_LIMIT, `admin:${addressOf(request)}`))) return tooMany();
  if (!(await isAdminKey(env, request.headers.get("X-Admin-Key")))) return problem(401, "That isn't the admin key.");
  if (path === "/api/admin/reports" && request.method === "GET") return json({ cases: await openCases(env), bans: await bans(env) });
  if (request.method !== "POST") return problem(405, "Only POST.", {}, { Allow: "POST" });
  const surface = path.match(/^\/api\/admin\/surfaces\/([^/]+)\/(remove|dismiss)$/);
  if (surface) {
    const [, id, action] = surface;
    if (action === "dismiss") {
      await resolveReports(env, id, "dismissed");
      return json({ dismissed: true });
    }
    let andSharer = false;
    if (isJSON(request)) {
      const body: unknown = await request.json().catch(() => null);
      andSharer = isObject(body) && body.block === true;
    }
    return (await takeDown(env, id, andSharer)) === "done" ? json({ removed: true, blocked: andSharer }) : problem(404, "There's no shared page here.");
  }
  const user = path.match(/^\/api\/admin\/users\/([^/]+)\/(block|unblock)$/);
  if (user && USER_ID.test(user[1])) {
    if (user[2] === "block") await ban(env, user[1]);
    else await env.DB.prepare("DELETE FROM sharing_bans WHERE user_id = ?").bind(user[1]).run();
    return json({ user: user[1], blocked: user[2] === "block" });
  }
  return problem(404, "Not found.");
}

/** The admin's page: a form for the key, then the open reports, each with what can be done.
 * There's no script and no cookie: the key travels in each form, posted back here. */
export async function adminPage(request: Request, env: SharingEnv): Promise<Response> {
  if (!env.ADMIN_KEY) return html(messagePage("Nothing here", "This page doesn't exist."), 404);
  const signIn = (problem?: string) =>
    html(
      formPage(
        "Reports",
        `<header><h1>Reports</h1><p class="summary">Shared pages people have reported.</p></header>
<form class="form" method="post" action="/admin">
<label class="stack-tight"><span class="secondary">Admin key</span><input type="password" name="key" autocomplete="current-password" required></label>
${problem ? `<p class="problem">${escape(problem)}</p>` : ""}
<button class="button" type="submit">Open</button>
</form>`,
      ),
      problem ? 401 : 200,
      "no-store",
      FORM_CSP,
    );
  if (request.method === "GET") return signIn();
  if (request.method !== "POST") return html(messagePage("Nothing here", "This page doesn't exist."), 405);
  if (!(await underLimit(env.READ_LIMIT, `admin:${addressOf(request)}`))) return html(messagePage("Slow down", "Too many requests at once. Try again in a minute."), 429);
  let form: URLSearchParams;
  try {
    form = new URLSearchParams(await readBody(request, 4_000));
  } catch {
    return signIn("That didn't work. Try again.");
  }
  const key = form.get("key");
  if (!(await isAdminKey(env, key))) return signIn("That isn't the admin key.");

  const action = form.get("action");
  const id = form.get("id") ?? "";
  let notice = "";
  if (action === "look") {
    const stored = ID_PATTERN.test(id) ? await loadForReview(env.DB, id) : null;
    const found = ID_PATTERN.test(id) ? await find(env.DB, id) : null;
    if (stored) return html(surfacePage(stored, new URL(request.url).origin), 200, "no-store");
    if (found) return html(gonePage(found.state === "shared" ? "stopped" : found.state), 200, "no-store");
    notice = "There's no shared page with that id.";
  } else if (action === "remove" || action === "remove-and-block") {
    notice = (await takeDown(env, id, action === "remove-and-block")) === "done" ? (action === "remove" ? "Taken down." : "Taken down, and its sharer can't share anymore.") : "There's no shared page with that id.";
  } else if (action === "dismiss" && ID_PATTERN.test(id)) {
    await resolveReports(env, id, "dismissed");
    notice = "Reports closed. The page stays up.";
  } else if (action === "unblock" && USER_ID.test(id)) {
    await env.DB.prepare("DELETE FROM sharing_bans WHERE user_id = ?").bind(id).run();
    notice = "That account can share again.";
  }

  const origin = new URL(request.url).origin;
  const button = (label: string, act: string, target: string, quiet = false) =>
    `<form method="post" action="/admin"><input type="hidden" name="key" value="${escape(key ?? "")}"><input type="hidden" name="action" value="${act}"><input type="hidden" name="id" value="${escape(target)}"><button class="button${quiet ? " quiet" : ""}" type="submit">${label}</button></form>`;
  const reasonName = Object.fromEntries(REPORT_REASONS);
  const date = (seconds: number) => new Date(seconds * 1000).toISOString().slice(0, 10);
  const cases = await openCases(env);
  const banned = await bans(env);
  const list = cases.length
    ? cases
        .map(
          (item) => `<section class="case">
<h3><a href="${escape(`${origin}/s/${item.id}`)}" rel="noreferrer">${escape(item.title || "Untitled")}</a></h3>
<p class="secondary">${item.reports} report${item.reports === 1 ? "" : "s"}: ${Object.entries(item.reasons).map(([reason, count]) => `${escape(reasonName[reason] ?? reason)} (${count})`).join(", ")}</p>
<p class="footnote">${escape(item.id)} · ${item.state === "shared" ? "shared" : escape(item.state)} · ${item.views} views · shared ${date(item.created)}${item.owner ? ` · sharer ${escape(item.owner)}` : " · shared before accounts"}</p>
${item.notes.length ? `<ul class="notes">${item.notes.map((note) => `<li>${escape(note)}</li>`).join("")}</ul>` : ""}
<div class="actions">${button("Look", "look", item.id, true)}${item.state === "removed" ? "" : button("Take down", "remove", item.id)}${item.owner ? button("Take down and block sharer", "remove-and-block", item.id) : ""}${button("Dismiss", "dismiss", item.id, true)}</div>
</section>`,
        )
        .join("\n")
    : `<p class="secondary">No open reports.</p>`;
  const blockedList = banned.length
    ? banned.map((row) => `<section class="case"><p>${escape(row.user)}</p><p class="footnote">Since ${date(row.created)}</p><div class="actions">${button("Let them share again", "unblock", row.user, true)}</div></section>`).join("\n")
    : `<p class="secondary">Nobody.</p>`;
  return html(
    formPage(
      "Reports",
      `<header><h1>Reports</h1><p class="summary">${cases.length ? `${cases.length} page${cases.length === 1 ? "" : "s"} reported.` : "Nothing waiting."}</p>${notice ? `<p class="note">${escape(notice)}</p>` : ""}</header>
${list}
<h3>Take down a link</h3>
<form class="form" method="post" action="/admin"><input type="hidden" name="key" value="${escape(key ?? "")}"><input type="hidden" name="action" value="remove">
<label class="stack-tight"><span class="secondary">The link's id, the ten characters after /s/</span><input type="text" name="id" pattern="[0-9A-Za-z]{10}" required></label>
<button class="button" type="submit">Take down</button></form>
<h3>Blocked from sharing</h3>
${blockedList}`,
    ),
    200,
    "no-store",
    FORM_CSP,
  );
}
