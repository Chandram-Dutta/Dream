// Text as the app shows it: prose with live values (`{name}`) and maths (`$...$`), ported from
// TeX.segments and Placeholders in the app (Dream/Engine/TeX.swift, Formatting.swift), with
// maths typeset by KaTeX on the server so the page needs no script.

import katex from "katex";

/** Everything from a shared surface is untrusted; nothing reaches the page unescaped. */
export function escape(value: unknown): string {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

type Segment = { math: string } | { text: string };

/** Splits text into prose and maths, the way the app does: `$...$`, `$$...$$`, `\(...\)` and
 * `\[...\]`. A `$` opens maths only before a non-space and closes it only after a non-space and
 * before a non-digit, so "$5 to $10" stays prose. */
export function segments(raw: string): Segment[] {
  if (!raw.includes("$") && !raw.includes("\\(") && !raw.includes("\\[")) return [{ text: raw }];
  const characters = Array.from(raw.replaceAll("\f", "\\f").replaceAll("\b", "\\b").replaceAll("\t", "\\t"));
  const result: Segment[] = [];
  let prose = "";
  let index = 0;
  const at = (position: number) => characters[position];
  const find = (marker: string, from: number) => {
    const wanted = Array.from(marker);
    for (let position = from; position + wanted.length <= characters.length; position++) {
      if (wanted.every((character, offset) => characters[position + offset] === character)) return position;
    }
    return -1;
  };
  const math = (start: number, end: number, next: number) => {
    if (prose) result.push({ text: prose });
    prose = "";
    result.push({ math: repaired(characters.slice(start, end).join("")) });
    index = next;
  };
  while (index < characters.length) {
    const character = characters[index];
    if (character === "\\" && at(index + 1) === "$") {
      prose += "$";
      index += 2;
      continue;
    }
    if (character === "\\" && (at(index + 1) === "(" || at(index + 1) === "[")) {
      const end = find(at(index + 1) === "(" ? "\\)" : "\\]", index + 2);
      if (end >= 0) {
        math(index + 2, end, end + 2);
        continue;
      }
    }
    if (character === "$") {
      if (at(index + 1) === "$") {
        const end = find("$$", index + 2);
        if (end > index + 2) {
          math(index + 2, end, end + 2);
          continue;
        }
      }
      const next = at(index + 1);
      if (next !== undefined && !/\s/.test(next)) {
        let end = -1;
        for (let position = index + 1; position < characters.length; position++) {
          const candidate = characters[position];
          if (candidate === "\n" && at(position + 1) === "\n") break;
          if (candidate === "$" && characters[position - 1] !== "\\" && !/\s/.test(characters[position - 1]) && !/[0-9]/.test(at(position + 1) ?? "")) {
            end = position;
            break;
          }
        }
        if (end >= 0) {
          math(index + 1, end, end + 1);
          continue;
        }
      }
    }
    prose += character;
    index++;
  }
  if (prose) result.push({ text: prose });
  return result;
}

/** JSON reads `\f`, `\b` and friends in maths as control characters; put them back. */
function repaired(tex: string): string {
  let result = "";
  const characters = Array.from(tex);
  characters.forEach((character, index) => {
    if (character === "\f") result += "\\f";
    else if (character === "\b") result += "\\b";
    else if (character === "\t") result += "\\t";
    else if (character === "\r") result += "\\r";
    else if (character === "\n") result += /\p{L}/u.test(characters[index + 1] ?? " ") ? "\\n" : " ";
    else result += character;
  });
  return result.trim();
}

/** Values and maths a page fills its text with, worked out by the app's engine. */
export interface Live {
  /** Each input and output as shown, like "₹2,400" or "9.8 m/s²". */
  values: Record<string, string>;
  /** Each as maths, for `\val{name}` in LaTeX. */
  tex: Record<string, string>;
}

/** LaTeX with each `\val{name}` replaced by its value. */
export function filled(tex: string, live: Live): string {
  return tex.replace(/\\val(?:ue)?\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}/g, (_, name: string) => live.tex[name] ?? `\\text{${name}}`);
}

/** Maths as HTML. KaTeX escapes what it's given and, without `trust`, refuses links and
 * anything else that could reach outside the page. */
export function math(tex: string, live: Live, display = false): string {
  try {
    return katex.renderToString(filled(tex, live), { displayMode: display, throwOnError: true, trust: false, strict: "ignore", maxSize: 20, maxExpand: 300, output: "htmlAndMathml" });
  } catch {
    return `<code class="tex">${escape(tex)}</code>`;
  }
}

/** Prose with live values and inline maths. */
export function rich(raw: unknown, live: Live): string {
  if (typeof raw !== "string" || !raw) return "";
  return segments(raw)
    .map((segment) => {
      if ("math" in segment) return math(segment.math, live);
      return segment.text.replace(/\{([^{}]*)\}|([^{]+|\{)/g, (whole, name: string | undefined) => {
        if (name === undefined) return escape(whole);
        const trimmed = name.trim();
        if (!trimmed) return "{}";
        const value = live.values[trimmed];
        return value === undefined ? escape(trimmed) : `<b class="live">${escape(value)}</b>`;
      });
    })
    .join("");
}

/** Plain text with maths and placeholders left out, for titles and link previews. */
export function plain(raw: unknown, live: Live): string {
  if (typeof raw !== "string") return "";
  return segments(raw)
    .map((segment) => ("math" in segment ? segment.math : segment.text.replace(/\{([^{}]*)\}/g, (_, name: string) => live.values[name.trim()] ?? name.trim())))
    .join("")
    .replace(/\s+/g, " ")
    .trim();
}
