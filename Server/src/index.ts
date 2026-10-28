// Dream's sharing server: stores shared surfaces under short, unguessable ids, hands them back to
// the app as JSON, shows them on the web to people without Dream, and tells iOS which links the
// app opens.
//
//   POST /api/surfaces        a shared surface (JSON), from a signed-in user  → 201 { id, url }
//   GET  /api/surfaces/:id    the shared surface, for the app; PUT and DELETE for its owner
//   GET  /s/:id               the web viewer; also the universal link the app opens
//   …                         owners' links, reports, blocks and the admin (sharing.ts)
//   GET  /.well-known/apple-app-site-association
//   GET  /api/mcp/featured, /api/mcp/servers   the directory of MCP servers (directory.ts)
//   POST /api/search, POST /api/read, GET /reader   web search and pages, for the app (web.ts)
//   POST /api/dev/session     a test user's session, in local development only (auth.ts)
//   POST /api/auth/apple, /api/me…   signing in with Apple, the account, export and deletion (accounts.ts)
//   GET, POST /api/sync; GET, PUT, DELETE /api/photos/:id   a signed-in person's own data (sync.ts)
//   POST /api/model, GET /api/usage, /api/appstore/*, /api/attest/*   the model, limits and Dream Plus (plan.ts)
//   GET  /privacy, /terms, /support   the policy, terms and help (legal.ts)
//   POST /api/diagnostics     crash and hang reports, anonymous; GET /api/admin/diagnostics (diagnostics.ts)
//
// Nothing personal is logged: no addresses, no surface content. Addresses are only used as
// rate-limit keys, which Cloudflare counts and the Worker never stores.

import { refreshAppleKeys, routeAccounts } from "./accounts";
import type { AppleEnv } from "./apple";
import { devSession, type AuthEnv } from "./auth";
import { directory } from "./directory";
import { CSP, messagePage } from "./page";
import { routePlan, type PlanEnv } from "./plan";
import { routeRelease, type ReleaseEnv } from "./release";
import { routeSharing, type SharingEnv } from "./sharing";
import { routeSync, type SyncEnv } from "./sync";
import { routeWeb, type WebEnv } from "./web";

export interface Env extends WebEnv, AuthEnv, AppleEnv, SharingEnv, SyncEnv, PlanEnv, ReleaseEnv {
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
      const release = await routeRelease(request, env, ctx, url);
      if (release) return release;
      if (path === "/api/dev/session") {
        const session = await devSession(request, env);
        if (session) return session;
      }
      if (path === "/api/auth/apple" || path.startsWith("/api/me")) {
        const account = await routeAccounts(request, env, url);
        if (account) return account;
      }
      const synced = await routeSync(request, env, url);
      if (synced) return synced;
      if (path === "/.well-known/apple-app-site-association" || path === "/apple-app-site-association") {
        return reading ? associatedDomains(env) : problem(405, "Only GET.", { Allow: "GET, HEAD" });
      }
      // Shared links, their owners, reports, blocks and the admin (sharing.ts).
      const sharing = await routeSharing(request, env, ctx, url);
      if (sharing) return sharing;
      if (path.startsWith("/api/mcp/")) {
        if (!reading) return problem(405, "Only GET.", { Allow: "GET, HEAD" });
        if (!(await allowed(env.READ_LIMIT, request, "directory"))) return problem(429, "Too many requests. Try again in a minute.", { "Retry-After": "60" });
        const answer = await directory(request, url);
        if (answer) return answer;
      }
      // "/" is the landing page in public/ (scripts/copy-website.mjs); this is only reached if a
      // build left it out.
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

  // Every few hours (wrangler.jsonc): Apple's sign-in keys, kept in D1 for sign-ins to read.
  async scheduled(_controller, env, ctx): Promise<void> {
    ctx.waitUntil(refreshAppleKeys(env));
  },
} satisfies ExportedHandler<Env>;
