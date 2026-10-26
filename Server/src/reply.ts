// Answers for the app's account routes (plan.ts and the files it calls): JSON, never cached.

const HEADERS = { "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Cache-Control": "no-store" };

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...HEADERS, "Content-Type": "application/json; charset=utf-8", ...headers } });
}

export function problem(status: number, message: string, headers: Record<string, string> = {}, extra: Record<string, unknown> = {}): Response {
  return json({ error: message, ...extra }, status, headers);
}

/** Whether this key is still under its limit. Without a limiter (an unconfigured deployment),
 * everything is let through. Keys are user ids or addresses, which Cloudflare counts and the
 * Worker never stores. */
export async function allowed(limiter: RateLimit | undefined, key: string): Promise<boolean> {
  if (!limiter) return true;
  return (await limiter.limit({ key })).success;
}

/** At most `max` bytes of the body, or null if there's more. */
export async function bodyBytes(request: Request, max: number): Promise<Uint8Array | null> {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > max) return null;
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

/** A JSON object from bytes, or null. */
export function object(bytes: Uint8Array): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
    return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

export const isJSON = (request: Request) => /^application\/json(\s*;|$)/i.test(request.headers.get("Content-Type") ?? "");
