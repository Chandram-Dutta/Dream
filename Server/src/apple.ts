// Sign in with Apple, on the server's side. The app signs in with Apple and sends the identity
// token Apple gave it; `verifyIdentityToken` checks it's really Apple's (its signature, against
// Apple's published keys), for Dream (the audience), still fresh, and made for this sign-in (the
// nonce). Deleting an account also asks Apple to forget Dream (`revoke`), which needs a client
// secret signed with Dream's Sign in with Apple key.
//
// Nothing here is logged, and tokens are never stored. Only types are imported, so
// test/accounts.mjs runs this file in Node with keys of its own.

export const APPLE = "https://appleid.apple.com";

export interface AppleEnv {
  /** Dream's bundle ID, the audience of its identity tokens. Several may be listed, separated by
   * commas; the first is the one that revokes. */
  APPLE_CLIENT_ID?: string;
  /** The developer team that owns the key. */
  APPLE_TEAM_ID?: string;
  /** Secret. The Sign in with Apple key's ID, from the developer portal. */
  APPLE_KEY_ID?: string;
  /** Secret. The key itself: the text of its .p8 file. */
  APPLE_PRIVATE_KEY?: string;
  /** A stand-in for appleid.apple.com. Only tests set it, and it's only used with DEV_LOGIN. */
  APPLE_BASE_URL?: string;
  DEV_LOGIN?: string;
}

/** Why an identity token was refused. Never says anything about who it was for. */
export type TokenFailure = "malformed" | "algorithm" | "key" | "signature" | "issuer" | "audience" | "expired" | "early" | "nonce" | "subject";

export class TokenRefused extends Error {
  readonly reason: TokenFailure;
  constructor(reason: TokenFailure) {
    super(`The identity token was refused: ${reason}`);
    this.reason = reason;
  }
}

/** Apple couldn't be reached, so nothing could be checked. */
export class AppleUnavailable extends Error {}

/** Named on every request to Apple: appleid.apple.com answers some agents, like curl's and the
 * Workers default, with 501 Not Implemented. */
const USER_AGENT = "Dream/1.0 (+https://dream.onlychan.xyz)";

/** What a verified identity token says. */
export interface AppleIdentity {
  /** Apple's stable id for the person, in Dream's team. */
  sub: string;
  /** Only when they shared it; with Hide My Email, an address Apple forwards. */
  email: string | null;
  isPrivateEmail: boolean;
  /** The token's nonce claim: a hash of the nonce the app made. */
  nonce: string;
  expiresAt: number;
}

/** Finds Apple's public key with this id, or null when Apple has none by that id. */
export type KeyLookup = (kid: string) => Promise<CryptoKey | null>;

/** Seconds of clock difference forgiven, either way. */
const LEEWAY = 60;

export function audiences(env: AppleEnv): string[] {
  return (env.APPLE_CLIENT_ID ?? "").split(",").map((id) => id.trim()).filter(Boolean);
}

/** Where Apple is: appleid.apple.com, or the tests' stand-in in local development. */
export function appleBase(env: AppleEnv): string {
  return env.DEV_LOGIN === "1" && env.APPLE_BASE_URL ? env.APPLE_BASE_URL.replace(/\/$/, "") : APPLE;
}

/** Checks an identity token from the app, made for the nonce it sends alongside (as made, before
 * hashing). Throws `TokenRefused` saying why it isn't good, or `AppleUnavailable`. */
export async function verifyIdentityToken(
  token: string,
  options: { audiences: string[]; nonce: string | null; key: KeyLookup; now?: number },
): Promise<AppleIdentity> {
  const now = options.now ?? Math.floor(Date.now() / 1000);
  const parts = token.split(".");
  if (parts.length !== 3 || parts.some((part) => !/^[A-Za-z0-9_-]+$/.test(part))) throw new TokenRefused("malformed");
  const header = decodeJSON(parts[0]);
  const claims = decodeJSON(parts[1]);
  const signature = decodeBase64URL(parts[2]);
  if (!header || !claims || !signature) throw new TokenRefused("malformed");
  // Only what Apple signs with. "none", or a symmetric algorithm, would let anyone write a token.
  if (header.alg !== "RS256") throw new TokenRefused("algorithm");
  if (typeof header.kid !== "string" || !header.kid) throw new TokenRefused("key");
  const key = await options.key(header.kid);
  if (!key) throw new TokenRefused("key");
  const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  if (!(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, signed))) throw new TokenRefused("signature");

  if (claims.iss !== APPLE) throw new TokenRefused("issuer");
  const audience = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!options.audiences.length || !audience.some((aud) => typeof aud === "string" && options.audiences.includes(aud))) throw new TokenRefused("audience");
  if (typeof claims.exp !== "number" || claims.exp + LEEWAY < now) throw new TokenRefused("expired");
  if (typeof claims.iat === "number" && claims.iat - LEEWAY > now) throw new TokenRefused("early");
  // The app put a hash of its nonce in the request to Apple, and Apple put it in the token: a
  // token made for some other sign-in doesn't match.
  if (options.nonce !== null && (typeof claims.nonce !== "string" || claims.nonce !== (await sha256Hex(options.nonce)))) throw new TokenRefused("nonce");
  if (typeof claims.sub !== "string" || !claims.sub || claims.sub.length > 200) throw new TokenRefused("subject");

  const email = typeof claims.email === "string" && claims.email.includes("@") && claims.email.length <= 320 ? claims.email : null;
  return {
    sub: claims.sub,
    email,
    isPrivateEmail: isPrivateRelay(email) || claims.is_private_email === true || claims.is_private_email === "true",
    nonce: typeof claims.nonce === "string" ? claims.nonce : "",
    expiresAt: claims.exp,
  };
}

/** Hide My Email addresses, which Apple forwards to the person's real one. */
export function isPrivateRelay(email: string | null): boolean {
  return !!email && /@privaterelay\.appleid\.com$/i.test(email);
}

// MARK: - Apple's keys

interface PublishedKey {
  kty?: string;
  kid?: string;
  alg?: string;
  n?: string;
  e?: string;
}

let published: { url: string; fetchedAt: number; keys: Map<string, CryptoKey> } | null = null;

/** Apple's signing keys, fetched from `<base>/auth/keys` and kept for a day. Apple rotates them, so
 * an id that isn't known yet fetches them again, at most once a minute. */
export function appleKeys(base: string = APPLE): KeyLookup {
  const url = `${base}/auth/keys`;
  return async (kid) => {
    const now = Date.now();
    const current = published?.url === url ? published : null;
    if (current && now - current.fetchedAt < 86_400_000 && current.keys.has(kid)) return current.keys.get(kid)!;
    if (current && now - current.fetchedAt < 60_000) return current.keys.get(kid) ?? null;
    let body: { keys?: PublishedKey[] };
    try {
      const response = await fetch(url, { headers: { Accept: "application/json", "User-Agent": USER_AGENT }, signal: AbortSignal.timeout(8_000) });
      if (!response.ok) throw new AppleUnavailable(`Apple's keys: ${response.status}`);
      body = await response.json();
    } catch (error) {
      console.error("Apple's keys couldn't be fetched:", error instanceof AppleUnavailable ? error.message : error instanceof Error ? error.name : typeof error);
      if (current) return current.keys.get(kid) ?? null;
      throw error instanceof AppleUnavailable ? error : new AppleUnavailable("Apple's keys couldn't be fetched");
    }
    const keys = new Map<string, CryptoKey>();
    for (const jwk of body.keys ?? []) {
      if (jwk.kty !== "RSA" || !jwk.kid || !jwk.n || !jwk.e || (jwk.alg && jwk.alg !== "RS256")) continue;
      try {
        keys.set(jwk.kid, await crypto.subtle.importKey("jwk", { kty: "RSA", n: jwk.n, e: jwk.e, alg: "RS256", ext: true }, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]));
      } catch {
        // A key that can't be read is one nothing can be checked against.
      }
    }
    published = { url, fetchedAt: now, keys };
    return keys.get(kid) ?? null;
  };
}

// MARK: - Revoking

/** What happened when Apple was asked to forget Dream for someone. */
export type Revocation = "revoked" | "no key" | "no code" | "someone else" | "failed";

/** The client secret Apple's token and revoke endpoints ask for: a short-lived token signed with
 * Dream's Sign in with Apple key (ES256). Null when the key isn't set. */
export async function clientSecret(env: AppleEnv, now = Math.floor(Date.now() / 1000)): Promise<string | null> {
  const clientID = audiences(env)[0];
  if (!env.APPLE_PRIVATE_KEY || !env.APPLE_KEY_ID || !env.APPLE_TEAM_ID || !clientID) return null;
  const key = await crypto.subtle.importKey("pkcs8", pemBytes(env.APPLE_PRIVATE_KEY), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = { alg: "ES256", kid: env.APPLE_KEY_ID.trim() };
  const claims = { iss: env.APPLE_TEAM_ID.trim(), iat: now, exp: now + 300, aud: APPLE, sub: clientID };
  const input = `${encodeBase64URL(JSON.stringify(header))}.${encodeBase64URL(JSON.stringify(claims))}`;
  // WebCrypto signs ECDSA as r ‖ s, which is what JWS expects.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
  return `${input}.${encodeBase64URL(new Uint8Array(signature))}`;
}

/** Asks Apple to forget Dream for the person who just confirmed with `code`, a fresh authorization
 * code from the app: it's exchanged for a refresh token, which is then revoked. That removes Dream
 * from their Apple ID's Sign in with Apple list. The exchange says whose code it was, and nothing
 * is revoked unless that's `sub`, the account being deleted. Never throws. */
export async function revoke(env: AppleEnv, code: string | null, sub: string | null): Promise<Revocation> {
  let secret: string | null;
  try {
    secret = await clientSecret(env);
  } catch {
    return "failed";
  }
  if (!secret) return "no key";
  if (!code) return "no code";
  const clientID = audiences(env)[0];
  const base = appleBase(env);
  try {
    const exchanged = await form(`${base}/auth/token`, { client_id: clientID, client_secret: secret, code, grant_type: "authorization_code" });
    if (!exchanged.ok) return "failed";
    const tokens = (await exchanged.json()) as { refresh_token?: string; access_token?: string; id_token?: string };
    const token = tokens.refresh_token ?? tokens.access_token;
    if (!token) return "failed";
    // Straight from Apple over TLS, so its claims can be read as they are.
    const claims = decodeJSON(tokens.id_token?.split(".")[1] ?? "");
    if (!sub || claims?.sub !== sub) return "someone else";
    const revoked = await form(`${base}/auth/revoke`, {
      client_id: clientID,
      client_secret: secret,
      token,
      token_type_hint: tokens.refresh_token ? "refresh_token" : "access_token",
    });
    return revoked.ok ? "revoked" : "failed";
  } catch {
    return "failed";
  }
}

function form(url: string, fields: Record<string, string>): Promise<Response> {
  return fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json", "User-Agent": USER_AGENT },
    body: new URLSearchParams(fields).toString(),
    signal: AbortSignal.timeout(10_000),
  });
}

// MARK: - Encoding

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function encodeBase64URL(data: string | Uint8Array): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function decodeBase64URL(text: string): Uint8Array | null {
  try {
    const binary = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (text.length % 4)) % 4));
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
}

function decodeJSON(part: string): Record<string, unknown> | null {
  const bytes = decodeBase64URL(part);
  if (!bytes) return null;
  try {
    const value = JSON.parse(new TextDecoder().decode(bytes));
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

/** A .p8 file's key as bytes. Its text may arrive with real line breaks or with "\n" written out. */
function pemBytes(pem: string): Uint8Array {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----(BEGIN|END) [A-Z ]+-----/g, "")
    .replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (character) => character.charCodeAt(0));
}
