// Who may read the operator's views, like the diagnostics summary: whoever sends the `ADMIN_KEY`
// secret in `X-Admin-Key`. Without the secret, those routes don't exist.
//
// No imports, so test/unit.mjs runs it in Node.

export interface AdminEnv {
  /** Secret. The operator's key, at least 16 characters; set with `wrangler secret put ADMIN_KEY`. */
  ADMIN_KEY?: string;
}

async function digest(text: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

/** "unset" when there's no usable key, so the route answers as if it weren't there. Keys are
 * compared as hashes, in constant time, so neither length nor content leaks through timing. */
export async function adminAccess(request: Request, env: AdminEnv): Promise<"yes" | "no" | "unset"> {
  const key = env.ADMIN_KEY?.trim() ?? "";
  if (key.length < 16) return "unset";
  const given = request.headers.get("X-Admin-Key")?.trim() ?? "";
  const [expected, actual] = await Promise.all([digest(key), digest(given)]);
  let difference = given.length === 0 ? 1 : 0;
  for (let index = 0; index < expected.length; index++) difference |= expected[index] ^ actual[index];
  return difference === 0 ? "yes" : "no";
}
