// Checking sounds (Dream/Engine/Checker+Sounds.swift). Like blocks, sounds are always fixed
// locally: a tone that can't be worked out is dropped rather than sent back to the model.

import { CONSTANTS, describe, evaluate as evaluateExpr, FormulaError, names as namesIn, renamed, tryParse, usesKnownFunctions } from "./formula.ts";
import { closestName, identifier, words } from "./names.ts";
import { adjustableInputs, evaluate, initialValues, inputsFeeding, isControl, makeBlock, sound as soundNamed, type Evaluation } from "./surface.ts";
import { compare, plain, trim, trimAll } from "./swift.ts";
import type { Block, Issue, Sound, Surface } from "./types.ts";

/** How many tones a sound plays at once: enough for beats and most chords. */
const VOICES = 4;

/** A formula worked out with the page's values, or null if it can't be or isn't a number. */
export function valueOf(formula: string, evaluation: Evaluation): number | null {
  const expr = tryParse(formula);
  if (!expr) return null;
  try {
    const value = evaluateExpr(expr, (name) => {
      const known = evaluation.values.get(name);
      if (known !== undefined) return known;
      const constant = CONSTANTS.get(name);
      if (constant !== undefined) return constant;
      throw new FormulaError(`'${name}' isn't an input or output`);
    });
    return Number.isFinite(value) ? value : null;
  } catch {
    return null;
  }
}

/** Names, formulas and recordings. Runs before the blocks are checked, so a block can only keep a
 * sound that survived. */
export function checkSounds(surface: Surface): Issue[] {
  const original = surface.sounds;
  if (!original) return [];
  const issues: Issue[] = [];
  const fixed = (message: string) => issues.push({ kind: "fixed", message });
  const warning = (message: string) => issues.push({ kind: "warning", message });
  const values = new Set([...surface.inputs.map((input) => input.name), ...surface.outputs.map((output) => output.name)]);
  const start = evaluate(surface, initialValues(surface));
  const names = new Set<string>();

  /** A formula the tone can use: near-miss names renamed. Null if it can't be worked out. */
  const formula = (raw: string, sound: string): string | null => {
    const expr = tryParse(raw);
    if (!expr || !usesKnownFunctions(expr)) return null;
    const renames = new Map<string, string>();
    for (const name of namesIn(expr)) {
      if (values.has(name) || CONSTANTS.has(name)) continue;
      const match = closestName(name, values);
      if (match === null) return null;
      renames.set(name, match);
    }
    if (!renames.size) return raw;
    const list = [...renames].sort(([a], [b]) => compare(a, b)).map(([from, to]) => `'${from}' as '${to}'`);
    fixed(`In the sound '${sound}', read ${list.join(", ")}.`);
    return describe(renamed(expr, renames));
  };

  const sounds: Sound[] = [];
  for (const candidate of original) {
    const sound: Sound = { ...candidate, tones: candidate.tones };
    sound.name = identifier(sound.name === "" ? sound.label : sound.name);
    if (sound.name === "") {
      fixed("Dropped a sound with no name.");
      continue;
    }
    // Blocks name sounds the way they name inputs, so the two mustn't be confused.
    if (values.has(sound.name)) sound.name += "Sound";
    if (names.has(sound.name)) {
      fixed(`Dropped a second sound named '${sound.name}'.`);
      continue;
    }
    names.add(sound.name);
    sound.label = trimAll(sound.label);
    if (sound.label === "") sound.label = words(sound.name);

    if (sound.tones.length) {
      sound.search = "";
      delete sound.recording;
      const tones = [];
      for (const tone of sound.tones.slice(0, VOICES)) {
        const frequency = formula(tone.frequency, sound.name);
        if (frequency === null) {
          fixed(`Dropped a tone of '${sound.name}' whose frequency can't be worked out: ${tone.frequency}`);
          continue;
        }
        const amplitude = trim(tone.amplitude) === "" ? null : formula(tone.amplitude, sound.name);
        if (amplitude === null) fixed(`Gave a tone of '${sound.name}' a moderate loudness.`);
        tones.push({ frequency, amplitude: amplitude ?? "0.4", waveform: tone.waveform });
      }
      sound.tones = tones;
      if (!sound.tones.length) {
        fixed(`Dropped the sound '${sound.name}', which has no tone left.`);
        continue;
      }
      for (const tone of sound.tones) {
        const level = valueOf(tone.frequency, start);
        if (level !== null && !(level >= 20 && level <= 20_000)) warning(`'${sound.name}' starts at ${plain(level)} Hz, which people can't hear.`);
      }
    } else {
      sound.search = trimAll(sound.search);
      if (!sound.recording) {
        fixed(sound.search === ""
          ? `Dropped the sound '${sound.name}', which has neither tones nor a recording.`
          : `Dropped the sound '${sound.name}': no recording was found for "${sound.search}".`);
        continue;
      }
    }
    sounds.push(sound);
  }
  if (sounds.length) surface.sounds = sounds;
  else delete surface.sounds;
  return issues;
}

/** A sound block plays one sound: a near miss is read as the sound it means, and with only one
 * sound, a block naming none plays that. It's headed by the sound's own label. */
export function soundBlock(original: Block, surface: Surface, fixed: (message: string) => void): Block | null {
  const block: Block = { ...original, title: "", over: "", text: "", items: [], children: [] };
  const names = new Set((surface.sounds ?? []).map((sound) => sound.name));
  if (names.has(block.ref)) return block;
  const match = closestName(block.ref, names) ?? (names.size === 1 && block.ref === "" ? [...names][0] : null);
  if (match !== null) {
    block.ref = match;
    return block;
  }
  fixed(`Removed a sound block for '${block.ref}', which isn't a sound.`);
  return null;
}

function controls(block: Block): Set<string> {
  if (isControl(block.kind)) return new Set([block.ref]);
  const found = new Set<string>();
  for (const child of block.children) for (const name of controls(child)) found.add(name);
  return found;
}

const meets = (a: Set<string>, b: Set<string>) => [...a].some((name) => b.has(name));

/** Every sound is heard once. One no block plays gets a block of its own; a tone shaped by controls
 * in a single section joins them there. In a section, a sound comes after any chart and before the
 * controls: see it, hear it, then change it while it plays. */
export function placeSounds(surface: Surface): Issue[] {
  const sounds = surface.sounds;
  if (!sounds) return [];
  const issues: Issue[] = [];
  const placed = new Set<string>();
  const deduplicated = (blocks: Block[]): Block[] =>
    blocks.flatMap((original) => {
      if (original.kind === "sound") {
        if (placed.has(original.ref)) {
          issues.push({ kind: "fixed", message: `Removed a second block playing '${original.ref}'.` });
          return [];
        }
        placed.add(original.ref);
        return [original];
      }
      const block = { ...original, children: deduplicated(original.children) };
      // A row is for results side by side; a player needs the width.
      if (block.kind === "row" && block.children.some((child) => child.kind === "sound")) block.kind = "section";
      if ((block.kind === "section" || block.kind === "row") && !block.children.length) return [];
      return [block];
    });
  surface.blocks = deduplicated(surface.blocks);

  const allIDs = (blocks: Block[]): string[] => blocks.flatMap((block) => [block.id, ...allIDs(block.children)]);
  const ids = new Set(allIDs(surface.blocks));
  for (const sound of sounds) {
    if (placed.has(sound.name)) continue;
    let id = `${sound.name}-sound`;
    while (ids.has(id)) id += "-2";
    ids.add(id);
    surface.blocks.push(makeBlock(id, "sound", { ref: sound.name }));
    issues.push({ kind: "fixed", message: `Added a block to play '${sound.name}'.` });
  }

  const adjustable = new Set(adjustableInputs(surface).map((input) => input.name));
  for (let index = surface.blocks.length - 1; index >= 0; index--) {
    const block = surface.blocks[index];
    if (block.kind !== "sound") continue;
    const sound = soundNamed(surface, block.ref);
    if (!sound || !sound.tones.length) continue;
    const shaping = new Set<string>();
    for (const tone of sound.tones) {
      for (const formula of [tone.frequency, tone.amplitude]) {
        const expr = tryParse(formula);
        for (const name of expr ? namesIn(expr) : []) for (const fed of inputsFeeding(surface, name)) if (adjustable.has(fed)) shaping.add(fed);
      }
    }
    if (!shaping.size) continue;
    const holders = surface.blocks.map((_, at) => at).filter((at) => at !== index && meets(controls(surface.blocks[at]), shaping));
    if (holders.length !== 1 || surface.blocks[holders[0]].kind !== "section") continue;
    surface.blocks.splice(index, 1);
    const home = holders[0] > index ? holders[0] - 1 : holders[0];
    const children = surface.blocks[home].children;
    const firstControl = children.findIndex((child) => isControl(child.kind));
    children.splice(firstControl < 0 ? children.length : firstControl, 0, block);
    issues.push({ kind: "fixed", message: `Put the sound '${sound.name}' with the controls that change it.` });
  }
  for (const section of surface.blocks) {
    if (section.kind !== "section") continue;
    const children = section.children;
    const firstControl = children.findIndex((child) => isControl(child.kind));
    if (firstControl < 0) continue;
    const late = children.map((_, at) => at).filter((at) => at > firstControl && children[at].kind === "sound");
    if (!late.length) continue;
    const moved = late.map((at) => children[at]);
    for (const at of [...late].reverse()) children.splice(at, 1);
    children.splice(firstControl, 0, ...moved);
  }
  return issues;
}
