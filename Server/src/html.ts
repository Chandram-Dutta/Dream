// A web page's words, without its menus, scripts and furniture, and what it says about itself:
// title, site name, canonical address, date and language. Uses the Workers runtime's streaming
// HTMLRewriter, so nothing builds a document tree from untrusted HTML.

import { decodeEntities, dayOf, tidy } from "./webtext";

export interface PageText {
  text: string;
  title?: string;
  site?: string;
  canonical?: string;
  date?: string;
  language?: string;
}

/** Elements whose text isn't the page's content. `header` counts only outside an article. */
const SKIPPED = "head, script, style, noscript, template, svg, math, canvas, iframe, object, nav, footer, aside, form, button, select, dialog, menu, [hidden], [aria-hidden=true]";
const MAIN = "main, article, [role=main]";
const BLOCKS = "p, div, section, li, dt, dd, tr, blockquote, pre, figcaption, table, ul, ol, h1, h2, h3, h4, h5, h6, hr";
const VOID = new Set(["br", "hr", "img", "input", "meta", "link", "source", "wbr", "area", "base", "col", "embed", "track", "param"]);

/** Reads HTML (at most what's in `html`, already size-capped) into plain text with light Markdown. */
export async function readHTML(html: Uint8Array, contentType: string, base: URL): Promise<PageText> {
  let skip = 0;
  let main = 0;
  const body: string[] = [];
  const article: string[] = [];
  let title = "";
  let ld = "";
  const meta: Record<string, string> = {};
  let canonical: string | undefined;
  let language: string | undefined;
  let time: string | undefined;

  const emit = (text: string) => {
    body.push(text);
    if (main > 0) article.push(text);
  };
  /** Counts an element as open until its end tag. Void elements have none. */
  const region = (element: Element, enter: () => void, leave: () => void) => {
    if (VOID.has(element.tagName)) return;
    enter();
    try {
      element.onEndTag(leave);
    } catch {
      leave();
    }
  };

  const rewriter = new HTMLRewriter()
    .on("html", { element: (element) => void (language ??= element.getAttribute("lang") ?? undefined) })
    .on("title", { text: (chunk) => void (title.length < 400 && (title += chunk.text)) })
    .on("meta", {
      element(element) {
        const key = (element.getAttribute("property") ?? element.getAttribute("name") ?? element.getAttribute("itemprop") ?? "").toLowerCase();
        const content = element.getAttribute("content");
        if (key && content && !(key in meta) && content.length < 1_000) meta[key] = content;
      },
    })
    .on("link", {
      element(element) {
        const rel = (element.getAttribute("rel") ?? "").toLowerCase().split(/\s+/);
        if (rel.includes("canonical")) canonical ??= element.getAttribute("href") ?? undefined;
      },
    })
    .on("time[datetime]", { element: (element) => void (time ??= element.getAttribute("datetime") ?? undefined) })
    .on('script[type="application/ld+json"]', { text: (chunk) => void (ld.length < 200_000 && (ld += chunk.text)) })
    .on(SKIPPED, { element: (element) => region(element, () => skip++, () => skip--) })
    .on("header", { element: (element) => (main === 0 ? region(element, () => skip++, () => skip--) : undefined) })
    .on(MAIN, { element: (element) => region(element, () => main++, () => main--) })
    .on(BLOCKS, {
      element(element) {
        if (skip > 0) return;
        const tag = element.tagName;
        const heading = /^h([1-6])$/.exec(tag);
        emit(heading ? `\n\n${"#".repeat(Number(heading[1]))} ` : tag === "li" ? "\n- " : tag === "tr" ? "\n" : "\n\n");
        if (!VOID.has(tag)) {
          try {
            element.onEndTag(() => void (skip === 0 && emit(heading || tag === "p" ? "\n\n" : "\n")));
          } catch {
            // No end tag to wait for.
          }
        }
      },
    })
    .on("br", { element: () => void (skip === 0 && emit("\n")) })
    .on("td, th", { element: () => void (skip === 0 && emit(" | ")) })
    .onDocument({
      text(chunk) {
        if (skip === 0 && chunk.text) emit(chunk.text.replace(/\s+/g, " "));
      },
    });

  await rewriter.transform(new Response(html, { headers: { "Content-Type": contentType } })).arrayBuffer();

  const words = (parts: string[]) => tidy(decodeEntities(parts.join("")).replace(/ *\| *(\n|$)/g, "$1"));
  const mainText = words(article);
  const text = mainText.length >= 400 ? mainText : words(body);
  const data = linkedData(ld);
  const plainMeta = (key: string) => {
    const value = meta[key];
    return value ? decodeEntities(value).replace(/\s+/g, " ").trim() : undefined;
  };
  return {
    text,
    title: plainMeta("og:title") ?? (title.trim() ? decodeEntities(title).replace(/\s+/g, " ").trim() : undefined) ?? data.headline,
    site: plainMeta("og:site_name") ?? plainMeta("application-name") ?? data.publisher,
    canonical: absolute(canonical, base) ?? absolute(meta["og:url"], base),
    date: dayOf(meta["article:published_time"]) ?? data.published ?? dayOf(meta["date"]) ?? dayOf(meta["datepublished"]) ?? dayOf(meta["dc.date"]) ?? dayOf(time) ?? dayOf(meta["article:modified_time"]),
    language: language && /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,3}$/.test(language) ? language : undefined,
  };
}

/** What a page's JSON-LD says about it, where it's a plain article or page. */
function linkedData(text: string): { headline?: string; publisher?: string; published?: string } {
  if (!text.trim()) return {};
  // Pages sometimes put several JSON objects in one script, or arrays and graphs.
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return {};
  }
  const nodes: Record<string, unknown>[] = [];
  const visit = (node: unknown, depth: number) => {
    if (depth > 4 || nodes.length > 40) return;
    if (Array.isArray(node)) node.forEach((item) => visit(item, depth + 1));
    else if (node && typeof node === "object") {
      nodes.push(node as Record<string, unknown>);
      visit((node as Record<string, unknown>)["@graph"], depth + 1);
    }
  };
  visit(parsed, 0);
  const string = (value: unknown) => (typeof value === "string" && value.trim() && value.length < 400 ? value.trim() : undefined);
  const result: { headline?: string; publisher?: string; published?: string } = {};
  for (const node of nodes) {
    result.headline ??= string(node.headline);
    result.published ??= dayOf(node.datePublished);
    const publisher = node.publisher;
    if (publisher && typeof publisher === "object" && !Array.isArray(publisher)) result.publisher ??= string((publisher as Record<string, unknown>).name);
  }
  return result;
}

/** An http(s) address from a page, resolved against where it was read. */
function absolute(href: string | undefined, base: URL): string | undefined {
  if (!href) return undefined;
  try {
    const url = new URL(decodeEntities(href.trim()), base);
    if (url.protocol !== "http:" && url.protocol !== "https:") return undefined;
    url.hash = "";
    return url.href;
  } catch {
    return undefined;
  }
}
