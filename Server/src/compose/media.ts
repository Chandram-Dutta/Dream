// What a page plays and draws that's fetched once it's written, ported from the app so a page
// made here has the same recordings and molecules as one made on the phone:
//
//   recordings  Wikimedia Commons, one search per sound, then the best file iOS can play, with
//               its credit and licence (Dream/Generation/SoundLookup.swift).
//   molecules   PubChem's 3D record for a molecule a scene names, checked as strictly as the
//               model's output, and its own name and formula (MoleculeLookup.swift, and
//               Dream/Engine/Molecule.swift's MoleculeStructure(pubChem:)).
//
// What comes back is untrusted: only a checked structure and cleaned-up words reach the page,
// and nothing of it reaches the model. A sound or molecule that finds nothing is left without,
// and the checker drops it.
//
// test/compose.mjs runs it in Node, with a stand-in for `fetch`.

import type { MoleculeStructure, Recording } from "../engine/index";
import { USER_AGENT } from "./live";

type JSONObject = Record<string, unknown>;
type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

const isObject = (value: unknown): value is JSONObject => value !== null && typeof value === "object" && !Array.isArray(value);
const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** One request, and once more a moment later when the service asks busy clients to slow down. */
async function get(url: string, fetcher: Fetch, busy: number[], timeout: number): Promise<Response | null> {
  for (let attempt = 0; attempt < 2; attempt++) {
    let response: Response;
    try {
      response = await fetcher(url, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" }, signal: AbortSignal.timeout(timeout) });
    } catch {
      return null;
    }
    if (busy.includes(response.status) && attempt === 0) {
      await response.body?.cancel();
      await pause(1_000);
      continue;
    }
    return response;
  }
  return null;
}

// MARK: - Recordings

/** Commons' descriptions are HTML. */
function stripped(html: string): string {
  const entities: [string, string][] = [["&amp;", "&"], ["&quot;", '"'], ["&#039;", "'"], ["&#39;", "'"], ["&lt;", "<"], ["&gt;", ">"], ["&nbsp;", " "]];
  let text = html.replace(/<[^>]+>/g, " ");
  for (const [entity, character] of entities) text = text.split(entity).join(character);
  return text.split(/\s+/u).filter(Boolean).join(" ");
}

/** Words of three letters or more, roughly singular. */
function stems(text: string): Set<string> {
  return new Set(
    text
      .toLowerCase()
      .split(/[^\p{L}\p{M}\p{N}]+/u)
      .filter((word) => [...word].length > 2)
      .map((word) => (word.endsWith("s") && [...word].length > 3 ? word.slice(0, -1) : word)),
  );
}

/** Who made it, as plain text. A list of roles (speaker, recorder) keeps only the first. */
function credit(html: string): string {
  const item = /<li>(.*?)<\/li>/s.exec(html);
  const text = stripped(item ? item[1] : html);
  if ([...text].length <= 80) return text;
  return [...text].slice(0, 80).join("").split(" ").slice(0, -1).join(" ") + "…";
}

interface CommonsInfo {
  url?: string;
  descriptionurl?: string;
  mime?: string;
  duration?: number;
  extmetadata?: Record<string, { value?: unknown }>;
  derivatives?: { src?: string; type?: string }[];
}

const metadata = (info: CommonsInfo, name: string) => {
  const value = info.extmetadata?.[name]?.value;
  return typeof value === "string" ? value : "";
};

/** A version iOS streams: MP3, AAC or WAV as uploaded, else Commons' own MP3 of the file. MIDI is
 * skipped: it's a score played by a synthesizer, not a recording. */
function recordingOf(title: string, info: CommonsInfo): Recording | null {
  const mime = info.mime ?? "";
  if (mime.includes("midi")) return null;
  const native = ["audio/mpeg", "audio/mp3", "audio/mp4", "audio/aac", "audio/x-m4a", "audio/wav", "audio/x-wav", "audio/wave"];
  const mp3 = (info.derivatives ?? []).find((derivative) => typeof derivative.type === "string" && derivative.type.startsWith("audio/mpeg"))?.src;
  const original = native.includes(mime) ? info.url : undefined;
  // Commons' MP3 is far smaller than a WAV original.
  const chosen = mime === "audio/mpeg" ? original : (mp3 ?? original);
  if (!chosen) return null;
  let audio: URL;
  try {
    audio = new URL(chosen.startsWith("//") ? `https:${chosen}` : chosen);
  } catch {
    return null;
  }
  audio.search = "";
  const name = title.replace(/^File:/, "").replace(/\.[A-Za-z0-9]+$/, "");
  const objectName = stripped(metadata(info, "ObjectName"));
  return {
    title: objectName || name,
    audioURL: audio.href,
    pageURL: info.descriptionurl ?? `https://commons.wikimedia.org/wiki/${title.replace(/ /g, "_")}`,
    credit: credit(metadata(info, "Artist")),
    licence: stripped(metadata(info, "LicenseShortName")),
    ...(typeof info.duration === "number" && info.duration > 0 ? { duration: info.duration } : {}),
  };
}

/** SoundLookup.find: the best recording on Wikimedia Commons for what a sound searches for. */
export async function findRecording(search: string, fetcher: Fetch = fetch): Promise<Recording | null> {
  const words = stems(search);
  if (!words.size) return null;
  const url = new URL("https://commons.wikimedia.org/w/api.php");
  const items: Record<string, string> = {
    action: "query",
    format: "json",
    formatversion: "2",
    generator: "search",
    gsrnamespace: "6",
    gsrsearch: `${search} filetype:audio`,
    gsrlimit: "8",
    prop: "videoinfo",
    viprop: "url|size|mime|extmetadata|derivatives",
  };
  for (const [name, value] of Object.entries(items)) url.searchParams.set(name, value);
  const response = await get(url.href, fetcher, [429], 8_000);
  if (!response?.ok) {
    await response?.body?.cancel();
    return null;
  }
  const answer: unknown = await response.json().catch(() => null);
  const pages = isObject(answer) && isObject(answer.query) && Array.isArray(answer.query.pages) ? answer.query.pages.filter(isObject) : [];
  // Search ranks by text, so a file can turn up for a single word of a longer search; one that
  // shares fewer than half the search's words is a wrong turn. Of the rest: the one that matches
  // most, short rather than long, since a page wants the call itself and not an hour of a marsh
  // at dawn, then the one whose title is most nearly the search.
  let best: { rank: number[]; recording: Recording } | null = null;
  for (const page of pages) {
    const info = Array.isArray(page.videoinfo) && isObject(page.videoinfo[0]) ? (page.videoinfo[0] as CommonsInfo) : null;
    const title = typeof page.title === "string" ? page.title : "";
    const recording = info && recordingOf(title, info);
    if (!info || !recording) continue;
    const about = stems(stripped([title, metadata(info, "ImageDescription"), metadata(info, "Categories")].join(" ")));
    const shared = [...words].filter((word) => about.has(word)).length;
    if (shared * 2 <= words.size) continue;
    const length = recording.duration ?? 30;
    if (length >= 600) continue;
    const extra = [...stems(recording.title)].filter((word) => !words.has(word)).length;
    const rank = [shared * 2 - (length > 90 ? 1 : 0), -extra, -(typeof page.index === "number" ? page.index : 0)];
    // Swift's max keeps the first of equals.
    if (!best || compareRanks(rank, best.rank) > 0) best = { rank, recording };
  }
  return best?.recording ?? null;
}

function compareRanks(a: number[], b: number[]): number {
  for (let index = 0; index < Math.min(a.length, b.length); index++) if (a[index] !== b[index]) return a[index] - b[index];
  return a.length - b.length;
}

// MARK: - Molecules

/** More than PubChem computes conformers for, and more than a phone should draw as balls. */
const MAX_ATOMS = 300;

/** MoleculeStructure.cleaned: a name or formula as plain, short text: letters, digits, spaces and
 * the punctuation chemical names use. */
export function cleaned(text: string): string {
  const kept = [...text].filter((character) => /[\p{L}\p{M}\p{N} \-,()[\]'+.:]/u.test(character)).join("");
  return [...kept.trim()].slice(0, 80).join("");
}

/** MoleculeStructure(pubChem:): a PUG REST compound record (record_type=3d), checked, centred on
 * its middle. Null if it isn't a usable 3D structure: every atom, coordinate and bond must make
 * sense. */
export function structureOf(record: unknown, title = "", formula = ""): MoleculeStructure | null {
  const compound = isObject(record) && Array.isArray(record.PC_Compounds) && isObject(record.PC_Compounds[0]) ? record.PC_Compounds[0] : null;
  if (!compound) return null;
  const ints = (value: unknown) => (Array.isArray(value) && value.every((item) => Number.isInteger(item)) ? (value as number[]) : null);
  const numbers = (value: unknown) => (Array.isArray(value) && value.every((item) => typeof item === "number") ? (value as number[]) : null);
  const id = isObject(compound.id) && isObject(compound.id.id) ? compound.id.id.cid : undefined;
  const cid = Number.isInteger(id) ? (id as number) : 0;
  const atoms = isObject(compound.atoms) ? compound.atoms : {};
  const ids = ints(atoms.aid);
  const elements = ints(atoms.element);
  if (cid <= 0 || !ids || !elements || ids.length < 1 || ids.length > MAX_ATOMS || elements.length !== ids.length) return null;
  if (!elements.every((element) => element >= 1 && element <= 118) || new Set(ids).size !== ids.length) return null;
  const coordinates = Array.isArray(compound.coords) && isObject(compound.coords[0]) ? compound.coords[0] : null;
  const order = coordinates ? ints(coordinates.aid) : null;
  if (!coordinates || !order || new Set(order).size !== new Set(ids).size || !order.every((atom) => ids.includes(atom)) || !ids.every((atom) => order.includes(atom))) return null;
  const conformer = Array.isArray(coordinates.conformers) && isObject(coordinates.conformers[0]) ? coordinates.conformers[0] : null;
  const xs = conformer ? numbers(conformer.x) : null;
  const ys = conformer ? numbers(conformer.y) : null;
  const zs = conformer ? numbers(conformer.z) : null;
  if (!xs || !ys || !zs || xs.length !== order.length || ys.length !== order.length || zs.length !== order.length) return null;

  const position = new Map<number, [number, number, number]>();
  for (let index = 0; index < order.length; index++) {
    const point: [number, number, number] = [xs[index], ys[index], zs[index]];
    if (!point.every(Number.isFinite) || Math.hypot(...point) >= 500) return null;
    position.set(order[index], point);
  }
  const points = ids.map((atom) => position.get(atom)!);
  const middle = [0, 1, 2].map((axis) => points.reduce((sum, point) => sum + point[axis], 0) / points.length);
  const placed = elements.map((element, index) => ({ element, x: points[index][0] - middle[0], y: points[index][1] - middle[1], z: points[index][2] - middle[2] }));

  // Bonds between atoms that exist, at lengths real bonds have. Others are left out.
  const indexOf = new Map(ids.map((atom, index) => [atom, index]));
  const bonds: MoleculeStructure["bonds"] = [];
  const bonded = isObject(compound.bonds) ? compound.bonds : null;
  const from = bonded ? ints(bonded.aid1) : null;
  const to = bonded ? ints(bonded.aid2) : null;
  if (bonded && from && to) {
    const orders = ints(bonded.order) ?? from.map(() => 1);
    if (to.length !== from.length || orders.length !== from.length || from.length > ids.length * 4) return null;
    const seen = new Set<string>();
    for (let k = 0; k < from.length; k++) {
      const a = indexOf.get(from[k]);
      const b = indexOf.get(to[k]);
      if (a === undefined || b === undefined || a === b) continue;
      const pair = `${Math.min(a, b)}-${Math.max(a, b)}`;
      if (seen.has(pair)) continue;
      seen.add(pair);
      const length = Math.hypot(placed[a].x - placed[b].x, placed[a].y - placed[b].y, placed[a].z - placed[b].z);
      if (length < 0.5 || length > 3.5) continue;
      bonds.push({ from: a, to: b, order: orders[k] >= 1 && orders[k] <= 3 ? orders[k] : 1 });
    }
  }
  return { cid, title: cleaned(title), formula: cleaned(formula), atoms: placed, bonds };
}

/** What's been found, by name, so changing a page doesn't fetch it again. */
const molecules = new Map<string, MoleculeStructure>();

async function pubChem(path: string, fetcher: Fetch): Promise<unknown> {
  const response = await get(`https://pubchem.ncbi.nlm.nih.gov/rest/pug/${path}`, fetcher, [503, 429], 10_000);
  if (!response) return null;
  if (response.status !== 200) {
    await response.body?.cancel();
    return null;
  }
  // A full 3D record for the biggest molecules allowed is well under this.
  const text = await response.text().catch(() => "");
  if (!text || text.length >= 4_000_000) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

/** Swift's String.capitalized, near enough for a molecule's name: each word's first letter up. */
const capitalized = (text: string) => text.toLowerCase().replace(/(^|[^\p{L}\p{N}'])(\p{L})/gu, (_, before: string, letter: string) => before + letter.toUpperCase());

/** MoleculeLookup.find: a molecule's measured or computed 3D structure from PubChem, with
 * PubChem's own name and formula. */
export async function findMolecule(name: string, fetcher: Fetch = fetch): Promise<MoleculeStructure | null> {
  const key = name.trim().toLowerCase();
  if (!key || [...key].length > 80) return null;
  const known = molecules.get(key);
  if (known) return known;
  // As addingPercentEncoding leaves only these: every byte of anything else is escaped.
  const segment = [...new TextEncoder().encode(key)].map((byte) => (/[a-z0-9-]/.test(String.fromCharCode(byte)) ? String.fromCharCode(byte) : `%${byte.toString(16).toUpperCase().padStart(2, "0")}`)).join("");
  const found = structureOf(await pubChem(`compound/name/${segment}/JSON?record_type=3d`, fetcher));
  if (!found) return null;
  const table = await pubChem(`compound/cid/${found.cid}/property/Title,MolecularFormula/JSON`, fetcher);
  const rows = isObject(table) && isObject(table.PropertyTable) && Array.isArray(table.PropertyTable.Properties) ? table.PropertyTable.Properties.filter(isObject) : [];
  const row = rows.find((item) => item.CID === found.cid);
  if (row) {
    found.title = cleaned(typeof row.Title === "string" ? row.Title : "");
    found.formula = cleaned(typeof row.MolecularFormula === "string" ? row.MolecularFormula : "");
  }
  if (!found.title) found.title = cleaned(capitalized(name));
  if (molecules.size > 500) molecules.delete(molecules.keys().next().value!);
  molecules.set(key, found);
  return found;
}

/** Forgets the molecules found, for tests. */
export function forgetMolecules(): void {
  molecules.clear();
}
