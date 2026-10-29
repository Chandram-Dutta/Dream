// A page in shorthand (Dream/Generation/Prompts.swift's outline and logicSummary, with the
// pieces Prompts+Figures, +Sounds, +Scenes, +Web and +Live add): what the log shows, and what a
// repair or a change shows the model, in far fewer tokens than JSON.
//
// Not ported: a connected service's action is outlined by its tool and the JSON it sends
// (ConnectionLive.swift); here it's outlined like any other action, by its fields.

import { recordCollections, titleField, visibleBlocks } from "./surface.ts";
import { compare, lower, plain } from "./swift.ts";
import type { Block, RecordField, RecordValue, Surface } from "./types.ts";

/** The calculation in the shorthand the prompts use. */
export function logicSummary(surface: Surface): string {
  const lines = ["Inputs:"];
  for (const input of surface.inputs) {
    switch (input.format) {
      case "toggle":
        lines.push(`- ${input.name}: "${input.label}", toggle, starts ${input.initial !== 0 ? "on" : "off"}`);
        break;
      case "choice":
        lines.push(`- ${input.name}: "${input.label}", choice of ${input.options.join(" / ")}, starts at option ${plain(input.initial)}`);
        break;
      default: {
        const symbol = (input.symbol === "" ? "" : `, written ${input.symbol}`) + (input.unit === "" ? "" : `, in ${input.unit}`);
        switch (input.role) {
          case "given":
            lines.push(`- ${input.name}: "${input.label}", given ${input.format}, ${plain(input.initial)}${symbol}`);
            break;
          case "variable":
            lines.push(`- ${input.name}: "${input.label}", variable ${input.format}, ${plain(input.min)} to ${plain(input.max)}${symbol}`);
            break;
          case "adjustable":
            lines.push(`- ${input.name}: "${input.label}", ${input.format}, starts at ${plain(input.initial)}, ${plain(input.min)} to ${plain(input.max)}, step ${plain(input.step)}${symbol}`);
            break;
          case "live":
            lines.push(`- ${input.name}: "${input.label}", live ${input.format} from ${input.source}, now ${plain(input.initial)}${symbol}`);
            break;
        }
      }
    }
  }
  lines.push("Outputs:");
  for (const output of surface.outputs) {
    lines.push(`- ${output.name}: "${output.label}", ${output.format}${output.symbol === "" ? "" : `, written ${output.symbol}`}${output.unit === "" ? "" : `, in ${output.unit}`} = ${output.formula}`);
  }
  return lines.join("\n");
}

/** The page in shorthand, for showing the model what's there and for the log. */
export function outline(surface: Surface): string {
  const lines = (blocks: Block[], depth: number): string[] =>
    blocks.flatMap((block) => {
      const pad = "  ".repeat(depth);
      let line = `${pad}- ${block.kind} #${block.id}`;
      if (block.ref !== "") line += ` ref ${block.ref}`;
      if (block.over !== "") line += ` over ${block.over}`;
      if (block.title !== "") line += ` "${block.title}"`;
      const result = [line];
      if (block.text !== "") result.push(`${pad}  ${block.text}`);
      for (const item of block.items) result.push(`${pad}  • ${item.label === "" ? item.value : `${item.label}: ${item.value}`}`);
      return [...result, ...lines(block.children, depth + 1)];
    });
  const summary = collectionSummary(surface);
  const all = [`${surface.title}: ${surface.summary}`, ...(summary === "" ? [] : [summary]), ...lines(visibleBlocks(surface), 0)];
  all.push(...soundOutline(surface), ...visualOutline(surface), ...liveOutline(surface), ...sceneOutline(surface));
  if (surface.related.length) all.push("related: " + surface.related.join(", "));
  all.push(...citationOutline(surface));
  return all.join("\n");
}

/** "an expense", "a grocery". */
function indefinite(noun: string): string {
  const first = lower(noun)[0];
  return (first !== undefined && "aeio".includes(first) ? "an " : "a ") + noun;
}

/** The value as a model or a person would write it back: "400", "2026-10-26", "yes". */
function written(field: RecordField, value: RecordValue): string {
  if (typeof value === "number") {
    if (field.type === "date") return new Date(value * 1000).toISOString().slice(0, 10);
    if (field.type === "done") return value !== 0 ? "yes" : "no";
    return plain(value);
  }
  return value;
}

/** The lists in shorthand. Never the user's entries. */
function collectionSummary(surface: Surface): string {
  const collections = recordCollections(surface);
  if (!collections.length) return "";
  const lines = ["Lists:"];
  for (const collection of collections) {
    const fields = collection.fields.map((field) =>
      field.type === "choice" ? `${field.name} (choice of ${field.options.join(" / ")})` : `${field.name} (${field.type})`);
    lines.push(`- ${collection.name}: "${collection.label}", each ${indefinite(collection.entry === "" ? "entry" : collection.entry)}: ${fields.join(", ")}`
      + (collection.source === undefined ? "" : `; filled from ${collection.source}`));
    const title = titleField(collection);
    if (title && collection.starters.length) {
      const titles = collection.starters.slice(0, 30).flatMap((starter) => (title.name in starter ? [written(title, starter[title.name])] : []));
      lines.push(`  starters: ${titles.join(", ")}`);
    }
  }
  return lines.join("\n");
}

function soundOutline(surface: Surface): string[] {
  const sounds = surface.sounds;
  if (!sounds || !sounds.length) return [];
  return ["sounds:", ...sounds.map((sound) => {
    if (!sound.tones.length) {
      const recording = sound.recording;
      const found = recording ? ` (found "${recording.title}", ${recording.licence}${recording.credit === "" ? "" : `, ${recording.credit}`})` : "";
      return `- ${sound.name} "${sound.label}": recording, search "${sound.search}"${found}`;
    }
    const tones = sound.tones.map((tone) => `${tone.waveform} at ${tone.frequency} Hz, amplitude ${tone.amplitude}`);
    return `- ${sound.name} "${sound.label}": tones ${tones.join("; ")}`;
  })];
}

function visualOutline(surface: Surface): string[] {
  const lines: string[] = [];
  for (const figure of surface.figures ?? []) {
    lines.push(`figure ${figure.name}:`);
    for (const point of figure.points) lines.push(`  point ${point.name} = (${point.x}, ${point.y})${point.label === "" ? "" : ` "${point.label}"`}`);
    for (const shape of figure.shapes) {
      let line = `  ${shape.kind} ${shape.points.join(", ")}`;
      if (shape.kind === "circle") line += ` radius ${shape.radius}`;
      else if (shape.kind === "arc") line += ` radius ${shape.radius} from ${shape.from}° to ${shape.to}°`;
      else if (shape.kind === "path") line += `(${shape.x}, ${shape.y}) over ${shape.over}${shape.from === "" ? "" : ` from ${shape.from} to ${shape.to}`}`;
      if (shape.label !== "") line += ` "${shape.label}"`;
      lines.push(`${line} ${shape.tone}`);
    }
  }
  for (const diagram of surface.diagrams ?? []) {
    lines.push(`diagram ${diagram.name}, ${diagram.shape}:`);
    for (const node of diagram.nodes) lines.push(`  ${node.id} "${node.label}"${node.detail === "" ? "" : `: ${node.detail}`}`);
    for (const edge of diagram.edges) lines.push(`  ${edge.from} → ${edge.to}${edge.label === "" ? "" : ` "${edge.label}"`}`);
  }
  return lines;
}

function liveOutline(surface: Surface): string[] {
  const lines: string[] = [];
  const sources = surface.sources;
  if (sources && sources.length) {
    lines.push("sources (fetched with the live tool; fetch again to change one):");
    for (const source of sources) {
      const asked = Object.entries(source.parameters).sort(([a], [b]) => compare(a, b)).map(([key, value]) => `${key} ${value}`).join(", ");
      const fields = source.fields.map((field) => `${source.name}.${field.name}`).join(", ");
      lines.push(`- ${source.name}: ${source.kind}, ${asked}; fields ${fields}`);
    }
  }
  const actions = surface.actions;
  if (actions && actions.length) {
    lines.push("actions:");
    for (const action of actions) {
      const fields = Object.entries(action.fields).sort(([a], [b]) => compare(a, b)).map(([key, value]) => `${key} "${value}"`).join(", ");
      lines.push(`- ${action.name}: ${action.kind}, ${fields}`);
    }
  }
  return lines;
}

function sceneOutline(surface: Surface): string[] {
  const lines: string[] = [];
  for (const scene of surface.scenes ?? []) {
    lines.push(`scene ${scene.name}${scene.time === "" ? "" : `, time ${scene.time}`}:`);
    const molecule = scene.molecule;
    if (molecule) {
      const found = molecule.structure ? ` (found "${molecule.structure.title}", PubChem CID ${molecule.structure.cid}, ${molecule.structure.atoms.length} atoms)` : "";
      lines.push(`  molecule ${molecule.name}${found}`);
    }
    for (const object of scene.objects) {
      let line = `  ${object.name} ${object.kind} ${object.position}`;
      if (object.to !== "") line += ` to ${object.to}`;
      if (object.size !== "") line += ` size ${object.size}`;
      if (object.turn !== "") line += ` turn ${object.turn}`;
      if (object.tilt !== "") line += ` tilt ${object.tilt}`;
      if (object.label !== "") line += ` "${object.label}"`;
      lines.push(`${line} ${object.tone}`);
    }
    for (const plot of scene.plots) {
      lines.push(`  plot z = ${plot.z} for x ${plot.xFrom} to ${plot.xTo}, y ${plot.yFrom} to ${plot.yTo}${plot.label === "" ? "" : ` "${plot.label}"`}`);
    }
  }
  return lines;
}

function citationOutline(surface: Surface): string[] {
  const citations = surface.citations;
  if (!citations || !citations.length) return [];
  return ["citations (pages already read; list again the ones the screen still uses): " + citations.map((citation) => citation.url).join(", ")];
}
