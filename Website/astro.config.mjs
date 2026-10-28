// Dream's landing page: a static site, built to dist/.
import { defineConfig } from "astro/config";

export default defineConfig({
  site: "https://dream.onlychan.xyz",
  output: "static",
  // The dev toolbar loads its own scripts; the site needs none of it.
  devToolbar: { enabled: false },
  build: {
    // Small stylesheets go inline; the rest load from /_astro/.
    inlineStylesheets: "auto",
  },
});
