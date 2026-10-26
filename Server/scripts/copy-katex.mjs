// Copies KaTeX's stylesheet and fonts into public/katex, so the web viewer serves them itself
// rather than sending readers to a third-party CDN.
import { cpSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const katex = join(dirname(createRequire(import.meta.url).resolve("katex/package.json")), "dist");
const target = join(root, "public", "katex");

rmSync(target, { recursive: true, force: true });
mkdirSync(join(target, "fonts"), { recursive: true });
cpSync(join(katex, "katex.min.css"), join(target, "katex.min.css"));
// Every browser that runs the viewer reads woff2.
for (const font of readdirSync(join(katex, "fonts")).filter((name) => name.endsWith(".woff2"))) {
  cpSync(join(katex, "fonts", font), join(target, "fonts", font));
}
