// The page engine on the server: what the model wrote, turned into a page and checked exactly as
// the app does (Dream/Engine), so the loop can send real mistakes back to the model. Kept equal to
// the Swift engine by golden tests (test/golden, test/engine.mjs). docs/ServerGeneration.md.
//
// The job runner imports only this file. Pages are plain JSON in the shape the app's Swift
// Surface encodes, so what's sent is what the app decodes. The checks change the page they're
// given, as the Swift does with `inout`, and return it with what they found.
//
// The checker reads the user's currency and units, which the app takes from the phone's locale:
// pass the request's `locale` (ComposeRequest.locale fits) to checkLogic. Without one it checks
// for a reader in the US, as the golden cases do by default.
//
// Reading the model's answer as it streams, as the app does: parsePartial(text so far), then, if
// wireIsReadable, surfaceFromPartial; a moment it can't read (a choice half written) keeps the
// page as it was. The finished answer is surfaceFromWire when wireIsWhole, and otherwise an
// answer cut short, read with surfaceFromPartial.

import { checkBlocks as checkBlocksIn, checkLogic as checkLogicIn, isRepeatingItself as repeating } from "./checker.ts";
import { checkCitations as checkCitationsIn, checkSourcing as checkSourcingIn, citationOf, ReadingList, type ReadPage } from "./citations.ts";
import { logicSummary as summaryOf, outline as outlineOf } from "./outline.ts";
import { parsePartial } from "./partial.ts";
import { hasLogic as logicIn, isEmpty as emptyIn, label as labelIn } from "./surface.ts";
import type { Citation, EngineLocale, Issue, MoleculeStructure, Recording, Reference, Surface } from "./types.ts";
import { asReader } from "./units.ts";
import { fromPartial, fromWire, wireIsReadable, wireIsWhole } from "./wire.ts";

export type { Citation, EngineLocale, Issue, MoleculeStructure, ReadPage, Recording, Reference, Surface };
export type * from "./types.ts";
export { citationOf, parsePartial, wireIsReadable, wireIsWhole };

/** A finished answer (WireSurface JSON) as a page: Surface.init(_ wire:reference:). Use it when
 * `wireIsWhole(wire)`; an answer that isn't whole is read with surfaceFromPartial, as the app does. */
export function surfaceFromWire(wire: unknown, reference: Reference | null): Surface {
  return fromWire(wire, reference);
}

/** The answer so far, while it streams: Surface.init(partial:reference:). */
export function surfaceFromPartial(wire: unknown, reference: Reference | null): Surface {
  return fromPartial(wire, reference);
}

/** Nothing on it: no title, summary, blocks or calculation. */
export function isEmpty(surface: Surface): boolean {
  return emptyIn(surface);
}

/** Surface.isRepeatingItself: a page that has started looping, which the loop stops. */
export function isRepeatingItself(surface: Surface): boolean {
  return repeating(surface);
}

/** Checker.checkLogic: fixes what it can in place, returns everything it found. */
export function checkLogic(surface: Surface, locale?: EngineLocale): { surface: Surface; issues: Issue[] } {
  return { surface, issues: asReader(locale ?? US, () => checkLogicIn(surface)) };
}

/** Checker.checkSourcing: a page about the world that looked nothing up goes back once. `read` is
 * every page read and every article looked up (citationOf), as for checkCitations. */
export function checkSourcing(surface: Surface, read: ReadPage[]): Issue[] {
  return checkSourcingIn(surface, new ReadingList(read));
}

/** Checker.checkCitations, with what was read: each page with every address it can be cited by
 * (`addresses`), and each Wikipedia article looked up, as citationOf(reference). Null checks only
 * the addresses, as for a page from elsewhere. */
export function checkCitations(surface: Surface, read: ReadPage[] | null): { surface: Surface; issues: Issue[] } {
  return { surface, issues: checkCitationsIn(surface, read === null ? null : new ReadingList(read)) };
}

/** Checker.checkBlocks: the blocks tidied, and anything the page doesn't show yet placed. */
export function checkBlocks(surface: Surface, locale?: EngineLocale): { surface: Surface; issues: Issue[] } {
  return { surface, issues: asReader(locale ?? US, () => checkBlocksIn(surface)) };
}

/** Surface.outline: the page in shorthand, for the log and for repairs (Prompts.swift). */
export function outline(surface: Surface): string {
  return outlineOf(surface);
}

/** Surface.logicSummary: the calculation in shorthand, for repairs. */
export function logicSummary(surface: Surface): string {
  return summaryOf(surface);
}

/** Surface.hasLogic: it has inputs or outputs. */
export function hasLogic(surface: Surface): boolean {
  return logicIn(surface);
}

/** Surface.label(of:): what the page calls a name: an input's, output's, sound's, list's or list
 * field's label, or the name itself. For describing the block a change points at. */
export function label(surface: Surface, name: string): string {
  return labelIn(surface, name);
}

// MARK: - What the lookups after the repairs find

/** What to search Wikimedia Commons for: each recording that hasn't been found (findRecordings). */
export function recordingSearches(surface: Surface): string[] {
  return (surface.sounds ?? []).filter((sound) => !sound.tones.length && !sound.recording && sound.search !== "").map((sound) => sound.search);
}

/** The recordings found, by what was searched for, onto the sounds that wanted them. */
export function addRecordings(surface: Surface, found: Map<string, Recording>): Surface {
  for (const sound of surface.sounds ?? []) {
    const recording = !sound.tones.length && !sound.recording ? found.get(sound.search) : undefined;
    if (recording) sound.recording = recording;
  }
  return surface;
}

/** What to look up on PubChem: each molecule without its structure yet (findMolecules). */
export function moleculeNames(surface: Surface): string[] {
  return (surface.scenes ?? []).flatMap((scene) => (scene.molecule && !scene.molecule.structure && scene.molecule.name !== "" ? [scene.molecule.name] : []));
}

/** The structures found, by name, onto the scenes that named them. */
export function addMolecules(surface: Surface, found: Map<string, MoleculeStructure>): Surface {
  for (const scene of surface.scenes ?? []) {
    const structure = scene.molecule && !scene.molecule.structure ? found.get(scene.molecule.name) : undefined;
    if (structure && scene.molecule) scene.molecule.structure = structure;
  }
  return surface;
}

const US: EngineLocale = { currency: "USD", currencySymbol: "$", measurementSystem: "ussystem", language: "en", region: "US" };
