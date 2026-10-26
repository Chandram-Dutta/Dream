// Charts as inline SVG and plain HTML: a calculation's curves (the points worked out by the app),
// and a data block's real figures, as bars or, for years, a line over time.

import { escape } from "./text";

export interface Line {
  label: string;
  points: [number, number][];
}

const WIDTH = 320;
const HEIGHT = 180;
const MARGIN = { left: 44, right: 12, top: 12, bottom: 26 };

function compact(value: number, language: string): string {
  try {
    return new Intl.NumberFormat(language, { notation: "compact", maximumFractionDigits: 2 }).format(value);
  } catch {
    return String(Math.round(value * 100) / 100);
  }
}

/** Bounds with a little room, so a flat line still has somewhere to sit. */
function extent(values: number[]): [number, number] {
  let low = Math.min(...values);
  let high = Math.max(...values);
  if (low === high) {
    const pad = Math.abs(low) * 0.1 || 1;
    low -= pad;
    high += pad;
  }
  return [low, high];
}

let charts = 0;

function frame(lines: Line[], language: string, axis: string, area: boolean, xLabel?: (x: number) => string): string {
  const id = `c${++charts}`;
  const all = lines.flatMap((line) => line.points);
  const [x0, x1] = extent(all.map(([x]) => x));
  let [y0, y1] = extent(all.map(([, y]) => y));
  // Amounts read best from zero.
  if (y0 > 0 && y0 < y1 * 0.5) y0 = 0;
  const sx = (x: number) => MARGIN.left + ((x - x0) / (x1 - x0)) * (WIDTH - MARGIN.left - MARGIN.right);
  const sy = (y: number) => HEIGHT - MARGIN.bottom - ((y - y0) / (y1 - y0)) * (HEIGHT - MARGIN.top - MARGIN.bottom);
  const paths = lines
    .map((line, index) => {
      const d = line.points.map(([x, y], i) => `${i ? "L" : "M"}${sx(x).toFixed(1)} ${sy(y).toFixed(1)}`).join("");
      const fill = area && index === 0 ? `<path d="${d}L${sx(line.points.at(-1)![0]).toFixed(1)} ${sy(y0).toFixed(1)}L${sx(line.points[0][0]).toFixed(1)} ${sy(y0).toFixed(1)}Z" fill="url(#${id}-fill)"/>` : "";
      const stroke = index ? `class="line line-${index % 4}"` : `class="line" stroke="url(#${id}-stroke)"`;
      return `${fill}<path d="${d}" ${stroke}/>`;
    })
    .join("");
  const grid = [y0, (y0 + y1) / 2, y1]
    .map((y) => `<line x1="${MARGIN.left}" x2="${WIDTH - MARGIN.right}" y1="${sy(y).toFixed(1)}" y2="${sy(y).toFixed(1)}" class="grid"/><text x="${MARGIN.left - 6}" y="${(sy(y) + 4).toFixed(1)}" text-anchor="end">${escape(compact(y, language))}</text>`)
    .join("");
  const label = xLabel ?? ((x: number) => compact(x, language));
  const ticks = `<text x="${MARGIN.left}" y="${HEIGHT - 6}" text-anchor="start">${escape(label(x0))}</text><text x="${WIDTH - MARGIN.right}" y="${HEIGHT - 6}" text-anchor="end">${escape(label(x1))}</text>`;
  const title = lines.map((line) => line.label).join(", ");
  return `<figure class="chart"><svg viewBox="0 0 ${WIDTH} ${HEIGHT}" role="img" aria-label="${escape(title)}${axis ? ` along ${escape(axis)}` : ""}">
<defs><linearGradient id="${id}-stroke" gradientUnits="userSpaceOnUse" x1="${MARGIN.left}" x2="${WIDTH - MARGIN.right}" y1="0" y2="0"><stop offset="0" class="stop-accent"/><stop offset="1" class="stop-companion"/></linearGradient>
<linearGradient id="${id}-fill" x1="0" x2="0" y1="0" y2="1"><stop offset="0" class="stop-companion" stop-opacity="0.28"/><stop offset="1" class="stop-accent" stop-opacity="0.02"/></linearGradient></defs>
${grid}${paths}${ticks}</svg>${axis ? `<figcaption>${escape(axis)}</figcaption>` : ""}${lines.length > 1 ? legend(lines) : ""}</figure>`;
}

function legend(lines: Line[]): string {
  return `<ul class="legend">${lines.map((line, index) => `<li class="key-${index % 4}">${escape(line.label)}</li>`).join("")}</ul>`;
}

/** A calculation's chart: each output along the input it runs over. */
export function curveChart(lines: Line[], axis: string, language: string): string {
  const drawable = lines.filter((line) => line.points.length > 1);
  return drawable.length ? frame(drawable, language, axis, drawable.length === 1) : "";
}

/** A data block: a line over time when every label is a year in order, otherwise bars. */
export function dataChart(points: { label: string; value: number }[], language: string): string {
  if (!points.length) return "";
  const years = points.map((point) => Number(point.label.trim()));
  const overTime = points.length >= 3 && years.every((year) => Number.isFinite(year)) && years.every((year, i) => i === 0 || year >= years[i - 1]);
  if (overTime) {
    return frame([{ label: "", points: points.map((point, i) => [years[i], point.value]) }], language, "", true, (x) => String(Math.round(x)));
  }
  const largest = Math.max(...points.map((point) => Math.abs(point.value)), 1e-9);
  return `<div class="bars">${points
    .map(
      (point) =>
        `<div class="bar"><span class="bar-label">${escape(point.label)}</span><span class="bar-track"><span class="bar-fill" style="width:${Math.max(2, (Math.abs(point.value) / largest) * 100).toFixed(1)}%"></span><span class="bar-value">${escape(compact(point.value, language))}</span></span></div>`,
    )
    .join("")}</div>`;
}
