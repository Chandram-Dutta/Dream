// A directory of MCP servers for Dream's Discover screen, from the official MCP Registry
// (registry.modelcontextprotocol.io, still in preview), plus a few Dream has checked itself.
//
//   GET /api/mcp/featured                 the checked few, with whether each needs a sign-in
//   GET /api/mcp/servers?search=&cursor=  the registry, searched by name, a page at a time
//
// The registry describes each server with a server.json. Only servers the app can use are kept:
// a remote over streamable HTTP, at an https address, that needs no headers or address variables
// filled in (the app signs in with OAuth, never with keys typed in). What comes back is reshaped
// for the app and cached, so the registry sees one request per search an hour, not one per phone.
// The registry's text is someone else's: the app shows it as plain text and nothing more.

const REGISTRY = "https://registry.modelcontextprotocol.io/v0.1/servers";
const SEARCH_TTL = 60 * 60;
const FEATURED_TTL = 24 * 60 * 60;

/** A server as the app sees it. */
export interface Entry {
  /** The registry's name, like app.linear/linear, or Dream's own id for one it lists itself. */
  id: string;
  name: string;
  summary: string;
  /** The MCP endpoint to connect to. */
  url: string;
  website: string | null;
  /** A PNG, JPEG or WebP on the server's own domain. */
  icon: string | null;
  /** True when it needs a sign-in, false when it doesn't, null when nobody has checked. */
  signIn: boolean | null;
  category: string | null;
  /** Other names people use for it, like Jira for Atlassian, for noticing it in a request. */
  aliases: string[];
  featured: boolean;
}

/** Checked by hand on 2026-10-27: each answered over streamable HTTP, and those that need a
 * sign-in found their sign-in server and let Dream register itself there. Figma's refused to
 * register Dream, so it isn't here. */
export const FEATURED: Entry[] = [
  { id: "app.linear/linear", name: "Linear", summary: "Your issues, projects and cycles.", url: "https://mcp.linear.app/mcp", website: "https://linear.app", icon: "https://static.linear.app/integrations/mcp/icon-256.png", signIn: true, category: "Work", aliases: [], featured: true },
  { id: "com.notion/mcp", name: "Notion", summary: "Your pages and databases.", url: "https://mcp.notion.com/mcp", website: "https://www.notion.so", icon: null, signIn: true, category: "Work", aliases: [], featured: true },
  { id: "com.atlassian/atlassian-mcp-server", name: "Atlassian", summary: "Jira issues and Confluence pages.", url: "https://mcp.atlassian.com/v1/mcp", website: "https://www.atlassian.com", icon: null, signIn: true, category: "Work", aliases: ["Jira", "Confluence"], featured: true },
  { id: "dream/deepwiki", name: "DeepWiki", summary: "Ask about any public GitHub repository.", url: "https://mcp.deepwiki.com/mcp", website: "https://deepwiki.com", icon: null, signIn: false, category: "Code", aliases: [], featured: true },
  { id: "dev.sentry/sentry", name: "Sentry", summary: "Errors and issues in your projects.", url: "https://mcp.sentry.dev/mcp", website: "https://sentry.io", icon: null, signIn: true, category: "Code", aliases: [], featured: true },
  { id: "co.huggingface/hf-mcp-server", name: "Hugging Face", summary: "Models, datasets, Spaces and papers.", url: "https://huggingface.co/mcp", website: "https://huggingface.co", icon: null, signIn: false, category: "Code", aliases: [], featured: true },
  { id: "com.microsoft/microsoft-learn-mcp", name: "Microsoft Learn", summary: "Microsoft's documentation and code samples.", url: "https://learn.microsoft.com/api/mcp", website: "https://learn.microsoft.com", icon: null, signIn: false, category: "Docs", aliases: [], featured: true },
  { id: "dream/context7", name: "Context7", summary: "Up-to-date docs for programming libraries.", url: "https://mcp.context7.com/mcp", website: "https://context7.com", icon: null, signIn: false, category: "Docs", aliases: [], featured: true },
  { id: "com.cloudflare.mcp/mcp", name: "Cloudflare Docs", summary: "Cloudflare's developer documentation.", url: "https://docs.mcp.cloudflare.com/mcp", website: "https://developers.cloudflare.com", icon: null, signIn: false, category: "Docs", aliases: [], featured: true },
];

const SECURITY = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Cross-Origin-Resource-Policy": "same-origin",
};

function json(body: unknown, status = 200, ttl = 0): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...SECURITY, "Content-Type": "application/json; charset=utf-8", "Cache-Control": ttl ? `public, max-age=${ttl}` : "no-store" },
  });
}

/** Answers /api/mcp/ requests; null for paths that aren't its own. */
export async function directory(request: Request, url: URL): Promise<Response | null> {
  if (url.pathname === "/api/mcp/featured") return json({ servers: FEATURED }, 200, FEATURED_TTL);
  if (url.pathname !== "/api/mcp/servers") return null;
  const search = (url.searchParams.get("search") ?? "").trim();
  const cursor = url.searchParams.get("cursor") ?? "";
  if (search.length > 80 || cursor.length > 300 || /[\u0000-\u001f]/.test(search + cursor)) {
    return json({ error: "That search is too long." }, 400);
  }
  // One cache entry per search and page, whatever else the request carried.
  const key = new Request(`${url.origin}/api/mcp/servers?search=${encodeURIComponent(search.toLowerCase())}&cursor=${encodeURIComponent(cursor)}`);
  const cache = caches.default;
  const kept = await cache.match(key);
  if (kept) return kept;

  const upstream = new URL(REGISTRY);
  upstream.searchParams.set("version", "latest");
  upstream.searchParams.set("limit", "100");
  if (search) upstream.searchParams.set("search", search.toLowerCase());
  if (cursor) upstream.searchParams.set("cursor", cursor);
  let page: RegistryPage;
  try {
    const response = await fetch(upstream, { headers: { Accept: "application/json", "User-Agent": "Dream directory" } });
    if (!response.ok) return json({ error: "The MCP Registry didn't answer. Try again in a moment." }, 502);
    page = (await response.json()) as RegistryPage;
  } catch {
    return json({ error: "The MCP Registry didn't answer. Try again in a moment." }, 502);
  }
  const fresh = json({ servers: usable(page.servers ?? []), next: page.metadata?.nextCursor ?? null }, 200, SEARCH_TTL);
  await cache.put(key, fresh.clone());
  return fresh;
}

// MARK: - The registry's shape

interface RegistryPage {
  servers?: { server?: ServerJSON; _meta?: Record<string, { status?: string; isLatest?: boolean }> }[];
  metadata?: { nextCursor?: string; count?: number };
}

interface ServerJSON {
  name?: string;
  title?: string;
  description?: string;
  websiteUrl?: string;
  icons?: { src?: string; mimeType?: string; theme?: string }[];
  remotes?: { type?: string; url?: string; headers?: { isRequired?: boolean; value?: string }[]; variables?: Record<string, unknown> }[];
}

/** The page's servers the app can use, reshaped, one per address. */
export function usable(entries: RegistryPage["servers"] & {}): Entry[] {
  const seen = new Set<string>();
  const out: Entry[] = [];
  for (const entry of entries) {
    const server = entry.server;
    const status = entry._meta?.["io.modelcontextprotocol.registry/official"]?.status;
    if (!server?.name || (status && status !== "active")) continue;
    const remote = (server.remotes ?? []).find(
      (r) =>
        r.type === "streamable-http" &&
        typeof r.url === "string" &&
        isHTTPS(r.url) &&
        !r.url.includes("{") &&
        !Object.keys(r.variables ?? {}).length &&
        !(r.headers ?? []).some((h) => h.isRequired && !h.value),
    );
    if (!remote?.url || seen.has(remote.url)) continue;
    seen.add(remote.url);
    out.push({
      id: server.name.slice(0, 200),
      name: plain(server.title) || nameFrom(server.name),
      summary: plain(server.description).slice(0, 160),
      url: remote.url,
      website: server.websiteUrl && isHTTPS(server.websiteUrl) ? server.websiteUrl : null,
      icon: icon(server, remote.url),
      signIn: null,
      category: null,
      aliases: [],
      featured: false,
    });
  }
  return out;
}

function isHTTPS(text: string): boolean {
  try {
    const url = new URL(text);
    return url.protocol === "https:" && !url.username && !url.password;
  } catch {
    return false;
  }
}

/** Text as one plain line. */
function plain(text: string | undefined): string {
  return (text ?? "").replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim();
}

/** A name from the registry's reverse-DNS one: com.notion/mcp is Notion. */
function nameFrom(name: string): string {
  const [namespace, rest = ""] = name.split("/");
  const generic = /^(mcp|server|mcp-server|remote|official)$/i.test(rest);
  const base = generic || !rest ? namespace.split(".").filter((part) => !/^(com|io|ai|app|dev|co|org|net|github)$/i.test(part)).pop() ?? namespace : rest;
  return base.replace(/[-_.]+/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase()).trim().slice(0, 60);
}

/** An icon the app can show without asking anyone new: a bitmap, over https, from the server's
 * own domain. SVGs can carry scripts, and the app can't draw them anyway. */
function icon(server: ServerJSON, endpoint: string): string | null {
  const home = site(endpoint);
  for (const candidate of server.icons ?? []) {
    if (!candidate.src || !isHTTPS(candidate.src) || candidate.theme === "dark") continue;
    const type = candidate.mimeType ?? "";
    const bitmap = /^image\/(png|jpe?g|webp)$/.test(type) || (!type && /\.(png|jpe?g|webp)(\?|$)/i.test(candidate.src));
    if (bitmap && site(candidate.src) === home) return candidate.src;
  }
  return null;
}

/** The last two labels of a host: mcp.linear.app and static.linear.app are both linear.app. */
function site(text: string): string {
  try {
    return new URL(text).hostname.split(".").slice(-2).join(".");
  } catch {
    return "";
  }
}
