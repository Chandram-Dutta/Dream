// The checker's rules for units (Dream/Engine/Checker+Units.swift), called from checkLogic and
// checkBlocks: units tidied and taken out of labels, and never written twice beside a live value.

import { isMeasured } from "./surface.ts";
import { sorted, upper } from "./swift.ts";
import { join, parts, type Part } from "./tex.ts";
import type { Block, Format, Issue, Surface } from "./types.ts";
import { Currency, Units } from "./units.ts";

/** Units as Dream writes them: tidied, out of labels, and only where they mean something. */
export function checkUnits(surface: Surface): Issue[] {
  const tidied: string[] = [];
  for (const item of [...surface.inputs, ...surface.outputs]) {
    const [label, unit] = tidiedUnit(item.label, item.unit, item.format);
    if (label !== item.label || unit !== item.unit) tidied.push(item.name);
    item.label = label;
    item.unit = unit;
  }
  if (!tidied.length) return [];
  return [{ kind: "fixed", message: `Tidied the units of ${tidied.map((name) => `'${name}'`).join(", ")}.` }];
}

const LABELLED = /^(.+?)\s*[(\[]\s*([^()\[\]]{1,16}?)\s*[)\]]$/u;

function tidiedUnit(original: string, raw: string, format: Format): [string, string] {
  let label = original;
  let unit = Units.tidy(raw);
  // "Distance (km)": the unit belongs in the unit. "Tip (%)" and "Bill ($)" repeat the format.
  const match = label.match(LABELLED);
  if (match) {
    const inside = match[2];
    const shownByFormat = (format === "percent" && inside === "%")
      || (format === "currency" && (inside === Currency.symbol || upper(inside) === Currency.code || "$€£¥₹".includes(inside)));
    const isUnit = isMeasured(format) && (unit === "" ? Units.isUnit(inside) : Units.tidy(inside) === unit);
    const isCurrency = format === "currency" && Currency.isCode(upper(inside));
    if (shownByFormat || isUnit || isCurrency) {
      label = match[1];
      if (unit === "" && isUnit) unit = Units.tidy(inside);
      if (unit === "" && isCurrency) unit = upper(inside);
    }
  }
  // Money in another currency keeps its code, like USD.
  if (format === "currency" && Currency.isCode(upper(unit))) unit = upper(unit);
  else if (!isMeasured(format)) unit = "";
  return [label, unit];
}

const REPEATED_IN_MATHS =
  /(\\val(?:ue)?\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\})(?:\s|\\[,;:! ]|~)*(\\(?:mathrm|text|textrm|rm|mbox)\{[^{}]*\}(?:\^\{?-?[0-9]\}?)?)/gu;

/** A live value already shows its unit, so "{distance} m" or `\val{v}\,\mathrm{m/s}` says it twice. */
export function removeRepeatedUnits(surface: Surface): Issue[] {
  const units = new Map<string, string>();
  for (const item of [...surface.inputs, ...surface.outputs]) {
    if (item.unit !== "" && isMeasured(item.format) && !units.has(item.name)) units.set(item.name, item.unit);
  }
  if (!units.size) return [];
  const repeated = new Set<string>();

  const math = (tex: string): string => {
    if (!tex.includes("\\val")) return tex;
    return tex.replace(REPEATED_IN_MATHS, (whole: string, value: string, name: string, written: string) => {
      const unit = units.get(name);
      if (unit === undefined || Units.tidy(written) !== unit) return whole;
      repeated.add(name);
      return value;
    });
  };

  const prose = (text: string): string => {
    if (!text.includes("{")) return text;
    const result: Part[] = [];
    let changed = false;
    for (const part of parts(text)) {
      if ("text" in part) {
        const last = result[result.length - 1];
        const unit = last && "name" in last ? units.get(last.name) : undefined;
        const rest = unit === undefined ? null : Units.dropping(unit, part.text);
        if (last && "name" in last && rest !== null) {
          repeated.add(last.name);
          changed = true;
          result.push({ text: rest });
        } else {
          result.push(part);
        }
      } else if ("math" in part) {
        const fixed = math(part.math);
        changed = changed || fixed !== part.math;
        result.push({ math: fixed });
      } else {
        result.push(part);
      }
    }
    return changed ? join(result) : text;
  };

  const fix = (block: Block): Block => ({
    ...block,
    title: prose(block.title),
    text: block.kind === "equation" ? math(block.text) : prose(block.text),
    items: block.items.map((item) => ({ label: item.label, value: prose(item.value) })),
    children: block.children.map(fix),
  });

  surface.blocks = surface.blocks.map(fix);
  if (!repeated.size) return [];
  return [{
    kind: "fixed",
    message: `Removed units written after the live values of ${sorted(repeated).map((name) => `'${name}'`).join(", ")}, which show their own.`,
  }];
}
