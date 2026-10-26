// Text from the web, made small and plain before it goes back to the app: entities decoded,
// Markdown flattened for snippets, whitespace tidied, and long text cut at a paragraph.
//
// No imports, so `npm test` checks these directly in Node.

const NAMED: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", ndash: "–", mdash: "—", hellip: "…",
  lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”", laquo: "«", raquo: "»", middot: "·", bull: "•",
  copy: "©", reg: "®", trade: "™", deg: "°", times: "×", divide: "÷", minus: "−", plusmn: "±",
  euro: "€", pound: "£", yen: "¥", cent: "¢", rupee: "₹", frac12: "½", frac14: "¼", frac34: "¾",
  sup2: "²", sup3: "³", micro: "µ", para: "¶", sect: "§", shy: "", zwj: "", zwnj: "", thinsp: " ", ensp: " ", emsp: " ",
};

/** HTML character references, as a page's raw text carries them. */
export function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-f]{1,6}|#\d{1,7}|[a-z][a-z0-9]{1,31});/gi, (whole, name: string) => {
    if (name[0] === "#") {
      const code = name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
      return code > 0 && code <= 0x10ffff && !(code >= 0xd800 && code <= 0xdfff) ? String.fromCodePoint(code) : "";
    }
    return NAMED[name.toLowerCase()] ?? whole;
  });
}

/** Markdown with its links as plain words and its images gone. A page's links aren't pages
 * anyone read, so they don't travel on. */
export function delink(markdown: string): string {
  return markdown
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/<(https?:\/\/[^>\s]{1,2000})>/g, "$1");
}

/** One line of plain text from Markdown: links become their words, images and emphasis go. */
export function flatten(markdown: string): string {
  return delink(markdown)
    .replace(/<[^>]{1,200}>/g, " ")
    .replace(/^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+/gm, "")
    .replace(/\\([\\`*_{}[\]()#+\-.!|])/g, "$1")
    .replace(/(\*\*|__|`)/g, "")
    .replace(/(^|[\s(])[_*]([^_*\n]{1,300})[_*](?=$|[\s).,;:!?])/g, "$1$2")
    .replace(/\s+/g, " ")
    .trim();
}

/** At most `max` characters, ending on a word, with an ellipsis if anything was cut. */
export function clip(text: string, max: number): string {
  if (text.length <= max) return text;
  const cut = text.slice(0, max - 1);
  const space = cut.lastIndexOf(" ");
  return `${(space > max * 0.5 ? cut.slice(0, space) : cut).trimEnd()}…`;
}

/** Tidies extracted page text: trimmed lines, no runs of blank lines, no repeated lines. */
export function tidy(text: string): string {
  const lines: string[] = [];
  const seen = new Set<string>();
  for (const raw of text.split("\n")) {
    const line = raw.replace(/[ \t\f\v ]+/g, " ").trim();
    if (!line) {
      if (lines.length && lines[lines.length - 1] !== "") lines.push("");
      continue;
    }
    // Menus and separators that slipped through: no letters or digits at all.
    if (!/[\p{L}\p{N}]/u.test(line)) continue;
    // Short lines that repeat are navigation and labels; long ones are content.
    if (line.length < 80 && seen.has(line)) continue;
    seen.add(line);
    lines.push(line);
  }
  return lines.join("\n").trim();
}

/** At most `max` characters of page text, ending at a paragraph or sentence where it can. */
export function capText(text: string, max: number): { text: string; truncated: boolean } {
  if (text.length <= max) return { text, truncated: false };
  const cut = text.slice(0, max);
  const paragraph = cut.lastIndexOf("\n\n");
  const sentence = Math.max(cut.lastIndexOf(". "), cut.lastIndexOf(".\n"));
  const end = paragraph > max * 0.6 ? paragraph : sentence > max * 0.6 ? sentence + 1 : cut.lastIndexOf(" ") > max * 0.6 ? cut.lastIndexOf(" ") : max;
  return { text: `${cut.slice(0, end).trimEnd()}\n…`, truncated: true };
}

/** A site's name from its host when the page doesn't give one: www.gsmarena.com → gsmarena.com. */
export function siteOf(host: string): string {
  return host.toLowerCase().replace(/^(www\d?|m|amp|mobile)\./, "");
}

/** A date as YYYY-MM-DD, from the forms pages write them in, or undefined. */
export function dayOf(text: unknown): string | undefined {
  if (typeof text !== "string" || !text.trim()) return undefined;
  const iso = text.trim().match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (iso) return `${iso[1]}-${iso[2]}-${iso[3]}`;
  const time = Date.parse(text);
  return Number.isFinite(time) ? new Date(time).toISOString().slice(0, 10) : undefined;
}
