// Answers for the sharing routes (sharing.ts, shares.ts, safety.ts): JSON, problems, pages, and
// rate limits. Never cached by default, since links can stop or change at any time.

import { CSP } from "./page";

const SECURITY = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Cross-Origin-Resource-Policy": "same-origin",
};

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(status === 204 ? null : JSON.stringify(body), {
    status,
    headers: { ...SECURITY, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...headers },
  });
}

/** A refusal, in words, with anything the app needs to tell refusals apart. */
export function problem(status: number, message: string, extra: Record<string, unknown> = {}, headers: Record<string, string> = {}): Response {
  return json({ error: message, ...extra }, status, headers);
}

export function html(body: string, status = 200, cache = "no-store", csp = CSP): Response {
  return new Response(body, {
    status,
    headers: { ...SECURITY, "Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": csp, "X-Frame-Options": "DENY", "Cache-Control": cache },
  });
}

export const tooMany = () => problem(429, "Too many requests. Try again in a minute.", {}, { "Retry-After": "60" });

/** Whether this key is still under its limit. Keys are an address or an account id, which
 * Cloudflare counts and the Worker never stores. Without a limiter, everything is let through. */
export async function underLimit(limiter: RateLimit | undefined, key: string): Promise<boolean> {
  if (!limiter) return true;
  return (await limiter.limit({ key })).success;
}

export const addressOf = (request: Request) => request.headers.get("CF-Connecting-IP") ?? "unknown";

/** Whether a request says it sends JSON, the only kind the API reads. */
export function isJSON(request: Request): boolean {
  return /^application\/json(\s*;|$)/i.test(request.headers.get("Content-Type") ?? "");
}
