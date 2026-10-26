// Which addresses the reader may fetch: public web pages over http or https, never this machine,
// a private network, a link-local or metadata address, or a name only a local network knows.
// `checkURL` judges the address as written; the reader also checks where its name resolves
// (web.ts), since a public-looking name can point at a private address.
//
// No imports, so `npm test` checks these directly in Node.

export const MAX_URL_LENGTH = 2_000;

export type Refusal = "length" | "malformed" | "scheme" | "credentials" | "port" | "host" | "private";

/** A URL the reader may fetch, without its fragment, or why not. */
export function checkURL(text: unknown): { url: URL } | { refused: Refusal } {
  if (typeof text !== "string" || !text.trim() || text.length > MAX_URL_LENGTH) return { refused: "length" };
  let url: URL;
  try {
    url = new URL(text.trim());
  } catch {
    return { refused: "malformed" };
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return { refused: "scheme" };
  if (url.username || url.password) return { refused: "credentials" };
  // Only the web's own ports: anything else is a service, not a page.
  if (url.port && url.port !== "80" && url.port !== "443") return { refused: "port" };
  const host = hostOf(url);
  if (!host) return { refused: "host" };
  const ip = parseIP(host);
  if (ip) return isPublicIP(ip) ? { url: withoutFragment(url) } : { refused: "private" };
  if (!isPublicName(host)) return { refused: "host" };
  return { url: withoutFragment(url) };
}

/** The host as the URL parser wrote it, lowercased, without a trailing dot or IPv6 brackets. */
export function hostOf(url: URL): string {
  return url.hostname.toLowerCase().replace(/\.$/, "").replace(/^\[(.*)\]$/, "$1");
}

function withoutFragment(url: URL): URL {
  const copy = new URL(url.href);
  copy.hash = "";
  return copy;
}

/** Names that only mean something on a local network, or are reserved for tests and examples. */
const LOCAL_SUFFIXES = ["localhost", "local", "internal", "intranet", "lan", "home", "corp", "private", "test", "invalid", "example", "onion", "arpa", "localdomain"];

/** A name that could be a public website: letters, digits and hyphens, with a dot and a real top-level domain. */
export function isPublicName(host: string): boolean {
  if (host.length > 253 || !/^[a-z0-9.-]+$/.test(host)) return false;
  const labels = host.split(".");
  if (labels.length < 2 || labels.some((label) => !label || label.length > 63 || label.startsWith("-") || label.endsWith("-"))) return false;
  const top = labels[labels.length - 1];
  if (!/^([a-z]{2,63}|xn--[a-z0-9-]{1,59})$/.test(top)) return false;
  return !LOCAL_SUFFIXES.includes(top);
}

export type IP = { version: 4; bytes: number[] } | { version: 6; groups: number[] };

/** An IP address written as a host, in the forms the URL parser leaves: dotted IPv4, or IPv6. */
export function parseIP(host: string): IP | null {
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) {
    const bytes = host.split(".").map(Number);
    return bytes.every((byte) => byte <= 255) ? { version: 4, bytes } : null;
  }
  if (!host.includes(":") || !/^[0-9a-f:.]+$/.test(host)) return null;
  let text = host;
  // An IPv4 address at the end, like ::ffff:127.0.0.1, becomes two groups.
  const tail = text.match(/(\d{1,3}(?:\.\d{1,3}){3})$/);
  if (tail) {
    const bytes = tail[1].split(".").map(Number);
    if (bytes.some((byte) => byte > 255)) return null;
    text = text.slice(0, -tail[1].length) + `${((bytes[0] << 8) | bytes[1]).toString(16)}:${((bytes[2] << 8) | bytes[3]).toString(16)}`;
  }
  const halves = text.split("::");
  if (halves.length > 2) return null;
  const part = (piece: string) => (piece ? piece.split(":") : []);
  const head = part(halves[0]);
  const rest = halves.length === 2 ? part(halves[1]) : [];
  const missing = 8 - head.length - rest.length;
  if ((halves.length === 2 && missing < 1) || (halves.length === 1 && missing !== 0)) return null;
  const groups = [...head, ...Array(halves.length === 2 ? missing : 0).fill("0"), ...rest].map((group) => (/^[0-9a-f]{1,4}$/.test(group) ? parseInt(group, 16) : NaN));
  return groups.length === 8 && groups.every(Number.isFinite) ? { version: 6, groups } : null;
}

/** Whether an address is on the public internet, rather than private, local, shared, reserved or for documentation. */
export function isPublicIP(ip: IP): boolean {
  if (ip.version === 4) {
    const [a, b, c] = ip.bytes;
    if (a === 0 || a === 10 || a === 127 || a >= 224) return false;
    if (a === 100 && b >= 64 && b <= 127) return false; // carrier-grade NAT
    if (a === 169 && b === 254) return false; // link-local, and cloud metadata
    if (a === 172 && b >= 16 && b <= 31) return false;
    if (a === 192 && b === 168) return false;
    if (a === 192 && b === 0 && (c === 0 || c === 2)) return false;
    if (a === 192 && b === 88 && c === 99) return false;
    if (a === 198 && (b === 18 || b === 19)) return false; // benchmarking
    if (a === 198 && b === 51 && c === 100) return false;
    if (a === 203 && b === 0 && c === 113) return false;
    return true;
  }
  const g = ip.groups;
  // IPv4 inside IPv6: mapped (::ffff:a.b.c.d) and NAT64 (64:ff9b::a.b.c.d) are judged as IPv4.
  const embedded = (): IP => ({ version: 4, bytes: [g[6] >> 8, g[6] & 255, g[7] >> 8, g[7] & 255] });
  if (g.slice(0, 5).every((x) => x === 0) && g[5] === 0xffff) return isPublicIP(embedded());
  if (g[0] === 0x64 && g[1] === 0xff9b && g.slice(2, 6).every((x) => x === 0)) return isPublicIP(embedded());
  // Only global unicast (2000::/3) is public, less Teredo, 6to4 and documentation.
  if (g[0] < 0x2000 || g[0] > 0x3fff) return false;
  if (g[0] === 0x2001 && (g[1] === 0 || g[1] === 0xdb8)) return false;
  if (g[0] === 0x2002) return false;
  return true;
}
