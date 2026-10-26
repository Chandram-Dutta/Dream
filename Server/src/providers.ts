// Who searches the web and reads pages for Dream. The app only ever sees /api/search and
// /api/read (web.ts), so a provider can change here without touching it.
//
// Parallel (parallel.ai) is the default for both: Search for ranked pages with excerpts, Extract
// for a page's content as Markdown. Another provider, like Cloudflare's Web Search API through
// the Workers AI binding (`env.AI.websearch({ gatewayId, query, limit })`, which answers
// `{ items: [{ url, title, description }] }`), would be one more class with the same shape.

import { clip, dayOf, flatten, siteOf } from "./webtext";

export type Freshness = "day" | "week" | "month" | "year";

export interface SearchQuery {
  /** Keywords, as a search box takes them. */
  query: string;
  /** What the search is for, in a sentence. Providers that can use it rank by it. */
  objective?: string;
  count: number;
  freshness?: Freshness;
  /** A country the question is about, as an ISO 3166-1 alpha-2 code. */
  region?: string;
}

export interface SearchHit {
  title: string;
  url: string;
  snippet: string;
  site: string;
  date?: string;
}

export interface PageQuery {
  url: string;
  /** What the reader wants from the page. Providers that can use it return the parts about it. */
  focus?: string;
  maxChars: number;
}

export interface ProvidedPage {
  url: string;
  title?: string;
  date?: string;
  text: string;
  /** The text is the parts about the focus, not the page from the top. */
  excerpted: boolean;
}

export interface SearchProvider {
  readonly name: string;
  search(query: SearchQuery, signal: AbortSignal): Promise<SearchHit[]>;
}

export interface PageProvider {
  readonly name: string;
  /** The page's content, or null when the provider couldn't read it. */
  read(query: PageQuery, signal: AbortSignal): Promise<ProvidedPage | null>;
}

/** A provider failed. `status` is its HTTP status, or 0 for no answer. Never carries what was asked. */
export class ProviderError extends Error {
  readonly status: number;

  constructor(status: number) {
    super(`Provider answered ${status}`);
    this.name = "ProviderError";
    this.status = status;
  }
}

/** Snippet length for search results: enough to choose a page, not enough to quote from. */
const SNIPPET = 360;

/** Search and Extract on Parallel's v1 API (docs.parallel.ai), with the key as a Worker secret. */
export class Parallel implements SearchProvider, PageProvider {
  readonly name = "parallel";

  constructor(
    private readonly key: string,
    private readonly base = "https://api.parallel.ai",
    /** `fast` is about 700 ms and $1 per 1,000 searches; `basic` and `advanced` are $5. */
    private readonly mode = "fast",
  ) {}

  async search(query: SearchQuery, signal: AbortSignal): Promise<SearchHit[]> {
    const advanced: Record<string, unknown> = {
      max_results: query.count,
      excerpt_settings: { max_chars_per_result: 800 },
    };
    if (query.freshness) advanced.source_policy = { after_date: since(query.freshness) };
    if (query.region) advanced.location = query.region;
    const body = await this.post(
      "/v1/search",
      {
        objective: query.objective ?? query.query,
        search_queries: [query.query],
        mode: this.mode,
        max_chars_total: 6_000,
        advanced_settings: advanced,
      },
      signal,
    );
    const results = Array.isArray(body.results) ? body.results : [];
    const hits: SearchHit[] = [];
    const seen = new Set<string>();
    for (const raw of results) {
      if (!raw || typeof raw !== "object") continue;
      const item = raw as Record<string, unknown>;
      const url = webURL(item.url);
      if (!url || seen.has(url.href)) continue;
      seen.add(url.href);
      const excerpts = Array.isArray(item.excerpts) ? item.excerpts.filter((excerpt): excerpt is string => typeof excerpt === "string") : [];
      const title = typeof item.title === "string" && item.title.trim() ? flatten(item.title) : siteOf(url.hostname);
      hits.push({ title: clip(title, 200), url: url.href, snippet: clip(flatten(excerpts.join(" … ")), SNIPPET), site: siteOf(url.hostname), date: dayOf(item.publish_date) });
      if (hits.length >= query.count) break;
    }
    return hits;
  }

  async read(query: PageQuery, signal: AbortSignal): Promise<ProvidedPage | null> {
    const body = await this.post(
      "/v1/extract",
      {
        urls: [query.url],
        ...(query.focus ? { objective: query.focus } : {}),
        max_chars_total: query.maxChars,
        advanced_settings: {
          excerpt_settings: { max_chars_per_result: query.maxChars },
          // Billed per address either way, so the page from the top comes too, for when the
          // excerpts miss.
          full_content: { max_chars_per_result: query.maxChars },
          fetch_policy: { timeout_seconds: 12 },
        },
      },
      signal,
    );
    const result = (Array.isArray(body.results) ? body.results : []).find((item): item is Record<string, unknown> => !!item && typeof item === "object");
    if (!result) return null;
    const excerpts = (Array.isArray(result.excerpts) ? result.excerpts : []).filter((excerpt): excerpt is string => typeof excerpt === "string" && !!excerpt.trim());
    const full = typeof result.full_content === "string" ? result.full_content.trim() : "";
    const focused = query.focus ? excerpts.join("\n\n…\n\n").trim() : "";
    const text = focused.length >= 80 || (focused && !full) ? focused : full;
    if (!text) return null;
    return {
      url: webURL(result.url)?.href ?? query.url,
      title: typeof result.title === "string" && result.title.trim() ? result.title.trim() : undefined,
      date: dayOf(result.publish_date),
      text,
      excerpted: text === focused,
    };
  }

  private async post(path: string, payload: unknown, signal: AbortSignal): Promise<Record<string, unknown>> {
    let response: Response;
    try {
      response = await fetch(`${this.base}${path}`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-api-key": this.key },
        body: JSON.stringify(payload),
        signal,
      });
    } catch {
      throw new ProviderError(0);
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new ProviderError(response.status);
    }
    const body: unknown = await response.json().catch(() => null);
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new ProviderError(502);
    return body as Record<string, unknown>;
  }
}

/** The first day a freshness covers, as YYYY-MM-DD, counted back from today. */
export function since(freshness: Freshness, now = Date.now()): string {
  const days = { day: 1, week: 7, month: 31, year: 366 }[freshness];
  return new Date(now - days * 86_400_000).toISOString().slice(0, 10);
}

/** An http(s) address with nothing personal in its form: no credentials, no fragment. */
function webURL(value: unknown): URL | null {
  if (typeof value !== "string" || value.length > 2_000) return null;
  try {
    const url = new URL(value);
    if ((url.protocol !== "http:" && url.protocol !== "https:") || url.username || url.password) return null;
    url.hash = "";
    return url;
  } catch {
    return null;
  }
}
