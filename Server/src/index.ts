// Dream's sharing server: stores shared surfaces under short, unguessable ids, hands them back to
// the app as JSON, shows them on the web to people without Dream, and tells iOS which links the
// app opens.
//
//   POST /api/surfaces        a shared surface (JSON)  → 201 { id, url }
//   GET  /api/surfaces/:id    the shared surface, for the app
//   GET  /s/:id               the web viewer; also the universal link the app opens
//   GET  /.well-known/apple-app-site-association
//   GET  /api/mcp/featured, /api/mcp/servers   the directory of MCP servers (directory.ts)
//   POST /api/search, POST /api/read, GET /reader   web search and pages, for the app (web.ts)
//   POST /api/dev/session     a test user's session, in local development only (auth.ts)
//   POST /api/model, GET /api/usage, /api/appstore/*, /api/attest/*   the model, limits and Dream Plus (plan.ts)
//
// Nothing personal is logged: no addresses, no surface content. Addresses are only used as
// rate-limit keys, which Cloudflare counts and the Worker never stores.

import { devSession, type AuthEnv } from "./auth";
import { directory } from "./directory";
import { CSP, messagePage, surfacePage } from "./page";
import { parseShared, readBody, Rejection } from "./payload";
import { routePlan, type PlanEnv } from "./plan";
import { ID_PATTERN, load, save } from "./store";
import { routeWeb, type WebEnv } from "./web";

export interface Env extends WebEnv, AuthEnv, PlanEnv {
  DB: D1Database;
  CREATE_LIMIT?: RateLimit;
  READ_LIMIT?: RateLimit;
  /** Apps that open /s/ links, as `<Team ID>.<bundle ID>`, separated by commas. */
  APP_IDS: string;
}

const SECURITY = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Cross-Origin-Resource-Policy": "same-origin",
};

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...SECURITY, "Content-Type": "application/json; charset=utf-8", ...headers } });
}

function html(body: string, status = 200, cache = "no-store"): Response {
  return new Response(body, {
    status,
    headers: { ...SECURITY, "Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": CSP, "X-Frame-Options": "DENY", "Cache-Control": cache },
  });
}

function problem(status: number, message: string, headers: Record<string, string> = {}): Response {
  return json({ error: message }, status, { "Cache-Control": "no-store", ...headers });
}

/** Whether this address is still under its limit. Without a limiter (an unconfigured
 * deployment), everything is let through. */
async function allowed(limiter: RateLimit | undefined, request: Request, bucket: string): Promise<boolean> {
  if (!limiter) return true;
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const { success } = await limiter.limit({ key: `${bucket}:${address}` });
  return success;
}

/** Which app opens /s/ links: iOS reads this through Apple's CDN when Dream is installed. */
function associatedDomains(env: Env): Response {
  const appIDs = (env.APP_IDS ?? "")
    .split(",")
    .map((id) => id.trim())
    .filter((id) => /^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$/.test(id));
  return json(
    { applinks: { details: [{ appIDs, components: [{ "/": "/s/*", comment: "Shared surfaces" }] }] } },
    200,
    { "Cache-Control": "public, max-age=3600" },
  );
}

async function create(request: Request, env: Env, origin: string): Promise<Response> {
  if (!(await allowed(env.CREATE_LIMIT, request, "create"))) return problem(429, "Too many shares at once. Try again in a minute.", { "Retry-After": "60" });
  const type = request.headers.get("Content-Type") ?? "";
  if (!/^application\/json(\s*;|$)/i.test(type)) return problem(415, "Send the surface as application/json.");
  try {
    const shared = parseShared(await readBody(request));
    const id = await save(env.DB, shared);
    return json({ id, url: `${origin}/s/${id}` }, 201, { "Cache-Control": "no-store" });
  } catch (error) {
    if (error instanceof Rejection) return problem(error.status, error.message);
    throw error;
  }
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const reading = request.method === "GET" || request.method === "HEAD";
    try {
      const web = await routeWeb(request, env, ctx, url);
      if (web) return web;
      const plan = await routePlan(request, env, ctx, url);
      if (plan) return plan;
      if (path === "/api/dev/session") {
        const session = await devSession(request, env);
        if (session) return session;
      }
      if (path === "/.well-known/apple-app-site-association" || path === "/apple-app-site-association") {
        return reading ? associatedDomains(env) : problem(405, "Only GET.", { Allow: "GET, HEAD" });
      }
      if (path === "/api/surfaces") {
        return request.method === "POST" ? await create(request, env, url.origin) : problem(405, "Only POST.", { Allow: "POST" });
      }
      const api = path.match(/^\/api\/surfaces\/([^/]+)$/);
      const viewer = path.match(/^\/s\/([^/]+)\/?$/);
      if (api || viewer) {
        if (!reading) return problem(405, "Only GET.", { Allow: "GET, HEAD" });
        if (!(await allowed(env.READ_LIMIT, request, "read"))) {
          return api ? problem(429, "Too many requests. Try again in a minute.", { "Retry-After": "60" }) : html(messagePage("Slow down", "Too many requests at once. Try again in a minute."), 429);
        }
        const id = (api ?? viewer)![1];
        const stored = ID_PATTERN.test(id) ? await load(env.DB, id) : null;
        if (api) {
          if (!stored) return problem(404, "There's no shared screen here.");
          const { preview: _, ...forApp } = stored;
          return json(forApp, 200, { "Cache-Control": "public, max-age=3600" });
        }
        if (!stored) return html(messagePage("This screen isn't here", "The link may be incomplete, or the screen was taken down."), 404);
        return html(surfacePage(stored, url.origin), 200, "public, max-age=300");
      }
      if (path.startsWith("/api/mcp/")) {
        if (!reading) return problem(405, "Only GET.", { Allow: "GET, HEAD" });
        if (!(await allowed(env.READ_LIMIT, request, "directory"))) return problem(429, "Too many requests. Try again in a minute.", { "Retry-After": "60" });
        const answer = await directory(request, url);
        if (answer) return answer;
      }
      if (path === "/" && reading) {
        return html(messagePage("Dream", "Screens shared from Dream open here. Ask for something on your iPhone, and Dream makes a screen that explains it, works it out, or both."), 200, "public, max-age=3600");
      }
      return reading ? html(messagePage("Nothing here", "This page doesn't exist."), 404) : problem(404, "Not found.");
    } catch (error) {
      // The kind of failure only: never the request, the address or the surface.
      console.error("Request failed", error instanceof Error ? error.name : typeof error);
      return reading && !path.startsWith("/api/") ? html(messagePage("Something went wrong", "Try again in a moment."), 500) : problem(500, "Something went wrong. Try again in a moment.");
    }
  },
} satisfies ExportedHandler<Env>;
