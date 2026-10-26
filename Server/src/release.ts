// What a public release needs from the server (PRODUCTION.md, workstream E): the privacy policy,
// terms and support pages (legal.ts), and crash reports from the app with a summary for whoever
// runs Dream (diagnostics.ts).
//
//   GET  /privacy, /terms, /support
//   POST /api/diagnostics
//   GET  /api/admin/diagnostics?days=7    with X-Admin-Key

import type { AnalyticsEnv } from "./analytics";
import { diagnosticsSummary, receiveDiagnostics, type DiagnosticsEnv } from "./diagnostics";
import { isLegalPath, legalPage } from "./legal";
import { CSP } from "./page";

export interface ReleaseEnv extends DiagnosticsEnv, AnalyticsEnv {}

function only(method: string): Response {
  return new Response(JSON.stringify({ error: `Only ${method}.` }), {
    status: 405,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", Allow: method === "GET" ? "GET, HEAD" : method },
  });
}

/** These routes, or null for any other path. */
export async function routeRelease(request: Request, env: ReleaseEnv, ctx: ExecutionContext, url: URL): Promise<Response | null> {
  const path = url.pathname.length > 1 ? url.pathname.replace(/\/$/, "") : url.pathname;
  const reading = request.method === "GET" || request.method === "HEAD";
  if (isLegalPath(path)) {
    if (!reading) return only("GET");
    return new Response(legalPage(path), {
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Content-Security-Policy": CSP,
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer",
        "X-Frame-Options": "DENY",
        "Cache-Control": "public, max-age=3600",
      },
    });
  }
  if (path === "/api/diagnostics") return request.method === "POST" ? receiveDiagnostics(request, env, ctx) : only("POST");
  if (path === "/api/admin/diagnostics") return reading ? diagnosticsSummary(request, env, url) : only("GET");
  return null;
}
