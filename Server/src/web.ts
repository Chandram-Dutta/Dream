// Web search and page reading for the Dream app, so screens can rest on more than Wikipedia.
//
//   POST /api/search   { query, objective?, count?, freshness?, region? }  → { results: [{ title, url, snippet, site, date? }] }
//   POST /api/read     { url, focus?, maxChars?, language? }               → { title, site, canonical, date?, text, … }
//   GET  /reader       what DreamReader is, for site owners who see it in their logs
//
// Both cost money (providers.ts), so neither is an open proxy: only signed-in people, using the
// app, may call them (a session, and App Attest or the shared key in X-Dream-Key: attest.ts),
// each account has a daily allowance (usage.ts), each address a rate limit, everyone together a
// daily budget, answers are cached for a while, and sizes and times are capped.
// The reader fetches only public http(s) pages, checks where names resolve before fetching,
// follows robots.txt, and says who it is.
//
// Nothing personal is logged or kept: no queries, no addresses, no page addresses. Cached
// answers are keyed by a hash of what was asked, and expire.

import { checkURL, hostOf, isPublicIP, parseIP, type Refusal } from "./address";
import { proveApp, type ProofEnv } from "./attest";
import { signInNeeded, userFrom, type AuthEnv, type User } from "./auth";
import { readHTML, type PageText } from "./html";
import { messagePage } from "./page";
import { readBody, Rejection } from "./payload";
import { Parallel, ProviderError, type Freshness, type PageProvider, type ProvidedPage, type SearchProvider } from "./providers";
import { READER_TOKEN, robotsAllows } from "./robots";
import { admitWeb, refusalResponse, type UsageEnv } from "./usage";
import { capText, delink, siteOf, tidy } from "./webtext";

export interface WebEnv extends ProofEnv, UsageEnv, AuthEnv {
  DB: D1Database;
  SEARCH_LIMIT?: RateLimit;
  PAGE_LIMIT?: RateLimit;
  /** Secret. Parallel's API key, for search and for reading pages. */
  PARALLEL_API_KEY?: string;
  /** Where Parallel's API is. Only tests change it, to a stand-in on this Mac. */
  PARALLEL_BASE_URL?: string;
  PARALLEL_SEARCH_MODE?: string;
  /** Provider calls a day, for everyone together, of each kind (searches, page reads). */
  WEB_DAILY_LIMIT?: string;
}

const SECURITY = { "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Cache-Control": "no-store" };

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...SECURITY, "Content-Type": "application/json; charset=utf-8", ...headers } });
}

function problem(status: number, message: string, headers: Record<string, string> = {}): Response {
  return json({ error: message }, status, headers);
}

/** The web routes, or null for any other path. */
export async function routeWeb(request: Request, env: WebEnv, ctx: ExecutionContext, url: URL): Promise<Response | null> {
  switch (url.pathname) {
    case "/api/search":
      return request.method === "POST" ? search(request, env, ctx) : problem(405, "Only POST.", { Allow: "POST" });
    case "/api/read":
      return request.method === "POST" ? read(request, env, ctx, url.origin) : problem(405, "Only POST.", { Allow: "POST" });
    case "/reader":
      return new Response(
        messagePage(
          "DreamReader",
          `DreamReader reads a public page only when someone using the Dream app asks about something it covers, and passes on just enough of it to answer them. It never follows links on its own, reads only pages robots.txt allows, and keeps a copy for a few hours at most. To keep it off a site, add "User-agent: ${READER_TOKEN}" and "Disallow: /" to its robots.txt.`,
        ),
        { headers: { ...SECURITY, "Content-Type": "text/html; charset=utf-8", "Cache-Control": "public, max-age=86400" } },
      );
    default:
      return null;
  }
}

// MARK: - Protection

/** Whether this address is under its limit. Addresses are only rate-limit keys, never stored. */
async function allowed(limiter: RateLimit | undefined, request: Request, bucket: string): Promise<boolean> {
  if (!limiter) return true;
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
  return (await limiter.limit({ key: `${bucket}:${address}` })).success;
}

/** Counts one provider call against today's budget, and says whether it's still within it. */
async function spend(env: WebEnv, kind: "search" | "read"): Promise<boolean> {
  const limit = Number(env.WEB_DAILY_LIMIT ?? "");
  const daily = Number.isInteger(limit) && limit >= 0 ? limit : 2_000;
  const day = new Date().toISOString().slice(0, 10);
  const row = await env.DB.prepare("INSERT INTO web_usage (day, kind, count) VALUES (?, ?, 1) ON CONFLICT (day, kind) DO UPDATE SET count = count + 1 RETURNING count")
    .bind(day, kind)
    .first<{ count: number }>();
  return (row?.count ?? Infinity) <= daily;
}

/** What the app sent: small, and only as application/json. */
async function input(request: Request): Promise<string | Response> {
  if (!/^application\/json(\s*;|$)/i.test(request.headers.get("Content-Type") ?? "")) return problem(415, "Send application/json.");
  try {
    return await readBody(request, 4_000);
  } catch (error) {
    return error instanceof Rejection ? problem(error.status === 413 ? 413 : 400, error.status === 413 ? "That's too much to ask at once." : "Expected a JSON object.") : problem(400, "That isn't JSON.");
  }
}

/** Checks the caller before anything costs anything: the rate limit, who's signed in, the body's
 * size, and that it's the app asking (the body is part of what App Attest signs). */
async function gate(request: Request, env: WebEnv, limiter: RateLimit | undefined, bucket: string): Promise<{ body: Record<string, unknown>; user: User } | Response> {
  if (!(await allowed(limiter, request, bucket))) return problem(429, "Too many requests. Try again in a minute.", { "Retry-After": "60" });
  const user = await userFrom(request, env);
  if (!user) return signInNeeded();
  const text = await input(request);
  if (text instanceof Response) return text;
  const refused = await proveApp(request, env, new TextEncoder().encode(text), "Web search");
  if (refused) return refused;
  try {
    const body: unknown = JSON.parse(text);
    return body && typeof body === "object" && !Array.isArray(body) ? { body: body as Record<string, unknown>, user } : problem(400, "Expected a JSON object.");
  } catch {
    return problem(400, "That isn't JSON.");
  }
}

// MARK: - Cache

async function digestBytes(text: string): Promise<ArrayBuffer> {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
}

async function digest(text: string): Promise<string> {
  return [...new Uint8Array(await digestBytes(text))].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function cached<T>(env: WebEnv, key: string): Promise<T | null> {
  const row = await env.DB.prepare("SELECT body FROM web_cache WHERE key = ? AND expires_at > ?").bind(key, now()).first<{ body: string }>();
  return row ? (JSON.parse(row.body) as T) : null;
}

async function keep(env: WebEnv, key: string, value: unknown, seconds: number): Promise<void> {
  await env.DB.batch([
    env.DB.prepare("INSERT OR REPLACE INTO web_cache (key, expires_at, body) VALUES (?, ?, ?)").bind(key, now() + seconds, JSON.stringify(value)),
    // Expired answers go a few at a time, as new ones arrive.
    env.DB.prepare("DELETE FROM web_cache WHERE key IN (SELECT key FROM web_cache WHERE expires_at <= ? LIMIT 50)").bind(now()),
  ]);
}

const now = () => Math.floor(Date.now() / 1000);

// MARK: - Search

const FRESHNESS = new Set(["day", "week", "month", "year"]);

/** Parallel, when its key is set. A key piped in with a trailing newline still works. */
function parallel(env: WebEnv): Parallel | null {
  const key = env.PARALLEL_API_KEY?.trim();
  return key ? new Parallel(key, env.PARALLEL_BASE_URL?.trim() || undefined, env.PARALLEL_SEARCH_MODE?.trim() || undefined) : null;
}

const searchProvider = (env: WebEnv): SearchProvider | null => parallel(env);
const pageProvider = (env: WebEnv): PageProvider | null => parallel(env);

const words = (value: unknown, max: number) => (typeof value === "string" ? value.replace(/\s+/g, " ").trim().slice(0, max + 1) : "");

async function search(request: Request, env: WebEnv, ctx: ExecutionContext): Promise<Response> {
  const gated = await gate(request, env, env.SEARCH_LIMIT, "search");
  if (gated instanceof Response) return gated;
  const { body, user } = gated;

  const query = words(body.query, 300);
  if (query.length < 2 || query.length > 300) return problem(400, "Send a query of 2 to 300 characters.");
  const objective = words(body.objective, 500);
  if (objective.length > 500) return problem(400, "Keep the objective under 500 characters.");
  if (body.count !== undefined && !(Number.isInteger(body.count) && (body.count as number) >= 1)) return problem(400, "count is a whole number from 1.");
  const count = Math.min((body.count as number | undefined) ?? 5, 8);
  if (body.freshness !== undefined && body.freshness !== null && body.freshness !== "" && !FRESHNESS.has(String(body.freshness))) return problem(400, "freshness is day, week, month or year.");
  const freshness = FRESHNESS.has(String(body.freshness)) ? (body.freshness as Freshness) : undefined;
  const region = typeof body.region === "string" && /^[A-Za-z]{2}$/.test(body.region) ? body.region.toLowerCase() : undefined;

  const provider = searchProvider(env);
  if (!provider) return problem(503, "Web search isn't set up on this server yet.");
  const refusal = await admitWeb(env, user.id, "search");
  if (refusal) return refusalResponse(refusal);
  // Never cached: Parallel's terms (§2(b)(i), §2(c)(xi)) keep each answer for the one person who
  // asked, so it's neither stored nor given to anyone else.
  if (!(await spend(env, "search"))) return problem(503, "Dream has searched the web as much as it can for today. Try again tomorrow.");

  try {
    const results = await provider.search({ query, objective: objective || undefined, count, freshness, region }, AbortSignal.timeout(10_000));
    return json({ results, provider: provider.name, cached: false });
  } catch (error) {
    return providerProblem(error, "search");
  }
}

function providerProblem(error: unknown, kind: string): Response {
  if (!(error instanceof ProviderError)) throw error;
  // The status only: never what was asked.
  console.error(`Web ${kind} provider failed`, error.status);
  return error.status === 429 ? problem(503, "Web search is busy. Try again in a moment.", { "Retry-After": "30" }) : problem(502, "Web search didn't answer. Try again in a moment.");
}

// MARK: - Reading

/** What a refused address is told. */
const REFUSED: Record<Refusal | "unresolved", string> = {
  length: "Send the address of a web page.",
  malformed: "That isn't a web address.",
  scheme: "Dream reads web pages over http and https only.",
  credentials: "Dream doesn't read addresses with a name or password in them.",
  port: "Dream reads web pages on the web's usual ports only.",
  host: "Dream reads public web pages only.",
  private: "Dream reads public web pages only.",
  unresolved: "Dream couldn't find that site, or it isn't public.",
};

const USER_AGENT = (origin: string) => `Mozilla/5.0 (compatible; ${READER_TOKEN}/1.0; +${origin}/reader)`;
/** The most of a page that's read: real articles are 50 to 500 KB of HTML. */
const MAX_PAGE = 2_000_000;
const MAX_ROBOTS = 500_000;
const READABLE = /^(text\/html|application\/xhtml\+xml|text\/plain|text\/markdown)$/;

interface ReadAnswer {
  url: string;
  canonical: string;
  title: string;
  site: string;
  date?: string;
  language?: string;
  text: string;
  excerpted: boolean;
  truncated: boolean;
  via: string;
}

async function read(request: Request, env: WebEnv, ctx: ExecutionContext, origin: string): Promise<Response> {
  const gated = await gate(request, env, env.PAGE_LIMIT, "page");
  if (gated instanceof Response) return gated;
  const { body, user } = gated;

  const checked = checkURL(body.url);
  if ("refused" in checked) return problem(400, REFUSED[checked.refused]);
  const url = checked.url;
  const focus = words(body.focus, 300).slice(0, 300);
  if (body.maxChars !== undefined && !(Number.isInteger(body.maxChars) && (body.maxChars as number) > 0)) return problem(400, "maxChars is a whole number.");
  const maxChars = Math.max(500, Math.min((body.maxChars as number | undefined) ?? 6_000, 12_000));
  const language = typeof body.language === "string" && /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$/.test(body.language) ? body.language : undefined;
  const refusal = await admitWeb(env, user.id, "read");
  if (refusal) return refusalResponse(refusal);

  const provider = pageProvider(env);
  // Only Dream's own reads are kept; the provider's, like its searches, go only to who asked.
  const key = await digest(`read:2:fetch:${JSON.stringify([url.href, focus, maxChars])}`);
  const hit = await cached<ReadAnswer>(env, key);
  if (hit) return json({ ...hit, cached: true });

  const deadline = AbortSignal.timeout(20_000);
  if (!(await resolvesPublicly(hostOf(url), deadline))) return problem(400, REFUSED.unresolved);
  const robots = await robotsFor(url, env, origin, deadline);
  if (robots === "unreachable") return problem(502, "That site isn't answering right now.");
  if (robots === "disallowed") return problem(403, "This site asks tools like Dream not to read that page.");

  // Dream's own fetch reads what the page says about itself (its canonical address, site name
  // and date), and its words when there's no provider or the provider can't read it.
  const useProvider = provider !== null && (await spend(env, "read"));
  const [own, provided] = await Promise.allSettled([
    fetchPage(url, env, origin, language, AbortSignal.any([deadline, AbortSignal.timeout(9_000)])),
    useProvider ? provider.read({ url: url.href, focus: focus || undefined, maxChars }, deadline) : Promise.resolve(null),
  ]);
  const page = own.status === "fulfilled" ? own.value : ({ failure: "failed" } as const);
  if ("failure" in page && page.failure === "refused") return problem(400, REFUSED.private);
  if ("failure" in page && page.failure === "disallowed") return problem(403, "This site asks tools like Dream not to read that page.");
  if (provided.status === "rejected" && !(provided.reason instanceof ProviderError)) throw provided.reason;
  if (provided.status === "rejected") console.error("Web read provider failed", (provided.reason as ProviderError).status);
  const fromProvider: ProvidedPage | null = provided.status === "fulfilled" && provided.value && provided.value.text.length >= 80 ? provided.value : null;
  const ownPage = "failure" in page ? undefined : page;

  const text = fromProvider?.text ?? ownPage?.text ?? "";
  if (!text.trim()) {
    if ("failure" in page) {
      switch (page.failure) {
        case "blocked": return problem(502, "That site didn't let Dream read the page.");
        case "missing": return problem(404, "There's no page at that address.");
        case "unsupported": return problem(415, "Dream reads web pages, not files like this one.");
        default: break;
      }
    }
    return problem(502, "Dream couldn't read that page.");
  }
  const final = ownPage ? new URL(ownPage.finalURL) : url;
  const capped = capText(tidy(delink(text)), maxChars);
  // A page may name another address as its own, but only on its own site: credits link there,
  // and a page shouldn't send readers somewhere it wasn't read from.
  const sameSite = (address: string | undefined, as: URL) => {
    try {
      return address !== undefined && siteOf(new URL(address).hostname) === siteOf(as.hostname);
    } catch {
      return false;
    }
  };
  const answer: ReadAnswer = {
    url: url.href,
    canonical: (sameSite(ownPage?.canonical, final) ? ownPage?.canonical : ownPage?.finalURL) ?? (sameSite(fromProvider?.url, url) ? fromProvider?.url : undefined) ?? url.href,
    title: ownPage?.title ?? fromProvider?.title ?? siteOf(final.hostname),
    site: ownPage?.site ?? siteOf(final.hostname),
    date: ownPage?.date ?? fromProvider?.date,
    language: ownPage?.language,
    text: capped.text,
    excerpted: fromProvider?.excerpted ?? false,
    truncated: capped.truncated,
    via: fromProvider ? provider!.name : "fetch",
  };
  if (!fromProvider) ctx.waitUntil(keep(env, key, answer, 6 * 3_600));
  return json({ ...answer, cached: false });
}

/** Whether every address a name resolves to is public, asked of Cloudflare's resolver over HTTPS. */
async function resolvesPublicly(host: string, signal: AbortSignal): Promise<boolean> {
  if (parseIP(host)) return true; // An address written out was judged by checkURL already.
  try {
    const answers = await Promise.all(
      ["A", "AAAA"].map(async (type) => {
        const response = await fetch(`https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(host)}&type=${type}`, {
          headers: { Accept: "application/dns-json" },
          signal: AbortSignal.any([signal, AbortSignal.timeout(3_000)]),
        });
        if (!response.ok) throw new Error("DNS");
        const body = (await response.json()) as { Status?: number; Answer?: { type: number; data: string }[] };
        return (body.Answer ?? []).filter((record) => record.type === 1 || record.type === 28).map((record) => record.data);
      }),
    );
    const addresses = answers.flat();
    return addresses.length > 0 && addresses.every((address) => {
      const ip = parseIP(address.toLowerCase());
      return ip !== null && isPublicIP(ip);
    });
  } catch {
    return false;
  }
}

type RobotsVerdict = "allowed" | "disallowed" | "unreachable";

/** What a site's robots.txt says about one page, read once a day per site. As RFC 9309 asks, a
 * missing file allows everything, and one that can't be reached allows nothing for now. */
async function robotsFor(url: URL, env: WebEnv, origin: string, signal: AbortSignal): Promise<RobotsVerdict> {
  const key = await digest(`robots:1:${url.origin}`);
  let robots = await cached<{ text: string } | { unreachable: true }>(env, key);
  if (!robots) {
    const fetched = await fetchSafely(new URL("/robots.txt", url.origin), origin, "text/plain", undefined, AbortSignal.any([signal, AbortSignal.timeout(5_000)]), MAX_ROBOTS);
    if ("failure" in fetched) {
      robots = fetched.failure === "missing" || fetched.failure === "blocked" ? { text: "" } : { unreachable: true };
    } else {
      robots = { text: new TextDecoder().decode(fetched.bytes) };
    }
    await keep(env, key, robots, "unreachable" in robots ? 600 : 86_400);
  }
  if ("unreachable" in robots) return "unreachable";
  return robotsAllows(robots.text, url.pathname + url.search) ? "allowed" : "disallowed";
}

type Failure = { failure: "refused" | "disallowed" | "blocked" | "missing" | "unsupported" | "failed" };

interface Fetched {
  bytes: Uint8Array;
  contentType: string;
  finalURL: string;
}

/** Fetches a public address, following at most five redirects and checking each one as if it
 * were asked for, and reads at most `max` bytes. `robots` checks pages on other sites a
 * redirect leads to; robots.txt itself isn't checked. Statuses 401, 403 and 429 are "blocked". */
async function fetchSafely(start: URL, origin: string, accept: string, robots: ((url: URL) => Promise<RobotsVerdict>) | undefined, signal: AbortSignal, max: number, language?: string): Promise<Fetched | Failure> {
  let url = start;
  for (let hop = 0; hop <= 5; hop++) {
    if (hop > 0) {
      const checked = checkURL(url.href);
      if ("refused" in checked || !(await resolvesPublicly(hostOf(url), signal))) return { failure: "refused" };
      if (robots && (await robots(url)) !== "allowed") return { failure: "disallowed" };
    }
    let response: Response;
    try {
      response = await fetch(url.href, {
        redirect: "manual",
        signal,
        headers: { "User-Agent": USER_AGENT(origin), Accept: accept, ...(language ? { "Accept-Language": `${language}, en;q=0.5` } : {}) },
      });
    } catch {
      return { failure: "failed" };
    }
    if (response.status >= 300 && response.status < 400 && response.headers.has("Location")) {
      await response.body?.cancel();
      let next: URL;
      try {
        next = new URL(response.headers.get("Location")!, url);
      } catch {
        return { failure: "failed" };
      }
      // Never from https down to plain http.
      if (url.protocol === "https:" && next.protocol !== "https:") return { failure: "refused" };
      next.hash = "";
      url = next;
      continue;
    }
    if (!response.ok) {
      await response.body?.cancel();
      return { failure: [401, 403, 429, 451].includes(response.status) ? "blocked" : response.status === 404 || response.status === 410 ? "missing" : "failed" };
    }
    const contentType = (response.headers.get("Content-Type") ?? "text/html").toLowerCase();
    const bytes = await readCapped(response, max);
    return bytes ? { bytes, contentType, finalURL: url.href } : { failure: "failed" };
  }
  return { failure: "failed" };
}

/** A page's text and what it says about itself, by Dream's own fetch. */
async function fetchPage(url: URL, env: WebEnv, origin: string, language: string | undefined, signal: AbortSignal): Promise<(PageText & { finalURL: string }) | Failure> {
  // Markdown first: sites that serve it to agents send it instead of HTML.
  const fetched = await fetchSafely(url, origin, "text/markdown, text/html;q=0.9, application/xhtml+xml;q=0.9, text/plain;q=0.8", (next) => robotsFor(next, env, origin, signal), signal, MAX_PAGE, language);
  if ("failure" in fetched) return fetched;
  const type = fetched.contentType.split(";")[0].trim();
  if (!READABLE.test(type)) return { failure: "unsupported" };
  const final = new URL(fetched.finalURL);
  if (type === "text/html" || type === "application/xhtml+xml") {
    return { ...(await readHTML(fetched.bytes, fetched.contentType, final)), finalURL: fetched.finalURL };
  }
  const text = decode(fetched.bytes, fetched.contentType);
  const heading = /^#\s+(.+)$/m.exec(text)?.[1]?.trim();
  return { text: tidy(text), title: heading, finalURL: fetched.finalURL };
}

/** At most `max` bytes of a body; a page cut short is still worth reading. */
async function readCapped(response: Response, max: number): Promise<Uint8Array | null> {
  if (!response.body) return new Uint8Array();
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      size += value.byteLength;
      if (size >= max) {
        await reader.cancel();
        break;
      }
    }
  } catch {
    if (!size) return null;
  }
  const bytes = new Uint8Array(Math.min(size, max));
  let offset = 0;
  for (const chunk of chunks) {
    const room = bytes.length - offset;
    if (room <= 0) break;
    bytes.set(chunk.subarray(0, room), offset);
    offset += Math.min(chunk.byteLength, room);
  }
  return bytes;
}

function decode(bytes: Uint8Array, contentType: string): string {
  const charset = /charset=["']?([\w-]+)/i.exec(contentType)?.[1];
  try {
    return new TextDecoder(charset ?? "utf-8").decode(bytes);
  } catch {
    return new TextDecoder().decode(bytes);
  }
}
