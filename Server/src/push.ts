// Push notifications (docs/ServerGeneration.md, Stage 3): an iPhone that left a page being made
// on the server hears when it's ready, when Dream has a question about it, or when the page needs
// one of the phone's own tools (a connected service, a journey), which only run with the app
// open, so there's a reason to come back. The job (compose/runner.ts) only asks for one when
// nobody is watching the page.
//
//   POST   /api/push/devices          { token, environment } (contract.ts's PushDevice): this
//                                     iPhone, for the account signed in on it → 204
//   DELETE /api/push/devices/:token   forgets it, as at sign-out → 204
//
// Both need the user's session. A device is kept with the session that registered it
// (migrations/0010_push.sql), so a session that ends, signed out here or from another iPhone,
// takes its notifications with it.
//
// Notifications go to Apple's Push Notification service with token-based auth: a JWT signed
// (ES256) with Dream's APNs key, from the secrets APNS_KEY, APNS_KEY_ID and APNS_TEAM_ID. Until
// they're set, nothing is sent, and that's logged once. What a notification says is only ever the
// page's title, the request's first few words, or the name of a service the user connected: it's
// shown on a lock screen, and passes through Apple. Tokens are never logged.
//
// Only types are imported besides auth.ts, reply.ts and apple.ts, so test/push.mjs runs the
// sender in Node with a key of its own and a stand-in for Apple.

import { encodeBase64URL, pemBytes } from "./apple";
import { sessionHash, signInNeeded, userFrom, type AuthEnv } from "./auth";
import type { PushDevice, PushPayload } from "./compose/contract";
import { allowed, bodyBytes, isJSON, object, problem } from "./reply";

export interface PushEnv extends AuthEnv {
  DB: D1Database;
  /** Secret. Dream's APNs key: the text of its .p8 file. */
  APNS_KEY?: string;
  /** Secret. That key's ID, from the developer portal. */
  APNS_KEY_ID?: string;
  /** Secret. The developer team the key belongs to. */
  APNS_TEAM_ID?: string;
  /** A stand-in for APNs, for both environments. Only tests set it, and it's only used with DEV_LOGIN. */
  APNS_BASE_URL?: string;
  /** Registering is rare (a sign-in, a launch), so it shares the per-account limit on making things. */
  CREATE_LIMIT?: RateLimit;
}

/** The app's bundle ID, which every notification is for. */
export const TOPIC = "xyz.onlychan.Dream";
/** Devices kept per account; registering another lets the longest unused go. */
export const MAX_DEVICES = 5;
/** APNs device tokens are 32 bytes today; Apple says not to count on it. */
const TOKEN = /^(?:[0-9a-f]{2}){32,100}$/;
const MAX_BODY = 1_000;

const NO_CONTENT = { "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Cache-Control": "no-store" };

// MARK: - Devices

/** The push routes, or null for any other path. */
export async function routePush(request: Request, env: PushEnv, url: URL): Promise<Response | null> {
  const one = /^\/api\/push\/devices\/([^/]+)$/.exec(url.pathname);
  if (url.pathname !== "/api/push/devices" && !one) return null;
  const method = one ? "DELETE" : "POST";
  if (request.method !== method) return problem(405, `Only ${method}.`, { Allow: method });
  const user = await userFrom(request, env);
  if (!user) return signInNeeded();
  if (!(await allowed(env.CREATE_LIMIT, `push:${user.id}`))) return problem(429, "Too many requests at once. Try again in a minute.", { "Retry-After": "60" });
  if (one) {
    const token = one[1].toLowerCase();
    if (!TOKEN.test(token)) return problem(400, "That isn't a device token.");
    const removed = await env.DB.prepare("DELETE FROM push_devices WHERE token = ? AND user_id = ?").bind(token, user.id).run();
    return removed.meta.changes ? new Response(null, { status: 204, headers: NO_CONTENT }) : problem(404, "That iPhone isn't getting notifications.");
  }

  if (!isJSON(request)) return problem(415, "Send application/json.");
  const raw = await bodyBytes(request, MAX_BODY);
  if (!raw) return problem(413, "That's too much to send at once.");
  const device = readDevice(object(raw));
  if ("error" in device) return problem(400, device.error);
  const session = await sessionHash(request);
  if (!session) return signInNeeded();
  const at = Math.floor(Date.now() / 1000);
  // One iPhone, one account: a token registered again, after someone else signed in on it, moves.
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO push_devices (token, user_id, session_hash, environment, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?5)
       ON CONFLICT (token) DO UPDATE SET
         created_at = CASE WHEN push_devices.user_id = excluded.user_id THEN push_devices.created_at ELSE excluded.created_at END,
         user_id = excluded.user_id, session_hash = excluded.session_hash, environment = excluded.environment, updated_at = excluded.updated_at`,
    ).bind(device.token, user.id, session, device.environment, at),
    env.DB.prepare(
      `DELETE FROM push_devices WHERE user_id = ?1 AND token NOT IN
         (SELECT token FROM push_devices WHERE user_id = ?1 ORDER BY updated_at DESC, created_at DESC LIMIT ?2)`,
    ).bind(user.id, MAX_DEVICES),
  ]);
  return new Response(null, { status: 204, headers: NO_CONTENT });
}

/** A PushDevice from the app, checked and tidied, or what's wrong with it. */
export function readDevice(body: Record<string, unknown> | null): PushDevice | { error: string } {
  if (!body) return { error: "Expected a JSON object." };
  const token = typeof body.token === "string" ? body.token.trim().toLowerCase() : "";
  if (!TOKEN.test(token)) return { error: "token is the device token APNs gave the app, as hex." };
  const environment = body.environment;
  if (environment !== "sandbox" && environment !== "production") return { error: "environment is sandbox or production." };
  return { token, environment };
}

// MARK: - What a notification says

/** A notification, as the job asks for one. */
export interface Notice {
  /** In bold, above the body. */
  title?: string;
  body: string;
  /** What the app opens when it's tapped. */
  payload: PushPayload;
  /** When APNs stops trying to deliver it, in seconds since 1970. */
  expires: number;
}

/** The job, as much of it as a notification needs (runner.ts's JobRecord). */
interface Job {
  id: string;
  pageID: string;
  deadline: number | null;
}

const WORDS = 6;
const CHARACTERS = 40;
const TITLE = 80;

/** At most `max` characters of a text, ending in "…" when cut. Whole characters, never half an emoji. */
function clip(text: string, max: number): string {
  const characters = Array.from(text);
  return characters.length <= max ? text : `${characters.slice(0, max - 1).join("").trimEnd()}…`;
}

/** The request's first few words, as a notification may quote it. */
export function shortRequest(request: string): string {
  const words = request.trim().split(/\s+/).filter(Boolean);
  const first = words.slice(0, WORDS).join(" ");
  return clip(words.length > WORDS ? `${first}…` : first, CHARACTERS);
}

/** The page is made: its title, and nothing else from it. Kept for a day, as the job is. */
export function pageReady(job: Job, request: string, surface: { title?: unknown }, now = Date.now()): Notice {
  const title = typeof surface.title === "string" ? surface.title.replace(/\s+/g, " ").trim() : "";
  return {
    title: "Your page is ready",
    body: title ? clip(title, TITLE) : `“${shortRequest(request)}”`,
    payload: { page: job.pageID, job: job.id, kind: "done" },
    expires: Math.floor(now / 1000) + 24 * 3600,
  };
}

/** Questions wait on an answer. Once they've waited too long they're left to Dream, so the
 * notification goes then too. */
export function questionWaiting(job: Job, request: string, now = Date.now()): Notice {
  return {
    body: `Dream has a question about “${shortRequest(request)}”`,
    payload: { page: job.pageID, job: job.id, kind: "asking" },
    expires: Math.floor((job.deadline ?? now + 10 * 60_000) / 1000),
  };
}

/** One of the phone's tools waits on the app being opened: the service it reads (the travel
 * tool works out a journey, contract.ts), and the request's first few words. It lasts as long
 * as the call waits. */
export function phoneNeeded(job: Job, request: string, tool: { name: string; service?: string }, deadline: number): Notice {
  const what = tool.name === "travel" ? "work out a journey" : `read ${clip(tool.service?.replace(/\s+/g, " ").trim() || "a connected service", CHARACTERS)}`;
  return {
    body: `Dream needs your iPhone to ${what} for “${shortRequest(request)}”`,
    payload: { page: job.pageID, job: job.id, kind: "device" },
    expires: Math.floor(deadline / 1000),
  };
}

// MARK: - Apple

/** How to reach APNs, or null while the secrets aren't set. */
export interface APNsConfig {
  key: string;
  keyID: string;
  teamID: string;
  /** The tests' stand-in, in place of Apple's hosts. */
  base?: string;
}

export function apnsConfig(env: PushEnv): APNsConfig | null {
  const key = env.APNS_KEY?.trim();
  const keyID = env.APNS_KEY_ID?.trim();
  const teamID = env.APNS_TEAM_ID?.trim();
  if (!key || !keyID || !teamID) return null;
  const base = env.DEV_LOGIN === "1" && env.APNS_BASE_URL ? env.APNS_BASE_URL.replace(/\/$/, "") : undefined;
  return { key, keyID, teamID, base };
}

/** Where a device's notifications go: development builds' tokens only work with the sandbox. */
export function apnsHost(environment: PushDevice["environment"]): string {
  return environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
}

/** APNs wants its token reused, and made again no more than every 20 minutes and no less than
 * every 60. Each token's iat is the start of the half hour it's made in, so every copy of the
 * Worker signs for the same moment and a token is at most half an hour old when it's used. */
const TOKEN_WINDOW = 30 * 60;

let signed: { keyID: string; teamID: string; iat: number; token: string } | null = null;

/** The provider token for this half hour: ES256, signed with Dream's APNs key. */
export async function providerToken(config: APNsConfig, now = Date.now()): Promise<string> {
  const iat = Math.floor(now / 1000 / TOKEN_WINDOW) * TOKEN_WINDOW;
  if (signed && signed.iat === iat && signed.keyID === config.keyID && signed.teamID === config.teamID) return signed.token;
  const key = await crypto.subtle.importKey("pkcs8", pemBytes(config.key), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const input = `${encodeBase64URL(JSON.stringify({ alg: "ES256", kid: config.keyID }))}.${encodeBase64URL(JSON.stringify({ iss: config.teamID, iat }))}`;
  // WebCrypto signs ECDSA as r ‖ s, which is what JWS expects.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
  const token = `${input}.${encodeBase64URL(new Uint8Array(signature))}`;
  signed = { keyID: config.keyID, teamID: config.teamID, iat, token };
  return token;
}

/** What became of one notification: sent, the device no longer takes them, or it didn't go. */
export type Delivery = "sent" | "gone" | "failed";

/** Reasons APNs gives for a token that will never work again (or not for Dream). */
const GONE = new Set(["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"]);

/** Sends one notification to one device. Never throws. */
export async function deliver(config: APNsConfig, device: PushDevice, notice: Notice, send: typeof fetch = fetch): Promise<Delivery> {
  const alert: Record<string, string> = { body: notice.body };
  if (notice.title) alert.title = notice.title;
  try {
    const response = await send(`${config.base ?? apnsHost(device.environment)}/3/device/${device.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await providerToken(config)}`,
        "apns-topic": TOPIC,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(notice.expires),
        // A question's notification, or the phone's, is replaced by the page's, once it's made.
        "apns-collapse-id": notice.payload.page,
        "content-type": "application/json",
      },
      body: JSON.stringify({ aps: { alert, sound: "default", "thread-id": notice.payload.page }, ...notice.payload }),
      signal: AbortSignal.timeout(10_000),
    });
    if (response.ok) {
      await response.body?.cancel();
      return "sent";
    }
    const reason = String(((await response.json().catch(() => null)) as { reason?: unknown } | null)?.reason ?? "");
    if (response.status === 410 || GONE.has(reason)) return "gone";
    // Signed for a moment APNs no longer takes, or with a key it doesn't know: made again next time.
    if (response.status === 403) signed = null;
    console.warn("APNs refused a notification:", response.status, reason || "no reason");
    return "failed";
  } catch (error) {
    console.warn("APNs couldn't be reached:", error instanceof Error ? error.name : typeof error);
    return "failed";
  }
}

let unconfigured = false;

/** Tells every iPhone signed in to the account, and forgets those APNs says are gone. Never throws. */
export async function notify(env: PushEnv, userID: string, notice: Notice, send: typeof fetch = fetch): Promise<void> {
  const config = apnsConfig(env);
  if (!config) {
    if (!unconfigured) console.log("Push notifications are off: APNS_KEY, APNS_KEY_ID and APNS_TEAM_ID aren't set.");
    unconfigured = true;
    return;
  }
  try {
    const { results } = await env.DB.prepare(
      `SELECT push_devices.token AS token, push_devices.environment AS environment FROM push_devices
       JOIN sessions ON sessions.token_hash = push_devices.session_hash
       WHERE push_devices.user_id = ? AND sessions.expires_at > ?`,
    )
      .bind(userID, Math.floor(Date.now() / 1000))
      .all<PushDevice>();
    const outcomes = await Promise.all(results.map((device) => deliver(config, device, notice, send)));
    const gone = results.filter((_, index) => outcomes[index] === "gone").map((device) => device.token);
    if (gone.length) {
      await env.DB.prepare(`DELETE FROM push_devices WHERE user_id = ? AND token IN (${gone.map(() => "?").join(", ")})`).bind(userID, ...gone).run();
    }
  } catch (error) {
    console.error("Notifications failed", error instanceof Error ? error.name : typeof error);
  }
}
