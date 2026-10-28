# Dream's website

The landing page for Dream: a static [Astro](https://astro.build) site that builds to `dist/`.
It isn't deployed anywhere yet. The proposal for serving it at `https://dream.onlychan.xyz/` is
at the end.

## Build and preview

```sh
cd Website
npm ci
npm run dev        # http://localhost:4387, reloads as you edit
npm run build      # the site, in dist/
npm run preview    # serves dist/ on http://localhost:4387 (stop it with `npx astro preview stop`)
```

Versions are pinned exactly (Astro 7.3.8, Mona Sans 5.3.0 from Fontsource), and
`package-lock.json` is committed. Astro's telemetry is off in every script.

## What's on the page

The page is a Dream page. When it opens, it shows what using Dream is like. Nothing explains it
first:

1. The Aura fills the window in the time of day's colors, with the composer in the middle
   saying "Ask for anything".
2. "How far away is the horizon?" types itself in, and is sent. The composer rises to the top.
3. The Aura thinks: its lights speed up, swirl and brighten, turning the colors of the page to
   come.
4. The page forms on a frosted sheet, one block at a time, and works. Its slider moves the eye
   and the horizon in the figure, and works out the distance.

Then the visitor can ask for another page, from the buttons under the composer: splitting a
bill (a slider and a stepper), a grocery list (tick things off, add your own) or a pendulum (it
swings at the period shown, on Earth, the Moon or Mars). The bill is in the visitor's currency,
and distances are in miles where people use them, from the browser's language.

Below the first screen: one line on what Dream is, then six more requests, each with a still
glimpse of the page it makes (`src/components/Glimpses.astro`): looking things up with
sources, the weather where you are, asking before it answers, reading a photo and translating
it, a log that grows, and remembering you. The page talks about what Dream does; privacy, terms
and support are the links in the footer.

How it's built:

- **One typeface, Mona Sans, in two widths**, as the app uses SF Pro. Expanded (125%) when
  Dream speaks: titles, headings and big numbers. Normal for your words and for reading.
- **The app's own look.** iOS's system colors over white or black, the composer, the tinted
  panels, and iOS sliders, steppers and segmented controls (`src/styles/home.css`).
- **The Aura** (`src/scripts/aura.ts`) is the app's `Aura.swift`, full screen, in WebGL:
  wandering lights in three neighbouring hues of the page's color, and one that follows the
  pointer or a finger. It's fixed behind the window, so its size never changes as the page
  forms; the first screen scrolls over it and the rest of the page rises over it. It's drawn at
  a third of the screen's resolution, and stops when the first screen is off screen or the tab
  is hidden.
- **Motion is transforms and opacity only.** Nothing is tied to the scroll and nothing snaps.
  The opening is the one thing that moves by itself (`src/scripts/home.ts`).
- **Reduce Motion:** every page is simply there, and the Aura holds still.
- **Without script**, the horizon page is shown made, and everything else reads the same.
- **No trackers, no cookies, no third-party requests.**

### Where the facts come from

Keep these in step when the product changes:

| On the page | Source |
|---|---|
| Weather, logs with charts, asking first, photos, translation, web search with sources | the app's blocks and tools (`Dream/UI/Blocks`, `Dream/Generation`) |
| Remembering you, and seeing and changing what it knows | "What Dream knows" in the app (`Dream/UI/Memory`) |
| Type it, say it, or show it a photo | the composer (`Dream/UI/HomeView.swift`) |

### Open TODOs

- **App Store link.** `APP_STORE_URL` in `src/config.ts` is a placeholder until the app record
  exists. Until then the button says "Coming soon to the App Store" and links nowhere
  (`src/components/Get.astro`).
- **Share image.** `public/share.jpg` is the app icon. A proper 1200 × 630 card would look better
  in link previews.

## Proposal: serving it at dream.onlychan.xyz "/" (not done)

**Recommended: build it into the Worker's static assets.** The Worker already serves
`Server/public/` as static assets (`"assets": { "directory": "./public" }` in
`wrangler.jsonc`). Cloudflare answers a request from a file when one matches, before the
Worker runs. Anything without a file still reaches the Worker as it does now. That includes
`/api/*`, `/s/:id`, `/privacy`, `/terms`, `/support`, `/admin` and `/.well-known/*`. So:

1. Copy `Website/dist/` into `Server/public/` as part of the Worker's build. For example, a
   `Server/scripts/copy-website.mjs` that runs `npm ci && npm run build` in `../Website`, then
   copies `dist/*` across. Chain it after `copy-katex.mjs` in `wrangler.jsonc`'s
   `build.command`. Add the copied files to `Server/.gitignore`.
2. Nothing collides. The site writes `index.html`, `/_astro/*` (hashed), `favicon.png`,
   `apple-touch-icon.png`, `icon*.png` and `share.jpg`. The Worker's own files are `/katex/*`
   and `robots.txt`; the site has no `robots.txt`, so the Worker's stays.
3. `/` then serves `index.html`, using the default `html_handling`. The Worker's own "/"
   message page in `src/index.ts` is never reached and can go. Keep `not_found_handling` at its
   default, `none`, so unknown paths still fall through to the Worker's 404. If
   `run_worker_first` is ever turned on, the Worker has to hand `/` to the `ASSETS` binding.
4. Static assets don't get the Worker's security headers. Add a `Server/public/_headers` file
   (Workers Static Assets read it). For `/` and `/index.html`:
   `Content-Security-Policy: default-src 'none'; script-src 'self' 'sha256-…'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
   plus `X-Content-Type-Options: nosniff` and `Referrer-Policy: no-referrer`. For
   `/_astro/*`: `Cache-Control: public, max-age=31536000, immutable`. The page has one inline
   script, which sets the time-of-day color and marks that scripts run. Recompute its hash after any change to it:

   ```sh
   node -e 'const s=require("fs").readFileSync("dist/index.html","utf8").match(/<script>([\s\S]*?)<\/script>/)[1];console.log("sha256-"+require("crypto").createHash("sha256").update(s).digest("base64"))'
   ```

5. Deploy as usual (`npx wrangler deploy` from `Server/`). The landing page and the API ship
   together, so the site's numbers and the server's limits change in the same deploy.

**Alternative: a Cloudflare Pages project** for `Website/` on the same custom domain, with the
Worker on routes for `/api/*`, `/s/*`, `/privacy`, `/terms`, `/support`, `/admin*`,
`/reader` and `/.well-known/*`. That means two deployments and a list of routes to keep
complete, where a missing route breaks a live path. It's only worth it if the site starts to
change much more often than the server.
