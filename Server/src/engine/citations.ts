// Keeping a page's sources honest (Dream/Engine/Checker+Citations.swift, Citation.swift): only
// web pages, only pages the model really read, each credited with the page's own title and site.
// Addresses are compared the way URLComponents reads them, so one page under two spellings of its
// address is credited once.
//
// Not ported: URLComponents turns an internationalized host written as punycode (xn--…) into its
// Unicode form before comparing; here it's compared as written.

import { hasInformation, showsLiveValues } from "./surface.ts";
import { count, lower, prefix, trimAll } from "./swift.ts";
import type { Block, Citation, Issue, Reference, Surface } from "./types.ts";

/** A page the model read, with every address it can be cited by: the one asked for, the one the
 * page calls its own, and where it ended up. */
export interface ReadPage extends Citation {
  addresses?: string[];
}

/** The most sources a page credits. */
export const CITATION_LIMIT = 8;

// MARK: - Addresses

interface Parts {
  scheme: string;
  /** As written, or null when the address has none. */
  host: string | null;
  hasUser: boolean;
  path: string;
  query: string | null;
}

const UNRESERVED = /[A-Za-z0-9\-._~!$&'()*+,;=:@/]/;

/** Percent-encodes what URLComponents would: anything outside a path's or query's allowed
 * characters, and a % that doesn't start an escape. */
function encoded(text: string, allowQuestion: boolean): string {
  let result = "";
  const all = Array.from(text);
  for (let index = 0; index < all.length; index++) {
    const character = all[index];
    if (character === "%" && /^[0-9A-Fa-f]{2}$/.test(all.slice(index + 1, index + 3).join(""))) {
      result += character;
      continue;
    }
    if (UNRESERVED.test(character) || (allowQuestion && character === "?")) {
      result += character;
      continue;
    }
    for (const byte of new TextEncoder().encode(character)) result += "%" + byte.toString(16).toUpperCase().padStart(2, "0");
  }
  return result;
}

function parts(raw: string): Parts | null {
  const match = raw.match(/^([A-Za-z][A-Za-z0-9+.\-]*):(.*)$/s);
  if (!match) return null;
  const scheme = match[1];
  let rest = match[2];
  const hash = rest.indexOf("#");
  if (hash >= 0) rest = rest.slice(0, hash);
  let host: string | null = null;
  let hasUser = false;
  if (rest.startsWith("//")) {
    const end = rest.slice(2).search(/[/?]/);
    const authority = end < 0 ? rest.slice(2) : rest.slice(2, 2 + end);
    rest = end < 0 ? "" : rest.slice(2 + end);
    if (/[\\\s]/.test(authority)) return null;
    const at = authority.lastIndexOf("@");
    hasUser = at >= 0;
    let hostPort = at >= 0 ? authority.slice(at + 1) : authority;
    if (hostPort.startsWith("[")) {
      const close = hostPort.indexOf("]");
      hostPort = close >= 0 ? hostPort.slice(0, close + 1) : hostPort;
    } else {
      const colon = hostPort.lastIndexOf(":");
      if (colon >= 0) hostPort = hostPort.slice(0, colon);
    }
    host = hostPort;
  }
  const question = rest.indexOf("?");
  const path = question >= 0 ? rest.slice(0, question) : rest;
  const query = question >= 0 ? rest.slice(question + 1) : null;
  return { scheme, host, hasUser, path: encoded(path, false), query: query === null ? null : encoded(query, true) };
}

/** Citation.key: an address the same however it's written, or null for anything but http and https. */
export function citationKey(url: string): string | null {
  const found = parts(trimAll(url));
  if (!found) return null;
  const scheme = lower(found.scheme);
  if (scheme !== "http" && scheme !== "https") return null;
  if (found.host === null || found.hasUser) return null;
  const host = lower(found.host);
  if (host === "") return null;
  const path = found.path.replace(/\/+$/, "");
  const bare = host.startsWith("www.") ? host.slice(4) : host;
  return bare + path + (found.query === null ? "" : `?${found.query}`);
}

/** `URL(string:)?.host()`: the host as written, percent-encoded. */
export function urlHost(url: string): string | null {
  if (url !== trimAll(url)) return null;
  const found = parts(url);
  if (!found || !found.host) return null;
  const host = found.host.startsWith("[") && found.host.endsWith("]") ? found.host.slice(1, -1) : found.host;
  return encoded(host, false);
}

/** A Wikipedia article as a credit. */
export function citationOf(reference: Reference): Citation {
  return { title: reference.title, site: "Wikipedia", url: reference.url };
}

// MARK: - Reading lists

/** The pages a model read while writing one page, by every address it could cite them by. */
export class ReadingList {
  readonly pages: Citation[] = [];
  private byAddress = new Map<string, number>();

  constructor(pages: ReadPage[] = []) {
    for (const page of pages) this.add(page, page.addresses ?? []);
  }

  add(page: Citation, addresses: string[] = []) {
    const key = citationKey(page.url);
    let index = key === null ? undefined : this.byAddress.get(key);
    if (index === undefined) {
      index = this.pages.length;
      const credit: Citation = { title: page.title, site: page.site, url: page.url };
      if (page.date !== undefined) credit.date = page.date;
      this.pages.push(credit);
    }
    for (const address of [page.url, ...addresses]) {
      const known = citationKey(address);
      if (known !== null && !this.byAddress.has(known)) this.byAddress.set(known, index);
    }
  }

  page(url: string): Citation | undefined {
    const key = citationKey(url);
    const index = key === null ? undefined : this.byAddress.get(key);
    return index === undefined ? undefined : this.pages[index];
  }
}

// MARK: - Checking

/** A page that tells the reader about the world rests on something looked up. A tool for the
 * user's own numbers states nothing about the world, and needs nothing. */
export function checkSourcing(surface: Surface, read: ReadingList): Issue[] {
  if (read.pages.length || surface.reference || showsLiveValues(surface) || (surface.services ?? []).length) return [];
  const statesFacts = (blocks: Block[]): boolean =>
    blocks.some((block) => ["facts", "stat", "timeline"].includes(block.kind) || (block.kind === "data" && block.ref === "") || statesFacts(block.children));
  if (!(surface.mode === "learn" || surface.mode === "read" || statesFacts(surface.blocks))) return [];
  return [{
    kind: "needsModel",
    message: "It states facts about the world without looking any up. Look them up first, with lookup, or search and read for anything current, local or about prices, then return the whole screen built on what they say.",
  }];
}

/** Keeps the sources a page credits to web pages and, while it's being written, to pages the model
 * read (`read`), credited with the page's own title, site and address. If it read pages but named
 * none, every page it read is credited. With `read` null, only the addresses are checked. */
export function checkCitations(surface: Surface, read: ReadingList | null): Issue[] {
  const issues: Issue[] = [];
  const fixed = (message: string) => issues.push({ kind: "fixed", message });
  let named = surface.citations ?? [];
  if (read && named.length === 0 && hasInformation(surface) && read.pages.length) {
    named = read.pages;
    issues.push({ kind: "warning", message: "Named no sources, so every page read is credited." });
  }
  // The article already credited as the reference isn't credited twice.
  const referenceKey = surface.reference ? citationKey(surface.reference.url) : null;
  const seen = new Set<string>(referenceKey === null ? [] : [referenceKey]);
  let kept: Citation[] = [];
  for (const citation of named) {
    const key = citationKey(citation.url);
    if (key === null || count(citation.url) > 2_000) {
      fixed("Dropped a source that isn't a web address.");
      continue;
    }
    let credited = citation;
    if (read) {
      const page = read.page(citation.url);
      if (!page) {
        fixed(`Dropped a source that wasn't read: ${urlHost(citation.url) ?? citation.url}.`);
        continue;
      }
      credited = page;
    }
    // Named twice, or under two addresses of one page.
    const creditedKey = citationKey(credited.url);
    if (creditedKey === null || seen.has(key) || seen.has(creditedKey)) continue;
    seen.add(key);
    seen.add(creditedKey);
    kept.push(bounded(credited));
  }
  if (kept.length > CITATION_LIMIT) {
    fixed(`Kept the first ${CITATION_LIMIT} of ${kept.length} sources.`);
    kept = kept.slice(0, CITATION_LIMIT);
  }
  if (kept.length) surface.citations = kept;
  else delete surface.citations;
  return issues;
}

/** No longer than a footnote needs, with a site name even if the page gave none. */
function bounded(original: Citation): Citation {
  const host = lower(urlHost(original.url) ?? "").replace(/^www\./, "");
  const citation: Citation = { title: original.title, site: original.site, url: original.url };
  citation.site = prefix(trimAll(citation.site), 80);
  if (citation.site === "") citation.site = host;
  citation.title = prefix(trimAll(citation.title), 200);
  if (citation.title === "") citation.title = citation.site;
  if (original.date !== undefined && /^\p{Nd}{4}-\p{Nd}{2}-\p{Nd}{2}$/u.test(original.date)) citation.date = original.date;
  return citation;
}
