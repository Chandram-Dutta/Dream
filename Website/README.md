# Dream's website

The landing page for Dream: a static [Astro](https://astro.build) site that builds to `dist/`.
It's served at `https://dream.onlychan.xyz/` by the Worker (`Server/`), and ships with it: see
the end.

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

## How it's served

The Worker (`Server/`) serves the site from its static assets, so the landing page and the API
ship in the same deploy (`npx wrangler deploy` from `Server/`):

- **`Server/scripts/copy-website.mjs`** runs in the Worker's build (`wrangler.jsonc`, after
  `copy-katex.mjs`), before every `wrangler dev` and deploy. It builds this site (installing
  its packages first if they're missing), then copies `dist/` into `Server/public/`, removing
  what the last build copied. The copies are in `Server/.gitignore`. It refuses to replace the
  Worker's own `robots.txt`, `katex/` or `_headers`.
- **Cloudflare answers a request from a file when one matches, before the Worker runs.** `/` is
  `index.html`. Anything without a file still reaches the Worker as before: `/api/*`, `/s/:id`,
  `/privacy`, `/terms`, `/support`, `/admin` and `/.well-known/*`. The Worker's own `/` page in
  `src/index.ts` is only reached if a build ever leaves the site out.
- **Headers.** Static files don't get the Worker's headers, so the script also writes
  `Server/public/_headers`. For `/` and `/index.html`, it sends the same security headers as the
  Worker's own pages. That includes a Content Security Policy with the hash of each inline
  script it finds in the built page, so changing the time-of-day script needs nothing by hand.
  For `/_astro/*`, which are hashed files, it sets a year's immutable caching.
