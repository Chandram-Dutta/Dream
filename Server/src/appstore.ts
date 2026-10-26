// Dream Plus, the subscription, as the App Store reports it. The app buys through StoreKit 2 and
// sends the signed transactions it gets; the App Store sends signed notifications when anything
// changes (a renewal, a refund, an expiry). Both are JWS (RFC 7515) signed with a certificate
// chain up to Apple Root CA - G3, checked here the way Apple's App Store Server Library checks
// them: three certificates in x5c, the intermediate signed by the pinned root (never by the root
// the sender included), Apple's marker extensions on the leaf and intermediate, every certificate
// valid when the data was signed, and an ES256 signature by the leaf.
//
//   POST /api/appstore/transactions    { signedTransactions: [JWS], signedRenewals?: [JWS] }  (signed in)
//   POST /api/appstore/notifications   { signedPayload: JWS }  (App Store Server Notifications v2)
//
// Formats: JWSTransactionDecodedPayload, JWSRenewalInfoDecodedPayload and
// responseBodyV2DecodedPayload in Apple's App Store Server API and Notifications documentation.
// Dates there are milliseconds since 1970.

import { certificate, ChainError, DERError, fromBase64, importKey, verifyChain, verifySignature, type Certificate } from "./x509";

/** Apple Root CA - G3, from https://www.apple.com/certificateauthority/ (SHA-256 fingerprint
 * 63343ABF B89A6A03 EBB57E9B 3F5FA7BE 7C4F5C75 6F3017B3 A8C488C3 653E9179). */
export const APPLE_ROOT_CA_G3 =
  "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==";

/** The App Store's marks: the leaf that signs receipts and transactions, and Apple's WWDR intermediate. */
const LEAF_MARK = "1.2.840.113635.100.6.11.1";
const INTERMEDIATE_MARK = "1.2.840.113635.100.6.2.1";

export class JWSError extends Error {}

const text = (bytes: Uint8Array) => new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);

function decodePart(part: string): Record<string, unknown> {
  if (!/^[A-Za-z0-9_-]+$/.test(part)) throw new JWSError("not base64url");
  const value: unknown = JSON.parse(text(fromBase64(part)));
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new JWSError("not an object");
  return value as Record<string, unknown>;
}

/** Verifies a JWS the App Store signed and returns its payload. `roots` are the trusted roots:
 * Apple's, plus a test root only in local development. */
export async function verifyJWS(jws: unknown, roots: Certificate[]): Promise<Record<string, unknown>> {
  if (typeof jws !== "string" || jws.length > 40_000) throw new JWSError("size");
  const parts = jws.split(".");
  if (parts.length !== 3) throw new JWSError("shape");
  try {
    const header = decodePart(parts[0]);
    const payload = decodePart(parts[1]);
    if (header.alg !== "ES256") throw new JWSError("algorithm");
    const chain = header.x5c;
    if (!Array.isArray(chain) || chain.length !== 3 || !chain.every((item) => typeof item === "string")) throw new JWSError("chain length");
    const leaf = certificate(fromBase64(chain[0] as string));
    const intermediate = certificate(fromBase64(chain[1] as string));
    // As Apple's library does without online checks: the chain must have been valid when signed.
    const at = typeof payload.signedDate === "number" ? payload.signedDate : Date.now();
    await verifyChain(leaf, intermediate, roots, at);
    if (!leaf.extensions.has(LEAF_MARK) || !intermediate.extensions.has(INTERMEDIATE_MARK)) throw new JWSError("not the App Store's certificates");
    if (leaf.curve !== "P-256") throw new JWSError("key");
    const signature = fromBase64(parts[2]);
    if (signature.length !== 64) throw new JWSError("signature");
    const valid = await verifySignature(await importKey(leaf.spki, "P-256"), "P-256", "SHA-256", signature, new TextEncoder().encode(`${parts[0]}.${parts[1]}`), true);
    if (!valid) throw new JWSError("signature");
    return payload;
  } catch (error) {
    if (error instanceof JWSError) throw error;
    if (error instanceof ChainError || error instanceof DERError || error instanceof SyntaxError || error instanceof TypeError || error instanceof RangeError) throw new JWSError(error.message || "malformed");
    throw error;
  }
}

// MARK: - What the payloads say

export interface Transaction {
  transactionId: string;
  originalTransactionId: string;
  bundleId: string;
  productId: string;
  type: string;
  environment: string;
  signedDate: number;
  expiresDate?: number;
  revocationDate?: number;
  appAccountToken?: string;
  isUpgraded?: boolean;
}

export interface Renewal {
  originalTransactionId: string;
  environment: string;
  signedDate: number;
  /** 1 renews, 0 doesn't. */
  autoRenewStatus?: number;
  gracePeriodExpiresDate?: number;
}

const string = (value: unknown) => (typeof value === "string" && value.length > 0 && value.length <= 200 ? value : undefined);
const number = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : undefined);

export function asTransaction(payload: Record<string, unknown>): Transaction {
  const transaction = {
    transactionId: string(payload.transactionId),
    originalTransactionId: string(payload.originalTransactionId),
    bundleId: string(payload.bundleId),
    productId: string(payload.productId),
    type: string(payload.type),
    environment: string(payload.environment),
    signedDate: number(payload.signedDate),
  };
  for (const [key, value] of Object.entries(transaction)) if (value === undefined) throw new JWSError(`transaction without ${key}`);
  return {
    ...(transaction as Omit<Transaction, "expiresDate">),
    expiresDate: number(payload.expiresDate),
    revocationDate: number(payload.revocationDate),
    appAccountToken: string(payload.appAccountToken)?.toLowerCase(),
    isUpgraded: payload.isUpgraded === true,
  };
}

export function asRenewal(payload: Record<string, unknown>): Renewal {
  const originalTransactionId = string(payload.originalTransactionId);
  const environment = string(payload.environment);
  const signedDate = number(payload.signedDate);
  if (!originalTransactionId || !environment || signedDate === undefined) throw new JWSError("renewal info without its ids");
  return { originalTransactionId, environment, signedDate, autoRenewStatus: number(payload.autoRenewStatus), gracePeriodExpiresDate: number(payload.gracePeriodExpiresDate) };
}

// MARK: - Settings

export interface StoreEnv {
  DB: D1Database;
  DEV_LOGIN?: string;
  /** `<Team ID>.<bundle ID>`; the first one is Dream's own. */
  APP_IDS: string;
  /** The app's Apple ID in App Store Connect (a number). Checked on production notifications once set. */
  APPSTORE_APP_APPLE_ID?: string;
  /** Which App Store environments count, separated by commas. Sandbox covers TestFlight and App Review. */
  APPSTORE_ENVIRONMENTS?: string;
  /** Local development only (with DEV_LOGIN): one more root to trust, base64 DER, for tests. */
  APPSTORE_TEST_ROOT?: string;
}

/** The products that make someone a subscriber: Dream Plus, monthly and yearly (Dream/Subscription/Products.swift). */
export const PRODUCTS = new Set(["xyz.onlychan.dream.plus.monthly", "xyz.onlychan.dream.plus.yearly"]);

export function bundleID(env: { APP_IDS: string }): string {
  const first = (env.APP_IDS ?? "").split(",")[0]?.trim() ?? "";
  return first.slice(first.indexOf(".") + 1);
}

export function environments(env: StoreEnv): Set<string> {
  return new Set((env.APPSTORE_ENVIRONMENTS ?? "Production,Sandbox").split(",").map((item) => item.trim()).filter(Boolean));
}

let pinned: Certificate | undefined;

export function trustedRoots(env: StoreEnv): Certificate[] {
  pinned ??= certificate(fromBase64(APPLE_ROOT_CA_G3));
  const roots = [pinned];
  if (env.DEV_LOGIN === "1" && env.APPSTORE_TEST_ROOT) roots.push(certificate(fromBase64(env.APPSTORE_TEST_ROOT)));
  return roots;
}

// MARK: - Subscriptions

export interface Subscription {
  product: string;
  /** Milliseconds; includes a billing grace period. */
  expiresAt: number;
  renews: boolean | null;
  environment: string;
}

/** The user's current subscription, if they have one that's paid up and not refunded. */
export async function activeSubscription(env: StoreEnv, userID: string): Promise<Subscription | null> {
  const allowed = [...environments(env)];
  const row = await env.DB.prepare(
    `SELECT product_id, expires_at, auto_renew, environment FROM subscriptions
     WHERE user_id = ? AND expires_at > ? AND revoked_at IS NULL AND environment IN (${allowed.map(() => "?").join(",") || "''"})
     ORDER BY expires_at DESC LIMIT 1`,
  )
    .bind(userID, Date.now(), ...allowed)
    .first<{ product_id: string; expires_at: number; auto_renew: number | null; environment: string }>();
  return row ? { product: row.product_id, expiresAt: row.expires_at, renews: row.auto_renew === null ? null : row.auto_renew === 1, environment: row.environment } : null;
}

export type Applied = "applied" | "ignored" | "someone else's";

/** Records what a verified transaction (and its renewal info, if known) says about a
 * subscription. The newest signed state wins, so notifications arriving out of order can't undo
 * a later one. A subscription already tied to another account stays with it. */
export async function apply(env: StoreEnv, userID: string, transaction: Transaction, renewal?: Renewal): Promise<Applied> {
  if (transaction.type !== "Auto-Renewable Subscription" || !PRODUCTS.has(transaction.productId)) return "ignored";
  // An upgrade moves the subscription to a new transaction, which arrives on its own.
  if (transaction.isUpgraded) return "ignored";
  const grace = renewal?.originalTransactionId === transaction.originalTransactionId ? renewal.gracePeriodExpiresDate ?? 0 : 0;
  const expiresAt = Math.max(transaction.expiresDate ?? 0, grace);
  const signedAt = Math.max(transaction.signedDate, renewal?.signedDate ?? 0);
  const renews = renewal?.autoRenewStatus === undefined ? null : renewal.autoRenewStatus === 1 ? 1 : 0;
  const row = await env.DB.prepare(
    `INSERT INTO subscriptions (original_transaction_id, user_id, product_id, environment, expires_at, revoked_at, auto_renew, signed_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (original_transaction_id) DO UPDATE SET
       product_id = excluded.product_id, environment = excluded.environment, expires_at = excluded.expires_at,
       revoked_at = excluded.revoked_at, auto_renew = COALESCE(excluded.auto_renew, subscriptions.auto_renew),
       signed_at = excluded.signed_at, updated_at = excluded.updated_at
     WHERE subscriptions.user_id = excluded.user_id AND excluded.signed_at >= subscriptions.signed_at
     RETURNING user_id`,
  )
    .bind(transaction.originalTransactionId, userID, transaction.productId, transaction.environment, expiresAt, transaction.revocationDate ?? null, renews, signedAt, Date.now())
    .first<{ user_id: string }>();
  if (row) return "applied";
  const owner = await env.DB.prepare("SELECT user_id FROM subscriptions WHERE original_transaction_id = ?").bind(transaction.originalTransactionId).first<{ user_id: string }>();
  // Otherwise it's an older state than one already applied, which is fine.
  return owner && owner.user_id !== userID ? "someone else's" : "applied";
}

/** Who a notification is about: whoever the subscription is already tied to, else the account
 * the app named when buying (appAccountToken is Dream's user id). */
async function ownerOf(env: StoreEnv, transaction: Transaction): Promise<string | null> {
  const known = await env.DB.prepare("SELECT user_id FROM subscriptions WHERE original_transaction_id = ?").bind(transaction.originalTransactionId).first<{ user_id: string }>();
  if (known) return known.user_id;
  if (!transaction.appAccountToken) return null;
  const user = await env.DB.prepare("SELECT id FROM users WHERE id = ? AND deleted_at IS NULL").bind(transaction.appAccountToken).first<{ id: string }>();
  return user?.id ?? null;
}

export type Verdict = { ok: true; applied: number } | { ok: false; status: number; message: string };

/** Signed transactions the app sends after buying, restoring or opening. Each must be for this
 * app, in an environment that counts, and either name this account or name none. */
export async function receiveTransactions(env: StoreEnv, userID: string, body: Record<string, unknown>): Promise<Verdict> {
  const signed = body.signedTransactions;
  const renewalsSigned = body.signedRenewals ?? [];
  if (!Array.isArray(signed) || signed.length < 1 || signed.length > 10 || !Array.isArray(renewalsSigned) || renewalsSigned.length > 10) {
    return { ok: false, status: 400, message: "Send signedTransactions, from 1 to 10 of them." };
  }
  const roots = trustedRoots(env);
  const counted = environments(env);
  const bundle = bundleID(env);
  const renewals = new Map<string, Renewal>();
  for (const jws of renewalsSigned) {
    try {
      const renewal = asRenewal(await verifyJWS(jws, roots));
      if (counted.has(renewal.environment)) renewals.set(renewal.originalTransactionId, renewal);
    } catch (error) {
      if (!(error instanceof JWSError)) throw error;
    }
  }
  let applied = 0;
  for (const jws of signed) {
    let transaction: Transaction;
    try {
      transaction = asTransaction(await verifyJWS(jws, roots));
    } catch (error) {
      if (error instanceof JWSError) return { ok: false, status: 400, message: "That purchase couldn't be checked with the App Store." };
      throw error;
    }
    if (transaction.bundleId !== bundle) return { ok: false, status: 400, message: "That purchase is for another app." };
    if (!counted.has(transaction.environment)) return { ok: false, status: 400, message: "That purchase was made in a test environment this server doesn't accept." };
    if (transaction.appAccountToken && transaction.appAccountToken !== userID.toLowerCase()) {
      return { ok: false, status: 409, message: "That subscription belongs to another Dream account." };
    }
    const result = await apply(env, userID, transaction, renewals.get(transaction.originalTransactionId));
    if (result === "someone else's") return { ok: false, status: 409, message: "That subscription belongs to another Dream account." };
    if (result === "applied") applied++;
  }
  return { ok: true, applied };
}

/** One App Store Server Notification. Answers 200 once it's handled, or when it's about no one
 * Dream knows (the app sends the purchase itself when it next opens); anything else is retried by
 * the App Store. */
export async function receiveNotification(env: StoreEnv, body: Record<string, unknown>): Promise<Verdict> {
  const roots = trustedRoots(env);
  let payload: Record<string, unknown>;
  try {
    payload = await verifyJWS(body.signedPayload, roots);
  } catch (error) {
    if (error instanceof JWSError) return { ok: false, status: 400, message: "That notification isn't signed by the App Store." };
    throw error;
  }
  const uuid = string(payload.notificationUUID);
  const type = string(payload.notificationType);
  const data = payload.data && typeof payload.data === "object" ? (payload.data as Record<string, unknown>) : null;
  if (!uuid || !type) return { ok: false, status: 400, message: "That notification is missing its id or type." };
  // Summaries, external purchase tokens and consent changes carry no subscription to apply.
  if (!data) return { ok: true, applied: 0 };
  if (data.bundleId !== bundleID(env)) return { ok: false, status: 400, message: "That notification is for another app." };
  const environment = string(data.environment);
  if (!environment || !environments(env).has(environment)) return { ok: true, applied: 0 };
  if (environment === "Production" && env.APPSTORE_APP_APPLE_ID && String(data.appAppleId) !== env.APPSTORE_APP_APPLE_ID.trim()) {
    return { ok: false, status: 400, message: "That notification is for another app." };
  }
  if (await env.DB.prepare("SELECT 1 FROM appstore_notifications WHERE uuid = ?").bind(uuid).first()) return { ok: true, applied: 0 };
  let applied = 0;
  if (type !== "TEST" && data.signedTransactionInfo) {
    let transaction: Transaction;
    let renewal: Renewal | undefined;
    try {
      transaction = asTransaction(await verifyJWS(data.signedTransactionInfo, roots));
      if (data.signedRenewalInfo) renewal = asRenewal(await verifyJWS(data.signedRenewalInfo, roots));
    } catch (error) {
      if (error instanceof JWSError) return { ok: false, status: 400, message: "That notification's transaction isn't signed by the App Store." };
      throw error;
    }
    if (transaction.bundleId !== bundleID(env)) return { ok: false, status: 400, message: "That notification is for another app." };
    const owner = await ownerOf(env, transaction);
    if (owner && (await apply(env, owner, transaction, renewal)) === "applied") applied = 1;
  }
  const at = Date.now();
  await env.DB.batch([
    env.DB.prepare("INSERT OR IGNORE INTO appstore_notifications (uuid, received_at) VALUES (?, ?)").bind(uuid, at),
    // Apple stops retrying after a few days, so a month of ids is plenty to spot repeats.
    env.DB.prepare("DELETE FROM appstore_notifications WHERE uuid IN (SELECT uuid FROM appstore_notifications WHERE received_at < ? LIMIT 50)").bind(at - 30 * 86_400_000),
  ]);
  return { ok: true, applied };
}
