// A surface's blocks as HTML, after BlockView in the app (Dream/UI/BlockView.swift): calculations
// sit in tinted panels, information reads as text on the page. The page is read-only, so controls
// are drawn at their values rather than made to move. Every field is checked as it's read, since
// a stored surface is untrusted.

import { curveChart, dataChart, type Line } from "./charts";
import type { JsonObject } from "./payload";
import { escape, math, rich, type Live } from "./text";

type Any = unknown;
const obj = (value: Any): JsonObject => (value !== null && typeof value === "object" && !Array.isArray(value) ? (value as JsonObject) : {});
const list = (value: Any): Any[] => (Array.isArray(value) ? value : []);
const str = (value: Any): string => (typeof value === "string" ? value : "");
const num = (value: Any): number | undefined => (typeof value === "number" && Number.isFinite(value) ? value : undefined);

const INFORMATION = new Set(["paragraph", "facts", "bullets", "steps", "timeline", "stat", "equation", "data", "diagram"]);

export interface Equation {
  equation: string;
  worked?: string;
  legend?: { symbol: string; meaning: string }[];
}

export interface Page {
  surface: JsonObject;
  live: Live;
  equations: Record<string, Equation>;
  charts: Record<string, { axis: string; lines: Line[] }>;
  /** The sharer's numbers, when they shared them. */
  values: Record<string, number>;
  language: string;
}

/** A shared surface's values come from the app's own engine. Anything missing shows as a dash,
 * the way the app shows a value it can't work out. */
function shown(page: Page, name: string): string {
  return page.live.values[name] ?? "—";
}

function named(page: Page, key: string, name: string): JsonObject | undefined {
  return list(page.surface[key]).map(obj).find((item) => item.name === name);
}

function label(page: Page, name: string): string {
  for (const key of ["inputs", "outputs", "sounds", "collections", "diagrams"]) {
    const found = named(page, key, name);
    if (found && str(found.label)) return str(found.label);
  }
  return name;
}

function heading(block: JsonObject, page: Page, tag = "h3"): string {
  const title = str(block.title);
  return title ? `<${tag}>${rich(title, page.live)}</${tag}>` : "";
}

/** The first number in a data value, so "1,210.9 million" reads as 1210.9. */
function numberIn(value: string): number | undefined {
  const match = value.replaceAll(",", "").match(/-?\d+(?:\.\d+)?/);
  return match ? Number(match[0]) : undefined;
}

export function renderBlocks(blocks: Any[], page: Page, depth = 0): string {
  return list(blocks)
    .map((block) => renderBlock(obj(block), page, depth))
    .join("");
}

function renderBlock(block: JsonObject, page: Page, depth: number): string {
  const kind = str(block.kind);
  const items = list(block.items).map(obj);
  const ref = str(block.ref).split(",")[0]?.trim() ?? "";
  const panel = (html: string) => (depth === 0 ? `<div class="panel">${html}</div>` : html);

  switch (kind) {
    case "section": {
      const children = list(block.children).map(obj);
      const instrument = children.some((child) => !INFORMATION.has(str(child.kind)));
      const inner = children.map((child) => renderBlock(child, page, depth + 1)).filter(Boolean);
      const title = str(block.title) ? `<h3 class="${instrument ? "instrument-title" : ""}">${rich(block.title, page.live)}</h3>` : "";
      const body = title + inner.join(instrument ? `<hr>` : "");
      return instrument && depth === 0 ? `<section class="panel stack">${body}</section>` : `<section class="stack">${body}</section>`;
    }
    case "row":
      return `<div class="row">${list(block.children)
        .map((child) => `<div class="cell">${renderBlock(obj(child), page, depth)}</div>`)
        .join("")}</div>`;
    case "hero":
      return `<div class="hero"><div class="caption">${escape(label(page, ref))}</div><div class="hero-value number">${escape(shown(page, ref))}</div></div>`;
    case "metric":
      return panel(`<div class="metric"><div class="caption">${escape(label(page, ref))}</div><div class="metric-value">${escape(shown(page, ref))}</div></div>`);
    case "chart": {
      const chart = page.charts[str(block.id)];
      if (!chart) return "";
      return panel(`${str(block.title) ? `<h4>${rich(block.title, page.live)}</h4>` : ""}${curveChart(chart.lines, chart.axis, page.language)}`);
    }
    case "slider":
    case "stepper":
    case "field":
    case "toggle":
    case "picker":
      return panel(control(kind, ref, page));
    case "equation":
      return equation(block, ref, page);
    case "data": {
      // A chart of the user's own entries: those never leave their phone.
      if (ref) return "";
      const points = items.flatMap((item) => {
        const value = numberIn(str(item.value));
        return value === undefined ? [] : [{ label: str(item.label), value }];
      });
      return `<div class="block">${heading(block, page)}${dataChart(points, page.language)}</div>`;
    }
    case "paragraph":
      return `<div class="block">${heading(block, page)}<p>${rich(block.text, page.live)}</p></div>`;
    case "facts":
      return `<div class="block">${heading(block, page)}<dl class="facts">${items
        .map((item) => `<div><dt>${rich(item.label, page.live)}</dt><dd>${rich(item.value, page.live)}</dd></div>`)
        .join("")}</dl></div>`;
    case "bullets":
      return `<div class="block">${heading(block, page)}<ul class="bullets">${items.map((item) => `<li>${rich(item.value, page.live)}</li>`).join("")}</ul></div>`;
    case "steps":
      return `<div class="block">${heading(block, page)}<ol class="steps">${items.map((item) => `<li>${rich(item.value, page.live)}</li>`).join("")}</ol></div>`;
    case "timeline":
      return `<div class="block">${heading(block, page)}<ol class="timeline">${items
        .map((item) => `<li><span class="when">${escape(item.label)}</span><span>${rich(item.value, page.live)}</span></li>`)
        .join("")}</ol></div>`;
    case "stat":
      return `<div class="block">${heading(block, page)}${items
        .map((item) => {
          const big = str(item.label) || str(item.value);
          return `<div class="stat"><div class="stat-value number">${escape(big)}</div>${str(item.label) ? `<div class="secondary">${rich(item.value, page.live)}</div>` : ""}</div>`;
        })
        .join("")}</div>`;
    case "list":
      return collection(ref, page);
    case "sound":
      return panel(sound(ref, page));
    case "diagram":
      return diagram(block, ref, page);
    case "figure":
      return panel(`${str(block.title) ? `<h4>${rich(block.title, page.live)}</h4>` : ""}<div class="placeholder"><span class="mark"></span>A drawing that moves with the numbers. Open it in Dream to try it.</div>`);
    default:
      // The quick-add bar, and kinds a newer app knows.
      return "";
  }
}

/** A control drawn at its value. */
function control(kind: string, name: string, page: Page): string {
  const input = named(page, "inputs", name);
  if (!input) return "";
  const caption = `<span class="caption">${escape(str(input.label) || name)}</span>`;
  const value = page.values[name] ?? num(input.initial) ?? 0;
  const reading = `<span class="reading number">${escape(shown(page, name))}</span>`;
  switch (kind) {
    case "toggle":
      return `<div class="control inline">${caption}<span class="switch${value !== 0 ? " on" : ""}" role="img" aria-label="${value !== 0 ? "On" : "Off"}"></span></div>`;
    case "picker": {
      const options = list(input.options).map(str);
      const selected = Math.round(value);
      if (options.length <= 3 && options.every((option) => option.length <= 14)) {
        return `<div class="control">${caption}<div class="segments">${options.map((option, index) => `<span${index === selected ? ' class="selected"' : ""}>${escape(option)}</span>`).join("")}</div></div>`;
      }
      return `<div class="control inline">${caption}<span class="choice">${escape(options[selected] ?? "—")}</span></div>`;
    }
    case "stepper":
      return `<div class="control inline"><span class="stack-tight">${caption}${reading}</span><span class="steppers" aria-hidden="true"><span>−</span><span>+</span></span></div>`;
    case "field":
      return `<div class="control">${caption}<span class="field number">${escape(shown(page, name))}</span></div>`;
    default: {
      const low = num(input.min) ?? 0;
      const high = num(input.max) ?? 1;
      const fraction = high > low ? Math.min(Math.max((value - low) / (high - low), 0), 1) : 0;
      return `<div class="control"><div class="inline">${caption}${reading}</div><div class="track" role="img" aria-label="${escape(shown(page, name))}"><span class="fill" style="width:calc(${(fraction * 100).toFixed(1)}% + ${(14 - fraction * 28).toFixed(1)}px)"></span><span class="thumb" style="left:calc(${(fraction * 100).toFixed(1)}% - ${(fraction * 28).toFixed(1)}px)"></span></div></div>`;
    }
  }
}

function equation(block: JsonObject, ref: string, page: Page): string {
  const calculated = ref ? page.equations[ref] : undefined;
  let body: string;
  let legend = list(block.items)
    .map(obj)
    .map((item) => ({ symbol: str(item.label), meaning: str(item.value) }));
  if (calculated) {
    body = `<div class="display">${math(calculated.equation, page.live, true)}</div>${calculated.worked ? `<div class="display worked">${math(calculated.worked, page.live, true)}</div>` : ""}`;
    legend = calculated.legend ?? [];
  } else {
    body = `<div class="display">${math(str(block.text), page.live, true)}</div>`;
  }
  const rows = legend.length > 1 || (legend.length === 1 && !calculated) ? `<dl class="legend-grid">${legend.map((item) => `<dt>${math(item.symbol, page.live)}</dt><dd>${rich(item.meaning, page.live)}</dd>`).join("")}</dl>` : "";
  return `<div class="block equation">${heading(block, page)}${body}${rows}</div>`;
}

/** A list's starting entries. The user's own entries never leave their phone. */
function collection(name: string, page: Page): string {
  const definition = named(page, "collections", name);
  if (!definition) return "";
  const fields = list(definition.fields).map(obj);
  const done = fields.filter((field) => field.type === "done");
  const check = done.length === 1 ? str(done[0].name) : "";
  const title = str((fields.find((field) => field.type === "text") ?? fields[0])?.name);
  const amount = str((fields.find((field) => field.type === "currency") ?? fields.find((field) => field.type === "number"))?.name);
  const starters = list(definition.starters).map(obj);
  const rows = starters
    .map((entry) => {
      const checked = check && (entry[check] === 1 || entry[check] === true);
      const value = amount ? entry[amount] : undefined;
      return `<li>${check ? `<span class="check${checked ? " on" : ""}"></span>` : ""}<span class="entry${checked ? " done" : ""}">${escape(str(entry[title]) || String(num(entry[title]) ?? ""))}</span>${typeof value === "number" ? `<span class="secondary number">${escape(value.toLocaleString(page.language))}</span>` : ""}</li>`;
    })
    .join("");
  const entries = str(definition.entry) || "entries";
  return `<div class="block"><h3>${escape(str(definition.label) || name)}</h3>${rows ? `<ul class="entries">${rows}</ul>` : `<p class="secondary">No ${escape(entries)} yet.</p>`}</div>`;
}

function sound(name: string, page: Page): string {
  const definition = named(page, "sounds", name);
  if (!definition) return "";
  const title = `<h4>${escape(str(definition.label) || name)}</h4>`;
  const recording = obj(definition.recording);
  const audio = str(recording.audioURL);
  if (audio.startsWith("https://upload.wikimedia.org/")) {
    const about = str(recording.pageURL);
    const credit = [str(recording.credit), str(recording.licence)].filter(Boolean).join(", ");
    const source = about.startsWith("https://commons.wikimedia.org/") ? `<a href="${escape(about)}">${escape(str(recording.title) || "Wikimedia Commons")}</a>` : escape(str(recording.title));
    return `${title}<audio controls preload="none" src="${escape(audio)}"></audio><p class="footnote">${source}${credit ? ` · ${escape(credit)}` : ""}</p>`;
  }
  return `${title}<div class="placeholder"><span class="mark"></span>A tone that follows the numbers. Play it in Dream.</div>`;
}

/** A diagram as the parts in order, joined the way the model joined them. */
function diagram(block: JsonObject, name: string, page: Page): string {
  const definition = named(page, "diagrams", name);
  if (!definition) return "";
  const nodes = list(definition.nodes).map(obj);
  if (!nodes.length) return "";
  const shape = str(definition.shape);
  let edges = list(definition.edges).map(obj);
  if (!edges.length && nodes.length > 1) {
    edges =
      shape === "flow" || shape === "cycle"
        ? nodes.slice(1).map((node, index) => ({ from: nodes[index].id, to: node.id, label: "" }))
        : nodes.slice(1).map((node) => ({ from: nodes[0].id, to: node.id, label: "" }));
    if (shape === "cycle") edges.push({ from: nodes[nodes.length - 1].id, to: nodes[0].id, label: "" });
  }
  const labelOf = (id: Any) => str(nodes.find((node) => node.id === id)?.label) || str(id);
  const node = (item: JsonObject) => `<div class="node"><strong>${escape(item.label)}</strong>${str(item.detail) ? `<span>${rich(item.detail, page.live)}</span>` : ""}</div>`;
  let body: string;
  if (shape === "hub" || shape === "tree") {
    const root = nodes[0];
    const children = edges.filter((edge) => edge.from === root.id);
    body = `${node(root)}<div class="branches">${children
      .map((edge) => {
        const child = nodes.find((item) => item.id === edge.to);
        return child ? `<div class="branch">${str(edge.label) ? `<em>${escape(edge.label)}</em>` : ""}${node(child)}</div>` : "";
      })
      .join("")}</div>`;
    const rest = nodes.filter((item) => item !== root && !children.some((edge) => edge.to === item.id));
    if (rest.length) {
      body += `<div class="branches">${rest
        .map((item) => {
          const parent = edges.find((edge) => edge.to === item.id);
          return `<div class="branch">${parent ? `<em>${escape(labelOf(parent.from))}</em>` : ""}${node(item)}</div>`;
        })
        .join("")}</div>`;
    }
  } else {
    body = nodes
      .map((item, index) => {
        const next = nodes[index + 1];
        const onward = edges.filter((edge) => edge.from === item.id);
        const toNext = next ? onward.find((edge) => edge.to === next.id) : undefined;
        const elsewhere = onward.filter((edge) => edge !== toNext && !(shape === "cycle" && index === nodes.length - 1 && edge.to === nodes[0].id));
        const arrow = next ? `<div class="arrow">${toNext && str(toNext.label) ? escape(toNext.label) : ""}</div>` : "";
        const branches = elsewhere.map((edge) => `<div class="aside">→ ${str(edge.label) ? `${escape(edge.label)}: ` : ""}${escape(labelOf(edge.to))}</div>`).join("");
        return node(item) + branches + arrow;
      })
      .join("");
    if (shape === "cycle" && nodes.length > 1) body += `<div class="arrow back">Back to ${escape(nodes[0].label)}</div>`;
  }
  return `<div class="block">${heading(block, page)}<div class="diagram ${escape(shape)}">${body}</div></div>`;
}
