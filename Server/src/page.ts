// The web viewer: a shared surface for people without Dream, rendered on the server as plain
// HTML and CSS. It reads like the app (Dream/UI/Theme.swift, SurfaceView.swift): the title in a
// wide face over a quiet field of the surface's colors, information as text on the page,
// calculations in tinted panels. There's no script, so the page's security policy allows none.

import { renderBlocks, type Equation, type Page } from "./blocks";
import type { Line } from "./charts";
import type { JsonObject } from "./payload";
import { accentOf, paletteCSS, themeColor } from "./palette";
import type { Stored } from "./store";
import { escape, plain, rich, type Live } from "./text";

const obj = (value: unknown): JsonObject => (value !== null && typeof value === "object" && !Array.isArray(value) ? (value as JsonObject) : {});
const strings = (value: unknown): Record<string, string> =>
  Object.fromEntries(Object.entries(obj(value)).filter((entry): entry is [string, string] => typeof entry[1] === "string"));

/** Images only ever come from Wikimedia, where the app found them; links go to Wikipedia, and to
 * the http(s) pages a surface cites. */
const isWikimediaImage = (url: unknown) => typeof url === "string" && /^https:\/\/upload\.wikimedia\.org\/[^\s"'<>]*$/.test(url);
const isWikipedia = (url: unknown) => typeof url === "string" && /^https:\/\/[a-z0-9-]+(\.m)?\.wikipedia\.org\/[^\s"'<>]*$/.test(url);

const INFORMATION = new Set(["paragraph", "facts", "bullets", "steps", "timeline", "stat", "equation", "data", "diagram"]);

export const CSP = "default-src 'none'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' https://upload.wikimedia.org; media-src https://upload.wikimedia.org; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
/** Pages with a form (reporting a page, and the admin's), which posts back to this server only. */
export const FORM_CSP = CSP.replace("form-action 'none'", "form-action 'self'");

/** The engine's working, as the app sent it; anything malformed is left out. */
function pageOf(stored: Stored): Page {
  const preview = obj(stored.preview);
  const live: Live = { values: strings(preview.values), tex: strings(preview.tex) };
  const equations: Record<string, Equation> = {};
  for (const [name, raw] of Object.entries(obj(preview.equations))) {
    const item = obj(raw);
    if (typeof item.equation !== "string") continue;
    const legend = Array.isArray(item.legend)
      ? item.legend.map(obj).flatMap((entry) => (typeof entry.symbol === "string" && typeof entry.meaning === "string" ? [{ symbol: entry.symbol, meaning: entry.meaning }] : []))
      : undefined;
    equations[name] = { equation: item.equation, worked: typeof item.worked === "string" ? item.worked : undefined, legend };
  }
  const charts: Record<string, { axis: string; lines: Line[] }> = {};
  for (const [id, raw] of Object.entries(obj(preview.charts))) {
    const chart = obj(raw);
    const lines = (Array.isArray(chart.lines) ? chart.lines : []).slice(0, 4).map(obj).map((line) => ({
      label: typeof line.label === "string" ? line.label : "",
      points: (Array.isArray(line.points) ? line.points : []).flatMap((point) =>
        Array.isArray(point) && point.length === 2 && typeof point[0] === "number" && typeof point[1] === "number" ? [[point[0], point[1]] as [number, number]] : [],
      ),
    }));
    charts[id] = { axis: typeof chart.axis === "string" ? chart.axis : "", lines };
  }
  const language = typeof obj(stored.surface.locale).language === "string" ? String(obj(stored.surface.locale).language) : "en";
  return { surface: stored.surface, live, equations, charts, values: stored.values ?? {}, language: /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,3}$/.test(language) ? language : "en" };
}

function hasInformation(blocks: unknown): boolean {
  return (Array.isArray(blocks) ? blocks : []).map(obj).some((block) => INFORMATION.has(String(block.kind)) || hasInformation(block.children));
}

export function surfacePage(stored: Stored, origin: string): string {
  const page = pageOf(stored);
  const surface = stored.surface;
  const accent = accentOf(surface.accent);
  const reference = obj(surface.reference);
  const informative = hasInformation(surface.blocks);
  const image = informative && isWikimediaImage(reference.imageURL) ? String(reference.imageURL) : undefined;
  const title = plain(surface.title, page.live) || "A shared screen";
  const summary = plain(surface.summary, page.live);
  const related = (Array.isArray(surface.related) ? surface.related : []).filter((topic): topic is string => typeof topic === "string" && topic.length > 0);
  const source = sourceNote(surface, informative);
  const rtl = /^(ar|he|fa|ur|ps|yi|dv)(-|$)/i.test(page.language);
  const url = `${origin}/s/${stored.id}`;

  return document({
    language: page.language,
    rtl,
    title,
    accent,
    head: `<meta name="description" content="${escape(summary)}">
<link rel="canonical" href="${escape(url)}">
<meta property="og:type" content="article">
<meta property="og:site_name" content="Dream">
<meta property="og:title" content="${escape(title)}">
<meta property="og:description" content="${escape(summary)}">
<meta property="og:url" content="${escape(url)}">
<meta name="robots" content="noindex">
${image ?`<meta property="og:image" content="${escape(image)}">` : ""}`,
    body: `<header>
<h1>${rich(surface.title, page.live)}</h1>
${surface.summary ? `<p class="summary">${rich(surface.summary, page.live)}</p>` : ""}
${stored.values ? `<p class="note">Shared with their numbers</p>` : ""}
</header>
${image ? `<img class="cover" src="${escape(image)}" alt="" loading="lazy" referrerpolicy="no-referrer">` : ""}
${renderBlocks(Array.isArray(surface.blocks) ? surface.blocks : [], page)}
${related.length ? `<div class="chips">${related.map((topic) => `<span class="chip">${escape(topic)}</span>`).join("")}</div>` : ""}
${source ? `<footer class="source">${source}</footer>` : ""}
<p class="report"><a href="/s/${escape(stored.id)}/report" rel="nofollow">Report this page</a></p>`,
    open: `dream://s/${stored.id}`,
  });
}

/** What a link that stopped says instead of its page. */
export function gonePage(state: "stopped" | "expired" | "removed"): string {
  switch (state) {
    case "removed":
      return messagePage("This page was removed", "It broke Dream's rules for shared pages.");
    case "expired":
      return messagePage("This page is no longer shared", "Its link was set to stop working after a while.");
    case "stopped":
      return messagePage("This page is no longer shared", "The person who shared it has stopped sharing it.");
  }
}

/** Why someone might report a page, in the order the form lists them. */
export const REPORT_REASONS: [string, string][] = [
  ["hate", "Hate or harassment"],
  ["sexual", "Sexual content"],
  ["violence", "Violence or threats"],
  ["private", "Someone's private information"],
  ["spam", "Spam or a scam"],
  ["other", "Something else"],
];

/** Reporting a page from the web viewer: a few reasons and a note, posted back without script. */
export function reportPage(id: string, title: string, problem?: string): string {
  const reasons = REPORT_REASONS.map(
    ([value, label], index) => `<label><input type="radio" name="reason" value="${value}"${index === 0 ? " required" : ""}> ${escape(label)}</label>`,
  ).join("\n");
  return formPage(
    "Report this page",
    `<header><h1>Report this page</h1><p class="summary">${escape(title)}</p></header>
<form class="form" method="post" action="/s/${escape(id)}/report">
<fieldset class="reasons"><legend>What's wrong with it?</legend>
${reasons}
</fieldset>
<label class="stack-tight"><span class="secondary">Anything else we should know (optional)</span>
<textarea name="note" rows="4" maxlength="500"></textarea></label>
${problem ? `<p class="problem">${escape(problem)}</p>` : ""}
<button class="button" type="submit">Send report</button>
<p class="footnote">Reports are anonymous. Nothing about you is kept.</p>
</form>`,
  );
}

/** A page around a form: the report form, and the admin's. `body` is HTML, already escaped. */
export function formPage(title: string, body: string): string {
  return document({ language: "en", rtl: false, title, accent: "indigo", head: `<meta name="robots" content="noindex">`, body });
}

interface Credit {
  site: string;
  title: string;
  url: string;
}

/** A web address a credit may link to: http or https, with no name or password in it. */
function webAddress(value: unknown): string | undefined {
  if (typeof value !== "string" || value.length > 2_000 || !/^https?:\/\/[^\s"'<>\\]+$/.test(value)) return undefined;
  try {
    const url = new URL(value);
    return (url.protocol === "https:" || url.protocol === "http:") && !url.username && !url.password ? url.href : undefined;
  } catch {
    return undefined;
  }
}

/** Who the facts came from, as the app's source note says it (Dream/UI/SourceNote.swift): the
 * Wikipedia article first, then every page cited, each site linked to its first page. */
function sourceNote(surface: JsonObject, informative: boolean): string {
  const reference = obj(surface.reference);
  const credits: Credit[] = [];
  const seen = new Set<string>();
  const add = (site: unknown, title: unknown, address: unknown) => {
    const url = webAddress(address);
    if (!url || credits.length >= 9) return;
    const key = url.replace(/^https?:\/\/(www\.)?/, "").replace(/#.*$/, "").replace(/\/+$/, "");
    if (seen.has(key)) return;
    seen.add(key);
    const host = new URL(url).hostname.replace(/^www\./, "");
    const name = typeof site === "string" && site.trim() ? site.trim().slice(0, 80) : host;
    credits.push({ site: name, title: typeof title === "string" && title.trim() ? title.trim().slice(0, 200) : name, url });
  };
  if (isWikipedia(reference.url)) add("Wikipedia", reference.title, reference.url);
  for (const citation of (Array.isArray(surface.citations) ? surface.citations : []).slice(0, 8).map(obj)) add(citation.site, citation.title, citation.url);

  if (!credits.length) return informative ? `<span>Written without a source. Check anything important.</span>` : "";
  const link = (credit: Credit, text: string) => `<a href="${escape(credit.url)}" title="${escape(credit.title)}" rel="nofollow noopener noreferrer">${escape(text)}</a>`;
  let line: string;
  if (credits.length === 1) {
    const [only] = credits;
    line = link(only, only.title === only.site ? only.site : `${only.site}: ${only.title}`);
  } else {
    const sites = credits.filter((credit, index) => credits.findIndex((other) => other.site === credit.site) === index);
    const links = sites.map((credit) => link(credit, credit.site));
    line = links.length === 1 ? links[0] : `${links.slice(0, -1).join(", ")} and ${links[links.length - 1]}`;
  }
  const wikipedia = credits.some((credit) => isWikipedia(credit.url));
  return `<p>From ${line}</p>${wikipedia ? `<span class="tertiary">Wikipedia text is available under CC BY-SA 4.0.</span>` : ""}`;
}

export function messagePage(title: string, message: string): string {
  return document({ language: "en", rtl: false, title, accent: "indigo", head: "", body: `<header><h1>${escape(title)}</h1><p class="summary">${escape(message)}</p></header>` });
}

function document(parts: { language: string; rtl: boolean; title: string; accent: string; head: string; body: string; open?: string }): string {
  return `<!doctype html>
<html lang="${escape(parts.language)}"${parts.rtl ? ' dir="rtl"' : ""}>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="${themeColor(parts.accent)}">
<meta name="referrer" content="no-referrer">
<title>${escape(parts.title)} · Dream</title>
${parts.head}
<link rel="stylesheet" href="/katex/katex.min.css">
<style>${paletteCSS(parts.accent)}${STYLE}</style>
</head>
<body>
<div class="aura" aria-hidden="true"></div>
<main>
${parts.body}
</main>
${
  parts.open
    ? `<nav class="open"><span><strong>Dream</strong><span class="secondary">Change the numbers, ask for more, keep it.</span></span><a class="button" href="${escape(parts.open)}">Open in Dream</a></nav>`
    : ""
}
</body>
</html>`;
}

const STYLE = `
:root{color-scheme:light dark;--bg:#fff;--label:#000;--secondary:rgba(60,60,67,.6);--tertiary:rgba(60,60,67,.3);--separator:rgba(60,60,67,.29);
--wash:color-mix(in srgb,var(--accent) 9%,transparent);--edge:color-mix(in srgb,var(--accent) 20%,transparent);
--gradient:linear-gradient(90deg,var(--accent),var(--companion));--number:linear-gradient(180deg,var(--accent),var(--companion));
--display:-apple-system,BlinkMacSystemFont,system-ui,"Segoe UI",Roboto,"Helvetica Neue",sans-serif}
@media (prefers-color-scheme:dark){:root{--bg:#000;--label:#fff;--secondary:rgba(235,235,245,.6);--tertiary:rgba(235,235,245,.3);--separator:rgba(84,84,88,.6)}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--label);font:17px/1.47 var(--display);overflow-x:hidden}
main{position:relative;max-width:640px;margin:0 auto;padding:0 20px calc(140px + env(safe-area-inset-bottom));display:flex;flex-direction:column;gap:26px}
.aura{position:absolute;inset:0 0 auto 0;height:620px;pointer-events:none;opacity:.55;
background:radial-gradient(55% 45% at 15% 0%,color-mix(in srgb,var(--accent) 70%,transparent),transparent 70%),
radial-gradient(50% 40% at 90% 8%,color-mix(in srgb,var(--companion) 60%,transparent),transparent 70%),
radial-gradient(80% 50% at 50% 35%,color-mix(in srgb,var(--accent) 22%,transparent),transparent 75%);
-webkit-mask-image:linear-gradient(#000,rgba(0,0,0,.7) 30%,transparent);mask-image:linear-gradient(#000,rgba(0,0,0,.7) 30%,transparent)}
header{padding-top:56px}
h1,h3,h4,.hero-value,.metric-value,.reading,.field,.stat-value,.when,.steps li::before{font-family:var(--display);font-stretch:125%}
h1{font-size:clamp(32px,8.5vw,42px);line-height:1.1;font-weight:650;margin:0 0 12px;letter-spacing:-.01em;overflow-wrap:anywhere}
.summary{font-size:20px;line-height:1.4;color:var(--secondary);margin:0}
.note{margin:12px 0 0;font-size:13px;color:var(--secondary)}
.note::before{content:"";display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--gradient);margin-inline-end:8px;vertical-align:1px}
h3{font-size:20px;line-height:1.25;font-weight:600;margin:0}
h3.instrument-title,h4{font-size:17px;font-weight:600;margin:0}
p{margin:0}
.secondary,.caption,dt{color:var(--secondary)}
.tertiary{color:var(--tertiary)}
.footnote{font-size:13px;color:var(--secondary);margin:8px 0 0}
a{color:var(--accent);text-decoration:none}
.block,.stack{display:flex;flex-direction:column;gap:8px}
.panel{padding:18px;background:var(--wash);border:.5px solid var(--edge);border-radius:28px}
.panel.stack{gap:18px}
hr{border:0;height:.5px;background:var(--edge);margin:0}
.number,.live{font-variant-numeric:tabular-nums}
.number{background:var(--number);-webkit-background-clip:text;background-clip:text;color:transparent}
.live{color:var(--accent);font-weight:600}
.cover{display:block;width:100%;height:220px;object-fit:cover;border-radius:28px;border:.5px solid var(--edge);background:#fff}
.hero .caption{font-size:15px;font-weight:500}
.hero-value{font-size:64px;line-height:1.1;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.metric .caption{font-size:15px}
.metric-value{font-size:24px;font-weight:600;font-variant-numeric:tabular-nums}
.row{display:flex;gap:10px}
.row .cell{flex:1;min-width:0}
.control{display:flex;flex-direction:column;gap:14px}
.inline{display:flex;justify-content:space-between;align-items:baseline;gap:12px}
.control.inline{align-items:center;flex-direction:row}
.stack-tight{display:flex;flex-direction:column;gap:4px}
.reading{font-size:20px;font-weight:600}
.track{position:relative;height:34px}
.track::before{content:"";position:absolute;left:0;right:0;top:13px;height:8px;border-radius:4px;background:color-mix(in srgb,var(--accent) 14%,transparent)}
.track .fill{position:absolute;left:0;top:13px;height:8px;border-radius:4px;background:var(--gradient)}
.track .thumb{position:absolute;top:3px;width:28px;height:28px;border-radius:50%;background:#fff;border:.5px solid color-mix(in srgb,var(--accent) 30%,transparent);box-shadow:0 2px 4px color-mix(in srgb,var(--accent) 35%,transparent)}
.switch{flex:none;position:relative;width:51px;height:31px;border-radius:16px;background:color-mix(in srgb,var(--label) 12%,transparent)}
.switch::after{content:"";position:absolute;top:2px;left:2px;width:27px;height:27px;border-radius:50%;background:#fff;box-shadow:0 2px 4px rgba(0,0,0,.2)}
.switch.on{background:var(--accent)}
.switch.on::after{left:22px}
.segments{display:flex;gap:4px;padding:4px;border-radius:999px;background:color-mix(in srgb,var(--accent) 10%,transparent)}
.segments span{flex:1;text-align:center;padding:10px 6px;border-radius:999px;font-size:15px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.segments .selected{background:var(--gradient);color:#fff}
.choice{color:var(--accent);font-weight:500}
.steppers{display:flex;gap:10px}
.steppers span{width:44px;height:44px;border-radius:50%;display:grid;place-items:center;font-size:20px;font-weight:700;color:var(--accent);background:color-mix(in srgb,var(--accent) 14%,transparent)}
.field{font-size:34px;font-weight:600;padding-bottom:6px;border-bottom:1px solid var(--edge)}
.facts{margin:0}
.facts div{display:flex;justify-content:space-between;align-items:baseline;gap:16px;padding:11px 0;border-bottom:.5px solid var(--separator)}
.facts div:last-child{border-bottom:0}
.facts dd{margin:0;font-weight:500;text-align:end}
.bullets,.steps,.timeline,.entries{list-style:none;margin:0;padding:0;display:flex;flex-direction:column}
.bullets{gap:12px}
.bullets li{position:relative;padding-inline-start:19px}
.bullets li::before{content:"";position:absolute;inset-inline-start:0;top:.62em;width:7px;height:7px;border-radius:50%;background:var(--gradient)}
.steps{gap:16px;counter-reset:step}
.steps li{position:relative;padding-inline-start:42px;min-height:28px;counter-increment:step}
.steps li::before{content:counter(step);position:absolute;inset-inline-start:0;top:-1px;width:28px;height:28px;border-radius:50%;background:var(--gradient);color:#fff;font-size:15px;font-weight:700;display:grid;place-items:center}
.timeline li{position:relative;padding-inline-start:27px;padding-bottom:20px;display:flex;flex-direction:column;gap:3px}
.timeline li:last-child{padding-bottom:0}
.timeline li::before{content:"";position:absolute;inset-inline-start:0;top:6px;width:11px;height:11px;border-radius:50%;background:var(--gradient)}
.timeline li:not(:last-child)::after{content:"";position:absolute;inset-inline-start:4.5px;top:19px;bottom:-2px;width:2px;background:color-mix(in srgb,var(--accent) 22%,transparent)}
.when{font-size:15px;font-weight:600;color:var(--accent)}
.stat{display:flex;flex-direction:column;gap:2px}
.stat+.stat{margin-top:12px}
.stat-value{font-size:46px;line-height:1.15;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.equation .display{overflow-x:auto;overflow-y:hidden;padding:2px 0}
.equation .katex-display{margin:0;text-align:start}
.equation .katex-display>.katex{text-align:start;font-size:1.3em}
.equation .worked{color:var(--accent)}
.legend-grid{display:grid;grid-template-columns:auto 1fr;gap:7px 14px;margin:6px 0 0;font-size:16px}
.legend-grid dt{color:var(--accent);text-align:end}
.legend-grid dd{margin:0;color:var(--secondary)}
code.tex{font-size:14px;color:var(--secondary);white-space:pre-wrap}
.chart{margin:0}
.chart svg{display:block;width:100%;height:auto;overflow:visible}
.chart text{font:11px var(--display);fill:var(--secondary)}
.chart .grid{stroke:var(--separator);stroke-width:.5}
.chart .line{fill:none;stroke-width:2.5;stroke-linecap:round;stroke-linejoin:round}
.chart .line-1{stroke:var(--companion);stroke-width:2;stroke-dasharray:5 4}
.chart .line-2{stroke:var(--secondary);stroke-width:2;stroke-dasharray:5 4}
.chart .line-3{stroke:var(--tertiary);stroke-width:2;stroke-dasharray:5 4}
.stop-accent{stop-color:var(--accent)}
.stop-companion{stop-color:var(--companion)}
.chart figcaption{text-align:center;font-size:13px;color:var(--secondary);margin-top:4px}
.legend{list-style:none;margin:8px 0 0;padding:0;display:flex;flex-wrap:wrap;gap:6px 16px;font-size:13px;color:var(--secondary)}
.legend li::before{content:"";display:inline-block;width:16px;height:0;border-top:2.5px solid var(--accent);vertical-align:middle;margin-inline-end:6px}
.legend .key-1::before{border-top:2px dashed var(--companion)}
.legend .key-2::before{border-top:2px dashed var(--secondary)}
.legend .key-3::before{border-top:2px dashed var(--tertiary)}
.bars{display:grid;grid-template-columns:minmax(0,max-content) 1fr;gap:10px 12px;align-items:center}
.bar{display:contents}
.bar-label{font-size:15px;color:var(--secondary);max-width:40vw;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.bar-track{display:flex;align-items:center;gap:6px;min-width:0}
.bar-fill{height:16px;border-radius:8px;background:var(--gradient)}
.bar-value{font-size:12px;font-weight:600;color:var(--secondary);font-variant-numeric:tabular-nums;white-space:nowrap}
.entries li{display:flex;align-items:center;gap:12px;padding:11px 0;border-bottom:.5px solid var(--separator)}
.entries li:last-child{border-bottom:0}
.entries .entry{flex:1}
.entries .entry.done{color:var(--secondary);text-decoration:line-through}
.check{flex:none;width:22px;height:22px;border-radius:50%;border:1.5px solid color-mix(in srgb,var(--accent) 60%,transparent)}
.check.on{border:0;background:var(--gradient)}
.diagram{display:flex;flex-direction:column;align-items:stretch;gap:0}
.node{padding:12px 16px;border-radius:18px;background:var(--wash);border:.5px solid var(--edge);display:flex;flex-direction:column;gap:2px}
.node span{font-size:15px;color:var(--secondary)}
.arrow{align-self:center;display:flex;flex-direction:column;align-items:center;font-size:13px;color:var(--secondary);padding:4px 0}
.arrow::before{content:"";width:2px;height:16px;background:var(--gradient)}
.arrow::after{content:"";width:0;height:0;border:5px solid transparent;border-top:6px solid var(--companion);border-bottom:0}
.arrow.back{flex-direction:row;gap:6px}
.arrow.back::before{content:"↺";width:auto;height:auto;background:none;color:var(--accent);font-size:16px}
.arrow.back::after{display:none}
.aside{font-size:13px;color:var(--secondary);padding:4px 16px 0}
.branches{display:flex;flex-wrap:wrap;gap:10px;margin-top:10px;padding-inline-start:16px;border-inline-start:2px solid color-mix(in srgb,var(--accent) 22%,transparent)}
.branch{flex:1 1 140px;display:flex;flex-direction:column;gap:4px}
.branch em{font-style:normal;font-size:13px;color:var(--secondary)}
.placeholder{display:flex;align-items:center;gap:10px;color:var(--secondary);font-size:15px}
.placeholder .mark{flex:none;width:10px;height:10px;border-radius:50%;background:var(--gradient)}
audio{width:100%;margin-top:4px}
.chips{display:flex;flex-wrap:wrap;gap:8px}
.chip{padding:10px 15px;border-radius:999px;background:var(--wash);border:.5px solid var(--edge);font-size:15px;font-weight:500}
.source{display:flex;flex-direction:column;gap:4px;font-size:13px;color:var(--secondary)}
.open{position:fixed;left:16px;right:16px;bottom:calc(12px + env(safe-area-inset-bottom));max-width:600px;margin:0 auto;display:flex;align-items:center;justify-content:space-between;gap:12px;padding:8px 8px 8px 18px;border-radius:26px;border:.5px solid var(--edge);background:color-mix(in srgb,var(--bg) 72%,transparent);-webkit-backdrop-filter:blur(20px) saturate(1.8);backdrop-filter:blur(20px) saturate(1.8);box-shadow:0 8px 30px rgba(0,0,0,.08)}
.open>span{display:flex;flex-direction:column;font-size:13px;line-height:1.3;min-width:0}
.open strong{font-family:var(--display);font-stretch:125%;font-size:15px}
.button{flex:none;padding:12px 18px;border-radius:999px;background:var(--gradient);color:#fff;font-weight:600;font-size:15px}
.report{font-size:13px;margin:-8px 0 0}
.report a{color:var(--secondary);text-decoration:underline;text-underline-offset:2px}
.form{display:flex;flex-direction:column;gap:18px}
fieldset{border:0;margin:0;padding:0;display:flex;flex-direction:column}
legend{padding:0;margin-bottom:4px;font-weight:600}
.reasons label{display:flex;align-items:center;gap:12px;padding:12px 0;border-bottom:.5px solid var(--separator)}
.reasons label:last-child{border-bottom:0}
input[type=radio]{accent-color:var(--accent);width:20px;height:20px;margin:0}
input[type=password],input[type=text],textarea{width:100%;font:inherit;color:var(--label);background:var(--wash);border:.5px solid var(--edge);border-radius:16px;padding:12px 14px}
button.button{border:0;font-family:inherit;cursor:pointer;align-self:flex-start}
button.quiet{background:var(--wash);color:var(--accent)}
.problem{color:#c93400;font-size:15px}
.case{padding:18px;border-radius:24px;background:var(--wash);border:.5px solid var(--edge);display:flex;flex-direction:column;gap:8px}
.case h3 a{color:var(--label)}
.actions{display:flex;flex-wrap:wrap;gap:8px;margin-top:6px}
.actions form{margin:0}
.notes{margin:0;padding-inline-start:18px;color:var(--secondary);font-size:15px}
@media (max-width:380px){.open>span .secondary{display:none}.hero-value{font-size:52px}}
`;
