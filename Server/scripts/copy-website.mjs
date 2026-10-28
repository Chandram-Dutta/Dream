// Builds the landing page (../Website) and copies it into public/, where Cloudflare serves it at
// "/" before the Worker runs. Anything without a file here (the API, shared links, the policy
// pages) still reaches the Worker, as before.
//
// It also writes public/_headers, since static files don't get the Worker's own headers: the
// page's security headers, as index.ts sends with its pages, with the hash of each inline
// script the build made; and long caching for the build's hashed files.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, existsSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const site = join(root, "..", "Website");
const dist = join(site, "dist");
const target = join(root, "public");

if (!existsSync(join(site, "node_modules"))) execFileSync("npm", ["ci"], { cwd: site, stdio: "inherit" });
execFileSync("npm", ["run", "build"], { cwd: site, stdio: "inherit" });

// The Worker's own files stay its own.
const ours = new Set(["robots.txt", "katex", "_headers"]);
const files = readdirSync(dist);
const clash = files.filter((name) => ours.has(name));
if (clash.length) throw new Error(`The website would replace the Worker's ${clash.join(", ")}`);

// What the last build copied goes first, so old hashed files don't pile up.
for (const name of [...files, "_astro"]) rmSync(join(target, name), { recursive: true, force: true });
for (const name of files) cpSync(join(dist, name), join(target, name), { recursive: true });

const page = readFileSync(join(dist, "index.html"), "utf8");
const scripts = [...page.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(
  ([, body]) => `'sha256-${createHash("sha256").update(body).digest("base64")}'`,
);
const csp = [
  "default-src 'none'",
  `script-src 'self' ${scripts.join(" ")}`.trim(),
  "style-src 'self' 'unsafe-inline'",
  "font-src 'self'",
  "img-src 'self'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
].join("; ");
const security = [
  `Content-Security-Policy: ${csp}`,
  "X-Content-Type-Options: nosniff",
  "Referrer-Policy: no-referrer",
  "Cross-Origin-Resource-Policy: same-origin",
  "X-Frame-Options: DENY",
];
const rule = (path, headers) => `${path}\n${headers.map((header) => `  ${header}`).join("\n")}\n`;
writeFileSync(
  join(target, "_headers"),
  [
    "# Written by scripts/copy-website.mjs on every build.",
    rule("/", security),
    rule("/index.html", security),
    rule("/_astro/*", ["Cache-Control: public, max-age=31536000, immutable", "X-Content-Type-Options: nosniff"]),
  ].join("\n"),
);
console.log(`Website copied into public/ (${files.length} entries, ${scripts.length} inline script hashed)`);
