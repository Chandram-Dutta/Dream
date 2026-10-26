// Whether a request comes from the Dream app. Two proofs count:
//
// - App Attest, on iPhones: the app makes a key in the Secure Enclave and Apple attests, once,
//   that it belongs to a genuine copy of Dream (README.md, "App Attest"). After that, each model
//   and web request carries an assertion: a signature by that key over the request. An extracted
//   key is no use without the device.
// - The shared app key (`X-Dream-Key`, the DREAM_APP_KEYS secret): the floor, for the Mac bench,
//   `wrangler dev`, and phones set up by hand in Under the hood.
//
//   POST /api/attest/challenge   (signed in) → { challenge }        one use, five minutes
//   POST /api/attest/key         (signed in) { keyId, attestation, challenge } → 201
//
// Assertions travel as X-Dream-Attest-Key (the key id), X-Dream-Assertion (base64 CBOR) and
// X-Dream-Attest-Time (seconds). What's signed is `METHOD\npath\ntime\nhex(SHA-256(body))`. Apple
// suggests a fresh server challenge per assertion; instead the time bounds when an assertion
// can be used, the body hash binds it to one request, and the counter, which must not repeat,
// stops replays. Counters are accepted slightly out of order, since the app sends requests in
// parallel.

import { decode, decodeAll, CBORError, type CBOR } from "./cbor";
import { allowed, bodyBytes, isJSON, json, object, problem } from "./reply";
import { certificate, ChainError, concat, DERError, equal, firstOctetString, fromBase64, hex, importKey, sha256, toBase64, verifyChain, verifySignature, type Certificate } from "./x509";

/** Apple App Attestation Root CA, from https://www.apple.com/certificateauthority/ (SHA-256
 * fingerprint 1CB9823B A28BA6AD 2D33A006 941DE2AE 4F513EF1 D4E831B9 F7E0FA7B 6242C932). */
export const APP_ATTEST_ROOT =
  "MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYwJAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwKQXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNaFw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlvbiBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdhNbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9auYen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijVoyFraWVIyd/dganmrduC1bmTBGwD";

const NONCE_EXTENSION = "1.2.840.113635.100.8.2";
const AAGUIDS: Record<string, "production" | "development"> = {
  "appattest\0\0\0\0\0\0\0": "production",
  appattestdevelop: "development",
};
/** Launch validation categories that are Dream as shipped or as built for testing: TestFlight,
 * development and the App Store. Checked when the device reports one (newer systems do). */
const CATEGORIES = new Set([2, 3, 4]);

export class AttestError extends Error {}

export interface AttestEnv {
  DB: D1Database;
  DEV_LOGIN?: string;
  APP_IDS: string;
  /** Local development only (with DEV_LOGIN): one more root to trust, base64 DER, for tests. */
  ATTEST_TEST_ROOT?: string;
  ATTEST_LIMIT?: RateLimit;
}

export interface ProofEnv extends AttestEnv {
  /** Secret. The shared app keys, separated by commas so one can be rotated out. */
  DREAM_APP_KEYS?: string;
  /** "off" lets signed-in requests through without proof that they're from the app: an
   * emergency switch if App Attest misbehaves in production. */
  APP_PROOF?: string;
}

const appID = (env: { APP_IDS: string }) => (env.APP_IDS ?? "").split(",")[0]?.trim() ?? "";

let pinned: Certificate | undefined;
function roots(env: AttestEnv): Certificate[] {
  pinned ??= certificate(fromBase64(APP_ATTEST_ROOT));
  return env.DEV_LOGIN === "1" && env.ATTEST_TEST_ROOT ? [pinned, certificate(fromBase64(env.ATTEST_TEST_ROOT))] : [pinned];
}

const field = (map: CBOR, key: string): CBOR => (map instanceof Map ? map.get(key) : undefined);
const bytesOf = (value: CBOR): Uint8Array => {
  if (!(value instanceof Uint8Array)) throw new AttestError("expected bytes");
  return value;
};
const uint32 = (bytes: Uint8Array, at: number) => ((bytes[at] << 24) >>> 0) + (bytes[at + 1] << 16) + (bytes[at + 2] << 8) + bytes[at + 3];

/** The launch validation category in authenticator data's extensions, when there is one. */
function category(authData: Uint8Array, extensionsAt: number, key: string): number | undefined {
  if (!(authData[32] & 0x80) || extensionsAt >= authData.length) return undefined;
  const extensions = decode(authData, extensionsAt).value;
  const value = field(extensions, key);
  return typeof value === "number" ? value : undefined;
}

export interface Attested {
  spki: Uint8Array;
  environment: "production" | "development";
  receipt: Uint8Array;
}

/** Checks an attestation object as Apple's "Validating apps that connect to your server" lays out. */
export async function verifyAttestation(attestation: Uint8Array, keyID: Uint8Array, challenge: Uint8Array, app: string, trusted: Certificate[], now = Date.now()): Promise<Attested> {
  try {
    const object = decodeAll(attestation);
    if (field(object, "fmt") !== "apple-appattest") throw new AttestError("format");
    const statement = field(object, "attStmt");
    const chain = field(statement, "x5c");
    if (!Array.isArray(chain) || chain.length < 2) throw new AttestError("chain");
    const receipt = bytesOf(field(statement, "receipt"));
    const authData = bytesOf(field(object, "authData"));
    // 1. The credential certificate chains to Apple's App Attest root.
    const credential = certificate(bytesOf(chain[0]));
    const intermediate = certificate(bytesOf(chain[1]));
    await verifyChain(credential, intermediate, trusted, now);
    if (credential.curve !== "P-256") throw new AttestError("key");
    // 2–4. Its nonce extension is SHA-256(authData ‖ SHA-256(challenge)).
    const nonce = await sha256(concat(authData, await sha256(challenge)));
    const extension = credential.extensions.get(NONCE_EXTENSION);
    const embedded = extension ? firstOctetString(extension) : null;
    if (!embedded || !equal(embedded, nonce)) throw new AttestError("nonce");
    // 5. The key id is SHA-256 of the public key, as an uncompressed point.
    if (!equal(await sha256(credential.point), keyID)) throw new AttestError("key id");
    if (authData.length < 55) throw new AttestError("authenticator data");
    // 6. The RP ID is SHA-256 of Dream's App ID.
    if (!equal(authData.subarray(0, 32), await sha256(new TextEncoder().encode(app)))) throw new AttestError("app");
    // 7. A new key has signed nothing yet.
    if (uint32(authData, 33) !== 0) throw new AttestError("counter");
    // 8. The AAGUID says which App Attest environment made it.
    const environment = AAGUIDS[String.fromCharCode(...authData.subarray(37, 53))];
    if (!environment) throw new AttestError("aaguid");
    // 9. The credential id is the key id.
    const length = (authData[53] << 8) + authData[54];
    if (!equal(authData.subarray(55, 55 + length), keyID)) throw new AttestError("credential id");
    // 10. A launch category, where the device gives one, is Dream as built by its team.
    const keyEnd = decode(authData, 55 + length).end;
    const launched = category(authData, keyEnd, "apple_validation_category_01");
    if (launched !== undefined && !CATEGORIES.has(launched)) throw new AttestError("category");
    return { spki: credential.spki, environment, receipt };
  } catch (error) {
    if (error instanceof AttestError) throw error;
    if (error instanceof CBORError || error instanceof DERError || error instanceof ChainError || error instanceof RangeError || error instanceof TypeError) throw new AttestError(error.message || "malformed");
    throw error;
  }
}

/** Checks an assertion's signature and app, and returns its counter. */
export async function verifyAssertion(assertion: Uint8Array, clientData: Uint8Array, spki: Uint8Array, app: string): Promise<number> {
  try {
    const object = decodeAll(assertion);
    const signature = bytesOf(field(object, "signature"));
    const authData = bytesOf(field(object, "authenticatorData"));
    if (authData.length < 37) throw new AttestError("authenticator data");
    const nonce = await sha256(concat(authData, await sha256(clientData)));
    if (!(await verifySignature(await importKey(spki, "P-256"), "P-256", "SHA-256", signature, nonce))) throw new AttestError("signature");
    if (!equal(authData.subarray(0, 32), await sha256(new TextEncoder().encode(app)))) throw new AttestError("app");
    const launched = category(authData, 37, "validationCategory");
    if (launched !== undefined && !CATEGORIES.has(launched)) throw new AttestError("category");
    return uint32(authData, 33);
  } catch (error) {
    if (error instanceof AttestError) throw error;
    if (error instanceof CBORError || error instanceof RangeError || error instanceof TypeError) throw new AttestError(error.message || "malformed");
    throw error;
  }
}

/** How many counters below the highest may still arrive late, each once. */
const WINDOW = 20;

/** Where a counter leaves a key's (highest, seen) window, or null if it's a repeat or too old.
 * Bit i of `seen` means counter highest - 1 - i has been used. */
export function advance(highest: number, seen: number, counter: number): { highest: number; seen: number } | null {
  if (counter > highest) {
    const shift = counter - highest;
    return { highest: counter, seen: shift > WINDOW ? 0 : (seen * 2 ** shift + 2 ** (shift - 1)) % 2 ** WINDOW };
  }
  const index = highest - 1 - counter;
  if (counter === highest || index >= WINDOW) return null;
  const bit = 2 ** index;
  if (Math.floor(seen / bit) % 2 === 1) return null;
  return { highest, seen: seen + bit };
}

export const clientData = (method: string, path: string, time: string, bodyHash: Uint8Array) => new TextEncoder().encode(`${method}\n${path}\n${time}\n${hex(bodyHash)}`);

type AssertionCheck = "valid" | "invalid" | "unknown key" | "absent";

async function checkAssertion(request: Request, env: AttestEnv, body: Uint8Array): Promise<AssertionCheck> {
  const keyID = request.headers.get("X-Dream-Attest-Key");
  const assertion = request.headers.get("X-Dream-Assertion");
  const time = request.headers.get("X-Dream-Attest-Time");
  if (!keyID || !assertion || !time) return "absent";
  if (!/^[A-Za-z0-9+/=]{40,60}$/.test(keyID) || assertion.length > 4_000 || !/^\d{9,11}$/.test(time)) return "invalid";
  if (Math.abs(Number(time) - Date.now() / 1000) > 120) return "invalid";
  const row = await env.DB.prepare("SELECT public_key, counter, seen FROM attest_keys WHERE key_id = ?").bind(keyID).first<{ public_key: string; counter: number; seen: number }>();
  if (!row) return "unknown key";
  let counter: number;
  try {
    counter = await verifyAssertion(fromBase64(assertion), clientData(request.method, new URL(request.url).pathname, time, await sha256(body)), fromBase64(row.public_key), appID(env));
  } catch (error) {
    if (error instanceof AttestError || error instanceof DOMException) return "invalid";
    throw error;
  }
  // Compare and set, so two requests can't both spend the same counter.
  let state = { highest: row.counter, seen: row.seen };
  for (let attempt = 0; attempt < 4; attempt++) {
    const next = advance(state.highest, state.seen, counter);
    if (!next) return "invalid";
    const result = await env.DB.prepare("UPDATE attest_keys SET counter = ?, seen = ?, last_used_at = ? WHERE key_id = ? AND counter = ? AND seen = ?")
      .bind(next.highest, next.seen, Math.floor(Date.now() / 1000), keyID, state.highest, state.seen)
      .run();
    if (result.meta.changes === 1) return "valid";
    const fresh = await env.DB.prepare("SELECT counter, seen FROM attest_keys WHERE key_id = ?").bind(keyID).first<{ counter: number; seen: number }>();
    if (!fresh) return "unknown key";
    state = { highest: fresh.counter, seen: fresh.seen };
  }
  return "invalid";
}

/** Whether the request carries one of the shared app keys, compared in constant time. */
async function keyMatches(request: Request, env: ProofEnv): Promise<"yes" | "no" | "unset"> {
  const keys = (env.DREAM_APP_KEYS ?? "").split(",").map((key) => key.trim()).filter((key) => key.length >= 16);
  if (!keys.length) return "unset";
  const given = request.headers.get("X-Dream-Key")?.trim();
  if (!given || given.length < 16 || given.length > 200) return "no";
  const digest = async (text: string) => crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  const hash = await digest(given);
  let match = false;
  for (const key of keys) if (crypto.subtle.timingSafeEqual(hash, await digest(key))) match = true;
  return match ? "yes" : "no";
}

/** Whether a request is from the app, or the answer to send back if it isn't. `what` names the
 * feature for a server that isn't set up. */
export async function proveApp(request: Request, env: ProofEnv, body: Uint8Array, what: string): Promise<Response | null> {
  if (env.APP_PROOF === "off") return null;
  const assertion = await checkAssertion(request, env, body);
  if (assertion === "valid") return null;
  const key = await keyMatches(request, env);
  if (key === "yes") return null;
  if (key === "unset" && assertion === "absent") return problem(503, `${what} isn't set up on this server yet.`);
  // An unknown key means this server never saw it, or forgot it: the app makes a new one.
  return problem(401, "This is for the Dream app.", assertion === "unknown key" ? { "X-Dream-Attest": "again" } : {});
}

// MARK: - Routes

const now = () => Math.floor(Date.now() / 1000);

/** A one-time challenge for attesting a new key. */
export async function challenge(env: AttestEnv, userID: string): Promise<Response> {
  if (!(await allowed(env.ATTEST_LIMIT, `attest:${userID}`))) return problem(429, "Too many tries. Try again in a minute.", { "Retry-After": "60" });
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const value = toBase64(bytes);
  await env.DB.batch([
    env.DB.prepare("INSERT INTO attest_challenges (challenge, user_id, expires_at) VALUES (?, ?, ?)").bind(value, userID, now() + 300),
    env.DB.prepare("DELETE FROM attest_challenges WHERE challenge IN (SELECT challenge FROM attest_challenges WHERE expires_at < ? LIMIT 50)").bind(now()),
  ]);
  return json({ challenge: value });
}

/** Keeps a newly attested key, after checking its attestation against the challenge it was made for. */
export async function register(request: Request, env: AttestEnv, userID: string): Promise<Response> {
  if (!(await allowed(env.ATTEST_LIMIT, `attest:${userID}`))) return problem(429, "Too many tries. Try again in a minute.", { "Retry-After": "60" });
  if (!isJSON(request)) return problem(415, "Send application/json.");
  const raw = await bodyBytes(request, 20_000);
  if (!raw) return problem(413, "That's too big.");
  const body = object(raw);
  const keyID = typeof body?.keyId === "string" ? body.keyId : "";
  const attestation = typeof body?.attestation === "string" ? body.attestation : "";
  const given = typeof body?.challenge === "string" ? body.challenge : "";
  if (!/^[A-Za-z0-9+/=]{40,60}$/.test(keyID) || !attestation || attestation.length > 16_000 || !given) return problem(400, "Send keyId, attestation and challenge.");
  const used = await env.DB.prepare("DELETE FROM attest_challenges WHERE challenge = ? AND user_id = ? AND expires_at >= ? RETURNING challenge").bind(given, userID, now()).first();
  if (!used) return problem(400, "That challenge has expired. Ask for a new one.");
  let attested: Attested;
  try {
    attested = await verifyAttestation(fromBase64(attestation), fromBase64(keyID), fromBase64(given), appID(env), roots(env));
  } catch (error) {
    if (error instanceof AttestError || error instanceof DOMException) return problem(400, "That attestation didn't check out.");
    throw error;
  }
  const at = now();
  const inserted = await env.DB.prepare(
    "INSERT INTO attest_keys (key_id, user_id, public_key, environment, counter, seen, receipt, created_at, last_used_at) VALUES (?, ?, ?, ?, 0, 0, ?, ?, ?) ON CONFLICT (key_id) DO NOTHING RETURNING key_id",
  )
    .bind(keyID, userID, toBase64(attested.spki), attested.environment, toBase64(attested.receipt), at, at)
    .first();
  if (!inserted) return problem(409, "That key is already known.");
  return json({ keyId: keyID, environment: attested.environment }, 201);
}
