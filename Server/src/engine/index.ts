// The page engine on the server: what the model wrote, turned into a page and checked exactly as
// the app does (Dream/Engine), so the loop can send real mistakes back to the model. Kept equal to
// the Swift engine by golden tests (test/golden). docs/ServerGeneration.md.
//
// FOUNDATION STUB: the signatures are the contract between the job runner and the engine port.
// The engine port replaces the bodies; the job runner only imports these.

/** A page as the app's Surface encodes it (Dream/Engine/Surface.swift). */
export type Surface = Record<string, unknown> & { title: string; summary: string; blocks: unknown[] };

/** Wikipedia's article for the page, as Surface.reference. */
export interface Reference {
  title: string;
  extract: string;
  url: string;
  imageURL?: string;
}

/** A page the model read, as Citation. */
export interface Citation {
  title: string;
  site: string;
  url: string;
  date?: string;
}

export interface Issue {
  kind: "fixed" | "needsModel" | "warning";
  message: string;
}

/** A finished answer (WireSurface JSON) as a page: Surface.init(_ wire:reference:). */
export function surfaceFromWire(wire: unknown, reference: Reference | null): Surface {
  return { title: "", summary: "", blocks: [], ...(wire as object), reference: reference ?? undefined } as Surface;
}

/** The answer so far, while it streams: Surface.init(partial:reference:). */
export function surfaceFromPartial(wire: unknown, reference: Reference | null): Surface {
  return surfaceFromWire(wire, reference);
}

export function isEmpty(surface: Surface): boolean {
  return !surface.title && !surface.summary && surface.blocks.length === 0;
}

/** Surface.isRepeatingItself: a page that has started looping. */
export function isRepeatingItself(_surface: Surface): boolean {
  return false;
}

/** Checker.checkLogic: fixes what it can in place, returns everything it found. */
export function checkLogic(surface: Surface): { surface: Surface; issues: Issue[] } {
  return { surface, issues: [] };
}

/** Checker.checkSourcing. */
export function checkSourcing(_surface: Surface, _read: Citation[]): Issue[] {
  return [];
}

/** Checker.checkCitations, with what was read. */
export function checkCitations(surface: Surface, _read: Citation[]): { surface: Surface; issues: Issue[] } {
  return { surface, issues: [] };
}

/** Checker.checkBlocks. */
export function checkBlocks(surface: Surface): { surface: Surface; issues: Issue[] } {
  return { surface, issues: [] };
}

/** Surface.outline: the page in shorthand, for the log and for repairs (Prompts.swift). */
export function outline(surface: Surface): string {
  return `${surface.title}: ${surface.summary}`;
}

/** Surface.logicSummary: the calculation in shorthand, for repairs. */
export function logicSummary(_surface: Surface): string {
  return "";
}

/** Surface.hasLogic. */
export function hasLogic(surface: Surface): boolean {
  return Array.isArray(surface.inputs) && surface.inputs.length > 0;
}
