# App Store metadata (draft)

What to enter in App Store Connect for Dream's first release, and what to tell App Review. It's a
draft: placeholders are marked **[like this]**, and anything that depends on another workstream
says which. App Privacy answers are in [AppPrivacy.md](AppPrivacy.md).

Character limits are App Store Connect's. Check the counts again after editing.

## Name and identity

- **Display name on the phone:** Dream (`CFBundleDisplayName`, already set).
- **Store name** (30 at most). "Dream" on its own is almost certainly taken. In order of preference:
  1. Dream: pages for anything (25)
  2. Dream – ask, then play (22)
  3. Dream Pages (11)

  The store name and the display name can differ. Reserve the name early: creating the app record
  holds it.
- **Subtitle** (30 at most): Answers you can play with (25)
  - Alternatives: Ask once, get a living page (27); Pages that work things out (26).
- **Bundle ID:** `xyz.onlychan.Dream`. **SKU:** **[dream-ios-1]**.
- **Primary language:** English (U.S.). Adding English (U.K.) and English (India) later costs only
  the text below with local spelling.
- **Version:** 1.0, build number from 1 and up for every upload.
- **Copyright:** © 2026 **[legal name of the developer]**.

## Category

- **Primary: Productivity.** Most of what people make is something to use: splitting a bill, a
  budget with a monthly total, a trip plan with live weather and travel times, a grocery list.
- **Secondary: Education.** The other half is explaining: figures that move with sliders, diagrams,
  3D molecules, sounds, pages grounded in Wikipedia and the web with their sources.

Reference would also fit, but it's a smaller category with less browsing traffic.

## Promotional text (170 at most)

> Ask for anything, by typing, speaking or with a photo. Dream makes a page for it: one that
> explains, works it out, or both, with controls to play with. (151)

Promotional text can change without a new build, so it's the place for what's new.

## Description (4,000 at most)

> Ask for something, and Dream makes a page for it.
>
> Not a chat: a page. "Split a bill for five with a 12% tip" gives you sliders for the bill, the
> people and the tip, and the share for each person changes as you move them. "Why is the sky
> blue?" gives you a short explanation, a diagram and the source it came from. "A grocery list"
> gives you a list you can keep adding to.
>
> What a page can hold
> • Calculations with sliders, steppers and switches, and the result as you change them
> • Charts, and figures that move with the numbers, like a thrown ball's path
> • Diagrams of how things flow, cycle or branch
> • Molecules and simple shapes in 3D that you turn with a finger
> • Lists you keep, like groceries, expenses or habits, with totals and charts that add themselves up
> • Live values: the weather where you are, exchange rates, and travel times
> • Sounds: tones you can hear change, and real recordings
>
> Ask your way
> • Type, or tap the microphone and say it. Speech is turned into text on your iPhone.
> • Add a photo, like a receipt to add to your expenses or a plant you want to know about.
> • Change a page by saying what you want: "make it monthly", "add a price column".
> • Have a page read aloud, one step at a time when you're cooking or fixing something.
>
> Grounded, and honest about it
> Pages that state facts say where they came from: Wikipedia, or the web pages Dream read, with a
> link to each. AI can still get things wrong, so check anything important.
>
> Yours, and easy to share
> Your pages, lists and what Dream remembers about you are kept in your account, and you can see,
> change or delete what Dream remembers at any time. Share a page as a picture or a link that opens
> in Dream or in any browser. A shared page is blank by default; your numbers go only if you choose.
>
> Help improve Dream (crash reports and usage counts) is on once you sign in, as the line under
> Sign in with Apple says, and Account turns it off. It never sends what you ask or make.
>
> **[Subscription paragraph, once workstream D settles it: what's free, what the subscription adds,
> the price is shown in the app, it renews automatically unless cancelled at least 24 hours before
> the end of the period, and it's managed in Settings.]**
>
> Terms of use: https://dream.onlychan.xyz/terms
> Privacy policy: https://dream.onlychan.xyz/privacy

About 2,200 characters, leaving room for the subscription paragraph. Every feature listed is built
and merged (ROADMAP.md). Two things are deliberately left out until they've been tried by hand on a
device: connecting services such as Linear or Notion (MCP sign-in), and universal links. Add them
once they work.

## Keywords (100 at most)

```
calculator,explain,learn,math,physics,budget,split bill,grocery list,diagram,3d,weather,planner,ai
```

98 characters. No spaces after commas, no words already in the name or subtitle (they count
anyway), and no other companies' or models' names. Use "maths" in the U.K. and India localizations.

## URLs

- **Support URL:** https://dream.onlychan.xyz/support
- **Privacy policy URL:** https://dream.onlychan.xyz/privacy
- **Terms of use (EULA):** either Apple's standard EULA, or https://dream.onlychan.xyz/terms in the
  EULA field. For an auto-renewing subscription, guideline 3.1.2 needs working links to both the
  terms and the privacy policy in the metadata (the description, above) and inside the app, on the
  paywall (workstream D).
- **Marketing URL** (optional): none for now. **[A landing page at https://dream.onlychan.xyz/
  later.]**

All three pages are served by the Worker (Server/src/legal.ts), in Chandram Dutta's name as an
individual developer, with support@ and privacy@onlychan.xyz as contacts (Cloudflare Email
Routing). They were written without a lawyer; a one-time review is worth it once there's revenue
or an EU push.

## Screenshots

**Sizes.** One iPhone set is required: 6.9" (1320 × 2868 portrait, also accepted 1290 × 2796 and
1260 × 2736), or 6.5" (1284 × 2778 or 1242 × 2688) if there's no 6.9" set. App Store Connect
scales the set down for smaller iPhones. Dream is iPhone only, so no iPad set. **[Check the current
list in App Store Connect › Screenshot specifications before uploading.]**

**How to take them.** Run each request on a device with `Tools/device-tour.sh`, then pick the
frame. A 6.3" iPhone's screenshots (1206 × 2622) have the same proportions as 6.9" and can be
scaled up to 1320 × 2868 without distortion. Use made-up data only: no real names, places or
numbers from anyone's life. Light appearance, at a time of day whose home-screen colors suit the
set (they change through the day).

**Captions.** Short, sentence case, above the phone, on a field of the page's own colors. Eight
shots, in this order; the first three carry the listing, since search results show them.

| # | On screen | Caption |
|---|---|---|
| 1 | The home screen: the Aura at the top, a few ideas, a shelf of saved pages in their colors | Ask for anything. Get a page. |
| 2 | "Split a bill for 5 with a 12% tip": sliders for bill, people and tip, the share per person large | Pages that work it out |
| 3 | "Throw a ball at 20 m/s": the path drawn as a figure, mid-drag, with the range updating | Drag it and watch it change |
| 4 | "Caffeine molecule": the 3D ball-and-stick model, turned a little | See it in 3D |
| 5 | "Monthly expenses": the list, the month's total and the chart by category | Lists that add themselves up |
| 6 | "Weekend in Lisbon": live weather, travel time from the airport, the Apple Weather mark visible | Live weather, rates and travel times |
| 7 | A web-grounded page, like "Best budget phones this year", scrolled to its sources | Grounded in the web, with sources |
| 8 | The share sheet: Share link and Share picture, "Include my numbers" off | Share a page, not a chat |

Alternatives if one doesn't come out well: "How a bill becomes law" (diagram), "Why is the sky
blue?" (explanation with a Wikipedia image), "Read this recipe aloud" (hands-free steps).

## App preview video (optional)

15 to 25 seconds, recorded on the device, no voice-over, captions as above:

1. Type "split a bill for 5 with a 12% tip"; the Aura swirls while the page is made (sped up).
2. The page settles; a thumb drags the tip slider and the share per person changes.
3. Cut to the caffeine molecule turning under a finger.
4. Cut to the share sheet, then the same page in Safari.

Pages take 20 to 60 seconds to build. Speeding that part up is fine, but don't hide that it takes a
moment, or the review may call the preview misleading (guideline 2.3.4).

## Review notes

Paste into App Review Information › Notes, after filling in the placeholders:

> Dream makes an interactive page for whatever you ask: type a request on the home screen (or tap
> an idea), and a page appears in 20 to 60 seconds. The colored field at the top moves while it
> works.
>
> Sign-in: Dream uses Sign in with Apple only, so please sign in with your own Apple Account; no
> demo credentials are needed. **[Workstream A/D: confirm the free allowance covers a full review,
> at least 20 pages and 20 changes in a day, or that review accounts are given more.]**
>
> Pages are data, not code: the model returns a structured description (text, numbers, formulas,
> chart and figure definitions), which the app checks and draws with its own native views. No
> executable code is downloaded (guideline 2.5.2).
>
> Things to try:
> 1. "Split a bill for 5 with a 12% tip": move the sliders.
> 2. "Caffeine molecule": turn it with a finger.
> 3. "A grocery list": add "milk and eggs" in the bar at the bottom.
> 4. "What's the weather this weekend where I am?": Dream asks for your location, used only for
>    weather and travel times.
> 5. Long-press a block and say what to change, or tap the wand to change the whole page.
> 6. Share a page with the share button: a link opens in Dream or in any browser.
> 7. Account: **[where the account screen is]**, with export and delete (guideline 5.1.1(v)).
> 8. Subscription: **[where the paywall appears]**; it works with a sandbox account.
>
> Permissions, each asked only when it's first needed:
> - Location (when in use): the weather and travel times a page shows.
> - Microphone and speech recognition: asking out loud after tapping the microphone. Speech is
>   turned into text on the device.
> - Calendars (add only) and reminders: only when you tap a button on a page that says exactly
>   what it will add.
> - Photos: picked with the system photo picker, so Dream sees only the photo you choose; it's sent
>   with your request.
>
> AI and the web: pages are written by **[xAI's Grok]** through Dream's own server. Pages that
> state facts cite Wikipedia or the web pages that were read, and link to them; web text is shown
> as short excerpts and summaries, never as a browser. Nothing is sent to an AI provider before
> sign-in. The line under Sign in with Apple says that what you ask goes to Dream's AI providers,
> and that continuing agrees to the terms and privacy policy, which name xAI and list what it
> receives (guideline 5.1.2(i)).
>
> Shared pages: anyone with a link can view a shared page in Dream or on the web. Each one has a
> report button, reports reach a queue we review within **[24 hours]**, and pages can be taken down
> (guideline 1.2). **[Workstream C: how a reported sharer is blocked.]**
>
> Contact: **[name, email, phone]**.

## Age rating

Apple's questionnaire (updated in 2025, with 13+, 16+ and 18+ bands) asks about the content an app
can show, including what its AI can generate. Dream makes pages about whatever someone asks, so the
answers describe what a request can produce once the model's and Dream's own filters have run, not
what we hope people ask for.

| Question | Answer | Why |
|---|---|---|
| Cartoon or fantasy violence | None | Pages are explanations and tools, not stories or games. |
| Realistic violence | Infrequent / mild | History and news pages can describe wars or crimes, in an informational tone. |
| Prolonged graphic or sadistic violence | None | Should be refused by the model's instructions and server checks **[confirm with C/D]**. |
| Profanity or crude humor | Infrequent / mild | Someone can ask for it; pages are short and informational. |
| Mature or suggestive themes | Infrequent / mild | Health, relationships and history topics. |
| Horror or fear themes | None | |
| Sexual content or nudity | None | Must be refused; pictures come only from Wikimedia **[confirm the refusal is enforced, C/D]**. |
| Alcohol, tobacco or drug use or references | Infrequent / mild | Recipes and health information. |
| Medical or treatment information | Infrequent | Calculators like BMI or dosage by weight, and health explanations, with "check anything important". |
| Health or wellness topics | Yes | As above. |
| Simulated gambling | None | Odds and probability pages explain; nothing is wagered. |
| Contests | None | |
| Unrestricted web access | No | Dream shows short excerpts it read, with links that open in Safari; there's no browser in the app. |
| User-generated content | Yes | Shared pages can be viewed by anyone with the link; there's reporting and takedown. |
| Messaging and chat | No | People can't contact each other in Dream. |
| Advertising | No | |
| In-app controls (parental controls) | No | |
| Age assurance | No | **[Unless the accounts workstream adopts the Declared Age Range API.]** |

**Recommendation: 13+.** AI-made pages on any subject, grounded in open web results and shareable,
suit 13+ when sexual and graphic content is refused reliably and shared pages can be reported and
taken down. If the model's output isn't filtered on the server by launch (workstream C's check
before publishing, and D's proxy), answer the mature-content questions "Frequent" and take 16+, or
18+ if explicit content can get through. Dream's terms say 16+ everywhere, so the rating should
be 16+ at least. Chandram chose 16+ in India too, knowing the DPDP Act treats under-18s as
children needing a parent's consent; revisit if Dream grows there.

## Export compliance

Dream uses only the encryption built into iOS (HTTPS through URLSession, the Keychain, CryptoKit
hashing), which is exempt. `ITSAppUsesNonExemptEncryption` is NO in Config/Info.plist, so App Store
Connect won't ask on each upload. No documentation to file.

## Content rights

Answer "Yes, it contains third-party content, and I have the rights to use it":

- **Wikipedia text:** CC BY-SA 4.0; pages credit the article and link to it, with the licence named.
- **Wikimedia Commons images and recordings:** each file's free licence and author are shown.
- **Apple Weather:** the Apple Weather mark and its legal link appear wherever weather is shown,
  as WeatherKit's terms require.
- **Maps and travel times:** MapKit, under Apple's terms.
- **Molecules:** PubChem 3D conformers (public domain, from the U.S. National Library of Medicine).
- **Web pages:** short excerpts and summaries, each citing and linking its source.
  **[Legal review: quotation limits, and that Parallel's and xAI's terms allow a consumer app.]**

## In-app purchases

Workstream D owns these. **[Subscription group name; products with durations and prices; a free
trial or not; localized display names and descriptions; a review screenshot of the paywall; the
App Store Server Notifications v2 URL on the backend.]** The first subscription has to be
submitted together with a new app version.

## Before submitting

- [ ] Release build archived: Under the hood hidden, testing launch arguments ignored, no model
      traffic in the console (Dream/Engine/Build.swift).
- [ ] Privacy manifest included, and the App Privacy answers entered from AppPrivacy.md.
- [x] Privacy policy, terms and support pages written, with support@ and privacy@onlychan.xyz
  routed (no lawyer review yet; see above).
- [ ] Parallel's Data Processing Addendum signed, and whether shared pages may carry text made
  from its results (its terms keep each result for the one person who asked).
- [ ] Permission before a request first goes to the AI provider (5.1.2(i)): agreed at sign-in, with
  the providers named in the privacy policy (`SignInButton.agreement`). Decide whether review needs
  more than that.
- [ ] Sign in with Apple, account deletion in the app, Apple token revocation (A).
- [ ] Shared pages: report, takedown, a check before publishing, blocking abusive sharers (C).
- [ ] The free allowance is enough for a full review, and the subscription works in sandbox (D).
- [ ] Paywall: price, period, renewal terms, restore purchases, and links to terms and privacy (D).
- [ ] The production backend deployed, with D1 migrations applied and secrets set.
- [ ] Icon: Dream/Assets.xcassets/AppIcon (any, dark and tinted), regenerated with Tools/icon.sh.
- [ ] Screenshots for 6.9" and the app preview, if any.
- [ ] Age rating questionnaire, content rights, export compliance.
- [ ] EU Digital Services Act trader status declared (App Store Connect › Business); a trader's
      address, phone and email are shown on the EU storefronts.
- [ ] Paid Apps agreement, banking and tax forms (needed for the subscription).
- [ ] Availability: countries, and whether to launch in the EU and India before the legal review is
      done.
- [ ] TestFlight round on real devices first, including a fresh install and a sign-out.
