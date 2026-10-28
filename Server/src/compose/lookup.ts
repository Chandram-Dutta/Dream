// Wikipedia, for the lookup tool: one search, then the best article's introduction, picture and
// address. Ported from Dream/Generation/Lookup.swift, so a page made here grounds its facts in the
// same articles a page made on the phone would. In another language, that language's Wikipedia
// is searched first, and English is the fallback.
//
// No imports, so test/compose.mjs runs it in Node, with a stand-in for `fetch`.

/** Wikipedia's article for a page, as the app's Reference. */
export interface Reference {
  title: string;
  extract: string;
  url: string;
  imageURL?: string;
}

type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

const QUESTION_WORDS = new Set([
  "what", "whats", "is", "are", "was", "were", "who", "whom", "whose", "how", "do", "does", "did", "why", "when",
  "where", "which", "the", "a", "an", "of", "tell", "me", "about", "explain", "work", "works", "working", "can",
  "could", "i", "you", "my", "mean", "means", "meaning", "please", "this", "that", "it", "in", "to",
]);

/** Wikimedia asks every tool for a name and a way to reach whoever runs it. */
const USER_AGENT = "Dream/0.1 (Dream's server; +https://dream.onlychan.xyz/support)";

/** Letters, marks and digits, like Foundation's CharacterSet.alphanumerics. */
const words = (text: string) => text.toLowerCase().split(/[^\p{L}\p{M}\p{N}]+/u).filter(Boolean);

/** Content words, roughly singular, for comparing a subject with an article title. */
function stems(text: string): Set<string> {
  return new Set(words(text).filter((word) => [...word].length > 2 && !QUESTION_WORDS.has(word)).map((word) => (word.endsWith("s") ? word.slice(0, -1) : word)));
}

/** For scripts written without spaces, where a title and its subject share no separate words. */
function overlaps(title: string, topic: string): boolean {
  const [a, b] = [title.toLowerCase(), topic.toLowerCase()];
  return [...a].length >= 2 && [...b].length >= 2 && (a.includes(b) || b.includes(a));
}

/** The subdomain of a language's Wikipedia: fr for French (Languages.wikipedia). */
export function wikipedia(language: string): string {
  const code = /^[A-Za-z]{2,3}/.exec(language)?.[0]?.toLowerCase() ?? "en";
  return ({ nb: "no", fil: "tl" } as Record<string, string>)[code] ?? code;
}

/** The language of the Wikipedia an article came from, so related topics are found there too. */
export function languageOf(reference: Reference): string {
  try {
    const host = new URL(reference.url).hostname;
    return host.endsWith(".wikipedia.org") ? host.split(".")[0] : "en";
  } catch {
    return "en";
  }
}

interface Page {
  title: string;
  index?: number;
  extract?: string;
  fullurl?: string;
  thumbnail?: { source?: string };
  pageprops?: Record<string, unknown>;
  langlinks?: { title: string }[];
}

interface Answer {
  query?: { pages?: Page[]; search?: { title: string }[] };
}

async function query(items: Record<string, string>, language: string, fetcher: Fetch): Promise<Answer | null> {
  if (!language || !/^[A-Za-z-]+$/.test(language)) return null;
  const url = new URL(`https://${language}.wikipedia.org/w/api.php`);
  for (const [name, value] of Object.entries({ action: "query", format: "json", formatversion: "2", ...items })) url.searchParams.set(name, value);
  try {
    const response = await fetcher(url.href, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" }, signal: AbortSignal.timeout(8_000) });
    if (!response.ok) {
      await response.body?.cancel();
      return null;
    }
    return (await response.json()) as Answer;
  } catch {
    return null;
  }
}

/** An article's introduction, image and address, and its link to another language if asked. */
function articleItems(linking: boolean): Record<string, string> {
  return {
    prop: `extracts|pageimages|info|pageprops${linking ? "|langlinks" : ""}`,
    exintro: "1",
    explaintext: "1",
    exchars: "1800",
    exlimit: "3",
    piprop: "thumbnail",
    pithumbsize: "800",
    inprop: "url",
    ppprop: "disambiguation",
  };
}

function reference(page: Page, language: string): Reference | null {
  if (!page.extract) return null;
  return {
    title: page.title,
    extract: page.extract,
    url: page.fullurl ?? `https://${language}.wikipedia.org/wiki/${page.title.replace(/ /g, "_")}`,
    ...(page.thumbnail?.source ? { imageURL: page.thumbnail.source } : {}),
  };
}

/** The best article for a subject, and the title of the same article in another Wikipedia. Search
 * always returns something; an article whose title shares no word with the subject is usually a
 * wrong turn that would mislead the page. */
async function search(topic: string, language: string, fetcher: Fetch, other?: string): Promise<{ reference: Reference; link?: string } | null> {
  const answer = await query({ redirects: "1", generator: "search", gsrsearch: topic, gsrlimit: "3", ...articleItems(other !== undefined), ...(other ? { lllang: other } : {}) }, language, fetcher);
  const subject = stems(topic);
  const best = [...(answer?.query?.pages ?? [])]
    .sort((a, b) => (a.index ?? 0) - (b.index ?? 0))
    .find((page) => !(page.pageprops && "disambiguation" in page.pageprops) && !!page.extract && ([...stems(page.title)].some((stem) => subject.has(stem)) || overlaps(page.title, topic)));
  const found = best && reference(best, language);
  return found ? { reference: found, link: best.langlinks?.[0]?.title } : null;
}

/** One article, by its exact title. */
async function article(title: string, language: string, fetcher: Fetch): Promise<Reference | null> {
  const answer = await query({ redirects: "1", titles: title, ...articleItems(false) }, language, fetcher);
  const page = answer?.query?.pages?.[0];
  return page ? reference(page, language) : null;
}

/** Lookup.find: the article for a subject, in the language's Wikipedia or else English's. */
export async function find(topic: string, language = "en", fetcher: Fetch = fetch): Promise<Reference | null> {
  const local = wikipedia(language);
  if (local === "en") return (await search(topic, "en", fetcher))?.reference ?? null;
  const found = await search(topic, local, fetcher);
  if (found) return found.reference;
  // Models often name the subject in English, which another language's search can miss: find it
  // in English, then follow the article's link to the same one in this language.
  const english = await search(topic, "en", fetcher, local);
  if (!english) return null;
  if (english.link) {
    const translated = await article(english.link, local, fetcher);
    if (translated) return translated;
  }
  return english.reference;
}

/** Lookup.related: articles Wikipedia's search considers similar, for pages the model didn't
 * finish listing. */
export async function related(title: string, language = "en", fetcher: Fetch = fetch): Promise<string[]> {
  const answer = await query({ list: "search", srsearch: `morelike:${title}`, srlimit: "5", srprop: "" }, wikipedia(language), fetcher);
  return (answer?.query?.search ?? []).map((item) => item.title);
}
